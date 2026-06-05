# SP-A — Autonomous Capture Bridge (design)

- **Date:** 2026-06-05
- **Status:** approved (brainstorm) → spec review
- **Sub-project:** A of the autonomous-knowledge-loop roadmap (A deploy-bridge · B gate+surface · C dream-lifecycle · D retention · E project-continuity)
- **Grounded by:** the 2026-06-05 autonomous-loop current-state map (read-only discovery sweep)

## 1. Problem

The autonomous knowledge loop does not run. Transcripts **are** archived (77 `.txt` in `~/.second-brain/transcripts/`), but nothing turns them into wiki/PROJECT/graph deltas headlessly. The mechanism designed for it — the out-of-band drainer `scripts/extract-drain.sh` (built v0.13.0) — **was never installed and has never run once** (no `sb-extract-drain.timer`, `.extraction-state.jsonl` absent). The only thing mining transcripts is the manual-accept dream. So the wiki only grows from manual pins + dreams, and every recent session logged `[degraded] LLM extraction unavailable`.

Two structural reasons it never ran:
1. **In-session extraction is correctly skipped** under `CLAUDECODE` + OAuth to avoid a recursive-`claude` hang (`lib.sh:675-683`) — by design. The out-of-band drainer is the intended replacement, but it isn't deployed.
2. **There is no offline extraction path at all** — every backend terminates at `https://api.anthropic.com`, hardcoded (`lib.sh:836`). This contradicts the project's offline-first identity and forces a credential-bearing background service for the only working engine.

## 2. Goal & success criteria

An **archived transcript becomes a real wiki/PROJECT/graph delta without a live session**, via a **local-LLM-preferred** engine, and the plugin **loudly self-reports** capture health.

Success = ALL of:
- `sb_call_extractor` selects an engine by precedence **local → cli-OAuth → `--bare`** and records which one ran.
- A **real** extraction (not `SB_EXTRACT_STUB`) writes a **real** delta — proven on at least one available engine.
- The drainer is installable + activates a user timer that fires in idle windows and defers while an interactive `claude` is live.
- SessionStart surfaces a capture-health line (last-drain age, backend, deltas/7d) and shouts when capture is stale/zero.
- With nothing configured and no timer installed, behaviour is byte-for-byte today's (additive).

## 3. Non-goals (later sub-projects / fast-follow)

- Maintainer auto-run, `config.json`/`auto_improve` reader, the self-install **nudge** → **SP-B**.
- Dream `accepted`/`discarded` states + `archived_at`-aware banner → **SP-C**.
- `sb_prune_archives` retention (embeddings-cache GC, wiki-archive TTL) → **SP-D**.
- First-class `## Plans`/`## State` schema + PROJECT.md byte cap + `[degraded]` routing → **SP-E**.
- Streaming, multi-model routing, prompt-token budgeting for the local model, and remote/LAN model hosts → later. SP-A's local backend is a single blocking `/v1/chat/completions` POST to `localhost` ollama (the native adapter **is** in A, since the verified setup is raw ollama).

## 4. Design — five isolated units

