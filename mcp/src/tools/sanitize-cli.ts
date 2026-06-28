#!/usr/bin/env node
// Bundled sanitizer CLI — applies the canonical stripInvisible() so the bash side (dream-snapshot)
// can clean untrusted transcripts before the dream-runner agent reads them, reusing the exact TS
// codepoint set (no drift). Two modes:
//   - no args:        stdin -> stdout  (e.g. `node sanitize-cli.bundle.js < src > dst`)
//   - one+ file args: rewrite each file IN PLACE
import { readFileSync, writeFileSync } from 'fs';
import { stripInvisible } from './sanitize.js';

const files = process.argv.slice(2);
if (files.length === 0) {
  let input = '';
  process.stdin.setEncoding('utf-8');
  process.stdin.on('data', (c) => { input += c; });
  process.stdin.on('end', () => process.stdout.write(stripInvisible(input)));
} else {
  for (const f of files) writeFileSync(f, stripInvisible(readFileSync(f, 'utf-8')));
}
