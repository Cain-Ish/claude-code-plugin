#!/bin/bash
# SKIPPED in v1.0 - kept as a placeholder so callers that invoke this file
# (README.md, docs/plans/2026-05-01-second-brain-v1.0-implementation.md Task 19)
# do not fail.
#
# This test was designed for the 0.7.0 reflection->critic->learnings pipeline
# (pre-clear.sh, extract-learnings.sh, post-compact.sh, smart-context.sh,
# drift-detect.sh, .pending-reflections.jsonl, friction/drift logs, quality-gate
# reflection emission, etc.). All 32 cases exercised scripts and JSONL queues
# that v1.0 deleted. There is no useful subset to keep; the v1.0 hot-tier flow
# (USER.md / PROJECT.md / index.txt active line / stop-hook-predicate / pin/
# archive MCP tools) is covered by:
#   - tests/test-stop-hook-predicate.sh
#   - tests/test-validate-plugin.sh
#   - mcp/test/*.test.ts
#
# When v1.0+ adds new hook regression coverage, replace this stub with a real
# test suite. Until then, this file exits 0 with a SKIP marker so existing
# runners can still call it without false failures.
# user-instruction-anchor: "1"

echo "SKIP: test-hooks-regression.sh - old reflection-pipeline tests, replaced in v1.0"
echo "      see test-stop-hook-predicate.sh + mcp/test/ for v1.0 coverage"
exit 0
