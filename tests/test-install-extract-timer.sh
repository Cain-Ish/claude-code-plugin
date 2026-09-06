#!/bin/bash
# Tests for install-extract-timer.sh (print mode — never touches real systemd)
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
INSTALL="$SCRIPT_DIR/install-extract-timer.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export XDG_CONFIG_HOME="$SANDBOX/config"   # redirect systemd user dir into sandbox

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== install-extract-timer.sh tests ==="

# Test 1: default (print) mode emits both units and touches nothing
# Force systemd rendering: on non-Linux hosts uname returns MINGW*/Darwin and the
# default OS branch would output windows/launchd instead of systemd unit text.
OUT=$(SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>&1 || true)
printf '%s' "$OUT" | grep -q 'sb-extract-drain.service' && ok "prints .service" || no "prints .service"
printf '%s' "$OUT" | grep -q 'OnUnitActiveSec=30min'     && ok "prints .timer body" || no "prints .timer body"
# ExecStart must reference the STABLE shim (bin/sb-extract-drain.sh), NOT a version-pinned
# cache path (which goes stale/GC'd after a plugin upgrade — gap #1).
printf '%s' "$OUT" | grep -qE 'ExecStart=bash .*/bin/sb-extract-drain\.sh' && ok "ExecStart → stable shim" || no "ExecStart → stable shim"
printf '%s' "$OUT" | grep -qE 'ExecStart=.*/cache/.*/scripts/extract-drain\.sh' && no "ExecStart must NOT pin a versioned cache path" || ok "ExecStart not version-pinned"
printf '%s' "$OUT" | grep -q 'enable-linger'             && ok "surfaces linger command" || no "surfaces linger command"
[ ! -e "$XDG_CONFIG_HOME/systemd/user/sb-extract-drain.timer" ] \
  && ok "print mode writes nothing" || no "print mode writes nothing"

# Test 2: no ACTIVE PrivateDevices= directive (a warning comment mentioning it is fine)
printf '%s' "$OUT" | grep -qE '^[[:space:]]*PrivateDevices=' && no "must NOT set PrivateDevices directive" || ok "no active PrivateDevices directive"

# Test 3: rendered service has no unresolved @EXEC@ token
printf '%s' "$OUT" | grep -q '@EXEC@' && no "ExecStart still has @EXEC@ token" || ok "ExecStart token substituted"

# Test 4 (U3): hardened default unit grants brain + knowledge, NOT ~/.claude
HARD="$SCRIPT_DIR/../systemd/sb-extract-drain.service"
grep -q 'ReadWritePaths=.*%h/.second-brain' "$HARD" && ok "hardened: brain writable" || no "hardened: brain writable"
grep -q 'ReadWritePaths=.*%h/knowledge' "$HARD"      && ok "hardened: knowledge writable (wiki)" || no "hardened: knowledge writable"
grep -q '%h/.claude' "$HARD" && no "hardened must NOT grant ~/.claude" || ok "hardened: no creds grant"

# Test 5 (U3): OAuth variant exists and grants ~/.claude
OAUTH="$SCRIPT_DIR/../systemd/sb-extract-drain-oauth.service"
{ [ -f "$OAUTH" ] && grep -q '%h/.claude' "$OAUTH"; } && ok "oauth variant grants ~/.claude" || no "oauth variant missing/no creds grant"
{ [ -f "$OAUTH" ] && grep -q 'ReadWritePaths=.*%h/knowledge' "$OAUTH"; } && ok "oauth variant also writes knowledge" || no "oauth variant knowledge grant"

