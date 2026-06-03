// Single source of truth for the knowledge-base structure — derived entirely from the repo-root
// kb-schema.json (esbuild inlines it at build; tsconfig resolveJsonModule lets TS typecheck it).
// The bash side reads the SAME json via scripts/kb-schema.sh. Never hardcode a category list in a
// consumer — import from here. Guarded by tests/test-kb-schema.sh (TS ↔ bash ↔ json agree).
import schema from "../../../kb-schema.json";
export const STRUCTURED_TYPES = schema.structured_types;
export const UNSTRUCTURED_TYPES = schema.unstructured_types;
export const GENERATED_DIRS = schema.generated_dirs;
export const EDGE_TYPES = schema.edge_types;
export const PROJECT_SECTIONS = schema.project_sections;
export const FORGET_PROTECTED = schema.forget_protection.protected;
export const FORGET_DISCOUNTED = schema.forget_protection.discounted;
/** Raw inbox group: per-project staging for unprocessed material (SP-2). Never searched. */
export const RAW_DIR = schema.raw.dir;
export const RAW_STATUSES = schema.raw.statuses;
/** Wiki categories that hold authored content (have a directory, are scaffolded + write-guarded). */
export const CONTENT_CATEGORIES = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
/** Every recognized wiki category, including the generated MOC dirs (projects/, themes/). */
export const ALL_CATEGORIES = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];
/** A type with a structured ai-block schema (one of the six). */
export function isStructuredType(t) { return STRUCTURED_TYPES.includes(t); }
/** A generated/derived MOC directory (projects/, themes/) — a view, not authored content. */
export function isGeneratedDir(d) { return GENERATED_DIRS.includes(d); }
//# sourceMappingURL=kb-schema.js.map