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
/** Missing REQUIRED fields for the page type (empty when type unknown or all present). */
export declare function validateAiBlock(type: string, block: Record<string, string>): string[];
//# sourceMappingURL=ai-block.d.ts.map