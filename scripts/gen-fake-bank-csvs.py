#!/usr/bin/env python3
"""Write synthetic bank CSV exports — one per bank shape the importer must read.

    python3 scripts/gen-fake-bank-csvs.py            # → BookkeeperCore/Tests/BookkeeperCoreTests/Fixtures/bank/
    python3 scripts/gen-fake-bank-csvs.py --dev      # → _DevData/inbox/ (gitignored, for local runs)
    python3 scripts/gen-fake-bank-csvs.py --out DIR  # → anywhere else

Every merchant, amount and account number here is invented. No real bank data, ever —
the shapes follow _Research/2026-10-20-bank-spending-market-research.md §3, the
contents are a made-up Brooklyn life from May 2025 to Oct 2026.

Deterministic: the same seed writes the same bytes, so the fixtures can be committed
and regenerated without a diff. Stdlib only.
"""

import argparse
import csv
import io
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 20261020
START = date(2025, 5, 1)
END = date(2026, 10, 31)

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "BookkeeperCore/Tests/BookkeeperCoreTests/Fixtures/bank"
DEV_INBOX = REPO / "_DevData/inbox"

# 🥗 The merchant the rule engine has to fold: four raw spellings of one salad bar, and
# one shop whose name merely starts the same way.
KALE_VARIANTS = [
    "MR KALE BROOKLYN NY 0042 POS",
    "SQ *MR KALE BKLYN",
    "MR. KALE #2 BROOKLYN NY",
]
KALE_DECOY = "MR KALEIDOSCOPE TOYS BKLYN"

# (raw description, our group, low $, high $, visits per month)
# Groups map to each bank's own category vocabulary below.
MERCHANTS = [
    ("GOWANUS GRIND COFFEE BROOKLYN NY", "cafe", 3.75, 7.50, 9),
    ("LANTERN BEAN CAFE BKLYN", "cafe", 4.25, 9.00, 4),
    ("BODEGA MOON DELI BROOKLYN", "cafe", 2.50, 11.00, 5),
    ("FERRANTE'S SLICE SHOP BROOKLYN", "dining", 4.00, 18.00, 3),
    ("NINE DRAGONS NOODLE NEW YORK NY", "dining", 16.00, 42.00, 2),
    ("ATLANTIC TAQUERIA BROOKLYN NY", "dining", 12.00, 34.00, 2),
    ("PIER 6 OYSTER BAR BROOKLYN", "dining", 48.00, 135.00, 0.5),
    ("PROSPECT GREENS MARKET BROOKLYN", "grocery", 22.00, 96.00, 4),
    ("HALSEY STREET GROCERS", "grocery", 9.00, 41.00, 3),
    ("CORNER CO-OP BROOKLYN NY", "grocery", 30.00, 120.00, 1.5),
    ("CITY TRANSIT FARE NEW YORK", "transit", 2.90, 2.90, 6),
    ("YELLOWBIRD RIDES *TRIP", "transit", 11.00, 38.00, 1.5),
    ("BERGEN HARDWARE BROOKLYN", "shopping", 6.00, 64.00, 0.7),
    ("FULTON STREET BOOKS", "shopping", 12.00, 48.00, 0.8),
    (KALE_DECOY, "shopping", 14.00, 72.00, 0.3),
    ("STARLIGHT CINEMA BKLYN", "fun", 15.50, 31.00, 0.8),
    ("VELVET ROOM JAZZ NEW YORK", "fun", 25.00, 60.00, 0.4),
    ("SMITH ST PHARMACY BROOKLYN", "health", 5.00, 38.00, 1),
]

# Monthly bills: (raw, group, amount, day of month)
BILLS = [
    ("EASTRIVER POWER CO BILLPAY", "utility", None, 14),   # varies with the season
    ("BRIGHTLINE FIBER INTERNET", "utility", 59.99, 3),
    ("PIGEON MOBILE WIRELESS", "utility", 45.00, 21),
    ("IRONWORKS GYM MEMBERSHIP", "health", 89.00, 1),
    ("STREAMLY.TV SUBSCRIPTION", "fun", 15.49, 9),
    ("SONGBIRD MUSIC 866-555-0100", "fun", 10.99, 17),
]

