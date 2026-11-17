#!/usr/bin/env python3
"""Seed Bookkeeper Dev's crypto side with made-up wallets and a year of history — real
files in the real formats, the way gen-fake-bank-csvs.py makes bank exports. With these
in place the Dev app runs on data of its own instead of the built-in demo.

    python3 scripts/gen-fake-crypto.py --dev          # → _DevData/
    python3 scripts/gen-fake-crypto.py --out DIR      # → anywhere else
    python3 scripts/gen-fake-crypto.py --dev --force  # rewrite history.csv even if present
    python3 scripts/gen-fake-crypto.py --dev --force --match-live
        # …ending each wallet at what it's worth now, from wallets.txt × quotes.json —
        # so the strip's last bars meet the live figure instead of jumping to it

wallets.txt: seeded when it holds no wallet yet. Wallets already there (and every #hide,
#key, colour and position line) are left as they are — except one of the seeded names
that holds nothing, which gets its made-up holdings.
history.csv: one mark a day for the year up to yesterday (today is left for Archive
today), split per wallet, written only when there is no history file (or --force).

Every wallet, amount and value here is invented. No keys, no addresses of anyone's.
Deterministic: the same seed writes the same bytes. Stdlib only.
"""

import argparse
import json
import os
import random
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

SEED = 20261022
REPO = Path(__file__).resolve().parent.parent
DEV = REPO / "_DevData"

# Wallet line: nickname, two retired fields, network label.
WALLETS = ["Cold Vault", "Daily", "Testing 3"]

# #manual  wallet  symbol  coingeckoId  amount  llamaNetwork  contract  networkName
HOLDINGS = [
    ("Cold Vault", "ETH", "ethereum", "2.4", "", "", "Ethereum"),
    ("Cold Vault", "rETH", "", "3.5", "ethereum", "0xae78736cd615f374d3085123a210448e74fc6393", "Ethereum"),
    ("Cold Vault", "USDC", "", "5200", "ethereum", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "Ethereum"),
    ("Cold Vault", "BOLD", "", "2750", "ethereum", "0x6440f144b7e50d6a8439336510312d2f54beb01d", "Ethereum"),
    ("Cold Vault", "UNI", "uniswap", "50", "", "", "Arbitrum"),
    ("Daily", "ETH", "ethereum", "0.8", "", "", "Arbitrum"),
    ("Daily", "XMR", "monero", "9", "", "", "Monero"),
    ("Daily", "HYPE", "hyperliquid", "60", "", "", "HyperEVM"),
    ("Daily", "USDC", "", "1500", "hyperliquid", "0xb88339cb7199b77e23db6e890353e22632ba630f", "HyperEVM"),
    ("Testing 3", "SOL", "solana", "14", "", "", "Solana"),
]

# Where each wallet's history ends (roughly today's worth) and when it was opened.
# A wallet's line in the history starts the day it was opened.
HISTORY = {
    "Cold Vault": {"end": 30200.0, "opened_days_ago": 365, "drift": 0.30, "swing": 0.010},
    "Daily": {"end": 12400.0, "opened_days_ago": 365, "drift": 0.18, "swing": 0.013},
    "Testing 3": {"end": 2600.0, "opened_days_ago": 75, "drift": 0.10, "swing": 0.015},
}


def wallet_names(lines):
    return [l.split("\t")[0] for l in lines if l and not l.startswith("#")]


def seed_wallets(root: Path):
    f = root / "wallets.txt"
    lines = f.read_text(encoding="utf-8").splitlines() if f.exists() else []
    have = wallet_names(lines)
    if have:
        # Wallets already there stay as they are; one of ours that is there but holds
        # nothing gets its made-up holdings, so every wallet has something to draw.
        held = {l.split("\t")[1] for l in lines if l.startswith("#manual\t")}
        empty = [w for w in WALLETS if w in have and w not in held]
        add = [h for h in HOLDINGS if h[0] in empty]
        if add:
            lines += ["\t".join(("#manual",) + h) for h in add]
            write_private(f, "\n".join(lines) + "\n")
            print(f"   wallets.txt: filled {', '.join(empty)} ({len(add)} holdings); the rest left as is")
        else:
            print(f"   wallets.txt already holds {', '.join(have)} — left as is")
        return
    lines += [f"{w}\t\t\t" for w in WALLETS]
    lines += ["\t".join(("#manual",) + h) for h in HOLDINGS]
    write_private(f, "\n".join(lines) + "\n")
    print(f"   wallets.txt ← {len(WALLETS)} wallets, {len(HOLDINGS)} holdings")


