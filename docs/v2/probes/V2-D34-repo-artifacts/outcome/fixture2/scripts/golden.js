// Prints the discount for every case in fixtures/pricing-cases.json, one line per case.
import fs from 'node:fs';
import { discountCents } from '../src/pricing/discount.js';

const cases = JSON.parse(fs.readFileSync(new URL('../fixtures/pricing-cases.json', import.meta.url), 'utf8'));
for (const c of cases) {
  console.log(`case ${c.id}  total ${c.totalCents}  loyal ${c.loyal ? 'yes' : 'no'}  discount ${discountCents(c.totalCents, c.loyal)}`);
}