# Each bank's own word for our group — what lands in its Category column.
CATEGORIES = {
    "chase": {"cafe": "Food & Drink", "dining": "Food & Drink", "grocery": "Groceries",
              "transit": "Travel", "shopping": "Shopping", "fun": "Entertainment",
              "health": "Health & Wellness", "utility": "Bills & Utilities"},
    "capone": {"cafe": "Dining", "dining": "Dining", "grocery": "Grocery",
               "transit": "Other Travel", "shopping": "Merchandise", "fun": "Entertainment",
               "health": "Health Care", "utility": "Phone/Cable"},
    "discover": {"cafe": "Restaurants", "dining": "Restaurants", "grocery": "Supermarkets",
                 "transit": "Travel/ Entertainment", "shopping": "Merchandise",
                 "fun": "Travel/ Entertainment", "health": "Medical Services",
                 "utility": "Services"},
    "apple": {"cafe": "Restaurants", "dining": "Restaurants", "grocery": "Grocery",
              "transit": "Transportation", "shopping": "Shopping", "fun": "Entertainment",
              "health": "Medical", "utility": "Utilities"},
}

PAYROLL = "HALCYON LABS PAYROLL PPD ID: 9000000001"
RENT = "BRIGHTSTONE PROPERTY MGMT RENT WEB ID: 9000000002"


def months():
    d = START
    while d <= END:
        yield d
        d = date(d.year + (d.month == 12), d.month % 12 + 1, 1)


def days_in(month):
    nxt = date(month.year + (month.month == 12), month.month % 12 + 1, 1)
    return (nxt - month).days


def money(rng, lo, hi):
    return round(rng.uniform(lo, hi) * 4) / 4 if lo != hi else lo


def power_bill(month):
    # Summer air conditioning, winter heat — a bill that has a shape.
    return {6: 118.40, 7: 141.75, 8: 136.20, 12: 97.10, 1: 104.35, 2: 99.80}.get(month.month, 71.25)


def spending(rng, *, merchants, kale_per_month=0.0, bills=(), scale=1.0):
    """Purchases as (date, raw, group, dollars) — money out, positive here; each
    writer applies its bank's sign convention."""
    rows = []
    for m in months():
        n = days_in(m)
        for raw, group, lo, hi, per in merchants:
            visits = int(per * scale) + (rng.random() < (per * scale) % 1)
            for _ in range(visits):
                rows.append((m + timedelta(days=rng.randrange(n)), raw, group, money(rng, lo, hi)))
        kale = int(kale_per_month) + (rng.random() < kale_per_month % 1)
        for _ in range(kale):
            rows.append((m + timedelta(days=rng.randrange(n)), rng.choice(KALE_VARIANTS),
                         "dining", money(rng, 11.50, 16.75)))
        for raw, group, amount, day in bills:
            rows.append((m.replace(day=min(day, n)), raw, group,
                         amount if amount is not None else power_bill(m)))
    return sorted(r for r in rows if r[0] <= END)


def monthly_payments(rows, day=26):
    """A card paid off once a month: last month's spend, rounded, as a credit."""
    by_month = {}
    for d, _, _, amt in rows:
        by_month[(d.year, d.month)] = by_month.get((d.year, d.month), 0) + amt
    out = []
    for (y, mo), total in sorted(by_month.items()):
        pay = date(y + (mo == 12), mo % 12 + 1, day)
        if pay <= END:
            out.append((pay, round(total, 2)))
    return out


def mdy(d):
    return d.strftime("%m/%d/%Y")


def amt(x):
    return f"{x:.2f}"


def write(path, header, rows, *, lineterminator="\n", preamble=None):
    buf = io.StringIO()
    if preamble:
        buf.write(preamble)
    w = csv.writer(buf, lineterminator=lineterminator)
    if header:
        w.writerow(header)
    w.writerows(rows)
    path.write_text(buf.getvalue(), encoding="utf-8", newline="")
    print(f"  🧾 {path.name:<38} {len(rows):>5} rows")


# MARK: - Banks


def chase_card_rows(rng, *, extra=()):
    purchases = spending(rng, merchants=MERCHANTS, kale_per_month=4.5, bills=BILLS[1:])
    rows = []
    for d, raw, group, dollars in list(purchases) + list(extra):
        post = d + timedelta(days=rng.choice([0, 1, 1, 2]))
        rows.append((d, ["4417", mdy(d), mdy(post), raw, CATEGORIES["chase"][group], "Sale",
                         amt(-dollars), ""]))
    # One return, so a positive "Return" sits beside the payments.
    d = date(2025, 11, 18)
    rows.append((d, ["4417", mdy(d), mdy(d + timedelta(days=2)), "FULTON STREET BOOKS",
                     "Shopping", "Return", amt(24.00), ""]))
    for d, total in monthly_payments(purchases):
        label = "AUTOPAY PAYMENT - THANK YOU" if d.month % 2 else "PAYMENT THANK YOU-MOBILE"
        rows.append((d, ["4417", mdy(d), mdy(d), label, "", "Payment", amt(total), ""]))
    # Chase lists newest first.
    rows.sort(key=lambda r: (r[0], r[1][3]), reverse=True)
    return rows


