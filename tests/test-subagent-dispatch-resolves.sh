#!/bin/bash
# Behavioral guard (NOT a presence-grep): every `second-brain:<X>` a skill references — a
# subagent_type DISPATCH or a /second-brain:<skill> cross-ref — must RESOLVE to a real target:
# an agent (agents/<X>.md whose frontmatter `name:` matches <X>) or a skill (skills/<X>/SKILL.md).
#
# Why this exists: the old guards grep the SKILL.md body for the literal dispatch string and pass on
# mere PRESENCE — they never verify the target resolves. A renamed/typo'd subagent_type silently
# no-ops the dispatch at runtime (the persona-charter class: correct-looking text that never works).
# This already shipped once — commit 9f2264a fixed a non-resolving maintain subagent_type that the
# presence-greps did not catch (a human deep-review did). maintain also WRAPS `subagent_type:` onto a
# second line, so a single-line grep misses it — hence this resolves by VALUE, format-agnostically.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

# (a) Every agent's frontmatter name: must equal its filename — else subagent_type can't resolve it.
for a in "$ROOT"/agents/*.md; do
  base=$(basename "$a" .md)
  grep -qE "^name: *${base}\$" "$a" || fail "agents/${base}.md: frontmatter 'name:' != filename — dispatch would not resolve"
done
pass "every agent's name: matches its filename (subagent_type can resolve)"

# (b) Every second-brain:<X> reference in any skill resolves to a real skill OR a real agent.
refs=$(grep -rhoE 'second-brain:[a-z0-9-]+' "$ROOT"/skills/*/SKILL.md 2>/dev/null | sed 's/^second-brain://' | sort -u)
[ -n "$refs" ] || fail "found no 'second-brain:<X>' references (grep/path regression?)"
dangling=0
while IFS= read -r x; do
  [ -n "$x" ] || continue
  [ -f "$ROOT/skills/$x/SKILL.md" ] && continue
  { [ -f "$ROOT/agents/$x.md" ] && grep -qE "^name: *${x}\$" "$ROOT/agents/$x.md"; } && continue
  echo "  DANGLING: second-brain:$x → neither skills/$x/SKILL.md nor agents/$x.md(name:$x)"
  dangling=1
done <<REFS
$refs
REFS
[ "$dangling" -eq 0 ] || fail "a skill references a second-brain:<X> that resolves to no skill or agent (broken dispatch/cross-ref)"
pass "every second-brain:<X> skill reference resolves to a real skill or agent"

# (c) The data-promotion-critical maintain dispatches specifically resolve to AGENTS (not skills):
#     if knowledge-maintainer/raw-drainer stop resolving, /second-brain:maintain silently no-ops and
#     captured material never graduates into the wiki.
for ag in knowledge-maintainer raw-drainer; do
  grep -q "second-brain:$ag" "$ROOT/skills/maintain/SKILL.md" \
    || fail "skills/maintain no longer dispatches second-brain:$ag"
  grep -qE "^name: *${ag}\$" "$ROOT/agents/$ag.md" \
    || fail "agents/$ag.md missing or name: mismatch — maintain's dispatch would no-op"
done
pass "maintain's knowledge-maintainer + raw-drainer dispatches resolve to real agents"

echo; echo "ALL PASS"
