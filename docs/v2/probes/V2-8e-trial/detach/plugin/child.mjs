// 8e's probe: wait 150 s, past the Bash tool's 2-minute limit and the session's end, then write the marker
import fs from 'node:fs';
const marker = process.argv[2];
fs.writeFileSync(`${marker}.start`, String(process.pid));
setTimeout(() => fs.writeFileSync(marker, `alive ${new Date().toISOString()}`), 150_000);
