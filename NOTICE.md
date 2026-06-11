# Third-party content

## obra/superpowers — recommended companion (no longer vendored)

Versions ≤ 0.24.41 vendored five skills (brainstorming, systematic-debugging,
test-driven-development, verification-before-completion, writing-plans) from
[obra/superpowers](https://github.com/obra/superpowers) (MIT, Copyright (c)
2025 Jesse Vincent). They were **removed in 0.24.42** (R6, deep-dive SKAG-2):
with upstream superpowers installed alongside, the duplicate near-identical
skill descriptions doubled skill-list tokens in every session and dispatched
nondeterministically between divergent bodies (the fragmented
`docs/specs` vs `docs/superpowers/specs` corpus in this repo is the scar).

**Install the upstream plugin instead** (`superpowers` ≥ 5.1.0 from the
official marketplace). The `/second-brain:setup` skill warns when it is
absent. The plugin's own workflow prose references the `superpowers:*` skill
names. Standalone installs without superpowers simply don't get those five
discipline skills — the second-brain's own functionality does not depend on
them.

The pre-0.24.42 vendored copies (with their MIT license text) remain in git
history at tag-era `0.24.41` if ever needed.
