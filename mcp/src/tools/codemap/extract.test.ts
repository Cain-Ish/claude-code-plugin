/**
 * Task A2 tests — Tier-0 regex symbol + import extraction.
 * resolveId is stubbed as a pure membership lookup over a fixed id set:
 * extract.ts owns candidate expansion (candidateIds), the resolver only
 * answers "is this exact id a scanned file" — that split is the contract
 * build-graph (Task A3) relies on.
 */
import { describe, expect, it } from 'vitest';
import { candidateIds, extractFile } from './extract.js';
import type { ExtractResult } from './types.js';

function stubResolver(known: string[]): (spec: string, fromId: string) => string | null {
  const set = new Set(known);
  return (spec) => (set.has(spec) ? spec : null);
}

function symbolNames(r: ExtractResult): string[] {
  return r.symbols.map((s) => s.name);
}

describe('candidateIds', () => {
  it('expands an extensionless ./ spec to extension + index variants', () => {
    const c = candidateIds('./x', 'src/a.ts');
    expect(c).toContain('src/x.ts');
    expect(c).toContain('src/x.tsx');
    expect(c).toContain('src/x.js');
    expect(c).toContain('src/x.jsx');
    expect(c).toContain('src/x.mjs');
    expect(c).toContain('src/x.cjs');
    expect(c).toContain('src/x.py');
    expect(c).toContain('src/x/index.ts');
    expect(c).toContain('src/x/index.js');
    expect(c).toContain('src/x/__init__.py');
    // .ts first: TS-repo bias, first-match-wins ordering is part of the contract
    expect(c[0]).toBe('src/x.ts');
  });

  it('normalizes ../ against the importing file dir', () => {
    const c = candidateIds('../lib/util', 'src/deep/a.ts');
    expect(c).toContain('src/lib/util.ts');
    expect(c).toContain('src/lib/util/index.ts');
  });

  it('keeps an already-present known extension as the first candidate', () => {
    const c = candidateIds('./req.cjs', 'src/main.ts');
    expect(c[0]).toBe('src/req.cjs');
  });

  it('maps ESM .js/.jsx specifiers to .ts/.tsx source candidates', () => {
    // This repo's own house style: import './x.js' resolving to x.ts
    expect(candidateIds('./b.js', 'src/main.ts')).toEqual(['src/b.js', 'src/b.ts']);
    expect(candidateIds('./c.jsx', 'src/main.ts')).toEqual(['src/c.jsx', 'src/c.tsx']);
  });

  it('collapses interior ./ and ../ segments', () => {
    const c = candidateIds('./a/../b', 'src/m.ts');
    expect(c[0]).toBe('src/b.ts');
  });

  it('returns no candidates when the spec escapes the repo root', () => {
    expect(candidateIds('../../x', 'a.ts')).toEqual([]);
  });

  it('returns only the literal path for an unknown extension', () => {
    expect(candidateIds('./styles.css', 'src/a.ts')).toEqual(['src/styles.css']);
  });

  it('resolves "." to the importing dir index variants', () => {
    const c = candidateIds('.', 'src/pkg/a.ts');
    expect(c).toContain('src/pkg/index.ts');
  });

  it('lang py restricts expansion to .py + __init__.py (no .ts/index leakage)', () => {
    const c = candidateIds('./x', 'src/a.py', 'py');
    expect(c).toEqual(['src/x.py', 'src/x/__init__.py']);
  });

  it('lang ts restricts expansion: no .py, no __init__.py', () => {
    const c = candidateIds('./x', 'src/a.ts', 'ts');
    expect(c).toContain('src/x.ts');
    expect(c).toContain('src/x/index.ts');
    expect(c).not.toContain('src/x.py');
    expect(c).not.toContain('src/x/__init__.py');
  });

  it('omitted lang keeps the legacy full expansion (both .py and .ts families)', () => {
    const c = candidateIds('./x', 'src/a.ts');
    expect(c).toContain('src/x.ts');
    expect(c).toContain('src/x.py');
    expect(c).toContain('src/x/index.ts');
    expect(c).toContain('src/x/__init__.py');
  });
});

