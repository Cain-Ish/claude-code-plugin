/**
 * P3a Task A2 — Tier-0 symbol + import extraction (pure regex, zero deps).
 *
 * KNOWN LIMITS (accepted: this feeds a PageRank ranking heuristic, not a
 * compiler — Aider's repo-map is similarly approximate; the Phase 5 opt-in
 * WASM tree-sitter tier is the fidelity upgrade):
 * - No scope analysis: "top-level" means column 0. Specifiers inside comments
 *   or string literals can false-positive; template-literal / variable
 *   specifiers (require(x), import(`./${y}`)) are never seen.
 * - TS `interface`/`type` declarations are not captured (SymbolKind has no
 *   such kind in the shared contract); `export type { X }` names are.
 * - Python: parenthesized from-import lists spanning multiple lines are only
 *   parsed on the `from ...` line; absolute (non-dot) module imports resolve
 *   in-repo only when the import's first segment is a real package (has an
 *   __init__.py) under the repo root or a 'src/' layout (D037) — anything
 *   else (stdlib, third-party, or a package root this heuristic doesn't try)
 *   stays external.
 * - TS/JS bare specifiers resolve in-repo only via tsconfig/jsconfig
 *   `compilerOptions.paths` or `baseUrl` (D037, read once per scan); a repo
 *   with neither configured treats every bare specifier as external, same as
 *   before.
 * - Relative specifiers that resolve to no scanned file (e.g. './x.css') are
 *   dropped: not edges, not counted in externalImports (which by contract
 *   counts bare/package specifiers only).
 *
 * Purity contract: no fs, no env, no clock — same input, byte-identical
 * output. Candidate expansion for relative specifiers happens HERE
 * (candidateIds); the injected resolveId only answers membership over the
 * scanned-id set, which keeps extraction testable per-file and lets
 * build-graph (Task A3) pass a trivial Set lookup.
 */

import type { ExtractResult, ExtractedSymbol, Lang, SymbolKind } from './types.js';

/** Extensions the scanner (Task A1) admits — the only ids that can exist. */
const KNOWN_EXTS = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py'];
const INDEX_EXTS = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'];
/** ESM house style (this repo included): `import './x.js'` names x.ts on disk. */
const ESM_SOURCE_ALIAS: Record<string, string> = { '.js': '.ts', '.jsx': '.tsx' };

/**
 * Pure string math: normalize a relative specifier against the importing
 * file's POSIX id and expand it into candidate scanned-file ids, ordered so
 * a first-match-wins lookup prefers exact extension, then .ts-family, then
 * index/__init__ package entries. Returns [] when the spec escapes the repo
 * root ('..' past the top) — such ids cannot exist in the scan set.
 *
 * `lang` = the IMPORTING file's language, and it restricts the expansion
 * (adversarial-review fix): a Python `from . import utils` can only name
 * utils.py / utils/__init__.py — without the restriction it resolved to a
 * same-basename utils.TS when both existed (first-match-wins put '.ts'
 * first), handing the .py file's rank inflow to an unrelated TS file; the
 * inverse (TS extensionless import resolving to .py) is equally impossible
 * in real module systems. Omitting `lang` keeps the legacy all-ext behavior.
 */
export function candidateIds(spec: string, fromId: string, lang?: Lang): string[] {
  const base = joinPosix(spec, fromId);
  if (base === null) return [];
  return expandBase(base, lang);
}

/**
 * Extension/index/__init__ expansion shared by relative-specifier resolution
 * (candidateIds, base = a joinPosix'd path) and absolute/aliased specifier
 * resolution (base = a repo-root-relative path with no '.'/'..' math) — same
 * first-match-wins contract, just fed a differently-computed base (D037).
 */
