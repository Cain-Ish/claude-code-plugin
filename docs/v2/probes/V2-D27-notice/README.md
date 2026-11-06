# V2-D27 probe: does a line for the user reach them at session start?

The question, options, check and rule are registered in [DECISIONS.md](../../DECISIONS.md) (V2-D27, 2026-11-06,
before option (S) was built or run).

## What runs

- Option (S) was built in a copy of the plugin, version `2.0.0-alpha.6`. While a v1 shim is on disk, session start adds
  one `systemMessage` line beside its existing output. The shim is `bin/buddy-statusline.sh` or
  `bin/sb-extract-drain.sh`, under `$BRAIN_DIR` or `~/.second-brain`.
- [`deliver.mjs`](deliver.mjs) runs two Haiku sessions on CLI 2.1.319, each loading the copy with `--plugin-dir` and
  `--output-format stream-json --include-hook-events`, in a fresh git repo:
  - one with a `BRAIN_DIR` that holds `bin/sb-extract-drain.sh`;
  - one with an empty `BRAIN_DIR`.

## Result (2026-11-06): pass

| | with v1's shim | without |
| --- | --- | --- |
| the hook's `systemMessage` in the stream | the line | none |
| the hook's `additionalContext` | 1,277 bytes | 1,277 bytes, identical |
| the transcript | a `hook_system_message` attachment holding the line | none |
| the first request's input tokens | 25,555 | 25,553 |
| reply | "ok" | "ok." |

- *Claude's context:* the two first requests differ by 2 input tokens, and the line is about 35 tokens long. So the line
  reached the session as a message for the user, not as context for Claude.
- *Not checked:*
  - how the interactive screen shows the line. The docs call `systemMessage` a "Warning message shown to the user".
    The stream shows no separate message event in print mode;
  - D18's added time. It is measured with the release bench (map issue, step 18f).

Raw streams: `research/raw/d27/` (gitignored).
