"""Compare the prod rules with the candidate rules on the fixed snapshot in data/.

    python3 tools/backtest/compare.py

Part A (2023-01..2024-09) chooses the parameters, part B (2024-10..2026-10) reports them.
Part B was looked at while the ideas were formed, so it is NOT an independent holdout.
History before 2023 is deliberately left unused (only H2 2022 serves as warm-up for levels/SMA).
"""
import itertools

import sim

A = ("2023-01-03", "2024-09-30")
B = ("2024-10-01", "2026-10-01")
GRID = list(itertools.product([None, 50, 100, 200], [None, 0.05, 0.07, 0.10, 0.15]))
FUND_FEE = 0.003


def pct(x):
    return f"{x * 100:+6.1f}%"


def main():
    m = sim.load_market()
    for entry in ("next_open", "close"):
        for pos_base in ("shares", "total"):
            limit = "prod (share of shares)" if pos_base == "shares" else "fixed (share of account)"
            print(f"\n=== entry={entry}, position limit={limit}")
            base = dict(entry=entry, pos_base=pos_base)
            print(f"  {'prod rules':28s} A {pct(sim.run(m, *A, **base)['ret'])}  B {pct(sim.run(m, *B, **base)['ret'])}")
            res = []
            for ma, tr in GRID:
                kw = dict(base, ma=ma, trail=tr, cash_yield=True, fund_fee=FUND_FEE)
                res.append((sim.run(m, *A, **kw)["ret"], sim.run(m, *B, **kw)["ret"], ma, tr))
            res.sort(key=lambda x: -x[0])
            for ra, rb, ma, tr in res[:5]:
                print(f"  ma={str(ma):4s} trail={str(tr):5s}{'':12s} A {pct(ra)}  B {pct(rb)}")
            b_all = sorted(x[1] for x in res)
            print(f"  B over the whole grid: median {pct(b_all[len(b_all) // 2])}, "
                  f"min {pct(b_all[0])}, max {pct(b_all[-1])}")
    lq, tm = sim.load_bars("LQDT"), sim.load_bars("TMOS")
    print("\nBenchmarks (funds pay 0.3% on entry, 0.6% per switch):")
    for ma in (50, 100, 200):
        print(f"  TMOS/LQDT by SMA{ma:<3d}{'':14s} A {pct(sim.switch(m, tm, lq, *A, ma)['ret'])}  "
              f"B {pct(sim.switch(m, tm, lq, *B, ma)['ret'])}")
    for name, bars in (("LQDT", lq), ("TMOS", tm)):
        print(f"  {name:28s} A {pct(sim.bench(bars, *A, fee=FUND_FEE)['ret'])}  "
              f"B {pct(sim.bench(bars, *B, fee=FUND_FEE)['ret'])}")
    for name in ("MCFTR", "IMOEX"):
        bars = sim.load_bars(name)
        print(f"  {name:28s} A {pct(sim.bench(bars, *A)['ret'])}  B {pct(sim.bench(bars, *B)['ret'])}")


if __name__ == "__main__":
    main()
