/** Canonical invisible-character sanitizer — the single source of truth shared by the raw-inbox
 *  store (raw-inbox.ts), the episodic transcript read path (episodic-search.ts), and the bundled
 *  sanitize-cli (used by the bash dream-snapshot to clean transcripts before the dream-runner reads
 *  them). Keep it here so the codepoint set never drifts across call sites.
 *
 *  Strips characters that smuggle hidden instructions into stored memory (later mined into wiki
 *  pages and auto-injected): the Unicode Tags block (U+E0000–U+E007F) decodes to ASCII for the
 *  model while rendering invisibly, and ZWSP/word-joiner/BOM hide token boundaries. We deliberately
 *  KEEP U+200C/U+200D (ZWNJ/ZWJ) — load-bearing in many scripts and in emoji ZWJ sequences.
 *
 *  Scope: the Tags-block + zero-width channel. The bidi-control (Trojan-Source, U+202A–202E /
 *  U+2066–2069) and variation-selector (U+E0100–E01EF) channels are deferred (need deliberate
 *  RTL/emoji-VS handling). See wiki/learnings/claude-agent-architecture-deep-2026-06 + spec P6. */
const INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;

export function stripInvisible(s: string): string {
  return s.replace(INVISIBLE_RE, '');
}
