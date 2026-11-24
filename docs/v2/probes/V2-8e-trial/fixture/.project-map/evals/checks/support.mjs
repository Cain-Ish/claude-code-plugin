// 8e's check for the case where the pricing skill should not be used: README.md gained a Support section that says
// support answers within one day. Exit 0 for a pass
import fs from 'node:fs';

const t = fs.readFileSync('README.md', 'utf8');
process.exit(/^#+\s*Support\b/im.test(t) && /one (business |working )?day/i.test(t) ? 0 : 1);
