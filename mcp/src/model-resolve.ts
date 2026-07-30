// Tier -> concrete model, mirroring sb_resolve_model in scripts/lib.sh. Both read the SAME
// manifest and the SAME cache file, so bash and TS never disagree about what is available.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { resolveBrainDir } from "./brain-paths.js";
import { LADDERS, PIN_ENVS } from "./constants/model-ladder.js";

type Verdict = { state?: string; epoch?: number };

const DEFAULT_TTL_SECONDS = 604_800;

const authFingerprint = (): string => (process.env.ANTHROPIC_API_KEY ? "apikey" : "oauth");

function blockedSet(surface: string): Set<string> {
  const blocked = new Set<string>();
  let parsed: { auth_fingerprint?: string; surfaces?: Record<string, Record<string, Verdict>> };
  try {
    parsed = JSON.parse(readFileSync(join(resolveBrainDir(), "model-availability.json"), "utf8"));
  } catch {
    return blocked; // no cache (or unreadable) means nothing is known to be blocked
  }
  // A credential change means a different allowlist — discard every prior verdict.
  if (parsed.auth_fingerprint !== authFingerprint()) return blocked;
  const ttlRaw = Number(process.env.SB_MODEL_CACHE_TTL);
  const ttl = Number.isFinite(ttlRaw) && ttlRaw > 0 ? ttlRaw : DEFAULT_TTL_SECONDS;
  const now = Math.floor(Date.now() / 1000);
  for (const [model, v] of Object.entries(parsed.surfaces?.[surface] ?? {})) {
    if (v?.state !== "blocked") continue;
    const epoch = typeof v.epoch === "number" ? v.epoch : 0;
    if (epoch > 0 && now - epoch >= ttl) continue; // expired: re-admit
    blocked.add(model);
  }
  return blocked;
}

/** Never returns an empty string: a wrong model that errors loudly beats a missing one. */
export function resolveModel(tier: string, surface = "headless"): string {
  const pins = (PIN_ENVS[tier] ?? [])
    .map((envName) => process.env[envName])
    .filter((v): v is string => typeof v === "string" && v.length > 0);
  const rungs = [...pins, ...(LADDERS[surface]?.[tier] ?? [])];
  if (rungs.length === 0) return "sonnet";
  if (process.env.SB_MODEL_ELASTIC === "0") return rungs[0];
  const blocked = blockedSet(surface);
  return rungs.find((m) => !blocked.has(m)) ?? rungs[0];
}