def live_values(root: Path):
    """Each wallet's worth now: its hand-entered amounts × the saved quotes (hidden tokens
    left out). Read-only; made-up wallets, made-up amounts, public prices."""
    lines = (root / "wallets.txt").read_text(encoding="utf-8").splitlines()
    quotes = json.loads((root / "quotes.json").read_text(encoding="utf-8"))
    prices = quotes.get("prices", quotes)
    hidden = {l.split("\t")[1] for l in lines if l.startswith("#hide\t")}
    worth = {w: 0.0 for w in wallet_names(lines)}
    for l in lines:
        if not l.startswith("#manual\t"):
            continue
        p = l.split("\t") + [""] * 8
        wallet, cg, amount, net, ca = p[1], p[3], float(p[4] or 0), p[5], p[6].lower()
        key = f"{net}:{ca}" if net and ca else f"coingecko:{cg}" if cg else None
        if f"{ca}@{net}" in hidden or key not in prices:
            continue
        worth[wallet] = worth.get(wallet, 0.0) + amount * float(prices[key])
    return worth


def history_lines(today):
    rng = random.Random(SEED)
    days = 365
    # Walk each wallet backwards from its end value: a gentle drift down into the past plus
    # day-to-day noise, so the year reads as growth with dips.
    series = {}
    for name, h in HISTORY.items():
        v = h["end"]
        vals = []
        for back in range(1, days + 1):
            vals.append((back, v))
            step = 1 - h["drift"] / days + rng.gauss(0, h["swing"])
            v = max(1.0, v * step)
        series[name] = dict(vals)
    out = []
    for back in range(days, 0, -1):
        day = today - timedelta(days=back)
        stamp = int(datetime.combine(day, time(18, 0), tzinfo=timezone.utc).timestamp())
        split = {n: f"{series[n][back]:.2f}" for n, h in HISTORY.items() if back <= h["opened_days_ago"]}
        total = sum(float(x) for x in split.values())
        out.append(f"{stamp}\t{total:.2f}\t{json.dumps(split, separators=(',', ':'))}")
    return out


def seed_history(root: Path, force: bool):
    f = root / "history.csv"
    if f.exists() and not force:
        print("   history.csv already there — left as is (--force rewrites it)")
        return
    lines = history_lines(datetime.now(timezone.utc).date())
    write_private(f, "\n".join(lines) + "\n")
    print(f"   history.csv ← {len(lines)} daily marks")


def write_private(path: Path, text: str):
    """Temp file + rename, owner-only — the app never sees a half-written file."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dev", action="store_true", help="write into _DevData/")
    g.add_argument("--out", type=Path, help="write into this folder")
    ap.add_argument("--force", action="store_true", help="rewrite history.csv")
    ap.add_argument("--match-live", action="store_true", help="end each wallet at its live worth")
    a = ap.parse_args()
    root = DEV if a.dev else a.out
    root.mkdir(parents=True, exist_ok=True)
    seed_wallets(root)
    if a.match_live:
        for name, v in live_values(root).items():
            if v <= 0:
                continue
            h = HISTORY.setdefault(name, {"opened_days_ago": 120, "drift": 0.15, "swing": 0.013})
            h["end"] = round(v, 2)
        print("   ending at live worth: " + ", ".join(f"{n} ${h['end']:,.0f}" for n, h in HISTORY.items()))
    seed_history(root, a.force)


if __name__ == "__main__":
    main()
