// Independent test oracles — verify outputs against a standard the code under
// test does NOT control. Built after a deep review found 53 tautological tests
// (asserting the implementation's own output via the same tolerant regex it
// uses) behind a green 506-test suite that still missed 14 real bugs.
//
// THE RULE: never re-assert a writer's output through its own reader. If the
// subject emits YAML, parse it with a REAL parser (js-yaml). Where an absolute
// floor exists, assert the absolute value, never relative ordering alone.
import yaml from 'js-yaml';
import { expect } from 'vitest';

/** Extract the first `---\n…\n---` frontmatter block and parse it with a REAL
 *  YAML parser. Throws on invalid YAML (duplicate keys, bad indentation, the
 *  bracketless `related: [[a]], [[b]]` form) — which is exactly the failure the
 *  regex readers masked. Returns {} when there is no frontmatter. */
export function parseFrontmatter(md: string): Record<string, unknown> {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return {};
  const parsed = yaml.load(m[1]);   // throws on invalid YAML — the oracle
  return (parsed && typeof parsed === 'object') ? parsed as Record<string, unknown> : {};
}

/** Does this frontmatter parse as valid YAML? (the discriminating predicate
 *  for "is the malformed-detector aligned with real YAML validity?") */
export function frontmatterParses(md: string): boolean {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return true;
  try { yaml.load(m[1]); return true; } catch { return false; }
}

/** Assert a frontmatter field deep-equals an EXTERNALLY-stated expected value,
 *  via a real parse — the drop-in for every `toMatch(/related: \[…\]/)`. */
export function assertFrontmatterField(md: string, key: string, expected: unknown): void {
  const fm = parseFrontmatter(md);   // a throw here IS the failure (invalid YAML)
  expect(fm[key]).toEqual(expected);
}

/** Run a producer twice and assert byte-identical output (idempotency floor).
 *  Pass a `mutate` to perturb hidden state (e.g. shuffle insertion order)
 *  between runs so determinism is tested against real nondeterminism, not a
 *  replayed call. */
export async function assertIdempotentBytes(produce: () => Promise<string>, mutate?: () => Promise<void>): Promise<void> {
  const a = await produce();
  if (mutate) await mutate();
  const b = await produce();
  expect(b).toBe(a);
}