CHASE_CARD_HEADER = ["Card", "Transaction Date", "Post Date", "Description", "Category",
                     "Type", "Amount", "Memo"]


def chase_card(out):
    rng = random.Random(f"{SEED}-chase-card")
    # Two identical coffees on one day: the dedup must keep both (occurrence index).
    twins = [(date(2026, 2, 12), "GOWANUS GRIND COFFEE BROOKLYN NY", "cafe", 4.50)] * 2
    rows = chase_card_rows(rng, extra=twins)
    write(out / "chase_card.csv", CHASE_CARD_HEADER, [r for _, r in rows])

    # Two exports of the same card that overlap by February–March: re-dropping the
    # second must add only April.
    def window(lo, hi):
        return [r for d, r in rows if lo <= d <= hi]
    write(out / "chase_card_2026-01_to_2026-03.csv", CHASE_CARD_HEADER,
          window(date(2026, 1, 1), date(2026, 3, 31)))
    write(out / "chase_card_2026-02_to_2026-04.csv", CHASE_CARD_HEADER,
          window(date(2026, 2, 1), date(2026, 4, 30)))


def checking_flows(rng, *, payroll_net, card_payee):
    """Payroll in, rent and the card bill out — the rows every checking file shares."""
    flows = []   # (date, raw, signed dollars, kind)
    d = date(2025, 5, 2)          # biweekly Fridays
    while d <= END:
        flows.append((d, PAYROLL, round(payroll_net + rng.choice([0, 0, 0, 12.40, -8.15]), 2), "payroll"))
        d += timedelta(days=14)
    for m in months():
        # Lease renewed in June 2026 at a little more.
        rent = 2150.00 if m < date(2026, 6, 1) else 2195.00
        flows.append((m, RENT, -rent, "rent"))
        pay = m.replace(day=26)
        flows.append((pay, card_payee, -round(rng.uniform(1500, 2400), 2), "card"))
        # Money moved to savings is neither spend nor income — a transfer.
        flows.append((m.replace(day=3), "ONLINE TRANSFER TO SAV XXXXXX9001", -600.00, "transfer"))
        # ATM cash now and then.
        if rng.random() < 0.6:
            flows.append((m + timedelta(days=rng.randrange(days_in(m))),
                          "ATM WITHDRAWAL 000417 7TH AVE BROOKLYN", -float(rng.choice([40, 60, 100])), "atm"))
    return sorted(flows)


def chase_checking(out):
    rng = random.Random(f"{SEED}-chase-checking")
    flows = checking_flows(rng, payroll_net=2860.00, card_payee="CHASE CREDIT CRD AUTOPAY PPD ID: 9000000003")
    flows += [(d, raw, -dollars, "debit") for d, raw, _, dollars in
              spending(rng, merchants=MERCHANTS[:3] + MERCHANTS[7:9], scale=0.4)]
    flows.sort()
    balance, rows = 4200.00, []
    for d, raw, x, kind in flows:
        balance = round(balance + x, 2)
        typ = {"payroll": "ACH_CREDIT", "rent": "ACH_DEBIT", "card": "ACH_DEBIT",
               "atm": "ATM", "debit": "DEBIT_CARD", "transfer": "ACCT_XFER"}[kind]
        rows.append([("CREDIT" if x > 0 else "DEBIT"), mdy(d), raw, amt(x), typ, amt(balance), ""])
    rows.reverse()
    write(out / "chase_checking.csv",
          ["Details", "Posting Date", "Description", "Amount", "Type", "Balance", "Check or Slip #"], rows)


