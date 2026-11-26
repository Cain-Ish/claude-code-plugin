# V2-8n: the product on `main`

Built before the release; nothing here pushes. See `docs/v2/06-first-slice.md`, "8n, the product on `main`".

- `product.mjs <repo> <out>`: writes the allowlist from the repo's HEAD commit (`git archive`, never the working tree)
  into an empty `<out>`. The allowlist is the `ALLOW` array at its top: `plugin/` (without `plugin/test/`),
  `.claude-plugin/`, `README.md`, `LICENSE`, `.github/workflows/main.yml`.
- `check1.mjs <tree>`: check 1. Exit 1, naming each `extra:` and `missing:` path; nothing under `plugin/test/` passes.
- `.github/workflows/main.yml` is written by `product.mjs`. `v2.yml`'s jobs run `plugin/test/` (self-test, load bench), so
  they cannot run on `main`. `main.yml` has one job, `validate`, running `claude plugin validate plugin`.

## Dry run (clone of `v2` at f2147e42)

| | files | bytes |
|---|---|---|
| `main` today | 449 | 3,681,262 |
| product tree | 28 | 265,682 |

`check1.mjs`: ok. A tree with an extra file, a `plugin/test/` file and a missing LICENSE exits 1 naming all three.
`claude plugin validate plugin` on the product: passed.

## At the release

Check 2 (old `main` updates to the new one; needs the new `main` pushed). In a throwaway config:

    export CLAUDE_CONFIG_DIR=$(mktemp -d)            # throwaway; never the real config
    claude plugin marketplace add Cain-Ish/claude-code-plugin   # still the OLD main
    claude plugin install second-brain@second-brain
    # ... push the product tree to main ...
    claude plugin marketplace update second-brain
    claude plugin update second-brain@second-brain
    ls "$CLAUDE_CONFIG_DIR/plugins/marketplaces/second-brain"  # expect only the allowlist (no docs/, no plugin/test/)
    node check1.mjs "$CLAUDE_CONFIG_DIR/plugins/marketplaces/second-brain"
    claude plugin validate "$CLAUDE_CONFIG_DIR/plugins/marketplaces/second-brain/plugin"

If the old clone keeps stale files or the update fails, the README tells users to remove and add the marketplace again.
Check 3's second half: on that fresh install, `claude plugin details second-brain@second-brain`.

Check 4 (the user's GitHub setting): `main`'s ruleset today requires `v2.yml`'s `selftest` jobs on PRs to `main`.
Those jobs will not exist on the new `main`, so the PR would wait forever. Change the required checks to `validate`
(from `main.yml`) before or with the push.
