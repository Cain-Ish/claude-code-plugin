---
disable-model-invocation: true
name: field-check
description: Checks how the installed second-brain plugin works in the user's other active sessions, then turns what it finds into verified fixes and the next check. Use when the user asks to check the plugin here and in other active sessions, how the plugin is used, whether Claude calls it, or to update the plugin and ask the other sessions.
---
# Field check of the plugin

1. **Find the field sessions.** List the active sessions and, for each repo that runs the plugin, the version it has
   installed. Done when each field repo has its installed version next to the latest release.
2. **Move the installs.** Update each field repo's install to the latest release and ask its active session to run
   `/reload-plugins`. Done when the plugin registry shows that release in each field repo.
3. **Count.** Run "The loop, each count" in `docs/v2/probes/V2-D17-field/README.md`: freeze the changed transcripts,
   scan them, read what it names, and record the counts in `docs/v2/06-first-slice.md`. Done when 06 holds the
   count, in numbers only.
4. **Ask.** Send each session the fixed question from that README, at most once per session; its answer stays out
   of the repo. Done when each session has answered or said it cannot.
5. **Check against the concept.** Hold each finding against `docs/v2/00-charter.md`: does Claude call the plugin
   (hooks, skills, agents), and do the files it should make exist and hold what they should? Confirm each finding in
   the transcript or the code before acting on it. Done when every finding is marked confirmed or dropped.
6. **Triage and fix** each confirmed finding as step 6 of that loop says. A defect is a build step in
   `docs/v2/06-first-slice.md`, run from a plugin copy until its checks pass, then a PR merged on the user's word,
   and back to step 2. Done when the fix is merged and the field installs carry it.

<!-- evidence: d3.digest:72, d4.digest:1313, d4.digest:1397, d5.digest:357, d6.digest:343, d7.digest:24 -->