def bofa_checking(out):
    rng = random.Random(f"{SEED}-bofa")
    flows = checking_flows(rng, payroll_net=2615.00, card_payee="BANK OF AMERICA CREDIT CARD Bill Payment")
    flows += [(d, f"CHECKCARD {d.strftime('%m%d')} {raw}", -dollars, "debit") for d, raw, _, dollars in
              spending(rng, merchants=MERCHANTS[:9], kale_per_month=1.5, scale=0.6)]
    flows.sort()

    def thousands(x):
        return f"{x:,.2f}"

    opening = 6150.00
    balance, rows = opening, [[mdy(START), f"Beginning balance as of {mdy(START)}", "", thousands(opening)]]
    credits = debits = 0.0
    for d, raw, x, _ in flows:
        balance = round(balance + x, 2)
        credits += max(x, 0); debits += min(x, 0)
        # Bank of America quotes every amount and puts thousands commas inside.
        rows.append([mdy(d), raw, thousands(x), thousands(balance)])
    preamble_rows = [
        ["Description", "", "Summary Amt."],
        [f"Beginning balance as of {mdy(START)}", "", thousands(opening)],
        ["Total credits", "", thousands(round(credits, 2))],
        ["Total debits", "", thousands(round(debits, 2))],
        [f"Ending balance as of {mdy(END)}", "", thousands(balance)],
    ]
    pre = io.StringIO()
    csv.writer(pre, lineterminator="\n", quoting=csv.QUOTE_MINIMAL).writerows(preamble_rows)
    pre.write("\n")
    write(out / "bank_of_america_checking.csv", ["Date", "Description", "Amount", "Running Bal."],
          rows, preamble=pre.getvalue())


def wells_fargo(out):
    rng = random.Random(f"{SEED}-wells")
    flows = checking_flows(rng, payroll_net=2390.00, card_payee="WF CREDIT CARD AUTO PAY")
    flows += [(d, f"PURCHASE AUTHORIZED ON {d.strftime('%m/%d')} {raw} S0000000{i % 10}", -dollars, "debit")
              for i, (d, raw, _, dollars) in
              enumerate(spending(rng, merchants=MERCHANTS[:12], kale_per_month=1.0, scale=0.5))]
    flows.sort(reverse=True)
    # Headerless, every field quoted, and Windows line endings — as it downloads.
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n", quoting=csv.QUOTE_ALL)
    for d, raw, x, _ in flows:
        w.writerow([mdy(d), amt(x), "*", "", raw])
    (out / "wells_fargo.csv").write_text(buf.getvalue(), encoding="utf-8", newline="")
    print(f"  🧾 {'wells_fargo.csv':<38} {len(flows):>5} rows")


def capital_one(out):
    rng = random.Random(f"{SEED}-capone")
    purchases = spending(rng, merchants=MERCHANTS[3:10] + MERCHANTS[15:17], bills=BILLS[2:3], scale=0.7)
    rows = []
    for d, raw, group, dollars in purchases:
        rows.append((d, [d.isoformat(), (d + timedelta(days=1)).isoformat(), "0921", raw,
                         CATEGORIES["capone"][group], amt(dollars), ""]))
    for d, total in monthly_payments(purchases, day=24):
        rows.append((d, [d.isoformat(), d.isoformat(), "0921", "CAPITAL ONE AUTOPAY PYMT",
                         "Payment/Credit", "", amt(total)]))
    rows.sort(key=lambda r: (r[0], r[1][3]), reverse=True)
    write(out / "capital_one.csv",
          ["Transaction Date", "Posted Date", "Card No.", "Description", "Category", "Debit", "Credit"],
          [r for _, r in rows])


def amex(out):
    rng = random.Random(f"{SEED}-amex")
    purchases = spending(rng, merchants=MERCHANTS[3:7] + MERCHANTS[12:17], kale_per_month=1.0, scale=0.6)
    rows = []
    for d, raw, _, dollars in purchases:
        rows.append((d, [mdy(d), raw, "R. QUILL", "-31007", amt(dollars)]))   # charges positive
    for d, total in monthly_payments(purchases, day=22):
        rows.append((d, [mdy(d), "AUTOPAY PAYMENT - THANK YOU", "R. QUILL", "-31007", amt(-total)]))
    rows.sort(key=lambda r: (r[0], r[1][1]), reverse=True)
    write(out / "amex.csv", ["Date", "Description", "Card Member", "Account #", "Amount"],
          [r for _, r in rows])


