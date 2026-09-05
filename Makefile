.PHONY: test test-quiet hook-install hook-uninstall release-check production-lane

# Run the full second-brain test suite.
test:
	@bash tests/run-all.sh

# Quiet variant — only per-test verdicts, no inner stdout.
test-quiet:
	@SB_RUN_ALL_QUIET=1 bash tests/run-all.sh

# Wire up the in-repo pre-push gate. Idempotent.
# After this, `git push` runs tests/run-all.sh and aborts on any failure.
hook-install:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/pre-push
	@echo "pre-push hook installed (core.hooksPath = .githooks)"
	@echo "to bypass for one push: SB_SKIP_PREPUSH=1 git push"

# Reset to the default git hooks dir.
hook-uninstall:
	@git config --unset core.hooksPath || true
	@echo "pre-push hook uninstalled"

# What the release gate enforces: tests + smoke-import of the vector deps.
# Equivalent to the contract `pre-push` enforces, runnable on demand.
release-check:
	@echo "== release-check: vector-deps smoke =="
	@cd mcp && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' \
		|| { echo "FAIL: vector deps not installed — run: bash bin/install-vector-deps.sh"; exit 1; }
	@echo "== release-check: tests =="
	@bash tests/run-all.sh
	@echo "== release-check: PASS — tag is allowed =="

# D017 (post-audit improvement 4B): the ONLY place the real hybrid BM25+RRF/
# embeddings path is exercised — CI has no network to HuggingFace and stays
# permanently offline (SECOND_BRAIN_DISABLE_EMBEDDINGS=1), so a regression in
# the embeddings-ON branch can ship invisibly forever otherwise. Developer-
# machine only; requires the model already cached locally (bin/install-vector-
# deps.sh). Never wired into CI or run-all.sh — this is a deliberate SEPARATE
# gate, not a dependency of `make test`.
#   HF_HUB_OFFLINE=1: fail FAST if the model is somehow absent instead of
#   hanging on a network fetch attempt (there is none here — offline lane, but
#   the flag also documents the intent: this must never touch the network).
#   SECOND_BRAIN_DISABLE_EMBEDDINGS=0: the search/episodic vitest files check
#   for the literal string '1' to disable — any other value (including "0")
#   leaves embeddings ON. test-injection-gate.sh / test-loop-smoke.sh read the
#   SAME var with an unset-only default (`${VAR-1}`), so exporting it here
#   overrides their normal embeddings-off pin instead of being shadowed by it.
production-lane:
	@echo "== production-lane: vitest search/episodic suite (embeddings ON) =="
	@cd mcp && SECOND_BRAIN_DISABLE_EMBEDDINGS=0 HF_HUB_OFFLINE=1 npx vitest run --reporter=default \
		src/tools/episodic-index.test.ts \
		src/tools/episodic-read-guard.test.ts \
		src/tools/episodic-search-scope.test.ts \
		src/tools/episodic-search.test.ts \
		src/tools/episodic-textscore.test.ts \
		src/tools/knowledge-search-boost.test.ts \
		src/tools/knowledge-search.test.ts \
		src/tools/search-output-contract.test.ts
	@echo "== production-lane: injection-gate (embeddings ON) =="
	@SECOND_BRAIN_DISABLE_EMBEDDINGS=0 HF_HUB_OFFLINE=1 bash tests/test-injection-gate.sh
	@echo "== production-lane: loop-smoke (embeddings ON) =="
	@SECOND_BRAIN_DISABLE_EMBEDDINGS=0 HF_HUB_OFFLINE=1 bash tests/test-loop-smoke.sh
	@echo "== production-lane: PASS =="
