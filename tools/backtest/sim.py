"""Daily-bar replay of bin/current_strategy.rb plus the candidate rules discussed on 2026-10-02.

Settings mirror the prod .env as of 2026-10-02. Model, not a broker: read the README before
trusting a number.

Event order inside one trading day (enforced by tests/test_sim.py):
  1. OPEN       exits whose level is already crossed at the open fill at the open price;
                time exits fill at the open; next_open entries fill at the open, funded only by
                cash that exists at the open (earlier days + this open's exits).
  2. INTRADAY   stops and targets fill at their level; positions bought at this open are checked
                too. Stops are checked before targets (pessimistic when both are touched), and the
                trailing peak includes only highs up to the previous day.
  3. CLOSE      close entries fill at the close; such positions are first checked the next day.
  4. FUND       idle cash earns the fund's close-to-close return only on the part that stayed in
                the fund the whole day: the balance at the open minus what the open spent.
                Money that arrived during the day earns nothing that day.
"""
import bisect
import gzip
import json
import os
from statistics import mean

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

FEE = 0.003  # broker commission per side
DIP = 0.01
MAX_LOT_RUB = 900.0
MAX_DAILY = 1800.0
MAX_POS_SHARE = 0.33
MAX_SHARES_SHARE = 0.9
MIN_RVOL = 0.8
THR = {"up": 1.10, "side": 1.04, "down": 1.03}
FORCE = 1.10
LEVEL_SELL_MIN = 1.03
LV_LOOKBACK, LV_PIVOT, LV_CLUSTER, LV_PROX = 120, 5, 0.015, 0.015
CASH_BUFFER = 0.01
UP_TICKERS = "SBER,SBERP,T,ROSN,TATN,TATNP,VTBR,SNGSP,IRAO,RTKM,RUAL,CHMF,NLMK,GAZP".split(",")


def adjust_splits(bars):
    """Back-adjust prices before a split (close-to-close jump below x0.2 or above x5)."""
    bars = [dict(b) for b in bars if b.get("CLOSE")]
    for i in range(len(bars) - 1, 0, -1):
        ratio = bars[i]["CLOSE"] / bars[i - 1]["CLOSE"]
        if ratio < 0.2 or ratio > 5:
            factor = round(ratio, 3)
            for b in bars[:i]:
                for key in ("OPEN", "LOW", "HIGH", "CLOSE"):
                    b[key] *= factor
    return bars


def load_bars(name, data_dir=DATA):
    with gzip.open(os.path.join(data_dir, f"{name}.json.gz"), "rt") as f:
        return adjust_splits(json.load(f)["bars"])


