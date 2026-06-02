// AI-native representation — the per-page machine-first "shared intermediate" block.
// A marked region <!-- ai:begin … --> … <!-- ai:end --> holding flat YAML key:value
// fields (per-type schema). Pure module: parse / strip / validate. No I/O.
// Spec: docs/specs/2026-06-02-ai-native-knowledge-representation-design.md
// The begin marker is a single HTML comment line (its annotation tail stays on that line,
// `[^\n]*?` — so a stray token can't fold the comment-tail into the parsed body). Requires a
// matching ai:end; an unterminated ai:begin is NOT a block (no match → parse null / strip no-op).
export const AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
// Per-type schemas (spec §4). `required` = the load-bearing fields a good page of that
// type should carry; missing ones are WARNINGS (gentle), never errors.
export const AI_BLOCK_SCHEMAS = {
    learnings: { fields: ['claim', 'trigger', 'action', 'scope', 'evidence', 'supersedes'], required: ['claim', 'action'] },
    decisions: { fields: ['context', 'choice', 'alternatives', 'rationale', 'status', 'supersedes'], required: ['choice'] },
    entities: { fields: ['identity', 'current_state', 'depends_on', 'owns', 'status'], required: ['identity'] },
    issues: { fields: ['symptom', 'cause', 'fix', 'severity', 'status'], required: ['symptom', 'status'] },
    concepts: { fields: ['problem', 'solution', 'where_applied', 'tradeoffs'], required: ['problem', 'solution'] },
    security: { fields: ['threat', 'mitigation', 'scope', 'status'], required: ['threat', 'mitigation'] },
};
/** Own-key-safe schema lookup. A page's `type` is author-controlled (frontmatter or wiki
 *  sub-dir name), so a bare `AI_BLOCK_SCHEMAS[type]` index would resolve inherited
 *  `Object.prototype` keys — `type === "constructor"` returns the Object constructor (truthy,
 *  no `.fields`/`.required`), crashing the consumers with a TypeError. Guard with hasOwnProperty. */
export function schemaFor(type) {
    return Object.prototype.hasOwnProperty.call(AI_BLOCK_SCHEMAS, type) ? AI_BLOCK_SCHEMAS[type] : undefined;
}
/** Parse the flat-YAML `key: value` body of the ai:begin…ai:end region into an object.
 *  A line not matching `key:` is folded (appended) into the previous field's value.
 *  Returns null when the page has no block. */
export function parseAiBlock(content) {
    const m = content.match(AI_BLOCK_RE);
    if (!m)
        return null;
    const out = {};
    let last = '';
    for (const raw of m[1].split('\n')) {
        const line = raw.trimEnd();
        if (!line.trim())
            continue;
        const kv = line.match(/^([a-z_][a-z0-9_]*):\s*(.*)$/i);
        if (kv) {
            last = kv[1];
            out[last] = kv[2].trim();
        }
        else if (last) {
            out[last] = (out[last] + ' ' + line.trim()).trim();
        }
    }
    return out;
}
const AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, 'g'); // strip ALL blocks (defensive; spec = 1/page)
/** Remove every ai:begin…ai:end region so length/first-sentence consumers ignore it. */
export function stripAiBlock(text) {
    return text.replace(AI_BLOCK_RE_G, '');
}
export const AI_BLOCK_RENDER_BEGIN = '<!-- ai:begin (authored — flat YAML, see ai-block schema) -->';
export const AI_BLOCK_RENDER_END = '<!-- ai:end -->';
/** Inverse of parseAiBlock: render a block object as the marked region. Deterministic —
 *  fields emitted in the type's schema order (closed vocabulary: unknown fields dropped),
 *  empty values skipped. Returns '' when no schema field has a value (→ inject nothing). */
export function renderAiBlock(type, block) {
    const schema = schemaFor(type);
    if (!schema)
        return ''; // closed vocabulary: only the six known types produce a block
    const lines = [];
    for (const f of schema.fields) {
        const v = (block[f] ?? '').toString()
            .replace(/<!--|-->|ai:(begin|end)/gi, ' ') // neutralize marker tokens so a value can't close the region early
            .replace(/\s+/g, ' ').trim();
        if (v)
            lines.push(`${f}: ${v}`);
    }
    if (lines.length === 0)
        return '';
    return [AI_BLOCK_RENDER_BEGIN, ...lines, AI_BLOCK_RENDER_END].join('\n');
}
/** Compact one-line summary of a block (schema-ordered, present fields only) — the
 *  "shared intermediate" returned as a search snippet / injected into context. */
export function aiBlockSnippet(type, block) {
    const schema = schemaFor(type);
    const order = schema ? schema.fields : Object.keys(block);
    return order.filter(f => (block[f] ?? '').trim()).map(f => `${f}: ${block[f].trim()}`).join('; ');
}
/** Missing REQUIRED fields for the page type (empty when type unknown or all present). */
export function validateAiBlock(type, block) {
    const schema = schemaFor(type);
    if (!schema)
        return [];
    return schema.required.filter(f => !block[f] || !block[f].trim());
}
//# sourceMappingURL=ai-block.js.map