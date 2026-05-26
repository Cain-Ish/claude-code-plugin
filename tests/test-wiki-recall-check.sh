#!/usr/bin/env bash
# Unit-test scripts/wiki-recall-check.sh against a throwaway corpus.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-recall-check.sh"
[ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wiki/learnings"
printf -- '---\ntitle: Widget caching\ndescription: widgets cache via foobar\n---\nWidgets cache via the foobar store for speed.\n' > "$T/wiki/learnings/widget-caching.md"
printf -- '---\ntitle: Auth tokens\ndescription: oauth token refresh\n---\nOAuth tokens refresh on a sliding window.\n' > "$T/wiki/learnings/auth-tokens.md"
printf '%s\n' '{"q":"how do widgets cache","expect":["widget-caching"]}' \
              '{"q":"oauth token refresh","expect":["auth-tokens"]}' > "$T/q.jsonl"

P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

out=$(bash "$SC" --corpus "$T" --queries "$T/q.jsonl" --k 2); rc=$?
echo "$out" | grep -qE 'recall@2=1\.0' && ok "perfect recall on matching corpus" || bad "expected recall@2=1.0, got: $out"
[ "$rc" -eq 0 ] && ok "exit 0 on success" || bad "exit $rc"

# infra failure -> exit 2
out=$(bash "$SC" --corpus "$T" --queries "$T/missing.jsonl" --k 2 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "missing queries file -> exit 2" || bad "expected exit 2, got $rc"

# gate fail -> exit 1 (impossible recall threshold)
printf '%s\n' '{"q":"nonexistent zzz","expect":["nope"]}' > "$T/gate.jsonl"
out=$(SB_EVAL_MIN_RECALL=1.0 bash "$SC" --corpus "$T" --queries "$T/gate.jsonl" --k 2 --gate 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "gate recall failure -> exit 1" || bad "expected exit 1, got $rc ($out)"

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
