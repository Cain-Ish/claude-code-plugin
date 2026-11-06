# V2-D26 probe: v1's leftovers after the move

The question, options, check and rule are registered in [DECISIONS.md](../../DECISIONS.md) (V2-D26, 2026-11-06,
before the docs were read or this probe ran).

## What runs

[`.github/workflows/v2-d26.yml`](../../../../.github/workflows/v2-d26.yml), on GitHub's ephemeral Windows, macOS and
Linux runners. Each runner's real home is used, since the runner is thrown away. On Linux, the job first enables
lingering, so `systemctl --user` has a user session.

1. [`setup.sh`](setup.sh):
   - v1's plugin (`v1-final`) is copied into the plugin cache as `0.57.1`;
   - `settings.json` gets a statusline `echo before`;
   - one sample file is written to each data folder;
   - v1's own `sb buddy install` and `install-extract-timer.sh --apply` run from the cached copy. Each is checked to
     be in place: the chained statusline, the shims, the env file and the scheduler entry;
   - D25's move: `0.57.1` leaves the cache and a v2 copy arrives;
   - *precondition:* the statusline command then prints v1's message;
   - after 30 seconds, the data is hashed by [`datahash.mjs`](datahash.mjs): `~/.second-brain` without `bin/` and the
     env file, and `~/knowledge`.
2. *The route (M):*
   - [`statusline-edit.mjs`](statusline-edit.mjs) makes the settings edit the README states;
   - then the README's commands for the system: [`route-linux.sh`](route-linux.sh), [`route-macos.sh`](route-macos.sh)
     or [`route-windows.ps1`](route-windows.ps1).
3. [`verify.sh`](verify.sh) checks the registered pass conditions, including that the README holds each command line
   the route ran.

## Primary docs (read 2026-11-06)

- *No lifecycle hook:* none of the hook events fires on plugin install, update or removal
  ([hooks](https://code.claude.com/docs/en/hooks)). `Setup` "fires only when you launch Claude Code with `--init-only`,
  or with `--init` or `--maintenance` in non-interactive mode with the `-p` flag".
- *The old copy:* "When you update or uninstall a plugin, Claude Code writes an `.orphaned_at` marker into the previous
  version directory. It removes that directory in a background cleanup 14 days later"
  ([plugin loading](https://code.claude.com/docs/en/plugins/loading)). Until then, v1's two shims find v1's old copy
  and run it.

## Result (run 42280395683, 2026-11-06): pass on all three systems, on the first run

| | Windows | macOS | Linux |
| --- | --- | --- | --- |
| v1's install | task `sb-extract-drain` | LaunchAgent `sb-extract-drain` | `sb-extract-drain.service` + `.timer`, enabled |
| precondition: the statusline after the move | v1's message | v1's message | v1's message |
| `statusLine` after the route | `echo before` | `echo before` | `echo before` |
| scheduler entry | gone | gone, plist gone | gone, unit files gone |
| shims, launcher, env file | gone | gone | gone |
| data (files hashed) | unchanged (3) | unchanged (4) | unchanged (3) |
| README holds each command run | 2 of 2 | 3 of 3 | 4 of 4 |

- The precondition reproduces the user's case word for word: "buddy: no second-brain renderer found — run
  /second-brain:buddy install".
- *Stated limits:*
  - the statusline step in the README is an edit described in words. The probe makes that edit by script, so it
    shows the end state is enough, not that a reader makes the edit correctly;
  - the runners had a fresh `settings.json` and no other plugins;
  - `BRAIN_DIR` was not set, so the README's line about a custom folder is not exercised.

Raw log: `research/raw/d26/` (gitignored).