### U1 — Engine precedence + base-URL override (`scripts/lib.sh`)
`sb_call_extractor` gains explicit backend selection, controlled by `SB_EXTRACTOR_ENGINE` (`auto` default | `local` | `cli` | `bare`). In `auto`, try in order and use the first usable:
1. **local** — usable iff `SB_EXTRACTOR_LOCAL_URL` is set (default `http://localhost:11434`). A **native OpenAI-compatible** call: `POST ${SB_EXTRACTOR_LOCAL_URL}/v1/chat/completions` with `{model, messages:[{role:user,content:<extract-prompt+transcript>}]}`, parse `.choices[0].message.content`. Confirmed live: **ollama 0.23.4 serves `/v1` natively** (no LiteLLM needed) with model `qwen2.5:3b`. Model id from `SB_EXTRACTOR_LOCAL_MODEL` (default `qwen2.5:3b`). No credentials required. *(Secondary: an Anthropic-shaped proxy is still reachable via the `${ANTHROPIC_BASE_URL:-https://api.anthropic.com}` override at `lib.sh:836` — kept for users who front their model with one, but not required.)*
2. **cli-OAuth** — `claude -p` (non-`--bare`, honors OAuth). Only valid **out of session** (the drainer's context); the recursive-lock guard (`lib.sh:675-683`) still blocks in-session.
3. **bare** — `claude -p --bare …` iff `ANTHROPIC_API_KEY` is set.

`sb_write_extractor_health` records `backend=local|cli-oauth|bare` (extend the existing marker). New env, all optional + back-compat defaults: `SB_EXTRACTOR_ENGINE` (auto), `SB_EXTRACTOR_LOCAL_URL` (unset), `ANTHROPIC_BASE_URL` (unset → public host).

**Trust boundary:** `ANTHROPIC_BASE_URL`/`SB_EXTRACTOR_LOCAL_URL` are user-set; default stays the public Anthropic host. A non-localhost override is the user's responsibility (document: prefer `localhost`/a trusted LAN proxy; the transcript content is sent to whatever host is configured).

### U2 — Drainer correctness (`scripts/extract-drain.sh`)
Confirm/repair the drain loop: enumerate undrained archived transcripts (done-set in `~/.second-brain/.extraction-state.jsonl`), call `sb_call_extractor` per transcript, write the resulting wiki/PROJECT/graph delta via the existing merge path, append an `outcome:ok|fail` line, and **defer cleanly** (no attempt, no spawn) when an interactive `claude` is live for the uid (the 0.13.1 global-lock rule). No transcript is double-drained.

### U3 — systemd unit (`systemd/sb-extract-drain.service`)
Two variants from one source:
- **Hardened local-only (default):** **no** `%h/.claude` grant (the local ollama engine needs no Anthropic creds) — zero credential exposure for the background service. `NoNewPrivileges=`, `RestrictNamespaces=`, `ProtectSystem=`, writes scoped to `%h/.second-brain`.
- **OAuth-capable (`--oauth` opt-in):** the above **plus** `ReadWritePaths=%h/.claude` so `claude -p` can read OAuth creds + write its session/cache.

The single relaxation in the whole sub-project is the OAuth variant's `~/.claude` grant, and it is **opt-in** (default ships zero-credential).

### U4 — Install + activate (`scripts/install-extract-timer.sh`)
`--apply` installs the timer + service (idempotent; linger already enabled). **Default = the hardened local-only unit** (no `~/.claude` grant — matches the credentials-P0 stance and the verified local-engine setup). The OAuth-capable variant is the **explicit `--oauth` opt-in**, and when chosen the installer prints the exact `~/.claude` grant it is making (per "show exact commands"). Re-runnable.

### U5 — Capture self-check banner (`scripts/session-load.sh`)
A SessionStart line from `.extractor-health.json` + `.extraction-state.jsonl`: `capture: last drain <age> · backend=<b> · <n> deltas/7d`. When the timer is absent, or last drain > a threshold, or 0 deltas over the window, emit a **prominent** `## ⚠ capture not running` banner with the one-command fix (`install-extract-timer.sh --apply`). This is the "wired ≠ works" guard: dead capture can never silently persist again. Kill switch `SB_CAPTURE_HEALTH_BANNER=off`.

## 5. Verification (the crux — no stub passes for "done")

- **Plumbing tests** (CI-able, `SB_EXTRACT_STUB`): engine-precedence selection (each of local/cli/bare chosen under the right env), drainer done-set + no-double-drain, interactive-`claude` defer, the health-banner predicates. These prove the wiring.
- **Real-run check** (the must-pass — CI cannot cover the OAuth-vs-sandbox conflict, which is exactly why this gap shipped): one **non-stubbed** extraction writes a **real** delta. Primary procedure (the verified setup):
  - **local engine (ollama `qwen2.5:3b`):** runnable **in-session** — no recursive lock — so this is done *during the build*. `SB_EXTRACTOR_ENGINE=local SB_EXTRACTOR_LOCAL_URL=http://localhost:11434` → run the drainer on one real archived transcript → confirm a real wiki/PROJECT/graph delta + `.extraction-state.jsonl outcome:ok backend=local`.
  - **OAuth fallback (separate):** `bash scripts/extract-drain.sh` in an **idle window** (no interactive `claude`) → delta + `backend=cli-oauth status=ok`. (Operator step; can't run from inside this session.)
- "Green stubbed test" is explicitly **not** sufficient. The spec records this so a future change can't regress to proxy-only validation.

## 6. Rollout & back-compat

- Additive. With `SB_EXTRACTOR_ENGINE=auto` (default), no `SB_EXTRACTOR_LOCAL_URL`, no `ANTHROPIC_BASE_URL`, and no timer installed → behaviour is identical to today (drainer simply inactive; in-session still defers). No MCP server tool/schema change (server stays 2.6.4).
- Ships as a gated patch/minor release: version bump (plugin.json + marketplace.json lockstep) + a `skills/upgrade/SKILL.md` migration row. The migration **offers** (does not force) `install-extract-timer.sh --apply` — installing a user timer is a side effect the user opts into.
- Reversible: `systemctl --user disable --now sb-extract-drain.timer` + remove the unit; unset the env.

## 7. Security summary (threat model: credentials P0, offline-first)

- **Default install (hardened local-only unit + local ollama engine): zero Anthropic credential exposure; fully offline.** This is the out-of-the-box path on the verified machine.
- OAuth is an explicit `--oauth` opt-in: that variant adds the one relaxation (`~/.claude` RW to the background service), with the rest of the systemd hardening intact, and the installer prints the grant first.
- Override trust boundary documented (U1): transcript content goes to whatever `SB_EXTRACTOR_LOCAL_URL`/`ANTHROPIC_BASE_URL` names — default is `localhost` (on-device). No `curl | bash`.
- **Verified environment (2026-06-05):** ollama 0.23.4, model `qwen2.5:3b` (1.9 GB, Q4_K_M), `/v1` endpoint live on `localhost:11434`, ~3.5 GB RAM free on the Pi 5 (fits alongside the on-device embedder).

## Correction (0.24.19)

Two claims in this spec were wrong/over-stated and are corrected in 0.24.19 (Claude-first universal engine):
- **`ANTHROPIC_BASE_URL` override did NOT exist** in SP-A — Backend 2's curl was hardcoded to `https://api.anthropic.com`. It was actually added in 0.24.19 (`lib.sh` ~899) with a test.
- **"offline-first identity" / "local-LLM-preferred" over-frames local.** For a broadly-shipped Claude plugin, **Claude is the universal engine** (API key = in-session any OS; subscription = out-of-band drainer). The local model is an **opt-in** offline/privacy path (`SB_EXTRACTOR_LOCAL_URL`, unset by default) — tried first only when set, with Claude as the fallback. The plugin never assumes a local model is present.