# Test 6 (U4): installer default print = hardened (no creds); --oauth print = creds + announced grant
DOUT=$(SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>&1 || true)
printf '%s' "$DOUT" | grep -q '%h/.claude' && no "default print leaked creds grant" || ok "default print = hardened (no creds)"
OOUT=$(SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" --oauth 2>&1 || true)
printf '%s' "$OOUT" | grep -q '%h/.claude' && ok "--oauth print renders creds grant" || no "--oauth print missing creds grant"
printf '%s' "$OOUT" | grep -qiE 'grant|NOTE' && ok "--oauth announces the grant" || no "--oauth announces the grant"

# Test 7 (SP-4): launchd (macOS) rendering, forced via SB_INSTALL_OS_OVERRIDE.
LA=$(SB_INSTALL_OS_OVERRIDE=launchd bash "$INSTALL" 2>&1)
printf '%s' "$LA" | grep -q '<plist' && ok "launchd: renders a plist" || no "launchd: no plist"
{ printf '%s' "$LA" | grep -q 'StartInterval' && printf '%s' "$LA" | grep -q 'RunAtLoad'; } && ok "launchd: StartInterval + RunAtLoad" || no "launchd: interval/runatload"
# ProgramArguments must reference the STABLE shim, NOT a version-pinned cache path (gap #1).
printf '%s' "$LA" | grep -qE '<string>[^<]*/bin/sb-extract-drain\.sh</string>' && ok "launchd: ProgramArguments → stable shim" || no "launchd: ProgramArguments → stable shim"
printf '%s' "$LA" | grep -qE '<string>[^<]*/cache/.*/scripts/extract-drain\.sh</string>' && no "launchd must NOT pin a versioned cache path" || ok "launchd: not version-pinned"
printf '%s' "$LA" | grep -qi 'logged in' && ok "launchd: prints the no-linger caveat" || no "launchd: no-linger caveat"

# Test 8 (SP-4): launchd snapshots the user's engine env into the unit (minimal-env fix).
LAE=$(SB_INSTALL_OS_OVERRIDE=launchd SB_EXTRACTOR_LOCAL_URL=http://x:1 bash "$INSTALL" 2>&1)
printf '%s' "$LAE" | grep -q 'SB_EXTRACTOR_LOCAL_URL' && ok "launchd: snapshots SB_EXTRACTOR_LOCAL_URL into the unit env" || no "launchd: env snapshot"

# Test 8b (SP-4 gate): a value with XML-special chars is escaped in the plist (valid XML).
LAX=$(SB_INSTALL_OS_OVERRIDE=launchd SB_EXTRACTOR_LOCAL_URL='http://x?a=1&b=2' bash "$INSTALL" 2>&1)
printf '%s' "$LAX" | grep -q '&amp;' && ok "launchd: XML-escapes & in env values" || no "launchd: unescaped & (invalid plist)"
printf '%s' "$LAX" | grep -qE '<string>[^<]*&[^a]' && no "launchd: raw & leaked into a <string>" || ok "launchd: no raw & in <string>"

# Test 9 (SP-4): windows (Task Scheduler) rendering.
WIN=$(SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" 2>&1)
printf '%s' "$WIN" | grep -q 'schtasks /Create' && ok "windows: renders a schtasks command" || no "windows: no schtasks"
printf '%s' "$WIN" | grep -q 'MINUTE /MO 30' && ok "windows: 30-min interval" || no "windows: interval"
printf '%s' "$WIN" | grep -qi 'no sandbox' && ok "windows: prints the no-sandbox caveat" || no "windows: sandbox caveat"

# Test 10 (SP-4): unsupported OS → the frictionless API-key fallback, no crash.
UNS=$(SB_INSTALL_OS_OVERRIDE=plan9 bash "$INSTALL" 2>&1)
printf '%s' "$UNS" | grep -q 'ANTHROPIC_API_KEY' && ok "unsupported OS → points at the API-key fallback" || no "unsupported OS fallback"

# Test 11 (SP-4): the Linux/systemd path is unchanged under the OS override.
SD=$(SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>&1)
printf '%s' "$SD" | grep -q 'sb-extract-drain.service' && ok "systemd path intact" || no "systemd path broke"

# Test 12 (SP-B deep-review HIGH): a CUSTOM knowledge dir is forwarded to the out-of-band
# job AND granted in the systemd sandbox (else extraction+consolidation hit the wrong tree).
KD=/data/mykb
SDC=$(CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>/dev/null)
printf '%s' "$SDC" | grep -q "Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=$KD" && ok "systemd: custom KD forwarded via Environment=" || no "systemd: custom KD not forwarded"
printf '%s' "$SDC" | grep -qE "^ReadWritePaths=.*$KD" && ok "systemd: custom KD granted in ReadWritePaths" || no "systemd: custom KD not granted (sandbox would block writes)"
# default render must NOT inject a CLAUDE env line (back-compat)
printf '%s' "$SD" | grep -q 'Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR' && no "default render injected a custom KD env line" || ok "default render unchanged (no custom KD)"
LAK=$(CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" SB_INSTALL_OS_OVERRIDE=launchd bash "$INSTALL" 2>/dev/null)
printf '%s' "$LAK" | grep -q "$KD" && ok "launchd: custom KD snapshotted into the plist env" || no "launchd: custom KD not forwarded"

# --- --apply tests (shim + env-file). These WRITE, so confine them to the sandbox: point both
# BRAIN_DIR and HOME at $SANDBOX and stub the system schedulers on PATH so --apply is inert. ---
mkdir -p "$SANDBOX/stubs"
for tool in schtasks launchctl systemctl; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/stubs/$tool"; chmod +x "$SANDBOX/stubs/$tool"
done
# Prepend the stubs so --apply's scheduler calls are inert. Exported (not a word-split var) because
# $PATH contains spaces on Windows (C:\Program Files...) which would shatter an `env VAR=$PATH` form.
export PATH="$SANDBOX/stubs:$PATH"
export HOME="$SANDBOX"

# Does chmod actually take effect on this filesystem? (no-op on Windows MSYS / some mounts) — if not,
# the mode-600 assertion is meaningless here but is genuinely exercised on the Linux/macOS CI.
_cf=$(mktemp); chmod 600 "$_cf"
_cm=$(stat -c '%a' "$_cf" 2>/dev/null || stat -f '%Lp' "$_cf" 2>/dev/null || echo '')
chmod 644 "$_cf" 2>/dev/null
[ "$(stat -c '%a' "$_cf" 2>/dev/null || stat -f '%Lp' "$_cf" 2>/dev/null || echo '')" != "$_cm" ] && CHMOD_WORKS=1 || CHMOD_WORKS=0
rm -f "$_cf"

# Test 13 (gap #1, behavioral): the generated shim resolves the HIGHEST-semver installed
# extract-drain.sh, not the first/lowest — so a plugin upgrade can't leave the job on stale code.
BR13="$SANDBOX/brain13"
CB13="$SANDBOX/cache13/plug/second-brain"
for v in 0.0.1 0.0.2; do
  mkdir -p "$CB13/$v/scripts"
  printf '#!/bin/bash\necho "RAN %s"\n' "$v" > "$CB13/$v/scripts/extract-drain.sh"
  chmod +x "$CB13/$v/scripts/extract-drain.sh"
done
SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR13" bash "$INSTALL" --apply >/dev/null 2>&1 || true
SHIM13="$BR13/bin/sb-extract-drain.sh"
[ -f "$SHIM13" ] && ok "apply: generated the stable shim" || no "apply: shim not generated"
grep -q 'sort -V' "$SHIM13" 2>/dev/null && ok "shim: uses sort -V latest-version resolution" || no "shim: no sort -V resolution loop"
# Behavioral (EC-06, 2026-08-23): a PRODUCTION apply bakes an EMPTY first base, so the shim
# resolves ONLY under $HOME/.claude/plugins/cache. The previous version of this test sed-rewrote
# whatever base was baked — so it passed while the installer baked the dev checkout's parent
# and the live 30-minute scheduler ran the working tree. Now: point HOME at a fake cache with
# two versions and assert the shim picks the highest one THROUGH the cache glob.
BAKED_BASE=$(grep -oE 'for _base in "[^"]*"' "$SHIM13" | head -1 | sed 's/for _base in "//; s/"$//')
[ -z "$BAKED_BASE" ] && ok "shim (production): baked first base is EMPTY — no repo pin" \
  || no "shim (production): baked a repo/checkout base '$BAKED_BASE' — the scheduler would run a working tree"
FAKEHOME="$SANDBOX/home13"; mkdir -p "$FAKEHOME/.claude/plugins/cache/plug"
ln -s "$CB13" "$FAKEHOME/.claude/plugins/cache/plug/second-brain" 2>/dev/null \
  || cp -r "$CB13" "$FAKEHOME/.claude/plugins/cache/plug/second-brain"
RAN=$(HOME="$FAKEHOME" bash "$SHIM13" 2>/dev/null)
[ "$RAN" = "RAN 0.0.2" ] && ok "shim: resolves the HIGHEST cached version (0.0.2) via the plugin-cache glob [got: $RAN]" \
  || no "shim: cache-glob resolution wrong [got: '$RAN']"
# And with NO cache at all, a production shim must fail loud (exit 0 + stderr), not exec a checkout.
RAN=$(HOME="$SANDBOX/emptyhome" bash "$SHIM13" 2>&1)
case "$RAN" in *"no extract-drain.sh found"*) ok "shim (production, no cache): refuses loudly instead of falling back to a checkout" ;;
  *) no "shim (production, no cache): expected the loud refusal, got: '$RAN'" ;; esac

# Test 13b: --dev is the ONLY way to pin a checkout, and it says so.
BR13D="$SANDBOX/brain13d"
DEVOUT=$(SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR13D" bash "$INSTALL" --apply --dev 2>&1 >/dev/null)
SHIM13D="$BR13D/bin/sb-extract-drain.sh"
DEVBASE=$(grep -oE 'for _base in "[^"]*"' "$SHIM13D" | head -1 | sed 's/for _base in "//; s/"$//')
[ -n "$DEVBASE" ] && [ -d "$DEVBASE" ] && ok "--dev: bakes the checkout's parent as first base ($DEVBASE)" \
  || no "--dev: expected a checkout base, got '$DEVBASE'"
case "$DEVOUT" in *"pinned to checkout"*) ok "--dev: announces the pin on stderr" ;; *) no "--dev: silent pin (no stderr notice)" ;; esac

# Test 14 (gap #2, behavioral): --apply captures the engine env into a mode-600 .extract-timer-env
# the shim sources — custom KD / local-model / api-key users no longer silently get defaults.
BR14="$SANDBOX/brain14"
SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR14" \
  SB_EXTRACTOR_LOCAL_URL=http://x:1 CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=/data/kb \
  bash "$INSTALL" --apply >/dev/null 2>&1 || true
EF14="$BR14/.extract-timer-env"
[ -f "$EF14" ] && ok "apply: wrote the engine env-file" || no "apply: env-file missing"
grep -q '^export SB_EXTRACTOR_LOCAL_URL=' "$EF14" 2>/dev/null && ok "env-file: forwards SB_EXTRACTOR_LOCAL_URL" || no "env-file: missing SB_EXTRACTOR_LOCAL_URL"
grep -q '/data/kb' "$EF14" 2>/dev/null && ok "env-file: forwards the custom KNOWLEDGE_DIR" || no "env-file: missing custom KD"
grep -qE 'ENV_FILE=.*\.extract-timer-env' "$BR14/bin/sb-extract-drain.sh" 2>/dev/null \
  && grep -q '\. "\$ENV_FILE"' "$BR14/bin/sb-extract-drain.sh" 2>/dev/null \
  && ok "shim: sources the env-file" || no "shim: does not source the env-file"
if [ "$CHMOD_WORKS" = "1" ]; then
  MODE=$(stat -c '%a' "$EF14" 2>/dev/null || stat -f '%Lp' "$EF14" 2>/dev/null || echo '')
  [ "$MODE" = "600" ] && ok "env-file: mode 600 (may hold ANTHROPIC_API_KEY)" || no "env-file: mode $MODE not 600"
else
  ok "env-file: mode-600 check skipped (chmod inert on this FS; enforced on CI)"
fi

# Test 15 (gap #3): the windows /TR resolves a git-bash bash path (not the bare command -v bash that
# could catch WSL System32\bash.exe), and the installer wires win_bash for the probe.
WINTR=$(SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" 2>&1)
printf '%s' "$WINTR" | grep -qiE 'bash\.exe|[Gg]it.[Bb]in.bash' && ok "windows: /TR points at a git-bash bash.exe" || no "windows: /TR has no git-bash bash path"
# 2026-08-20: the task launches through a hidden wscript shim by default — schtasks runs /TR in
# the logged-on interactive session, so a direct bash.exe /TR painted a Git Bash console every
# 30 minutes. Assert the default is hidden AND that the documented escape hatch still works,
# so neither can regress silently.
printf '%s' "$WINTR" | grep -q 'wscript.exe //B //Nologo' \
  && ok "windows: default /TR uses the hidden wscript launcher" || no "windows: /TR is not the hidden launcher"
WINVIS=$(SB_DRAIN_VISIBLE_WINDOW=1 SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" 2>&1)
printf '%s' "$WINVIS" | grep -q 'wscript.exe' \
  && no "windows: SB_DRAIN_VISIBLE_WINDOW=1 still uses wscript (escape hatch broken)" \
  || ok "windows: SB_DRAIN_VISIBLE_WINDOW=1 falls back to a direct bash /TR"
grep -q 'BASH_W=$(win_bash)' "$INSTALL" && ok "installer: windows uses win_bash (WSL-safe probe)" || no "installer: windows not using win_bash"
grep -qE 'Git\\+bin\\+bash\.exe' "$INSTALL" && ok "installer: win_bash probes the Git\\bin path list" || no "installer: no git-bash probe list"
# The OLD sole resolver (bare command -v bash as BASH_W=) must be gone.
grep -qE 'BASH_W=.*command -v bash' "$INSTALL" && no "installer: still resolves BASH_W via bare command -v bash" || ok "installer: no bare command -v bash as sole resolver"

# Test 16 (uninstall cleanup): --uninstall removes the shim AND the env-file.
BR16="$SANDBOX/brain16"
SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR16" bash "$INSTALL" --apply >/dev/null 2>&1 || true
[ -f "$BR16/bin/sb-extract-drain.sh" ] || no "uninstall-setup: apply did not create the shim"
SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR16" bash "$INSTALL" --uninstall >/dev/null 2>&1 || true
{ [ ! -e "$BR16/bin/sb-extract-drain.sh" ] && [ ! -e "$BR16/.extract-timer-env" ]; } \
  && ok "uninstall: shim + env-file removed" || no "uninstall: shim/env-file left behind"

# Test 17 (review MED): win_bash must survive UNSET PROGRAMFILES/LOCALAPPDATA under `set -u`. Without
# the :- guards the for-list expansion aborts in the $(win_bash) subshell → empty BASH_W → a broken
# schtasks /TR (and the cygpath fallback never runs). Print-mode windows with both vars unset.
W17=$(env -u PROGRAMFILES -u LOCALAPPDATA SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" 2>&1)
printf '%s' "$W17" | grep -qi 'unbound variable' && no "win_bash: aborts on unset PROGRAMFILES/LOCALAPPDATA" || ok "win_bash: survives unset PROGRAMFILES/LOCALAPPDATA (set -u safe)"
# 2026-08-20: the Windows task now launches through a hidden wscript shim (schtasks runs /TR in
# the interactive session, so pointing it at bash.exe painted a console window every 30 min).
# The resolved bash path therefore appears on the `# launcher:` line rather than inside /TR.
# The ASSERTION IS UNCHANGED IN INTENT — win_bash must still yield a non-empty bash program —
# only its location moved. Accepts either form so SB_DRAIN_VISIBLE_WINDOW=1 also passes.
printf '%s' "$W17" | grep -qE '(# launcher:|/TR) +.*bash' && ok "win_bash: keeps a non-empty bash program token when vars unset" || no "win_bash: empty/broken bash program when vars unset"

# Test 18 (review LOW, intent): the hardened systemd DEFAULT is creds-free by contract — its env-file
# must NOT carry API creds; launchd/windows (no sandbox) and systemd --oauth MUST forward them.
BR18="$SANDBOX/brain18"
SB_INSTALL_OS_OVERRIDE=systemd BRAIN_DIR="$BR18" ANTHROPIC_API_KEY=sk-ant-TESTKEY SB_EXTRACTOR_LOCAL_URL=http://x:1 bash "$INSTALL" --apply >/dev/null 2>&1 || true
grep -q 'ANTHROPIC_API_KEY' "$BR18/.extract-timer-env" 2>/dev/null && no "hardened systemd: leaked API creds into env-file (breaks creds-free contract)" || ok "hardened systemd: env-file omits API creds (creds-free)"
grep -q 'SB_EXTRACTOR_LOCAL_URL' "$BR18/.extract-timer-env" 2>/dev/null && ok "hardened systemd: still forwards the local-engine knob" || no "hardened systemd: dropped the local-engine knob"
BR18W="$SANDBOX/brain18w"
SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR18W" ANTHROPIC_API_KEY=sk-ant-TESTKEY bash "$INSTALL" --apply >/dev/null 2>&1 || true
grep -q 'ANTHROPIC_API_KEY' "$BR18W/.extract-timer-env" 2>/dev/null && ok "windows (no sandbox): forwards the API key" || no "windows: dropped the API key"
BR18O="$SANDBOX/brain18o"
SB_INSTALL_OS_OVERRIDE=systemd BRAIN_DIR="$BR18O" ANTHROPIC_API_KEY=sk-ant-TESTKEY bash "$INSTALL" --apply --oauth >/dev/null 2>&1 || true
grep -q 'ANTHROPIC_API_KEY' "$BR18O/.extract-timer-env" 2>/dev/null && ok "systemd --oauth: forwards the API key (creds explicitly granted)" || no "systemd --oauth: dropped the API key"

# Test 19 (live-install bug): git-bash MSYS-translates schtasks' /flags (/Create -> C:\...\Git\Create) so
# the task is silently never created. The windows calls must run under MSYS_NO_PATHCONV=1, and --apply must
# FAIL LOUD (non-zero + a clear message) when schtasks rejects the task — not print "applied".
grep -qE 'MSYS_NO_PATHCONV=1 schtasks /Create' "$INSTALL" && ok "windows: schtasks /Create runs under MSYS_NO_PATHCONV" || no "windows: schtasks /Create not MSYS_NO_PATHCONV-guarded"
grep -qE 'MSYS_NO_PATHCONV=1 schtasks /Delete' "$INSTALL" && ok "windows: schtasks /Delete runs under MSYS_NO_PATHCONV" || no "windows: schtasks /Delete not MSYS_NO_PATHCONV-guarded"
BR19="$SANDBOX/brain19"; FS="$SANDBOX/failstub"; mkdir -p "$FS"
printf '#!/bin/sh\nexit 1\n' > "$FS/schtasks"; chmod +x "$FS/schtasks"
# --apply exits 1 on the (expected) schtasks failure. Capture it WITHOUT tripping `set -e`: an assignment
# from a failing command-substitution aborts the script on bash 4/5 (the linux CI) but NOT bash 3.2 (macOS)
# — which is exactly why this surfaced as linux-fail / macos-pass. The `if`-condition suspends `set -e`.
if OUT19=$(PATH="$FS:$PATH" SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR19" bash "$INSTALL" --apply 2>&1); then RC19=0; else RC19=$?; fi
{ [ "$RC19" -ne 0 ] && printf '%s' "$OUT19" | grep -qi 'NOT installed'; } \
  && ok "windows: --apply fails loud (rc!=0 + 'NOT installed') when schtasks errors" \
  || no "windows: --apply masked a schtasks failure (rc=$RC19)"
printf '%s' "$OUT19" | grep -qi '^applied' && no "windows: printed 'applied' despite schtasks failing" || ok "windows: did NOT print 'applied' on schtasks failure"

# Test 20 (D105): schtasks' own /Create defaults disallow starting on battery and stop the
# task if power switches to battery mid-run (verified live: `schtasks /Query .../FO LIST /V`
# shows "Power Management: Stop On Battery Mode, No Start On Batteries"). /Change cannot
# alter this after the fact, so --apply does a best-effort export -> patch -> re-import XML
# round trip. A smarter stub (unlike the blanket exit-0 stub above) answers /Query /XML with
# a minimal real task-export shape so the SUCCESS path (not just the graceful-failure path
# every earlier test already exercises via the blanket stub) is actually locked here.
BR20="$SANDBOX/brain20"; SS20="$SANDBOX/smartstub20"; mkdir -p "$SS20" "$BR20"
cat > "$SS20/schtasks" <<'STUBSH'
#!/bin/sh
case " $* " in
  *" /Query "*)
    cat <<'XML'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Settings>
    <DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
  </Settings>
  <Triggers>
    <TimeTrigger><Repetition><Interval>PT30M</Interval></Repetition></TimeTrigger>
  </Triggers>
</Task>
XML
    exit 0 ;;
  *) exit 0 ;;
esac
STUBSH
chmod +x "$SS20/schtasks"
OUT20=$(PATH="$SS20:$PATH" SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR20" bash "$INSTALL" --apply 2>&1)
printf '%s' "$OUT20" | grep -qi 'applied:' || no "D105 setup: --apply did not report success against the smart stub (got: $OUT20)"
printf '%s' "$OUT20" | grep -qi 'Power:.*battery too' \
  && ok "D105: a task whose exported XML shows battery restrictions gets them patched to false (reported)" \
  || no "D105: no confirmation that battery power settings were updated (got: $OUT20)"

# Test 21 (D105): when the export/patch/reimport round trip cannot succeed (e.g. the plain
# blanket exit-0 stub, which answers /Query with no XML at all), --apply must still succeed
# overall (the core task is already installed via the flag-based /Create above) and say so
# rather than silently pretending the power settings were fixed.
BR21="$SANDBOX/brain21"
OUT21=$(SB_INSTALL_OS_OVERRIDE=windows BRAIN_DIR="$BR21" bash "$INSTALL" --apply 2>&1)
printf '%s' "$OUT21" | grep -qi 'applied:' || no "D105: --apply still failed overall when the power-settings step can't run"
printf '%s' "$OUT21" | grep -qi 'Power: could not update' \
  && ok "D105: honestly reports when battery power settings could not be updated (never silently claims success)" \
  || no "D105: no honest fallback message when the power round trip has nothing to work with"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