function expandBase(base: string, lang?: Lang): string[] {
  const fileExts = lang === 'py' ? ['.py'] : lang ? KNOWN_EXTS.filter((e) => e !== '.py') : KNOWN_EXTS;
  const wantIndex = lang !== 'py';
  const wantInit = lang !== 'ts' && lang !== 'js';

  const lastSeg = base === '' ? '' : base.slice(base.lastIndexOf('/') + 1);
  const extMatch = /\.[A-Za-z0-9]+$/.exec(lastSeg);
  const ext = extMatch ? extMatch[0] : '';

  if (ext && KNOWN_EXTS.includes(ext)) {
    const out = [base];
    const alias = ESM_SOURCE_ALIAS[ext];
    if (alias) out.push(base.slice(0, -ext.length) + alias);
    return out;
  }
  if (ext) return [base]; // unknown extension (.css, .json, ...): literal or nothing

  const out: string[] = [];
  if (base !== '') for (const e of fileExts) out.push(base + e);
  const dirPrefix = base === '' ? '' : base + '/';
  if (wantIndex) for (const e of INDEX_EXTS) out.push(dirPrefix + 'index' + e);
  if (wantInit) out.push(dirPrefix + '__init__.py');
  return out;
}

/**
 * tsconfig.json/jsconfig.json compilerOptions relevant to module resolution
 * (D037). Read once per scan by scan-sources.ts's readTsPathConfig — extract.ts
 * stays fs-free per its purity contract; this is a plain data param.
 */
export interface TsPathConfig {
  /** POSIX-relative to repo root; '.' or '' means the repo root itself */
  baseUrl?: string;
  /** e.g. { "@/*": ["src/*"] } — wildcard ('*') or exact keys, first match wins */
  paths?: Record<string, string[]>;
}

/** '@/*' matched against '@/foo' captures 'foo'; an exact key matches only
 *  itself (captures ''); anything else is null (no match). */
function matchPathKey(spec: string, key: string): string | null {
  const star = key.indexOf('*');
  if (star === -1) return spec === key ? '' : null;
  const prefix = key.slice(0, star);
  const suffix = key.slice(star + 1);
  if (!spec.startsWith(prefix) || !spec.endsWith(suffix)) return null;
  if (spec.length < prefix.length + suffix.length) return null;
  return spec.slice(prefix.length, spec.length - suffix.length);
}

function applyPathTarget(target: string, captured: string): string {
  return target.includes('*') ? target.replace('*', captured) : target;
}

/**
 * Candidate repo-root-relative base paths (pre-extension-expansion) for a
 * bare TS/JS specifier, per tsconfig `paths` (checked first — first matching
 * key wins, all its targets are tried) and then `baseUrl` (bare specifier
 * resolved directly under baseUrl — covers plain `src/...`-style imports
 * when baseUrl is the repo root). [] when no config or no match at all.
 */
export function resolveAliasBases(spec: string, config?: TsPathConfig): string[] {
  if (!config) return [];
  const bases: string[] = [];
  for (const [key, targets] of Object.entries(config.paths ?? {})) {
    const captured = matchPathKey(spec, key);
    if (captured === null) continue;
    for (const target of targets) bases.push(applyPathTarget(target, captured));
  }
  if (bases.length === 0 && config.baseUrl !== undefined) {
    const baseUrl = config.baseUrl === '.' ? '' : config.baseUrl.replace(/\/$/, '');
    bases.push(baseUrl ? `${baseUrl}/${spec}` : spec);
  }
  return bases;
}

/** Anchors tried for an absolute (non-dot) Python import, in order: the repo
 *  root, then a 'src/' layout. Gated on the import's FIRST segment resolving
 *  to a real in-repo package (an __init__.py present under that anchor) so a
 *  stdlib/third-party name that coincidentally collides with a repo path
 *  (e.g. a top-level io.py) is never misclassified as internal (D037). */
const PY_ABS_ANCHORS = ['', 'src/'];

function resolveAbsolutePython(
  module: string,
  fromId: string,
  resolveId: (spec: string, fromId: string) => string | null,
): string | null {
  const parts = module.split('.').filter((p) => p !== '');
  if (parts.length === 0) return null;
  const joined = parts.join('/');
  for (const anchor of PY_ABS_ANCHORS) {
    if (resolveId(`${anchor}${parts[0]}/__init__.py`, fromId) === null) continue;
    for (const candidate of [`${anchor}${joined}.py`, `${anchor}${joined}/__init__.py`]) {
      const hit = resolveId(candidate, fromId);
      if (hit !== null) return hit;
    }
  }
  return null;
}

