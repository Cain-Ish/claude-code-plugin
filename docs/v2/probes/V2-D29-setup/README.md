# V2-D29 setup probes (06, section 3, S0)

`probes.mjs` runs probes P1 to P6 as registered in 06, section 3. Each runs with the pinned CLI 2.1.305 in throwaway
repos under a scratch folder. It writes `results/<probe>.json`: flags and counts only, no transcript text.

```
D17_CLAUDE=<pinned claude-2.1.305> node probes.mjs <scratch> [P1,P2,P3,P4,P5,P6]
```

**Two additions to P3, recorded before any run (2026-11-20):**
- a **control arm**: the same untracked rule, without the label. A 0 of 5 in the labelled arm then cannot mean that the
  rule never loaded;
- an **Opus 5.5 arm** beside the registered Haiku. The user works on Opus, and a label's effect can differ by model.

The registered bar is unchanged: at most 1 of 5 nonces in the labelled arm. It applies to each model.

**Probe notes:**
- In 2.1.305, the `--permission-mode` choice for the default mode is `manual`.
- P4 runs in an isolated `CLAUDE_CONFIG_DIR`, so the user's own transcripts are never at risk. If the session cannot
  start there (no login), the result still shows whether cleanup ran at startup.
