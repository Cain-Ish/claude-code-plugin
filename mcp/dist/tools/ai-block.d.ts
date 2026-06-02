export declare const AI_BLOCK_RE: RegExp;
export interface AiBlockSchema {
    fields: string[];
    required: string[];
}
export declare const AI_BLOCK_SCHEMAS: Record<string, AiBlockSchema>;
/** Parse the flat-YAML `key: value` body of the ai:begin…ai:end region into an object.
 *  A line not matching `key:` is folded (appended) into the previous field's value.
 *  Returns null when the page has no block. */
export declare function parseAiBlock(content: string): Record<string, string> | null;
/** Remove the ai:begin…ai:end region so length/first-sentence consumers ignore it. */
export declare function stripAiBlock(text: string): string;
export declare const AI_BLOCK_RENDER_BEGIN = "<!-- ai:begin (authored \u2014 flat YAML, see ai-block schema) -->";
export declare const AI_BLOCK_RENDER_END = "<!-- ai:end -->";
/** Inverse of parseAiBlock: render a block object as the marked region. Deterministic —
 *  fields emitted in the type's schema order (closed vocabulary: unknown fields dropped),
 *  empty values skipped. Returns '' when no schema field has a value (→ inject nothing). */
export declare function renderAiBlock(type: string, block: Record<string, string>): string;
/** Missing REQUIRED fields for the page type (empty when type unknown or all present). */
export declare function validateAiBlock(type: string, block: Record<string, string>): string[];
//# sourceMappingURL=ai-block.d.ts.map