// 8e's probe: start a detached child that outlives this command, the skill's turn and the session, then return at once
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const marker = process.env.SB_PROBE_MARKER;
spawn(process.execPath, [path.join(path.dirname(fileURLToPath(import.meta.url)), 'child.mjs'), marker], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
console.log('started');
