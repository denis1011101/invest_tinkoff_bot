"""Event-order tests on synthetic candles. Run: python3 -m unittest discover tools/backtest/tests"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sim  # noqa: E402

DATES = [f"2025-01-{d:02d}" for d in range(1, 21)]
SIGNAL = DATES[8]   # day whose bar carries the entry signal
TRADE = DATES[9]    # day the next_open entry fills


def bar(d, o, h, l, c, value=1e6):
    return {"TRADEDATE": d, "OPEN": o, "HIGH": h, "LOW": l, "CLOSE": c, "VALUE": value}


def flat(d, p=100.0):
    return bar(d, p, p, p, p)


def side_index():
    # alternating closes: never three rises or falls in a row -> trend "side" from day 4 on
    return [flat(d, 1000 + (i % 2)) for i, d in enumerate(DATES)]


def buy_candidate(overrides=None):
    """Ticker X: four rising closes, then a 1% dip on SIGNAL -> strict3 + dip pass for next_open on TRADE."""
    bars = []
    for i, d in enumerate(DATES):
        p = 90.0 + i  # strictly rising closes
        bars.append(bar(d, p, p, p, p))
    i = DATES.index(SIGNAL)
    bars[i] = bar(SIGNAL, 99.0, 100.0, 98.0, 99.5)
    for j in range(i + 1, len(DATES)):
        bars[j] = flat(DATES[j], 100.0)
    for d, b in (overrides or {}).items():
        bars[DATES.index(d)] = b
    return bars


def up_index():
    return [flat(d, 1000 + i) for i, d in enumerate(DATES)]


def market(series, fund=None, index=None):
    return sim.Market(series, {t: 1 for t in series}, index or side_index(), fund_bars=fund,
                      up_tickers=[], intersection=["X"] if "X" in series else [])


class EventOrderTest(unittest.TestCase):
    def trades_on(self, result, day, side=None):
        return [t for t in result["trades"] if t[0] == day and (side is None or t[1] == side)]

    @mock.patch.object(sim, "MAX_POS_SHARE", 1.01)
    @mock.patch.object(sim, "MAX_SHARES_SHARE", 1.01)
    def test_open_buy_is_not_funded_by_a_later_intraday_sale(self):
        # Y is held at avg 100 and reaches +4% only during TRADE; at the open only 14.70 is free.
        # Share limits are lifted so that only money can stop the buy.
        y = [flat(d, 100.0) for d in DATES]
        y[DATES.index(TRADE)] = bar(TRADE, 100.0, 110.0, 100.0, 105.0)
        m = market({"X": buy_candidate(), "Y": y})
        held = {"Y": {"qty": 1, "avg": 100.0}}  # the sale closes Y, so no exposure guard can block X
        rich = sim.run(m, DATES[5], DATES[-1], capital=1000.0, positions=held)
        self.assertEqual([t[2] for t in self.trades_on(rich, TRADE, "BUY")], ["X"])  # the signal exists
        r = sim.run(m, DATES[5], DATES[-1], capital=14.70, positions=held)
        self.assertEqual(self.trades_on(r, TRADE, "BUY"), [])
        sells = self.trades_on(r, TRADE, "SELL")
        self.assertEqual([(s[2], s[4], s[5]) for s in sells], [("Y", 104.0, "tp+4")])

    def test_position_bought_at_open_is_stopped_out_the_same_day(self):
        x = buy_candidate({TRADE: bar(TRADE, 100.0, 101.0, 80.0, 85.0)})
        for kw, reason in (({"trail": 0.10}, "trail"), ({"sl": 0.10}, "stop")):
            r = sim.run(market({"X": x}), DATES[5], DATES[-1], **kw)
            day = self.trades_on(r, TRADE)
            self.assertEqual([(t[1], t[4]) for t in day], [("BUY", 100.0), ("SELL", 90.0)], kw)
            self.assertEqual(day[1][5], reason)

    def test_gap_below_the_stop_fills_at_the_open(self):
        y = [flat(d, 100.0) for d in DATES]
        y[10] = bar(DATES[10], 80.0, 82.0, 79.0, 81.0)
        r = sim.run(market({"Y": y}), DATES[5], DATES[-1], sl=0.10, positions={"Y": {"qty": 1, "avg": 100.0}})
        self.assertEqual([(t[1], t[4], t[5]) for t in r["trades"]], [("SELL", 80.0, "stop")])

    def test_stop_wins_when_stop_and_target_are_both_touched(self):
        y = [flat(d, 100.0) for d in DATES]
        y[10] = bar(DATES[10], 100.0, 112.0, 85.0, 100.0)
        r = sim.run(market({"Y": y}), DATES[5], DATES[-1], sl=0.10, positions={"Y": {"qty": 1, "avg": 100.0}})
        self.assertEqual([(t[4], t[5]) for t in r["trades"]], [(90.0, "stop")])

    def test_targets_fill_in_price_order_not_by_the_days_high(self):
        # avg 100, 3 lots: a high of 109 and a high of 112 must share the first fill at +4%
        held = {"Y": {"qty": 3, "avg": 100.0}}
        fills = {}
        for high in (109.0, 112.0):
            y = [flat(d, 100.0) for d in DATES]
            y[10] = bar(DATES[10], 100.0, high, 100.0, 100.0)
            r = sim.run(market({"Y": y}), DATES[5], DATES[10], positions=held)
            fills[high] = [(t[3], t[4], t[5]) for t in r["trades"]]
        self.assertEqual(fills[109.0], [(1, 104.0, "tp+4")])
        self.assertEqual(fills[112.0], [(1, 104.0, "tp+4"), (2, 110.0, "force+10")])

    def test_up_trend_has_only_the_force_exit(self):
        held = {"Y": {"qty": 3, "avg": 100.0}}
        for high, expected in ((109.0, []), (112.0, [(3, 110.0, "force+10")])):
            y = [flat(d, 100.0) for d in DATES]
            y[10] = bar(DATES[10], 100.0, high, 100.0, 100.0)
            r = sim.run(market({"Y": y}, index=up_index()), DATES[5], DATES[10], positions=held)
            self.assertEqual([(t[3], t[4], t[5]) for t in r["trades"]], expected)

    def test_trailing_peak_uses_highs_up_to_the_previous_day(self):
        y = [flat(d, 100.0) for d in DATES]
        y[10] = bar(DATES[10], 100.0, 120.0, 100.0, 118.0)  # new peak 120, low 100 > 90
        y[11] = bar(DATES[11], 118.0, 118.0, 107.0, 110.0)  # stop now 108 -> sold at 108
        r = sim.run(market({"Y": y}), DATES[5], DATES[-1], trail=0.10, positions={"Y": {"qty": 1, "avg": 100.0}})
        self.assertEqual([(t[0], t[4]) for t in r["trades"]], [(DATES[11], 108.0)])

    def test_next_open_ignores_a_dip_that_happens_on_the_fill_day(self):
        x = buy_candidate()
        i = DATES.index(SIGNAL)
        x[i] = flat(SIGNAL, 99.0)                               # no dip on the signal bar
        x[i + 1] = bar(TRADE, 100.0, 100.0, 95.0, 96.0)         # dip only on the fill day
        r = sim.run(market({"X": x}), DATES[5], TRADE)
        self.assertEqual(self.trades_on(r, TRADE, "BUY"), [])

    def test_close_entry_is_not_exit_checked_on_its_own_day(self):
        x = buy_candidate({SIGNAL: bar(SIGNAL, 99.0, 100.0, 70.0, 99.5)})  # low far below any stop
        r = sim.run(market({"X": x}), DATES[5], SIGNAL, entry="close", sl=0.10)
        self.assertEqual([(t[1], t[4]) for t in r["trades"]], [("BUY", 99.5)])


class ReturnTest(unittest.TestCase):
    def test_starting_positions_count_in_the_starting_value(self):
        r = sim.run(market({"Y": [flat(d, 100.0) for d in DATES]}), DATES[5], DATES[-1],
                    capital=100.0, positions={"Y": {"qty": 1, "avg": 100.0}})
        self.assertEqual(r["trades"], [])
        self.assertAlmostEqual(r["ret"], 0.0, places=12)


class FundTest(unittest.TestCase):
    def fund(self, daily=1.001):
        return [flat(d, 100.0 * daily ** i) for i, d in enumerate(DATES)]

    def test_no_trades_equals_the_fund_benchmark(self):
        fund = self.fund()
        m = market({"Y": [flat(d) for d in DATES]}, fund=fund)
        r = sim.run(m, DATES[5], DATES[-1], cash_yield=True, fund_fee=0.003)
        self.assertAlmostEqual(r["ret"], sim.bench(fund, DATES[5], DATES[-1], fee=0.003)["ret"], places=12)

    def test_money_spent_at_the_open_earns_nothing_that_day(self):
        fund = self.fund(1.01)
        m = market({"X": buy_candidate()}, fund=fund)
        r = sim.run(m, DATES[5], TRADE, cash_yield=True)
        before = sim.run(m, DATES[5], SIGNAL, cash_yield=True)["cash_end"]
        spent = 100.0 * (1 + sim.FEE)
        self.assertAlmostEqual(r["cash_end"], before - spent + (before - spent) * 0.01, places=9)

    def test_intraday_sale_proceeds_earn_nothing_that_day(self):
        fund = self.fund(1.01)
        y = [flat(d, 100.0) for d in DATES]
        y[10] = bar(DATES[10], 100.0, 100.0, 85.0, 90.0)  # stop at 90 intraday
        m = market({"Y": y}, fund=fund)
        r = sim.run(m, DATES[5], DATES[10], cash_yield=True, sl=0.10, capital=1.0,
                    positions={"Y": {"qty": 1, "avg": 100.0}})
        # 1.0 earns on days 6..10 (not on the first day); the 89.73 of proceeds earns nothing
        self.assertAlmostEqual(r["cash_end"], 1.01 ** 5 + 90.0 * (1 - sim.FEE), places=9)


class PositionLimitTest(unittest.TestCase):
    def test_prod_limit_blocks_a_second_ticker_on_a_nearly_empty_account(self):
        y = [flat(d, 100.0) for d in DATES]
        m = market({"X": buy_candidate(), "Y": y})
        held = {"Y": {"qty": 1, "avg": 100.0}}
        prod = sim.run(m, DATES[5], TRADE, capital=20000.0, positions=held, pos_base="shares")
        fixed = sim.run(m, DATES[5], TRADE, capital=20000.0, positions=held, pos_base="total")
        self.assertEqual(prod["buys"], 0)   # 100 / (100 + 100) >= 0.33 of the shares total
        self.assertEqual(fixed["buys"], 1)


if __name__ == "__main__":
    unittest.main()
