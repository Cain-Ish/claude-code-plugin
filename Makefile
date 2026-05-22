.PHONY: test test-quiet hook-install hook-uninstall release-check

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
