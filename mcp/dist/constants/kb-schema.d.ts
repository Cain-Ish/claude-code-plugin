export declare const STRUCTURED_TYPES: readonly string[];
export declare const UNSTRUCTURED_TYPES: readonly string[];
export declare const GENERATED_DIRS: readonly string[];
export declare const EDGE_TYPES: readonly string[];
export declare const PROJECT_SECTIONS: readonly string[];
export declare const FORGET_PROTECTED: readonly string[];
export declare const FORGET_DISCOUNTED: readonly string[];
/** Raw inbox group: per-project staging for unprocessed material (SP-2). Never searched. */
export declare const RAW_DIR: string;
export declare const RAW_STATUSES: readonly string[];
/** Wiki categories that hold authored content (have a directory, are scaffolded + write-guarded). */
export declare const CONTENT_CATEGORIES: readonly string[];
/** Every recognized wiki category, including the generated MOC dirs (projects/, themes/). */
export declare const ALL_CATEGORIES: readonly string[];
/** A type with a structured ai-block schema (one of the six). */
export declare function isStructuredType(t: string): boolean;
/** A generated/derived MOC directory (projects/, themes/) — a view, not authored content. */
export declare function isGeneratedDir(d: string): boolean;
//# sourceMappingURL=kb-schema.d.ts.map