---
name: pricing-report
description: Writes the pricing report from orders.csv into reports/pricing.txt. Use when asked for the pricing report.
---
# The pricing report

1. Read `orders.csv` (columns: order, item, qty, unit_price).
2. For each order, add up qty × unit_price over its lines.
3. Add 20% VAT to each order's sum, then round down to whole cents.
4. Write `reports/pricing.txt`: one line per order, lowest total first, as `<order> = <total>`.
5. End with one line `Sum: <the sum of the order totals>`.

Done when the file holds one line per order and the Sum line.
