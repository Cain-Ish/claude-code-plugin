import { describe, expect, it } from "vitest";
import { DISPATCH_ALIASES, LADDERS, PIN_ENVS, PROTOCOL_NAMES, SURFACES, TIERS } from "./model-ladder.js";

describe("model-ladder manifest", () => {
  it("declares the three tiers and two surfaces", () => {
    expect(TIERS).toEqual(["fast", "mid", "deep"]);
    expect(SURFACES.sort()).toEqual(["dispatch", "headless"]);
  });

  it("leads every ladder with a bare alias", () => {
    for (const surface of SURFACES) {
      for (const tier of TIERS) {
        const rungs = LADDERS[surface][tier];
        expect(rungs.length).toBeGreaterThan(0);
        expect(DISPATCH_ALIASES).toContain(rungs[0]);
      }
    }
  });

  it("keeps dispatch ladders alias-only (the param is a schema enum)", () => {
    for (const tier of TIERS) {
      for (const rung of LADDERS.dispatch[tier]) expect(DISPATCH_ALIASES).toContain(rung);
    }
  });

  it("gives every tier a pin list starting with SB_MODEL_TIER_<TIER>", () => {
    for (const tier of TIERS) {
      expect(PIN_ENVS[tier][0]).toBe(`SB_MODEL_TIER_${tier.toUpperCase()}`);
    }
  });

  it("maps every tier to a PROTOCOL name", () => {
    expect(PROTOCOL_NAMES).toEqual({ fast: "SCOUT", mid: "DO", deep: "THINK" });
  });
});
