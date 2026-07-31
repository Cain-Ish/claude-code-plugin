export const meta = {
  name: 'devils-advocate',
  description: 'Adversarial five-lens review of a phase of work, refute-first verified — assumes the work is broken until proven otherwise',
  whenToUse: 'At every phase boundary, and before any release. Pass args: {phase, claims, files} — or a plain string describing the scope. Green tests are NOT evidence that a phase is done; this process exists because two audits in one session overturned two designs and found a live fail-open guard that every test passed around.',
  phases: [
    { title: 'Attack', detail: 'five independent adversarial lenses' },
    { title: 'Verify', detail: 'refute-first; a finding survives only if it cannot be refuted' },
  ],
}

// ---------------------------------------------------------------------------
// THE PROCESS (why it is shaped this way)
//
// 1. PRESUMPTION OF BROKENNESS. Each lens is told the work is guilty until proven
//    innocent. "Looks fine" is not a finding; only defects are.
// 2. FIVE LENSES THAT CANNOT COLLAPSE INTO EACH OTHER. Redundant reviewers agree with
//    each other and miss the same things. These five fail differently on purpose:
//    connectivity, adversarial input, contract drift, history, and over-build.
// 3. REFUTE-FIRST VERIFICATION. Every finding faces a skeptic whose job is to KILL it,
//    defaulting to refuted when uncertain. This is what keeps the output actionable
//    instead of a wall of plausible noise.
// 4. THE SINGLE-AXIS TRAP IS EXPLICIT. A fix that satisfies one lens can violate
//    another (closing a security bypass once caused silent data loss here). Lenses are
//    therefore told to state the cross-axis cost of their own proposed fix.
// ---------------------------------------------------------------------------

const REPO = 'C:/Workplace/Projects/claude-code-plugin-2'

const scope = (() => {
  if (!args) return { phase: 'the current working-tree changes', claims: '', files: '' }
  if (typeof args === 'string') return { phase: args, claims: '', files: '' }
  return { phase: args.phase || 'the current working-tree changes', claims: args.claims || '', files: args.files || '' }
})()

const CTX = `
Repo: ${REPO} — the second-brain Claude Code plugin (a local memory system for Claude Code).
Inspect real state: \`git -C "${REPO}" log --oneline -12\`, \`git -C "${REPO}" diff\`, and the files themselves.

UNDER REVIEW: ${scope.phase}
${scope.files ? `KEY FILES: ${scope.files}` : ''}
${scope.claims ? `CLAIMS MADE ABOUT IT (treat every one as a hypothesis to falsify, not a fact):\n${scope.claims}` : ''}

PROJECT CONSTRAINTS a finding must respect (check the code, do not assume):
- Windows git-bash/MSYS is the PRIMARY dev platform; also macOS (bash 3.2 floor, BSD tools),
  Linux, BSD CI. No GNU-only flags. jq on Windows emits CRLF -> tr -d '\\r' at read boundaries.
  GNU tar/rsync read "C:\\..." as host:path. pgrep/flock/ps -o are NOT all present on MSYS.
- Fail LOUD everywhere except PreToolUse guards (which fail safe). No silent 2>/dev/null exits.
- CONSTITUTION.md: fully autonomous, ZERO required user interaction. Safety comes from
  REVERSIBLE auto-consolidation, never from a human approval gate. A design that needs a human
  to approve routine writes is a violation, not a feature.
- Canonical wiki is ~/knowledge/wiki; ~/.second-brain/wiki is a legacy trap invisible to search.
- Single-source resolution: brain/knowledge dirs resolve ONLY via mcp/src/brain-paths.ts (TS)
  and lib.sh helpers (bash). Re-deriving them inline is the "two wikis" bug class.
- mcp/dist/** is committed and byte-compared by tests/test-bundle-current.sh.
- Determinism: same inputs must produce byte-identical output (no wall clock, no randomness).
- PROSE PROMISES NEED MACHINE LOCKS: a comment/doc/skill claiming a guarantee that no code
  enforces is itself a defect in this repo, not a nitpick.
- Surface budget is ratcheted: new scripts/tests/skills/agents need a same-commit bump.

WHAT COUNTS AS A FINDING: something that is BROKEN, UNPROVEN, DISHONEST (claim without a lock),
or DISPROPORTIONATE. Point at a file and line. If you cannot point at code, it is not a finding.
Do NOT report style preferences, and do NOT report pre-existing behavior unrelated to this work
unless this work made it load-bearing.
`

const FINDINGS = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: {
    findings: {
      type: 'array', maxItems: 10,
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'file', 'severity', 'failure', 'evidence'],
        properties: {
          title: { type: 'string', maxLength: 130 },
          file: { type: 'string', maxLength: 200 },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          failure: { type: 'string', maxLength: 800 },
          evidence: { type: 'string', maxLength: 900 },
          fix: { type: 'string', maxLength: 400 },
          cross_axis_cost: { type: 'string', maxLength: 300 },
        },
      },
    },
  },
}

const VERDICT = {
  type: 'object', additionalProperties: false, required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean' },
    reason: { type: 'string', maxLength: 800 },
    severity_adjusted: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'none'] },
  },
}