class Market:
    def __init__(self, series, lots, index_bars, fund_bars=None, up_tickers=None, intersection=None):
        self.dates = [b["TRADEDATE"] for b in index_bars]
        self.idx_close = {b["TRADEDATE"]: b["CLOSE"] for b in index_bars}
        self.series = {}
        for t, bars in series.items():
            self.series[t] = {"bars": bars, "dates": [b["TRADEDATE"] for b in bars],
                              "pos": {b["TRADEDATE"]: i for i, b in enumerate(bars)}}
        self.lots = lots
        fund_bars = fund_bars or []
        self.fund_ret = {fund_bars[i]["TRADEDATE"]: fund_bars[i]["CLOSE"] / fund_bars[i - 1]["CLOSE"]
                         for i in range(1, len(fund_bars))}
        self.up_tickers = [t for t in (up_tickers if up_tickers is not None else UP_TICKERS) if t in series]
        self.intersection = list(intersection if intersection is not None else series)
        self._levels = {}

    def bar(self, t, d):
        s = self.series[t]
        i = s["pos"].get(d)
        return (s["bars"][i], i) if i is not None else (None, None)

    def prev_close(self, t, d):
        """Last close strictly before d — what is known at the open of d."""
        s = self.series[t]
        j = bisect.bisect_left(s["dates"], d)
        return s["bars"][j - 1]["CLOSE"] if j > 0 else None

    def last_close(self, t, d):
        """Close of d if the ticker traded, else the last close before d."""
        b, _ = self.bar(t, d)
        return b["CLOSE"] if b else self.prev_close(t, d)

    def levels(self, t, i):
        """Support/resistance from completed bars strictly before index i (lib/level_analysis.rb)."""
        key = (t, i)
        if key in self._levels:
            return self._levels[key]
        c = self.series[t]["bars"][max(0, i - LV_LOOKBACK):i]
        out = {"support": [], "resistance": []}
        w = LV_PIVOT
        if len(c) >= 2 * w + 1:
            lows = [b["LOW"] for b in c]
            highs = [b["HIGH"] for b in c]
            sp, rp = [], []
            for k in range(w, len(c) - w):
                if all(v > lows[k] for v in lows[k - w:k] + lows[k + 1:k + w + 1]):
                    sp.append(lows[k])
                if all(v < highs[k] for v in highs[k - w:k] + highs[k + 1:k + w + 1]):
                    rp.append(highs[k])
            for name, prices in (("support", sp), ("resistance", rp)):
                clusters = []
                for p in sorted(prices):
                    for cl in clusters:
                        ctr = sum(cl) / len(cl)
                        if abs(p - ctr) / ctr <= LV_CLUSTER:
                            cl.append(p)
                            break
                    else:
                        clusters.append([p])
                out[name] = [sum(cl) / len(cl) for cl in clusters]
        self._levels[key] = out
        return out

    def near_resistance(self, t, i, p):
        r = [x for x in self.levels(t, i)["resistance"] if x >= p]
        return bool(r) and (min(r) - p) / min(r) <= LV_PROX

    def has_levels(self, t, i):
        lv = self.levels(t, i)
        return bool(lv["support"] or lv["resistance"])

    def support_distance(self, t, i, p):
        s = [x for x in self.levels(t, i)["support"] if x <= p]
        return (p - max(s)) / max(s) if s else 1.0

    def trend_for(self, k):
        """Index trend from the last 4 completed closes before day k (TradingLogic#trend_from_closes)."""
        closes = [self.idx_close[d] for d in self.dates[max(0, k - 10):k]]
        if len(closes) < 4:
            return "unknown", None
        a, b, c, d = closes[-4:]
        growth = closes[-1] / closes[-6] - 1 if len(closes) >= 6 else None
        if a < b < c < d:
            return "up", growth
        if a > b > c > d:
            return "down", growth
        return "side", growth

    def above_ma(self, k, ma):
        ic = [self.idx_close[x] for x in self.dates[max(0, k - ma):k]]
        return len(ic) == ma and ic[-1] > sum(ic) / ma


def load_market(data_dir=DATA):
    universe = json.load(open(os.path.join(HERE, "universe.json")))
    lots = json.load(open(os.path.join(HERE, "lots.json")))
    series = {t: load_bars(t, data_dir) for t in universe}
    return Market(series, lots, load_bars("IMOEX", data_dir), load_bars("LQDT", data_dir))


