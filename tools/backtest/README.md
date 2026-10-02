# Portfolio backtest (daily bars)

A Python model of `bin/current_strategy.rb` with the prod `.env` of 2026-10-02, plus candidate
rules (market filter, trailing stop, idle cash in a money-market fund). It replays a whole
20 000 ₽ account, not single signals — unlike `bin/momentum_backtest.rb`, which scores entries
only. Read-only: no broker token, no orders; data comes from the public MOEX ISS API.

```sh
python3 -m unittest discover tools/backtest/tests   # event-order tests on synthetic candles
python3 tools/backtest/compare.py                   # prod rules vs candidates vs benchmarks (~20 s)
python3 tools/backtest/fetch.py /tmp/iss            # rebuild the snapshot (compare before replacing data/)
```

Python 3.10+, standard library only.

## Data

`data/*.json.gz` is a fixed snapshot of daily bars, 2022-06-01..2026-10-01: the 44 tickers of
IMOEX ∩ the bot's market cache as of 2026-10-02 (`universe.json`, lot sizes in `lots.json`,
both taken from the server caches), the IMOEX and MCFTR indices and the LQDT and TMOS funds.
`fetch.py` reproduces it byte for byte (gzip without a timestamp), as long as ISS does not
revise old bars. Splits (GMKN, TRNFP, VTBR, PLZL, T) are back-adjusted when a
close-to-close jump is below ×0.2 or above ×5.

Evaluation starts in 2023. History before 2023 is deliberately kept unused as a future holdout;
H2 2022 is loaded only as warm-up for levels and moving averages.

## Event order within a day

Enforced by `tests/test_sim.py`:

1. **Open** — exits whose level the opening price already crossed fill at the open; time exits
   fill at the open; `next_open` entries fill at the open, funded only by cash available at the
   open.
2. **Intraday** — stops and targets fill at their level, including positions bought at this
   open. Stops are checked before targets (pessimistic when a bar touches both); the trailing
   peak includes highs only up to the previous day. Targets fill in the order a rising price
   reaches them, never by looking at the day's high: in SIDE/DOWN the one-lot exit (+3% near
   resistance, else the trend threshold) comes first, the +10% force exit of the remainder
   after it; in UP only the force exit applies. As in prod, the force exit is not limited to
   one sale per ticker per day. Proximity to resistance is evaluated at the +3% price only.
3. **Close** — `close` entries fill at the close and are first checked for exits the next day.
4. **Fund** — idle cash earns the fund's close-to-close return only on the part that stayed in
   the fund all day (balance at the open minus what the open spent). Money that arrived during
   the day earns nothing that day.

Entry modes: `next_open` (default) decides on the previous completed bar and fills at today's
open — no look-ahead. `close` decides on today's completed bar and fills at its close, which
assumes a closing-auction fill is available. The live bot buys intraday on a dip; neither mode
reproduces that exactly.

## Status

The model is not validated: four review rounds each found an event-order or accounting error,
and the tests cover only the cases found so far. Treat results as sensitivity analysis, not as
evidence that a rule beats a money-market fund.

## Known limitations

- `ret` is measured against cash plus starting `positions` valued at the last close before
  `start`; starting positions carry no buy date, so time exits never apply to them.
- No dividends: compare stock strategies with IMOEX (price index), not MCFTR.
- Survivorship: the universe is today's index; it flatters the past.
- Every order fills at the modelled price; no slippage, no T+1 settlement for funds.
- The prod position limit (`pos_base="shares"`, share of the shares total) blocks a second
  ticker on a nearly empty account; `pos_base="total"` models the intended share of the account.
  The choice alone moves results by about 10 p.p. — that is sensitivity of the model, not a
  measured error bar.
- Part B (2024-10..2026-10) of `compare.py` was looked at while the ideas were formed, so it is
  not an independent holdout.
