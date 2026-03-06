import argparse
import csv
from collections import defaultdict
from pathlib import Path

import yfinance as yf


REQUIRED_COLUMNS = ["ticker", "num_shares", "broker", "type"]


def format_currency(amount: float) -> str:
    return f"${amount:,.2f}"


def pull_info(source: str) -> tuple[dict[str, dict[str, float]], float]:
    """Populate a CSV with a value column using current Yahoo Finance prices.

    Expected schema: ticker,num_shares,broker,type
    """

    with open(source, "r", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("CSV file is empty.")

        missing_columns = [column for column in REQUIRED_COLUMNS if column not in reader.fieldnames]
        if missing_columns:
            raise ValueError(
                "CSV is missing required columns: " + ", ".join(missing_columns)
            )

        data = []
        broker_totals: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
        grand_total = 0.0

        for row in reader:
            ticker = row["ticker"]
            num_shares = float(row["num_shares"])
            broker = row["broker"]
            account_type = row["type"]
            if ticker == "CASH":
                current_price = 1.0
            else:
                stock_info = yf.Ticker(ticker).info
                current_price = stock_info["regularMarketPrice"]
            value = current_price * num_shares
            data.append([ticker, num_shares, broker, account_type, value])
            broker_totals[broker][account_type] += value
            grand_total += value

    # Write the updated data back to the CSV file
    with open(source, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["ticker", "num_shares", "broker", "type", "value"])  # Write the header
        writer.writerows(data)  # Write the updated data rows

    return broker_totals, grand_total


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Update a holdings CSV with current Yahoo Finance values."
    )
    parser.add_argument(
        "source",
        nargs="?",
        type=Path,
        default=Path("data.csv"),
        help="Path to the CSV file to update in place. Defaults to data.csv.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.source.exists():
        raise FileNotFoundError(
            f"Could not find CSV file at '{args.source}'. "
            "Supply a path explicitly, for example: pull_info.py /path/to/holdings.csv"
        )
    broker_totals, grand_total = pull_info(str(args.source))

    for broker, account_totals in broker_totals.items():
        print(f"{broker}:")
        for account_type, value in account_totals.items():
            print(f"  {account_type}: {format_currency(value)}")

    print(f"Total portfolio value: {format_currency(grand_total)}")


if __name__ == "__main__":
    main()
