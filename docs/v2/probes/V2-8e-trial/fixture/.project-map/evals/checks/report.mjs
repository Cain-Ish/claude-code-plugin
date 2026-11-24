// 8e's check for the pricing report: reports/pricing.txt in the working folder holds each order's total with 8% VAT,
// rounded half up to cents, highest first, one "<order>: <total>" line each, then "TOTAL: <sum>". Exit 0 for a pass
import fs from 'node:fs';

const rows = fs.readFileSync('orders.csv', 'utf8').trim().split('\n').slice(1).map((l) => l.split(','));
const sums = new Map();
for (const [order, , qty, price] of rows) sums.set(order, (sums.get(order) ?? 0) + Number(qty) * Math.round(Number(price) * 100));
const cents = [...sums].map(([o, c]) => [o, Math.floor(c * 1.08 + 0.5 + 1e-9)]).sort((a, b) => b[1] - a[1]);
const money = (c) => (c / 100).toFixed(2);
const want = [...cents.map(([o, c]) => `${o}: ${money(c)}`), `TOTAL: ${money(cents.reduce((s, [, c]) => s + c, 0))}`];
let got = [];
try { got = fs.readFileSync('reports/pricing.txt', 'utf8').split(/\r?\n/).map((l) => l.trim()).filter(Boolean); } catch {}
process.exit(JSON.stringify(got) === JSON.stringify(want) ? 0 : 1);
