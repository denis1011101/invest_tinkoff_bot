"""Rebuild the data snapshot from the public MOEX ISS API (no broker token needed).

    python3 tools/backtest/fetch.py OUT_DIR

Writes OUT_DIR/<NAME>.json.gz with daily bars 2022-06-01..2026-10-01 for every ticker in
universe.json, the IMOEX and MCFTR indices and the LQDT and TMOS funds. Both funds moved from
board TQTF to TQBR in June 2026, so their history is merged from the two boards.
Compare a fresh download with data/ before replacing it: ISS may revise old bars.
"""
import gzip
import json
import os
import sys
import time
import urllib.request

BASE = "https://iss.moex.com/iss"
FROM, TILL = "2022-06-01", "2026-10-01"
SHARE_COLS = "TRADEDATE,OPEN,LOW,HIGH,CLOSE,VALUE"
INDEX_COLS = "TRADEDATE,OPEN,LOW,HIGH,CLOSE"
HERE = os.path.dirname(os.path.abspath(__file__))


def get(url):
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except OSError:
            time.sleep(1 + attempt)
    raise RuntimeError(f"ISS request failed: {url}")


def history(path, cols):
    rows, start = [], 0
    while True:
        j = get(f"{BASE}/history/{path}.json?from={FROM}&till={TILL}&start={start}"
                f"&iss.only=history,history.cursor&history.columns={cols}")
        data = j["history"]["data"]
        rows += data
        index, total, page = j["history.cursor"]["data"][0]
        start = index + page
        if start >= total or not data:
            break
    return [dict(zip(cols.split(","), r)) for r in rows]


def save(out, name, bars):
    by_date = {b["TRADEDATE"]: b for b in bars}
    payload = json.dumps({"bars": [by_date[d] for d in sorted(by_date)]}).encode()
    # mtime=0 and no file name in the header: the same bars always give the same bytes
    with open(os.path.join(out, f"{name}.json.gz"), "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as f:
            f.write(payload)
    print(name, len(by_date), file=sys.stderr)


def main(out):
    os.makedirs(out, exist_ok=True)
    for t in json.load(open(os.path.join(HERE, "universe.json"))):
        save(out, t, history(f"engines/stock/markets/shares/boards/TQBR/securities/{t}", SHARE_COLS))
    for idx in ("IMOEX", "MCFTR"):
        save(out, idx, history(f"engines/stock/markets/index/securities/{idx}", INDEX_COLS))
    for fund in ("LQDT", "TMOS"):
        bars = []
        for board in ("TQTF", "TQBR"):
            bars += history(f"engines/stock/markets/shares/boards/{board}/securities/{fund}", SHARE_COLS)
        save(out, fund, bars)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
