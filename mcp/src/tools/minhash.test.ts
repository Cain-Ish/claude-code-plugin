import { describe, it, expect } from 'vitest';
import {
  proseTokens, shingles, signatureOf, minhashSignature, jaccardEstimate, nearDuplicatePairs,
  isEmptySignature, NUM_HASHES, type PageSig,
} from './minhash.js';

describe('proseTokens — what counts as prose', () => {
  it('strips frontmatter, ai-block, and [[link]] markup; lowercases to alnum tokens', () => {
    const page = [
      '---', 'title: X', 'tags: [alpha, beta]', '---',
      '<!-- ai:begin -->', 'claim: SHOULDNOTCOUNT', '<!-- ai:end -->',
      'Real Prose here, see [[other-page]] for More.',
    ].join('\n');
    const toks = proseTokens(page);
    expect(toks).toContain('real');
    expect(toks).toContain('prose');
    expect(toks).not.toContain('shouldnotcount'); // ai-block stripped
    expect(toks).not.toContain('title');          // frontmatter stripped
    expect(toks).not.toContain('other');          // [[link]] target dropped (structure, not prose)
  });
});

describe('shingles', () => {
  it('a page shorter than k collapses to one whole-text shingle', () => {
    expect([...shingles('hi there')]).toEqual(['hi there']); // 2 words < k=3
  });
});

describe('minhash signatures + jaccard', () => {
  const A = 'the quick brown fox jumps over the lazy dog near the river bank at dawn';
  const Anear = 'the quick brown fox jumps over the lazy dog near the river bank at dusk'; // 1 trailing word changed
  const B = 'completely unrelated content about postgres indexes vacuum analyze and query plans';

  it('identical content -> similarity exactly 1.0', () => {
    expect(jaccardEstimate(signatureOf(A), signatureOf(A))).toBe(1);
  });
  it('near-duplicate (one word changed) -> high similarity', () => {
    expect(jaccardEstimate(signatureOf(A), signatureOf(Anear))).toBeGreaterThan(0.6);
  });
  it('unrelated content -> low similarity', () => {
    expect(jaccardEstimate(signatureOf(A), signatureOf(B))).toBeLessThan(0.3);
  });
  it('signature length is NUM_HASHES', () => {
    expect(signatureOf(A).length).toBe(NUM_HASHES);
  });
});

describe('determinism (cross-platform reproducibility)', () => {
  it('same input -> byte-identical signature across recomputations', () => {
    const s1 = signatureOf('deterministic content for hashing stability across runs and machines');
    const s2 = signatureOf('deterministic content for hashing stability across runs and machines');
    expect([...s1]).toEqual([...s2]);
  });
  it('signature values stay within uint32 range (guards Math.imul / seed drift)', () => {
    for (const v of signatureOf('the quick brown fox jumps')) {
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThanOrEqual(0xffffffff);
    }
  });
  it('pins exact signature values (cross-version drift lock — a seed/LCG/djb2/shingling change fails this)', () => {
    const sig = signatureOf('the quick brown fox jumps');
    expect(sig[0]).toBe(2181256834);
    expect(sig[1]).toBe(1304033094);
    expect(sig[NUM_HASHES - 1]).toBe(804944982);
  });
});

describe('nearDuplicatePairs', () => {
  it('flags near-dup pairs above threshold, orders deterministically, skips distinct', () => {
    const dup = 'alpha content one two three four five six seven eight nine ten';
    const pages: PageSig[] = [
      { slug: 'beta', cat: 'learnings', sig: signatureOf(dup) },
      { slug: 'alpha', cat: 'learnings', sig: signatureOf(dup) },                                  // dup of beta
      { slug: 'gamma', cat: 'entities', sig: signatureOf('totally different words about routers switches vlans subnets') },
    ];
    const pairs = nearDuplicatePairs(pages, 0.7);
    expect(pairs).toHaveLength(1);
    expect(pairs[0].a).toBe('alpha'); // lexicographically-smaller slug first (deterministic)
    expect(pairs[0].b).toBe('beta');
    expect(pairs[0].sim).toBe(1);
    expect(pairs[0].a_cat).toBe('learnings');
  });
  it('distinct short pages produce no spurious pairs', () => {
    const pages: PageSig[] = [
      { slug: 'a', cat: 'x', sig: signatureOf('hi') },
      { slug: 'b', cat: 'x', sig: signatureOf('yo') },
    ];
    expect(nearDuplicatePairs(pages, 0.7)).toHaveLength(0);
  });

  // C1 regression: a metadata-only stub (frontmatter + ai-block, no prose) yields ZERO shingles →
  // an all-sentinel signature. Two DISTINCT such stubs must NOT collide at sim 1.0 → no merge.
  it('prose-empty stubs never collide (C1): two distinct metadata-only pages produce no pairs', () => {
    const stub = (title: string) =>
      ['---', `title: ${title}`, 'type: entities', '---', '<!-- ai:begin -->', 'identity: x', '<!-- ai:end -->'].join('\n');
    expect(shingles(stub('Alpha')).size).toBe(0);           // confirms the prose-empty condition
    const pages: PageSig[] = [
      { slug: 'alpha', cat: 'entities', sig: signatureOf(stub('Alpha')) },
      { slug: 'bravo', cat: 'entities', sig: signatureOf(stub('Bravo')) },
    ];
    expect(isEmptySignature(pages[0].sig)).toBe(true);
    expect(nearDuplicatePairs(pages, 0.7)).toHaveLength(0); // would be 1 (false dup) without the C1 fix
  });
});

describe('isEmptySignature', () => {
  it('is true for an empty shingle set, false for any real content', () => {
    expect(isEmptySignature(minhashSignature(new Set()))).toBe(true);
    expect(isEmptySignature(signatureOf('actual prose content here with several distinct words'))).toBe(false);
  });
});