function resolveAliasSpec(
  spec: string,
  fromId: string,
  lang: Lang,
  resolveId: (spec: string, fromId: string) => string | null,
  tsConfig?: TsPathConfig,
): string | null {
  for (const base of resolveAliasBases(spec, tsConfig)) {
    for (const candidate of expandBase(base, lang)) {
      const hit = resolveId(candidate, fromId);
      if (hit !== null) return hit;
    }
  }
  return null;
}

/** './a/../b' + 'src/m.ts' -> 'src/b'; null when '..' escapes the root. */
function joinPosix(spec: string, fromId: string): string | null {
  const stack = fromId.split('/').slice(0, -1).filter((s) => s !== '');
  for (const seg of spec.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') {
      if (stack.length === 0) return null;
      stack.pop();
    } else {
      stack.push(seg);
    }
  }
  return stack.join('/');
}

export function extractFile(
  id: string,
  src: string,
  lang: Lang,
  resolveId: (spec: string, fromId: string) => string | null,
  tsConfig?: TsPathConfig,
): ExtractResult {
  const parsed = lang === 'py' ? parsePython(src) : parseTsJs(src);

  const resolved = new Set<string>();
  const external = new Set<string>();
  for (const spec of parsed.relativeSpecs) {
    let hit: string | null = null;
    for (const candidate of candidateIds(spec, id, lang)) {
      hit = resolveId(candidate, id);
      if (hit !== null) break;
    }
    if (hit !== null) resolved.add(hit);
    // else: unresolved relative spec — dropped (see header contract)
  }
  for (const spec of parsed.externalSpecs) {
    // D037: an absolute in-repo import (Python) or an aliased/baseUrl bare
    // specifier (TS/JS) is still "external" in shape but may resolve inside
    // the scanned tree — try before falling back to the external count.
    const hit =
      lang === 'py'
        ? resolveAbsolutePython(spec, id, resolveId)
        : resolveAliasSpec(spec, id, lang, resolveId, tsConfig);
    if (hit !== null) resolved.add(hit);
    else external.add(spec);
  }

  return {
    symbols: parsed.symbols,
    imports: Array.from(resolved).sort(),
    externalImports: external.size,
  };
}

interface ParsedFile {
  symbols: ExtractedSymbol[];
  /** relative specifiers, normalized to './x' | '../x' form, pre-resolution */
  relativeSpecs: string[];
  externalSpecs: string[];
}

// --- TS/JS -----------------------------------------------------------------

