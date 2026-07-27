// Single source of truth for model selection — derived entirely from the repo-root
// model-ladder.json (esbuild inlines it at build; tsconfig resolveJsonModule lets TS typecheck
// it). The bash side reads the SAME json via sb_resolve_model in scripts/lib.sh. Never hardcode
// a model string in a consumer — add a rung here. Guarded by tests/test-model-ladder.sh.
import ladder from "../../../model-ladder.json";

export const TIERS: readonly string[] = ladder.tiers;
export const SURFACES: readonly string[] = Object.keys(ladder.ladders);
export const DISPATCH_ALIASES: readonly string[] = ladder.dispatch_aliases;
export const LADDERS: Record<string, Record<string, readonly string[]>> = ladder.ladders;
export const PIN_ENVS: Record<string, readonly string[]> = ladder.pins;
export const PROTOCOL_NAMES: Record<string, string> = ladder.protocol_names;
