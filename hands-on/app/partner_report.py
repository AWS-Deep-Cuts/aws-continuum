"""Build the order report that is sent to a partner shop.

Usage:
    python3 partner_report.py <order csv>

The order CSV has two columns: title,jacket
"""

import csv
import os
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
JACKET_DIR = os.path.join(BASE_DIR, "jackets")


def load_records():
    with open(os.path.join(DATA_DIR, "records.csv"), newline="", encoding="utf-8") as f:
        return {r["title"]: r for r in csv.DictReader(f)}


def read_jacket(name):
    path = os.path.join(JACKET_DIR, name)
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def build_report(csv_path):
    records = load_records()
    lines = ["# Order report", ""]
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            title = row.get("title", "").strip()
            record = records.get(title)
            if record is None:
                lines.append(f"- {title}: not in stock")
                continue
            lines.append(f"- {record['title']} / {record['artist']} ({record['year']}) {record['price']} JPY")
            jacket = row.get("jacket", "").strip()
            if jacket:
                lines.append("  jacket: " + read_jacket(jacket).replace("\n", "\n  "))
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 2:
        print("usage: python3 partner_report.py <order csv>", file=sys.stderr)
        return 2
    sys.stdout.write(build_report(sys.argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