const LENSES = [
  { key: 'wire', prompt: `${CTX}

LENS 1 — THE WIRE-TRACER. Assume nothing is connected. Trace every hop of the actual execution
path end to end and find where the chain BREAKS or is UNPROVEN: what invokes this, does that
invoker exist and run, does it reach this code on Windows AND macOS AND Linux, does it find its
dependencies from an INSTALLED plugin path (not just the repo layout), and does its output
actually reach the destination it claims. A hop that only works in the developer's checkout is
a broken hop.` },

  { key: 'saboteur', prompt: `${CTX}

LENS 2 — THE SABOTEUR. You are trying to BREAK this, not to review it. Find the input or
condition that makes it misbehave: prompt-injected/poisoned content, hostile filenames and
path traversal, a missing binary (node/jq/git/rsync/timeout/gzip), a full or read-only disk, a
file locked by antivirus mid-operation, CRLF, a crash between two writes, two processes racing
the same file, an interrupted run resumed later, empty/huge/malformed inputs. For each: what
concretely goes wrong, and is the failure LOUD or silent? Silent is worse.` },

  { key: 'contract', prompt: `${CTX}

LENS 3 — THE CONTRACT AUDITOR. Compare what is CLAIMED against what is ENFORCED. Hunt: comments,
docs, skills and commit messages promising a guarantee no code implements; tests asserting a
script's own source text instead of its behavior; kill switches that do not switch anything;
error paths that cannot fire; "reversible"/"never deleted"/"fail-closed"/"atomic" claims that
the code does not actually deliver. Also check conformance to the stated plan and the
constitution. A prose promise without a machine lock IS the finding.` },

  { key: 'historian', prompt: `${CTX}

LENS 4 — THE HISTORIAN. This repo keeps a detailed incident record. Read
.claude/skills/sb-failure-archaeology/ (SKILL.md + references/) and relevant git history, then
answer: does this work re-introduce a pattern that was tried and REVERTED before, repeat a known
incident class (fail-open guards, CRLF, MSYS path forms, stale bundles, SKIP false-greens,
silent no-ops, ranking boosts), or contradict a documented decision? Cite the incident.` },

  { key: 'minimalist', prompt: `${CTX}

LENS 5 — THE MINIMALIST. Argue this is OVER-BUILT. Find: code that duplicates an existing helper
(name the helper and its path), abstractions with one caller and no second coming, dead or
unreachable branches, config knobs nobody will ever turn, tests that assert the same thing
twice, and surface added out of proportion to the problem it solves. For each, say what should
be DELETED or collapsed. The repo's own rule is naive-correct over clever.` },
]

phase('Attack')
const results = await pipeline(
  LENSES,
  (l) => agent(l.prompt, { label: `attack:${l.key}`, phase: 'Attack', schema: FINDINGS }),
  (r, l) => {
    if (!r || !r.findings || !r.findings.length) return []
    return parallel(r.findings.map((f) => () =>
      agent(`${CTX}

You are the SKEPTIC. Your job is to KILL this claimed defect by reading the actual code.

CLAIM: ${f.title}
FILE: ${f.file}${f.line ? ':' + f.line : ''}
CLAIMED FAILURE: ${f.failure}
EVIDENCE OFFERED: ${f.evidence}

Refute it if ANY of these hold: the code already handles it; the scenario cannot occur given how
callers actually invoke it; it is pre-existing behavior this work did not make load-bearing; it
contradicts a documented intentional decision; the evidence misreads the code; or it is a style
opinion rather than a defect. Default to refuted=true when uncertain — a false finding costs more
than a missed one here, because it sends a maintainer chasing ghosts. Set refuted=false ONLY if
you verified the defect is real, and then state concretely what breaks and how you confirmed it.`,
        { label: `verify:${l.key}`, phase: 'Verify', schema: VERDICT })
        .then((v) => ({ ...f, lens: l.key, survived: v ? v.refuted === false : false, verdict: v ? v.reason : 'verifier unavailable', severity: (v && v.severity_adjusted && v.severity_adjusted !== 'none') ? v.severity_adjusted : f.severity }))
    ))
  }
)

const all = results.flat().filter(Boolean)
const rank = { critical: 0, high: 1, medium: 2, low: 3 }
const confirmed = all.filter((f) => f.survived).sort((a, b) => (rank[a.severity] ?? 9) - (rank[b.severity] ?? 9))
const byLens = {}
for (const f of all) byLens[f.lens] = (byLens[f.lens] || 0) + (f.survived ? 1 : 0)

log(`devil's advocate on "${scope.phase}": ${all.length} raised, ${confirmed.length} survived refutation`)
return {
  scope: scope.phase,
  confirmed: confirmed.map((f) => ({
    severity: f.severity, lens: f.lens, title: f.title, file: f.file, line: f.line,
    failure: f.failure, evidence: f.evidence, fix: f.fix, cross_axis_cost: f.cross_axis_cost,
    why_it_survived: f.verdict,
  })),
  dismissed: all.length - confirmed.length,
  surviving_per_lens: byLens,
  verdict: confirmed.length === 0
    ? 'No finding survived refutation. That is evidence, not proof — record what was NOT examined.'
    : `${confirmed.length} finding(s) survived. Fix or consciously accept each before calling this phase done.`,
}