def run(m, start, end, *, sl=None, time_exit=None, trail=None, ma=None, size=1, entry="next_open",
        pos_base="shares", cash_yield=False, fund_fee=0.0, capital=20000.0, positions=None, verbose=False):
    """Simulate [start, end]. entry: "next_open" (signal on the previous bar, fill at today's open)
    or "close" (signal on today's completed bar, fill at today's close — assumes a closing-auction
    fill is available). "ret" is measured against cash plus the starting positions valued at the
    last close before `start`. pos_base: "shares" = prod position_within_limit? (share of the shares total),
    "total" = share of the whole account. positions: optional {ticker: {"qty", "avg"}} held at start."""
    assert entry in ("next_open", "close"), entry
    cash = capital
    pos = {}
    for t, p in (positions or {}).items():
        pos[t] = {"qty": p["qty"], "avg": p["avg"], "first_k": None, "peak": p.get("peak", p["avg"])}
    trips, log, equity, util = [], [], [], []
    exit_reasons = {}
    stats = {"buys": 0, "sells": 0, "fees": 0.0}
    ks = [k for k, d in enumerate(m.dates) if start <= d <= end]
    use_fund = cash_yield

    def sell(t, qty, price, d, reason):
        nonlocal cash
        p = pos[t]
        gross = qty * price
        fee = gross * FEE
        cash += gross - fee
        stats["fees"] += fee
        if use_fund and fund_fee:
            cash -= (gross - fee) * fund_fee
            stats["fees"] += (gross - fee) * fund_fee
        trips.append(qty * (price - p["avg"]) - fee - qty * p["avg"] * FEE)
        exit_reasons[reason] = exit_reasons.get(reason, 0) + 1
        stats["sells"] += 1
        p["qty"] -= qty
        log.append((d, "SELL", t, qty, round(price, 4), reason))
        if p["qty"] <= 0:
            del pos[t]

    first_day = m.dates[ks[0]]
    start_value = cash + sum(p["qty"] * (m.prev_close(t, first_day) or p["avg"]) for t, p in pos.items())

    if use_fund and fund_fee:
        stats["fees"] += cash * fund_fee
        cash -= cash * fund_fee  # initial purchase of fund units at the first close

    for k in ks:
        d = m.dates[k]
        tr, growth = m.trend_for(k)
        cash_open = cash
        open_outflow = 0.0
        sold_today = set()
        bought_at_open = set()

        # ---- 1. OPEN exits: levels already crossed by the opening price
        for t in list(pos):
            b, i = m.bar(t, d)
            if not b:
                continue
            p, o = pos[t], b["OPEN"]
            stops = []
            if sl is not None:
                stops.append((p["avg"] * (1 - sl), "stop"))
            if trail is not None:
                stops.append((p["peak"] * (1 - trail), "trail"))
            hit = [s for s in stops if o <= s[0]]
            if hit:
                sell(t, p["qty"], o, d, max(hit)[1]); continue
            if time_exit is not None and p["first_k"] is not None and k - p["first_k"] >= time_exit:
                sell(t, p["qty"], o, d, "time"); continue
            if trail is not None:
                continue  # trailing stop replaces the fixed targets
            if o >= p["avg"] * FORCE:
                sell(t, p["qty"], o, d, "force+10"); continue
            if tr in ("side", "down"):
                if o >= p["avg"] * THR[tr]:
                    sell(t, min(m.lots[t], p["qty"]), o, d, f"tp+{round((THR[tr] - 1) * 100)}")
                    sold_today.add(t)
                elif o >= p["avg"] * LEVEL_SELL_MIN and m.near_resistance(t, i, o):
                    sell(t, min(m.lots[t], p["qty"]), o, d, "level")
                    sold_today.add(t)

        # ---- entry gates (shared by the open and close phases)
        allowed = tr != "unknown" and (ma is None or m.above_ma(k, ma))
        spent_today = 0.0

        def try_buy(t, lots, price, when):
            nonlocal cash, spent_today, open_outflow
            shares_val = sum(q["qty"] * (m.prev_close(x, d) or q["avg"]) for x, q in pos.items())
            total = cash + shares_val
            ppl = price * m.lots[t]
            lots = min(lots, int(cash / (ppl * (1 + CASH_BUFFER))))
            if lots < 1:
                return "cash"
            val = ppl * lots
            cur = pos[t]["qty"] * (m.prev_close(t, d) or price) if t in pos else 0.0
            if pos_base == "shares":
                if shares_val > 0 and (cur + val) / (shares_val + val) >= MAX_POS_SHARE:
                    return "position_limit"
            elif (cur + val) / total >= MAX_POS_SHARE:
                return "position_limit"
            if spent_today + val > MAX_DAILY * size:
                return "daily_budget"
            if (shares_val + val) / total > MAX_SHARES_SHARE:
                return "shares_exposure"
            fee = val * FEE + (val * (1 + FEE) * fund_fee if use_fund else 0.0)
            cash -= val + fee
            stats["fees"] += fee
            spent_today += val
            if when == "open":
                open_outflow += val + fee
            stats["buys"] += 1
            q = lots * m.lots[t]
            if t in pos:
                p = pos[t]
                p["avg"] = (p["avg"] * p["qty"] + price * q) / (p["qty"] + q)
                p["qty"] += q
                p["peak"] = max(p["peak"], price)
            else:
                pos[t] = {"qty": q, "avg": price, "first_k": k, "peak": price}
            log.append((d, "BUY", t, q, round(price, 4), tr))
            return "ok"

        def signal(t):
            """(signal bar, its index, execution price, index for levels/SMA) or None."""
            b, i = m.bar(t, d)
            if not b:
                return None
            if entry == "next_open":
                return (m.series[t]["bars"][i - 1], i - 1, b["OPEN"], i) if i >= 1 else None
            return b, i, b["CLOSE"], i

        def entries(when):
            if not allowed:
                return
            if tr == "up":
                base = 3 if growth is not None and growth >= 0.02 else 2
                cands = []
                for t in m.up_tickers:
                    s = signal(t)
                    if s and s[1] >= 20:
                        cands.append((s[0]["VALUE"], t, s))
                for _, t, (sb, si, price, li) in sorted(cands, key=lambda x: -x[0]):
                    if not sb["LOW"] <= sb["HIGH"] * (1 - DIP):
                        continue
                    hist = m.series[t]["bars"][si - 20:si]
                    if sb["VALUE"] / mean(x["VALUE"] for x in hist) < MIN_RVOL:
                        continue
                    if m.has_levels(t, li):
                        sma = mean(x["CLOSE"] for x in m.series[t]["bars"][li - 5:li])
                        if m.near_resistance(t, li, price) or not price > sma:
                            continue
                    lots = min(base * size, int(MAX_LOT_RUB * size / (price * m.lots[t])))
                    if lots >= 1 and try_buy(t, lots, price, when) == "ok" and when == "open":
                        bought_at_open.add(t)
            else:
                cands = []
                for t in m.intersection:
                    s = signal(t)
                    if not s or s[1] < 4:
                        continue
                    sb, si, price, li = s
                    c4 = [x["CLOSE"] for x in m.series[t]["bars"][si - 4:si]]
                    if not all(c4[j] < c4[j + 1] for j in range(3)):
                        continue
                    if int(MAX_LOT_RUB * size / (price * m.lots[t])) < 1:
                        continue
                    if not sb["LOW"] <= sb["HIGH"] * (1 - DIP):
                        continue
                    cands.append((m.support_distance(t, li, price), t, price))
                done = 0
                for _, t, price in sorted(cands, key=lambda x: x[0]):
                    lots = max(1, int(MAX_LOT_RUB * size / (price * m.lots[t]))) if size > 1 else 1
                    if try_buy(t, lots, price, when) == "ok":
                        if when == "open":
                            bought_at_open.add(t)
                        done += 1
                        if done >= size:
                            break

        # ---- 1b. OPEN entries
        if entry == "next_open":
            entries("open")

        # ---- 2. INTRADAY exits at their levels (incl. positions bought at this open)
        for t in list(pos):
            b, i = m.bar(t, d)
            if not b:
                continue
            p = pos[t]
            stops = []
            if sl is not None:
                stops.append((p["avg"] * (1 - sl), "stop"))
            if trail is not None:
                stops.append((p["peak"] * (1 - trail), "trail"))
            if stops:
                level, reason = max(stops)
                if b["LOW"] <= level:
                    # an existing position opened above the level (else it left at the open);
                    # one bought at the open paid the open, so the level is below its entry
                    sell(t, p["qty"], min(level, b["OPEN"]), d, reason); continue
            if trail is not None:
                p["peak"] = max(p["peak"], b["HIGH"])
                continue
            # Targets fill in the order a rising price reaches them, never by peeking at the high:
            # the one-lot SIDE/DOWN exit (level +3% or tp) comes first, the +10% force exit of the
            # remainder after it. As in prod, force exit is not limited to one sale per day.
            if tr in ("side", "down") and t not in sold_today:
                tp_px, lv_px = p["avg"] * THR[tr], p["avg"] * LEVEL_SELL_MIN
                if lv_px < tp_px and b["HIGH"] >= lv_px and m.near_resistance(t, i, max(lv_px, b["OPEN"])):
                    sell(t, min(m.lots[t], p["qty"]), max(lv_px, b["OPEN"]), d, "level")
                elif b["HIGH"] >= tp_px:
                    sell(t, min(m.lots[t], p["qty"]), max(tp_px, b["OPEN"]), d,
                         f"tp+{round((THR[tr] - 1) * 100)}")
            if t in pos and b["HIGH"] >= p["avg"] * FORCE:
                sell(t, p["qty"], max(p["avg"] * FORCE, b["OPEN"]), d, "force+10")

        # ---- 3. CLOSE entries
        if entry == "close":
            entries("close")

        # ---- 4. FUND: only money that sat in the fund all day earns the day's return
        if use_fund and k != ks[0] and d in m.fund_ret:
            cash += max(0.0, cash_open - open_outflow) * (m.fund_ret[d] - 1)

        eq = cash + sum(p["qty"] * (m.last_close(t, d) or p["avg"]) for t, p in pos.items())
        equity.append((d, eq))
        util.append(1 - cash / eq if eq else 0.0)

    final = equity[-1][1]
    peak, mdd = 0.0, 0.0
    for _, e in equity:
        peak = max(peak, e)
        mdd = min(mdd, e / peak - 1)
    wins = [x for x in trips if x > 0]
    losses = [x for x in trips if x <= 0]
    last_d = equity[-1][0]
    return {
        "final": final, "start_value": start_value, "ret": final / start_value - 1, "mdd": mdd,
        "buys": stats["buys"], "sells": stats["sells"], "fees": stats["fees"], "realized": sum(trips),
        "win_rate": len(wins) / len(trips) if trips else None,
        "avg_win": mean(wins) if wins else 0.0, "avg_loss": mean(losses) if losses else 0.0,
        "open_n": len(pos), "cash_end": cash, "util": mean(util),
        "open_pnl": sum(p["qty"] * ((m.last_close(t, last_d) or p["avg"]) - p["avg"]) for t, p in pos.items()),
        "exits": exit_reasons, "equity": equity, "log": log if verbose else [],
        "trades": log, "positions": pos,
    }


