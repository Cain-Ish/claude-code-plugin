#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-archived-slugs.sh"; [ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRAIN_DIR="$T"
mkdir -p "$T/wiki-archive/entities"
LOG="$T/wiki-archive-log.jsonl"
# x archived then restored (=> net: NOT archived); y archived (=> net: archived)
printf '%s\n' \
  '{"event":"archived","slug":"x","category":"entities","date":"2026-05-26T01:00:00Z"}' \
  '{"event":"archived","slug":"y","category":"entities","date":"2026-05-26T02:00:00Z"}' \
  '{"event":"restored","slug":"x","category":"entities","date":"2026-05-26T03:00:00Z"}' > "$LOG"
printf 'archived\n' > "$T/wiki-archive/entities/y.md"   # y's archive file exists

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(bash "$SC")
printf '%s\n' "$out" | grep -qx "y	entities" && ok "lists net-archived y" || bad "y not listed ($out)"
printf '%s\n' "$out" | grep -q '^x' && bad "x still listed (restored)" || ok "x excluded (restored)"
bash "$SC" --has y; [ $? -eq 0 ] && ok "--has y -> 0" || bad "--has y nonzero"
bash "$SC" --has x; [ $? -eq 1 ] && ok "--has x -> 1" || bad "--has x not 1"
p=$(bash "$SC" --path y); [ "$p" = "$T/wiki-archive/entities/y.md" ] && ok "--path y -> file" || bad "--path y wrong: $p"
bash "$SC" --path x >/dev/null; [ $? -eq 1 ] && ok "--path x -> 1 (not net-archived)" || bad "--path x not 1"
# a corrupt line must NOT nuke the whole set (per-line tolerant parse)
printf 'GARBAGE NOT JSON\n%s\n' '{"event":"archived","slug":"z","category":"entities","date":"2026-05-26T04:00:00Z"}' >> "$LOG"
printf 'archived\n' > "$T/wiki-archive/entities/z.md"
out=$(bash "$SC"); printf '%s\n' "$out" | grep -qx "z	entities" && ok "tolerant: valid lines survive a corrupt line" || bad "corrupt line nuked the set ($out)"
# fail-open: no log
rm -f "$LOG"; out=$(bash "$SC"); [ -z "$out" ] && ok "no log -> empty (fail-open)" || bad "expected empty"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
