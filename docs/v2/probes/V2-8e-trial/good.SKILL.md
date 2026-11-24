---
name: pricing-report
description: Writes the pricing report from orders.csv into reports/pricing.txt. Use when asked for the pricing report.
---
# The pricing report

1. Read `orders.csv` (columns: order, item, qty, unit_price).
2. For each order, add up qty × unit_price over its lines.
3. Add 8% VAT to each order's sum, then round half up to whole cents.
4. Write `reports/pricing.txt`: one line per order, highest total first, as `<order>: <total>` with two decimals.
5. End with one line `TOTAL: <the sum of the order totals>`, with two decimals. Nothing else in the file.

Done when the file holds one line per order and the TOTAL line, and nothing more.
