// Single source of truth for the knowledge-base structure — derived entirely from the repo-root
// kb-schema.json (esbuild inlines it at build; tsconfig resolveJsonModule lets TS typecheck it).
// The bash side reads the SAME json via scripts/kb-schema.sh. Never hardcode a category list in a
// consumer — import from here. Guarded by tests/test-kb-schema.sh (TS ↔ bash ↔ json agree).
import schema from "../../../kb-schema.json";

export const STRUCTURED_TYPES: readonly string[] = schema.structured_types;
export const UNSTRUCTURED_TYPES: readonly string[] = schema.unstructured_types;
export const GENERATED_DIRS: readonly string[] = schema.generated_dirs;
export const EDGE_TYPES: readonly string[] = schema.edge_types;
export const PROJECT_SECTIONS: readonly string[] = schema.project_sections;
export const FORGET_PROTECTED: readonly string[] = schema.forget_protection.protected;
export const FORGET_DISCOUNTED: readonly string[] = schema.forget_protection.discounted;

/** Raw inbox group: per-project staging for unprocessed material (SP-2). Never searched. */
export const RAW_DIR: string = schema.raw.dir;
export const RAW_STATUSES: readonly string[] = schema.raw.statuses;

/** Frontmatter fields every authored wiki page must carry. */
export const FRONTMATTER_REQUIRED: readonly string[] = schema.frontmatter_required;
/** Per-structured-type ai-block field contracts (marker grammar in schema.ai_blocks.markers). */
export const AI_BLOCK_TYPES: Record<string, { fields: string[]; required: string[] }> =
  schema.ai_blocks.types;

/** Wiki categories that hold authored content (have a directory, are scaffolded + write-guarded). */
export const CONTENT_CATEGORIES: readonly string[] = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
/** Every recognized wiki category, including the generated MOC dirs (projects/, themes/). */
export const ALL_CATEGORIES: readonly string[] = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];

/** A type with a structured ai-block schema (one of the six). */
export function isStructuredType(t: string): boolean { return STRUCTURED_TYPES.includes(t); }
/** A generated/derived MOC directory (projects/, themes/) — a view, not authored content. */
export function isGeneratedDir(d: string): boolean { return GENERATED_DIRS.includes(d); }
