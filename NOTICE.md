# Third-party content

This plugin bundles content from other open-source projects. License terms below.

## obra/superpowers (MIT)

The following skills are adapted from [obra/superpowers](https://github.com/obra/superpowers) (Copyright (c) 2025 Jesse Vincent) under the MIT License:

- `skills/brainstorming/`
- `skills/systematic-debugging/`
- `skills/test-driven-development/`
- `skills/verification-before-completion/`
- `skills/writing-plans/`

Five skills focused on senior-developer mindset (pause-to-think, plan, TDD, root-cause debug, evidence-before-claims). The other obra/superpowers skills (executing-plans, subagent-driven-development, using-git-worktrees, dispatching-parallel-agents, finishing-a-development-branch, receiving-code-review, requesting-code-review, writing-skills, using-superpowers) were not vendored — they are workflow-orchestration patterns better consumed via the upstream plugin.

Modifications made when vendoring:
- Cross-references to `superpowers:<skill-name>` rewritten to `second-brain:<skill-name>` so refs resolve in-plugin.
- `allowed-tools:` field added to YAML frontmatter to satisfy `scripts/validate-plugin.sh`.
- Sibling reference files not vendored (visual-companion.md, prompt templates, root-cause-tracing.md, defense-in-depth.md, condition-based-waiting.md). The main SKILL.md body is self-contained; deep-dives live upstream.
- Brainstorming spec/plan default paths simplified to `docs/specs/` and `docs/plans/` (dropped `superpowers/` prefix).

### MIT License

```
MIT License

Copyright (c) 2025 Jesse Vincent

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
