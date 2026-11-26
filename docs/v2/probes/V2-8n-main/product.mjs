// 8n: writes the product (and only it) from a repo's HEAD commit into an empty folder. Usage: node product.mjs <repo> <out>
import { execFileSync } from 'node:child_process';
import { mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ALLOW = ['plugin', '.claude-plugin', 'README.md', 'LICENSE', '.github/workflows/main.yml'];
export const EXCLUDE = ['plugin/test'];
const FROM_GIT = ALLOW.filter((p) => !p.startsWith('.github/'));

// The v2 workflow's jobs run plugin/test/, which main does not hold. This one only validates the manifests.
const WORKFLOW = `name: main
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with:
          node-version: 20
      - run: npm install -g @anthropic-ai/claude-code
      - run: claude plugin validate plugin
`;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [repo, out] = process.argv.slice(2);
  if (!repo || !out) { console.error('usage: product.mjs <repo> <out>'); process.exit(2); }
  mkdirSync(out, { recursive: true });
  if (readdirSync(out).length) { console.error(`${out} is not empty`); process.exit(2); }
  const tar = execFileSync('git', ['-C', repo, 'archive', '--format=tar', 'HEAD', '--', ...FROM_GIT, ...EXCLUDE.map((e) => `:(exclude)${e}`)], { maxBuffer: 1 << 30 });
  execFileSync('tar', ['-x', '-C', out], { input: tar });
  mkdirSync(join(out, dirname(ALLOW.at(-1))), { recursive: true });
  writeFileSync(join(out, ALLOW.at(-1)), WORKFLOW);
}