describe('extractFile ts/js', () => {
  const src = [
    "import { a } from './b.js';",
    "import * as fs from 'node:fs';",
    "import react from 'react';",
    "import react2 from 'react';",
    "import './side-effect.js';",
    "export { helper } from './util';",
    'import {',
    '  wide,',
    "} from './lazy.js';",
    "const req = require('./req.cjs');",
    "const dyn = import('./lazy.js');",
    '',
    'export function foo() {}',
    'export async function bar() {}',
    'export class Baz {}',
    'export const qux = 1;',
    'let hidden = 2;',
    'class Internal {}',
    'async function plainAsync() {}',
    'export default function main() {}',
    'export { alpha, beta as gamma };',
    'export type { Shape };',
  ].join('\n');

  const known = ['src/b.ts', 'src/util/index.ts', 'src/lazy.ts', 'src/req.cjs'];
  const run = () => extractFile('src/main.ts', src, 'ts', stubResolver(known));

  it('captures exported and top-level symbols with kinds', () => {
    const r = run();
    expect(r.symbols).toContainEqual({ name: 'foo', kind: 'function' });
    expect(r.symbols).toContainEqual({ name: 'bar', kind: 'function' });
    expect(r.symbols).toContainEqual({ name: 'Baz', kind: 'class' });
    expect(r.symbols).toContainEqual({ name: 'qux', kind: 'const' });
    expect(r.symbols).toContainEqual({ name: 'Internal', kind: 'class' });
    expect(r.symbols).toContainEqual({ name: 'plainAsync', kind: 'function' });
    expect(r.symbols).toContainEqual({ name: 'main', kind: 'default' });
    expect(r.symbols).toContainEqual({ name: 'alpha', kind: 'const' });
    expect(r.symbols).toContainEqual({ name: 'gamma', kind: 'const' });
    expect(r.symbols).toContainEqual({ name: 'Shape', kind: 'const' });
    expect(symbolNames(r)).not.toContain('hidden');
    expect(symbolNames(r)).not.toContain('beta');
  });

  it('resolves relative imports (from/require/dynamic/multiline) to sorted deduped ids', () => {
    const r = run();
    expect(r.imports).toEqual(['src/b.ts', 'src/lazy.ts', 'src/req.cjs', 'src/util/index.ts']);
  });

  it('counts bare specifiers as external, deduped, and never as internal edges', () => {
    const r = run();
    expect(r.externalImports).toBe(2); // node:fs + react (react deduped)
    expect(r.imports).not.toContain('react');
    expect(r.imports).not.toContain('node:fs');
  });

  it('drops unresolved relative specifiers entirely', () => {
    const r = run();
    for (const id of r.imports) expect(id).not.toMatch(/side-effect/);
  });

  it('captures a bare export default with the placeholder name', () => {
    const r = extractFile('src/d.ts', 'export default { a: 1 };\n', 'ts', stubResolver([]));
    expect(r.symbols).toContainEqual({ name: 'default', kind: 'default' });
  });

  it('is deterministic: identical input yields identical output', () => {
    expect(run()).toEqual(run());
  });

  it('extensionless TS import never resolves to a same-basename .py (dropped, not external)', () => {
    // The inverse of the confirmed py->ts misresolution: a TS module system
    // cannot import a .py file, so the only-candidate-on-disk must NOT match.
    const r = extractFile(
      'src/main.ts',
      "import { u } from './utils';\n",
      'ts',
      stubResolver(['src/utils.py']),
    );
    expect(r.imports).toEqual([]);
    expect(r.externalImports).toBe(0);
  });
});

describe('extractFile py', () => {
  const src = [
    'import os',
    'import numpy as np, sys',
    'from collections import OrderedDict',
    'from . import sibling',
    'from .helper import thing',
    'from ..top import other',
    '',
    'def top_fn():',
    '    pass',
    '',
    'async def async_fn():',
    '    pass',
    '',
    'class TopClass:',
    '    def method(self):',
    '        pass',
    '',
    '    class Nested:',
    '        pass',
  ].join('\n');

  const known = ['pkg/sub/sibling.py', 'pkg/sub/helper.py', 'pkg/top.py'];
  const run = () => extractFile('pkg/sub/mod.py', src, 'py', stubResolver(known));

  it('captures top-level def/class only (indented members excluded)', () => {
    const r = run();
    expect(r.symbols).toContainEqual({ name: 'top_fn', kind: 'function' });
    expect(r.symbols).toContainEqual({ name: 'async_fn', kind: 'function' });
    expect(r.symbols).toContainEqual({ name: 'TopClass', kind: 'class' });
    expect(symbolNames(r)).not.toContain('method');
    expect(symbolNames(r)).not.toContain('Nested');
  });

  it('resolves relative-dot modules against the file package path', () => {
    const r = run();
    expect(r.imports).toEqual(['pkg/sub/helper.py', 'pkg/sub/sibling.py', 'pkg/top.py']);
  });

  it('counts absolute module imports as external, deduped', () => {
    const r = run();
    expect(r.externalImports).toBe(4); // os, numpy, sys, collections
  });

  it('resolves a relative package import through __init__.py', () => {
    const r = extractFile(
      'pkg/main.py',
      'from .util import helper\n',
      'py',
      stubResolver(['pkg/util/__init__.py']),
    );
    expect(r.imports).toEqual(['pkg/util/__init__.py']);
  });

  it('handles from-dot import lists (each name a sibling candidate)', () => {
    const r = extractFile(
      'pkg/a.py',
      'from . import one, two\n',
      'py',
      stubResolver(['pkg/one.py', 'pkg/two.py']),
    );
    expect(r.imports).toEqual(['pkg/one.py', 'pkg/two.py']);
  });

  it('"from . import utils" resolves the .py sibling even when a same-basename .ts exists', () => {
    // Confirmed cross-language misresolution: first-match-wins put '.ts'
    // first, so the TS file stole the .py file's rank inflow pre-fix.
    const r = extractFile(
      'src/mod.py',
      'from . import utils\n',
      'py',
      stubResolver(['src/utils.ts', 'src/utils.py']),
    );
    expect(r.imports).toEqual(['src/utils.py']);
  });
});
