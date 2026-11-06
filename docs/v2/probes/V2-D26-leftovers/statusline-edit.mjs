// The settings edit the README states, done by script for the probe: a statusLine whose command runs v1's
// buddy-statusline.sh is removed, or replaced by the earlier command v1 kept in SB_BUDDY_CHAIN='...'.
// Usage: node statusline-edit.mjs <settings.json>
import fs from 'node:fs';

const file = process.argv[2];
const s = JSON.parse(fs.readFileSync(file, 'utf8'));
const cmd = s.statusLine?.command ?? '';
if (!/buddy-statusline\.sh/.test(cmd)) { console.log('no v1 statusLine'); process.exit(0); }
const chain = /^SB_BUDDY_CHAIN='((?:[^']|'\\'')*)' /.exec(cmd)?.[1].replace(/'\\''/g, "'");
if (chain) s.statusLine = { type: 'command', command: chain }; else delete s.statusLine;
fs.writeFileSync(file, JSON.stringify(s, null, 2) + '\n');
console.log(chain ? `statusLine restored: ${chain}` : 'statusLine removed');
