# V2-D25 probe: the marketplace name a v1 install meets on `main`

The question, options, check and rule are registered in [DECISIONS.md](../../DECISIONS.md) (V2-D25, 2026-11-06,
before the docs were read or this probe ran).

## Setup (2026-11-06, CLI 2.1.319, Windows)

- *The stand-in for GitHub:* a local bare repository with `main` at v1's release commit (`9718cee`, `0.57.1`), served
  over git's smart HTTP on `127.0.0.1` (a small CGI bridge to `git http-backend`). The CLI refuses a `file://` source
  ("Invalid marketplace source format"), and git's dumb HTTP cannot serve the CLI's shallow clone.
- *The arms,* each pushed to the stand-in as a branch:
  - (K): a probe-only commit on `v2` at `3de0a7e` that changes one line, the marketplace's `name`, to `second-brain`.
    It was never pushed to GitHub;
  - (R): `v2` at `3de0a7e` as it is (`second-brain-v2`). Its product is the released `2.0.0-alpha.5`.
- *Each arm* runs [`probe.sh`](probe.sh) in its own fresh `CLAUDE_CONFIG_DIR` in a short folder:
  1. add the stand-in with no ref, as v1's README told users to;
  2. install `second-brain@second-brain` (v1);
  3. move the stand-in's `main` to the arm's commit;
  4. `claude plugin marketplace update second-brain`, then `claude plugin update second-brain@second-brain`;
  5. read the marketplace and plugin lists, `known_marketplaces.json` and `installed_plugins.json`, and hash each
     cached copy with [`hash.mjs`](hash.mjs) (the self-test's product hash).
- *A difference from a real v1 install,* stated: the stand-in is a `git` source, while v1 users added a `github`
  source. Under (K), nothing about the name changes, so the update is an ordinary one.

## Primary docs (read 2026-11-06)

- *Where the name comes from:* "Claude Code takes that name from the `name` field in your `marketplace.json`, not from
  the repository name" ([host-marketplace](https://code.claude.com/docs/en/plugins/host-marketplace)).
- *A plugin's id:* `<marketplace>` "is the name the marketplace registered under"
  ([install](https://code.claude.com/docs/en/plugins/install)).
- *A change of that name later:* the docs do not say. The `renames` map covers plugin entries, not marketplaces.
- *Auto-update:* "Off by default: every other marketplace, including the community marketplace, third-party
  marketplaces, and local development marketplaces" ([install](https://code.claude.com/docs/en/plugins/install)). So
  a v1 user stays on v1 when `main` moves, until they run the update.

## Result: both arms pass

| | (K) `second-brain` | (R) `second-brain-v2` |
| --- | --- | --- |
| add, install v1 | exit 0, `0.57.1` | exit 0, `0.57.1` |
| marketplace update | exit 0, "Successfully updated marketplace: second-brain" | the same |
| plugin update | exit 0, "updated from 0.57.1 to 2.0.0-alpha.5" | the same |
| `second-brain@second-brain` | `2.0.0-alpha.5`, at the arm's commit | the same |
| cached copy's product hash | `62929fea5ecf` | `62929fea5ecf` |
| marketplace entries | one, `second-brain` | one, `second-brain`: the key stays the name it was added under |
| v1's cached copy | kept, marked with `.orphaned_at` | the same |

- Under (R), the fetched manifest says `second-brain-v2`, but the CLI keeps the entry under the name the user added it
  under. So the name does not decide whether a v1 install reaches v2.
- v1's cached copy stays on disk with an `.orphaned_at` marker, Claude Code's mark for later cleanup. It is no longer
  an install: `installed_plugins.json` holds only `2.0.0-alpha.5`. This bears on D26: v1's README says its statusline shim resolves the
  newest installed version at run time, which is now v2, and v2 has no renderer.

Raw output stays local (`research/raw/`, gitignored).
