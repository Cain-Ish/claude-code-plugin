/** Extract the first `---\n…\n---` frontmatter block and parse it with a REAL
 *  YAML parser. Throws on invalid YAML (duplicate keys, bad indentation, the
 *  bracketless `related: [[a]], [[b]]` form) — which is exactly the failure the
 *  regex readers masked. Returns {} when there is no frontmatter. */
export declare function parseFrontmatter(md: string): Record<string, unknown>;
/** Does this frontmatter parse as valid YAML? (the discriminating predicate
 *  for "is the malformed-detector aligned with real YAML validity?") */
export declare function frontmatterParses(md: string): boolean;
/** Assert a frontmatter field deep-equals an EXTERNALLY-stated expected value,
 *  via a real parse — the drop-in for every `toMatch(/related: \[…\]/)`. */
export declare function assertFrontmatterField(md: string, key: string, expected: unknown): void;
/** Run a producer twice and assert byte-identical output (idempotency floor).
 *  Pass a `mutate` to perturb hidden state (e.g. shuffle insertion order)
 *  between runs so determinism is tested against real nondeterminism, not a
 *  replayed call. */
export declare function assertIdempotentBytes(produce: () => Promise<string>, mutate?: () => Promise<void>): Promise<void>;
//# sourceMappingURL=test-oracle.d.ts.map