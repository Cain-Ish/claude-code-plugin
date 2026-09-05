// Candidate-fact validation — the Stage A ↔ Stage B contract of the P6 quarantine split.
//
// Stage A (the quarantined zero-tool summarizer) emits candidate-facts.json, already
// validator-enforced against kb-schema.json's candidate_facts.json_schema by the CLI
// (≥2.1.205). This module is the WRITER-side defense-in-depth: the file on disk is
// untrusted-derived DATA (model output over poisoned-able transcripts, and any process
// could have replaced it between the stages), so every fact is re-validated against the
// SAME schema object and every string is sanitized before it can influence a page write.
import { CANDIDATE_FACTS } from '../constants/kb-schema.js';
import { stripInvisible } from './sanitize.js';

export interface CandidateFact {
  kind: string;
  title?: string;
  claim: string;
  evidence?: string;
  source?: string;
  confidence?: string;
  /** kind:"relation" only — free-text endpoints Stage B resolves to real slugs. */
  from_hint?: string;
  to_hint?: string;
  /** Closed to `relates` for the unattended lane (see kb-schema _comment). */
  rel?: string;
}

export interface ValidatedFacts {
  facts: CandidateFact[];
  rejected: { index: number; reason: string }[];
}

const ITEM_PROPS = CANDIDATE_FACTS.json_schema.properties.facts.items.properties;
export const FACT_KINDS: readonly string[] = ITEM_PROPS.kind.enum;
export const KIND_TO_CATEGORY: Record<string, string> = CANDIDATE_FACTS.kind_to_category;
export const RELATION_EDGE_TYPES: readonly string[] = CANDIDATE_FACTS.relation_edge_types;
export const MAX_FACTS: number = CANDIDATE_FACTS.json_schema.properties.facts.maxItems;
const CAPS: Record<string, number> = Object.fromEntries(
  Object.entries(ITEM_PROPS)
    .filter(([, p]: [string, any]) => typeof p.maxLength === 'number')
    .map(([k, p]: [string, any]) => [k, p.maxLength])
);
const CONFIDENCE: readonly string[] = ITEM_PROPS.confidence.enum;

/**
 * Fact strings feed frontmatter values and markdown bodies, so beyond the invisible-
 * Unicode strip they must not be able to (a) break out of a YAML value (newlines/CR),
 * (b) open or close an HTML-comment region (the ai:/graph:/theme: generated-region
 * grammar is comment-based), or (c) smuggle control chars. Deterministic, idempotent.
 */
export function sanitizeFactString(s: string): string {
  return stripInvisible(s)
    .replace(/\r/g, '')   // CR first — the control-class below would turn it into a stray space
    // D035: U+2028 (LINE SEPARATOR) / U+2029 (PARAGRAPH SEPARATOR) are ECMAScript
    // LineTerminator characters — frontmatter.ts's extractYamlValue/extractYamlList (`^key:$`
    // with the `m` flag) and js-yaml both treat them as line breaks, same as \n. Left unstripped,
    // a title like "Deploy notes type: security project: evil" survives into
    // `title: <title>` frontmatter and PARSES as its own `type:`/`project:` line — forging the
    // page's facets, and winning over the writer's real line via first-match extraction (it comes
    // first in the file). Fold to \n so the newline handling below neutralizes it identically.
    .replace(/[\u2028\u2029]/g, '\n')
    .replace(/<!--/g, '(!--').replace(/-->/g, '--)')
    // eslint-disable-next-line no-control-regex
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, ' ');
}

/** Single-line variant for frontmatter/title positions (YAML values must not embed newlines). */
export function sanitizeFactLine(s: string): string {
  return sanitizeFactString(s).replace(/\n+/g, ' ').trim();
}

/**
 * Validate a parsed candidate-facts document ({"facts": [...]}). Never throws on bad
 * shapes — every defect becomes a rejected entry (fail-loud is the CALLER's job: it
 * surfaces the rejected count). Valid facts come back sanitized.
 */
export function validateCandidateFacts(raw: unknown): ValidatedFacts {
  const out: ValidatedFacts = { facts: [], rejected: [] };
  if (typeof raw !== 'object' || raw === null || !Array.isArray((raw as any).facts)) {
    out.rejected.push({ index: -1, reason: 'document is not an object with a facts array' });
    return out;
  }
  const arr = (raw as any).facts as unknown[];
  arr.forEach((item, index) => {
    if (index >= MAX_FACTS) { out.rejected.push({ index, reason: `over maxItems ${MAX_FACTS}` }); return; }
    if (typeof item !== 'object' || item === null) { out.rejected.push({ index, reason: 'fact is not an object' }); return; }
    const f = item as Record<string, unknown>;
    const kind = typeof f.kind === 'string' ? f.kind : '';
    if (!FACT_KINDS.includes(kind)) { out.rejected.push({ index, reason: `kind '${String(f.kind)}' not in closed vocabulary` }); return; }
    if (typeof f.claim !== 'string' || f.claim.length === 0) { out.rejected.push({ index, reason: 'claim missing/empty' }); return; }
    for (const [field, cap] of Object.entries(CAPS)) {
      const v = f[field];
      if (v !== undefined && (typeof v !== 'string' || v.length > cap)) {
        out.rejected.push({ index, reason: `${field} not a string or over ${cap}-char cap` });
        return;
      }
    }
    if (f.confidence !== undefined && !CONFIDENCE.includes(f.confidence as string)) {
      out.rejected.push({ index, reason: `confidence '${String(f.confidence)}' not in closed vocabulary` });
      return;
    }
    // Claim/evidence are FLATTENED to single lines, not merely sanitized. A fact is an
    // atomic assertion, so nothing is lost — and an embedded newline is an injection
    // primitive: rendered into a page body it produces lines that impersonate metadata
    // ("provenance: trusted", "rogue: true"), which a later reader or LLM may believe.
    // Caught by tests/test-consolidation-poison-fixture.sh (the YAML-breakout fact).
    const fact: CandidateFact = { kind, claim: sanitizeFactLine(f.claim as string) };
    if (typeof f.title === 'string') fact.title = sanitizeFactLine(f.title);
    if (typeof f.evidence === 'string') fact.evidence = sanitizeFactLine(f.evidence);
    if (typeof f.source === 'string') fact.source = sanitizeFactLine(f.source);
    if (typeof f.confidence === 'string') fact.confidence = f.confidence;
    // A relation fact is only useful if it names BOTH endpoints with a permitted edge type.
    // Rejecting here (rather than silently dropping downstream) keeps the count visible.
    if (kind === 'relation') {
      const fh = typeof f.from_hint === 'string' ? sanitizeFactLine(f.from_hint) : '';
      const th = typeof f.to_hint === 'string' ? sanitizeFactLine(f.to_hint) : '';
      const rl = typeof f.rel === 'string' ? f.rel : 'relates';
      if (!fh || !th) { out.rejected.push({ index, reason: 'relation fact missing from_hint/to_hint' }); return; }
      if (!RELATION_EDGE_TYPES.includes(rl)) {
        out.rejected.push({ index, reason: `relation rel '${rl}' not permitted unattended (allowed: ${RELATION_EDGE_TYPES.join(', ')})` });
        return;
      }
      fact.from_hint = fh; fact.to_hint = th; fact.rel = rl;
    }
    if (fact.claim.trim().length === 0) { out.rejected.push({ index, reason: 'claim empty after sanitization' }); return; }
    out.facts.push(fact);
  });
  return out;
}
