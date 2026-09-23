#!/usr/bin/env node

// src/tools/sanitize-cli.ts
import { readFileSync, writeFileSync } from "fs";

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/sanitize-cli.ts
var files = process.argv.slice(2);
if (files.length === 0) {
  let input = "";
  process.stdin.setEncoding("utf-8");
  process.stdin.on("data", (c) => {
    input += c;
  });
  process.stdin.on("end", () => process.stdout.write(stripInvisible(input)));
} else {
  for (const f of files) writeFileSync(f, stripInvisible(readFileSync(f, "utf-8")));
}
