# Worked transcripts — verified live 2026-07-05

Companion to [../SKILL.md](../SKILL.md). Every transcript below was executed against this
repo on 2026-07-05 with the 0.33.31 release batch uncommitted in the working tree
(HEAD `6fba312` = release 0.33.30). Commands are bash from the repo root; all state is
sandboxed (`mktemp -d`).

## §1 — Test-the-test, read-only variant: the REFLECT feedback loop (Recipe 5)

Goal: prove the regression lock discriminates — the pre-fix clusterer admits a generated
reflection page into its own cluster; the 0.33.31 fix excludes it. No working-tree mutation:
the pre-fix component is extracted from git with `git show`.

```bash
S=$(mktemp -d)
mkdir -p "$S/root/scripts" "$S/root/mcp/dist/tools" "$S/kd/wiki/entities" "$S/kd/wiki/learnings"

# Pre-fix component pair, extracted read-only from HEAD (6fba312 / 0.33.30 — the last
# commit WITHOUT the generated:true filter). After 0.33.31 lands, keep using 6fba312 here.
git show 6fba312:mcp/dist/tools/graph-cluster-cli.bundle.js > "$S/root/mcp/dist/tools/graph-cluster-cli.bundle.js"
git show 6fba312:scripts/graph-cluster.sh                   > "$S/root/scripts/graph-cluster.sh"

# Fixture (the KD3 shape from tests/test-graph-cluster-shim.sh:89-96): a 4-clique {a,b,c,d}
# plus a GENERATED reflection page related to all four members — exactly what a prior dream's
# REFLECT phase writes into learnings/.
page(){ s=$1; shift; rel=""; for r in "$@"; do rel="${rel}[[${r}]], "; done
  printf '%s\n' '---' "title: $s" 'type: entities' "related: ${rel%, }" '---' "# $s body" \
    > "$S/kd/wiki/entities/$s.md"; }
page a b c d; page b a c d; page c a b d; page d a b c
printf '%s\n' '---' 'title: reflection-a' 'type: learnings' 'generated: true' 'reflection: true' \
  'related: [a, b, c, d]' 'member_hash: deadbeef' '---' '# synthesized practice' \
  > "$S/kd/wiki/learnings/reflection-a.md"

echo "--- PRE-FIX (6fba312 bundle):"
CLAUDE_PLUGIN_ROOT="$S/root" bash "$S/root/scripts/graph-cluster.sh" --knowledge-dir "$S/kd" \
  | jq -c '.[0].members, .[0].id'
echo "--- FIXED (working-tree bundle):"
CLAUDE_PLUGIN_ROOT="$(pwd)" bash scripts/graph-cluster.sh --knowledge-dir "$S/kd" \
  | jq -c '.[0].members, .[0].id'
```

Observed output (2026-07-05):

```
--- PRE-FIX (6fba312 bundle):
["a","b","c","d","reflection-a"]
"a"
--- FIXED (working-tree bundle):
["a","b","c","d"]
"a"
```

Interpretation: pre-fix, the reflection page joins the cluster it summarizes → `member_hash`
changes every dream (idempotence defeated; the LLM re-reflects forever). In this fixture the
id stays `a` because `a` sorts before `reflection-a`; for a cluster like `{x,y,z}` the
reflection page (`r…` < `x…`) sorts FIRST and *becomes* the cluster id, spawning
`reflection-reflection-<id>` pages each run — the growth mode described in
`mcp/src/tools/graph-cluster-cli.ts:69-76` (working tree) and CHANGELOG `## 0.33.31`.

Stash-based equivalent while the fix is uncommitted (mutating, standard workflow):

```bash
bash tests/test-graph-cluster-shim.sh   # ALL PASS
git stash push -- mcp/src/tools/graph-cluster-cli.ts mcp/dist/tools/graph-cluster-cli.bundle.js
bash tests/test-graph-cluster-shim.sh   # FAILs: 'REFLECT feedback loop: generated reflection page joined its own cluster'
git stash pop
```

The bundle MUST be stashed together with the `.ts`: the shim executes
`mcp/dist/tools/graph-cluster-cli.bundle.js`, so stashing only the source leaves the fixed
bundle live and the test stays green — a false RED-check.

## §2 — Guard violation-injection probe (Recipe 2)

```bash
printf '{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HOME/.ssh/authorized_keys" \
  | BRAIN_DIR="$(mktemp -d)" bash scripts/symlink-guard.sh \
  | jq -r '.hookSpecificOutput.permissionDecision // "SILENT-ALLOW"'
```

Expected on a healthy install: `deny`. `SILENT-ALLOW` = the guard is fail-open on this box —
the exact defect class the 2026-07-02 audit proved live on Windows (pre-0.33.31, a
`C:\Users\<you>\.ssh\id_rsa` payload produced empty output). The Windows-form probe and the
benign-payload/no-overblocking probe, plus the persona-tool-guard and wiki-write-guard
payload shapes, are catalogued in sb-diagnostics-and-tooling (one home per fact — not
duplicated here).

## §3 — Patch-id equivalence session (Recipe 7)

Commands and verbatim output, 2026-07-05:

```
$ git log main..fix/home-cwd-relative-brain-dir --oneline
ef7a8e7 fix(mcp): resolve brain/knowledge dir via os.homedir(), not process.env.HOME

$ git show ef7a8e7 | git patch-id
d810f36ce683377f73efe9b9cdc3f22f4ea16ef0 ef7a8e7a75b1e1f9b111c533e976efde985fb52f

$ git show 788f193 | git patch-id
d810f36ce683377f73efe9b9cdc3f22f4ea16ef0 788f19364943099ca8b06db88e4f225f79f3547a

$ git cherry main fix/home-cwd-relative-brain-dir
- ef7a8e7a75b1e1f9b111c533e976efde985fb52f
```

Reading: identical first field from `git patch-id` = identical diff content; the `-` prefix
from `git cherry` says main already contains a patch-equivalent commit. The branch carries
nothing unique — deletable.

## §4 — P1c injection measurement probe (Recipe 6)

```bash
printf '{"session_id":"measure","prompt":"how should I refactor the search module to add caching?"}' \
  | BRAIN_DIR="$(mktemp -d)" bash scripts/persona-context.sh \
  | jq -r '.hookSpecificOutput.additionalContext // ""' | wc -c
```

Observed 2026-07-05 (sandboxed, empty BRAIN_DIR): `1023` bytes ≈ 255 tokens at the
~4 bytes/token heuristic. The recorded reference measurement for the shipped claim is
~662 B ≈ ~165 tokens (CHANGELOG `## 0.33.30`, P1c); the delta is expected — the injection is
keyword- and state-driven, so byte counts vary with the prompt and the persona/wiki state of
the box. What the recipe requires is not one magic number but the recorded command + the
number it produced on the state you measured.
