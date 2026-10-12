// Single source of truth for the knowledge-base structure — derived entirely from the repo-root
// kb-schema.json (esbuild inlines it at build; tsconfig resolveJsonModule lets TS typecheck it).
// The bash side reads the SAME json via scripts/kb-schema.sh. Never hardcode a category list in a
// consumer — import from here. Guarded by tests/test-kb-schema.sh (TS ↔ bash ↔ json agree).
import schema from "../../../kb-schema.json";

const STRUCTURED_TYPES: readonly string[] = schema.structured_types;
const UNSTRUCTURED_TYPES: readonly string[] = schema.unstructured_types;
const GENERATED_DIRS: readonly string[] = schema.generated_dirs;

/** P6 Stage A↔B contract: the summarizer's --json-schema object and the writer's kind→category
 * map. Both sides read THIS object (bash: jq .candidate_facts.json_schema) — never a copy. */
export const CANDIDATE_FACTS: {
  kind_to_category: Record<string, string>;
  relation_edge_types: string[];
  json_schema: any;
} = schema.candidate_facts;

/** Frontmatter fields every authored wiki page must carry. */
export const FRONTMATTER_REQUIRED: readonly string[] = schema.frontmatter_required;
/** Per-structured-type ai-block field contracts (marker grammar in schema.ai_blocks.markers). */
export const AI_BLOCK_TYPES: Record<string, { fields: string[]; required: string[] }> =
  schema.ai_blocks.types;

/** Wiki categories that hold authored content (have a directory, are scaffolded + write-guarded). */
export const CONTENT_CATEGORIES: readonly string[] = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
/** Every recognized wiki category, including the generated MOC dirs (projects/, themes/). */
export const ALL_CATEGORIES: readonly string[] = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];