def bench(bars, start, end, capital=20000.0, fee=0.0):
    """Buy at the first close in [start, end] (paying fee), hold to the last close."""
    bars = [b for b in bars if start <= b["TRADEDATE"] <= end]
    first, last = bars[0]["CLOSE"] / (1 - fee), bars[-1]["CLOSE"]
    peak, mdd = 0.0, 0.0
    for b in bars:
        peak = max(peak, b["CLOSE"])
        mdd = min(mdd, b["CLOSE"] / peak - 1)
    return {"ret": last / first - 1, "final": capital * last / first, "mdd": mdd}


def switch(m, tmos_bars, lqdt_bars, start, end, ma, capital=20000.0, cost=0.006):
    """Hold TMOS while IMOEX > SMA(ma) of completed closes, else LQDT. The choice made from closes
    before day d takes effect at the close of d; every switch pays `cost` (sale + purchase)."""
    tm = {b["TRADEDATE"]: b["CLOSE"] for b in tmos_bars}
    lq = {b["TRADEDATE"]: b["CLOSE"] for b in lqdt_bars}
    eq, held, switches, peak, mdd, prev = capital, None, 0, capital, 0.0, None
    for k, d in enumerate(m.dates):
        if not (start <= d <= end) or d not in tm or d not in lq:
            continue
        want = "TMOS" if m.above_ma(k, ma) else "LQDT"
        if prev is not None:
            src = tm if held == "TMOS" else lq
            eq *= src[d] / src[prev]
        if want != held:
            switches += 1
            eq *= 1 - (cost if held is not None else cost / 2)
            held = want
        prev = d
        peak = max(peak, eq)
        mdd = min(mdd, eq / peak - 1)
    return {"ret": eq / capital - 1, "mdd": mdd, "switches": switches}