def citi(out):
    rng = random.Random(f"{SEED}-citi")
    purchases = spending(rng, merchants=MERCHANTS[7:12] + MERCHANTS[17:], bills=BILLS[3:4], scale=0.6)
    rows = []
    for d, raw, _, dollars in purchases:
        rows.append((d, [mdy(d), raw, amt(dollars), ""]))              # debit unsigned
    for d, total in monthly_payments(purchases, day=20):
        rows.append((d, [mdy(d), "PAYMENT THANK YOU", "", amt(-total)]))  # credit has a minus
    rows.sort(key=lambda r: (r[0], r[1][1]), reverse=True)
    write(out / "citi.csv", ["Date", "Description", "Debit", "Credit"], [r for _, r in rows])


def discover(out):
    rng = random.Random(f"{SEED}-discover")
    purchases = spending(rng, merchants=MERCHANTS[:2] + MERCHANTS[7:9] + MERCHANTS[12:14],
                         kale_per_month=1.0, bills=BILLS[4:5], scale=0.6)
    rows = []
    for d, raw, group, dollars in purchases:
        rows.append((d, [mdy(d), mdy(d + timedelta(days=1)), raw, amt(dollars),
                         CATEGORIES["discover"][group]]))               # purchases positive
    for d, total in monthly_payments(purchases, day=18):
        rows.append((d, [mdy(d), mdy(d), "INTERNET PAYMENT - THANK YOU", amt(-total),
                         "Payments and Credits"]))
    rows.sort(key=lambda r: (r[0], r[1][2]))                             # oldest first
    write(out / "discover.csv", ["Trans. Date", "Post Date", "Description", "Amount", "Category"],
          [r for _, r in rows])


def apple_card(out):
    rng = random.Random(f"{SEED}-apple")
    purchases = spending(rng, merchants=MERCHANTS[:6] + MERCHANTS[10:12], kale_per_month=2.0,
                         bills=BILLS[5:], scale=0.5)
    clean = {raw: raw.split(" BROOKLYN")[0].split(" BKLYN")[0].split(" NEW YORK")[0].title()
             for _, raw, _, _ in purchases}
    for v in KALE_VARIANTS:
        clean[v] = "Mr. Kale"
    rows = []
    for d, raw, group, dollars in purchases:
        rows.append((d, [mdy(d), mdy(d + timedelta(days=1)), raw, clean[raw],
                         CATEGORIES["apple"][group], "Purchase", amt(dollars), "R. Quill"]))
    for d, total in monthly_payments(purchases, day=28):
        rows.append((d, [mdy(d), mdy(d), "AUTOPAY PAYMENT", "Apple Card", "Payment", "Payment",
                         amt(-total), "R. Quill"]))
    rows.sort(key=lambda r: (r[0], r[1][2]), reverse=True)
    write(out / "apple_card.csv",
          ["Transaction Date", "Clearing Date", "Description", "Merchant", "Category", "Type",
           "Amount (USD)", "Purchased By"], [r for _, r in rows])


def quoted_edge_case(out):
    """Commas and quotes inside fields — a hand parser that splits on ',' breaks here."""
    rows = [
        ["4417", "03/14/2026", "03/15/2026", "MR. KALE, BROOKLYN NY", "Food & Drink", "Sale", "-13.25", ""],
        ["4417", "03/14/2026", "03/16/2026", 'BAR "THE GOWANUS" BROOKLYN', "Food & Drink", "Sale", "-42.00",
         "split with A., B., and C."],
        ["4417", "03/13/2026", "03/14/2026", "PROSPECT GREENS MARKET, INC.", "Groceries", "Sale", "-1,204.18",
         ""],
        ["4417", "03/12/2026", "03/12/2026", "FULTON STREET BOOKS", "Shopping", "Return", "18.99",
         'returned "Invisible Cities", wrong edition'],
        ["4417", "03/11/2026", "03/12/2026", "SQ *MR KALE BKLYN", "Food & Drink", "Sale", "-14.50",
         "line one\nline two"],
    ]
    write(out / "chase_card_quoted_commas.csv", CHASE_CARD_HEADER, rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dev", action="store_true", help=f"write to {DEV_INBOX.relative_to(REPO)}")
    ap.add_argument("--out", type=Path, help="write to this directory instead")
    args = ap.parse_args()
    out = args.out or (DEV_INBOX if args.dev else FIXTURES)
    out.mkdir(parents=True, exist_ok=True)
    print(f"🏦 fake bank exports → {out}")
    for make in (chase_card, chase_checking, bofa_checking, wells_fargo, capital_one, amex,
                 citi, discover, apple_card, quoted_edge_case):
        make(out)
    print("✅ done")


if __name__ == "__main__":
    main()