const RE_EXPORT_FN = /^export\s+(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/gm;
const RE_EXPORT_CLASS = /^export\s+(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/gm;
const RE_EXPORT_VAR = /^export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)/gm;
const RE_EXPORT_BRACE = /^export\s+(?:type\s+)?\{([^}]*)\}/gm;
const RE_EXPORT_DEFAULT = /^export\s+default\b(?:\s+(?:async\s+)?(?:function\s*\*?|class)\s+([A-Za-z_$][\w$]*))?/m;
const RE_PLAIN_FN = /^(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/gm;
const RE_PLAIN_CLASS = /^(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/gm;

// Specifier sources. RE_FROM deliberately matches only the `from '<spec>'`
// tail so multiline `import { ... } from './x'` statements still hit; it
// covers both import-from and export-from.
const RE_FROM = /\bfrom\s*(['"])([^'"\n]+)\1/g;
const RE_SIDE_EFFECT_IMPORT = /^\s*import\s*(['"])([^'"\n]+)\1/gm;
const RE_REQUIRE = /\brequire\s*\(\s*(['"])([^'"\n]+)\1\s*\)/g;
const RE_DYNAMIC_IMPORT = /\bimport\s*\(\s*(['"])([^'"\n]+)\1\s*\)/g;

function parseTsJs(src: string): ParsedFile {
  const symbols: ExtractedSymbol[] = [];
  const seen = new Set<string>();
  const push = (name: string, kind: SymbolKind): void => {
    const key = kind + ':' + name;
    if (seen.has(key)) return;
    seen.add(key);
    symbols.push({ name, kind });
  };

  for (const m of src.matchAll(RE_EXPORT_FN)) push(m[1], 'function');
  for (const m of src.matchAll(RE_EXPORT_CLASS)) push(m[1], 'class');
  for (const m of src.matchAll(RE_EXPORT_VAR)) push(m[1], 'const');
  for (const m of src.matchAll(RE_EXPORT_BRACE)) {
    for (const name of parseBraceNames(m[1])) push(name, 'const');
  }
  const def = RE_EXPORT_DEFAULT.exec(src);
  if (def) push(def[1] ?? 'default', 'default');
  for (const m of src.matchAll(RE_PLAIN_FN)) push(m[1], 'function');
  for (const m of src.matchAll(RE_PLAIN_CLASS)) push(m[1], 'class');

  const relativeSpecs: string[] = [];
  const externalSpecs: string[] = [];
  for (const re of [RE_FROM, RE_SIDE_EFFECT_IMPORT, RE_REQUIRE, RE_DYNAMIC_IMPORT]) {
    for (const m of src.matchAll(re)) {
      const spec = m[2];
      if (isRelativeSpec(spec)) relativeSpecs.push(spec);
      else externalSpecs.push(spec);
    }
  }
  return { symbols, relativeSpecs, externalSpecs };
}

/** '{ alpha, beta as gamma, type Shape }' -> exported names (post-`as`). */
function parseBraceNames(inner: string): string[] {
  const names: string[] = [];
  for (const part of inner.split(',')) {
    let name = part.trim();
    if (name.startsWith('type ')) name = name.slice(5).trim();
    const asIdx = name.indexOf(' as ');
    if (asIdx >= 0) name = name.slice(asIdx + 4).trim();
    if (/^[A-Za-z_$][\w$]*$/.test(name)) names.push(name);
  }
  return names;
}

function isRelativeSpec(spec: string): boolean {
  return spec === '.' || spec === '..' || spec.startsWith('./') || spec.startsWith('../');
}

// --- Python ----------------------------------------------------------------

// def/class anchored at column 0 = top-level; imports allow indentation
// (try/except ImportError blocks are common) — asymmetry is deliberate.
const RE_PY_DEF = /^(?:async\s+)?def\s+([A-Za-z_]\w*)/gm;
const RE_PY_CLASS = /^class\s+([A-Za-z_]\w*)/gm;
const RE_PY_IMPORT = /^\s*import\s+(.+)$/gm;
const RE_PY_FROM = /^\s*from\s+([.\w]+)\s+import\s+(.+)$/gm;

function parsePython(src: string): ParsedFile {
  const symbols: ExtractedSymbol[] = [];
  const seen = new Set<string>();
  const push = (name: string, kind: SymbolKind): void => {
    const key = kind + ':' + name;
    if (seen.has(key)) return;
    seen.add(key);
    symbols.push({ name, kind });
  };
  for (const m of src.matchAll(RE_PY_DEF)) push(m[1], 'function');
  for (const m of src.matchAll(RE_PY_CLASS)) push(m[1], 'class');

  const relativeSpecs: string[] = [];
  const externalSpecs: string[] = [];

  for (const m of src.matchAll(RE_PY_IMPORT)) {
    for (const mod of parsePyNameList(m[1])) externalSpecs.push(mod);
  }

  for (const m of src.matchAll(RE_PY_FROM)) {
    const module = m[1];
    const dots = /^\.+/.exec(module)?.[0].length ?? 0;
    if (dots === 0) {
      externalSpecs.push(module);
      continue;
    }
    // N leading dots = current package (1) then one '..' per extra dot;
    // remainder dots are path separators against the file's package dir.
    const prefix = dots === 1 ? './' : '../'.repeat(dots - 1);
    const rest = module.slice(dots);
    if (rest !== '') {
      relativeSpecs.push(prefix + rest.replace(/\./g, '/'));
    } else {
      // `from . import a, b` — each imported name is a sibling-module
      // candidate; names that are plain attrs of __init__ simply not resolve.
      for (const name of parsePyNameList(m[2])) relativeSpecs.push(prefix + name);
    }
  }
  return { symbols, relativeSpecs, externalSpecs };
}

/** 'numpy as np, sys' | '(a, b)' -> original (pre-`as`) names; '*' skipped. */
function parsePyNameList(list: string): string[] {
  const names: string[] = [];
  for (const part of list.replace(/[()\\]/g, '').split(',')) {
    const name = part.trim().split(/\s+as\s+/)[0].trim();
    if (/^[A-Za-z_][\w.]*$/.test(name)) names.push(name);
  }
  return names;
}
