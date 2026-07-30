import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { LADDERS } from "./constants/model-ladder.js";
import { resolveModel } from "./model-resolve.js";

// Rungs 1+ come from the manifest, never a literal here — tests/test-model-ladder.sh's tripwire
// fails the suite on a hardcoded model-ID string outside model-ladder.json, and a test asserting
// against a stale duplicate would silently drift from the real ladder anyway.
const deepLadder = LADDERS.headless.deep;

let dir: string;
const saved = { ...process.env };

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "sb-model-"));
  process.env.BRAIN_DIR = dir;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.SB_MODEL_TIER_DEEP;
  delete process.env.SB_PERSONA_MODEL;
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
  process.env = { ...saved };
});

const cache = (models: Record<string, unknown>) =>
  writeFileSync(
    join(dir, "model-availability.json"),
    JSON.stringify({ schema: 1, auth_fingerprint: "oauth", surfaces: { headless: models } }),
  );

describe("resolveModel", () => {
  it("returns rung 0 with a clean cache", () => {
    expect(resolveModel("deep")).toBe("opus");
  });

  it("skips a blocked rung", () => {
    cache({ opus: { state: "blocked", epoch: Math.floor(Date.now() / 1000) } });
    expect(resolveModel("deep")).toBe(deepLadder[1]);
  });

  it("re-admits an expired verdict", () => {
    cache({ opus: { state: "blocked", epoch: Math.floor(Date.now() / 1000) - 999_999 } });
    expect(resolveModel("deep")).toBe("opus");
  });

  it("ignores a cache written under different credentials", () => {
    cache({ opus: { state: "blocked", epoch: Math.floor(Date.now() / 1000) } });
    process.env.ANTHROPIC_API_KEY = "sk-test";
    expect(resolveModel("deep")).toBe("opus");
  });

  it("treats an operator pin as rung 0 but still demotes it", () => {
    process.env.SB_MODEL_TIER_DEEP = "pinned-x";
    expect(resolveModel("deep")).toBe("pinned-x");
    cache({ "pinned-x": { state: "blocked", epoch: Math.floor(Date.now() / 1000) } });
    expect(resolveModel("deep")).toBe("opus");
  });

  it("honors the legacy per-caller pin", () => {
    process.env.SB_PERSONA_MODEL = "legacy-x";
    expect(resolveModel("deep")).toBe("legacy-x");
  });

  it("SB_MODEL_CACHE_TTL=0 re-admits instantly instead of falling back to the 7-day default", () => {
    process.env.SB_MODEL_CACHE_TTL = "0";
    cache({ opus: { state: "blocked", epoch: Math.floor(Date.now() / 1000) } });
    expect(resolveModel("deep")).toBe("opus");
  });

  it("returns rung 0 when every rung is blocked", () => {
    const epoch = Math.floor(Date.now() / 1000);
    cache(Object.fromEntries(deepLadder.map((m) => [m, { state: "blocked", epoch }])));
    expect(resolveModel("deep")).toBe(deepLadder[0]);
  });
});
