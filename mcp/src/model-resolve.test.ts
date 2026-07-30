import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { resolveModel } from "./model-resolve.js";

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
    expect(resolveModel("deep")).toBe("claude-opus-5");
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

  it("returns rung 0 when every rung is blocked", () => {
    const epoch = Math.floor(Date.now() / 1000);
    cache(Object.fromEntries(
      ["opus", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "sonnet"]
        .map((m) => [m, { state: "blocked", epoch }]),
    ));
    expect(resolveModel("deep")).toBe("opus");
  });
});
