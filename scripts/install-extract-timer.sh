#!/bin/bash
# install-extract-timer.sh — install/print/uninstall the per-OS scheduler that runs
# extract-drain.sh out-of-band: systemd timer (Linux) / launchd LaunchAgent (macOS) /
# Task Scheduler (Windows Git-Bash). OS is auto-detected (override SB_INSTALL_OS_OVERRIDE).
#
#   (no flag)     print the rendered unit + commands; touch nothing.
#   --apply       install + enable the scheduler.
#   --uninstall   disable + remove it.
#   --oauth       (Linux/systemd only) the creds-granting hardened variant. Off Linux
#                 there is no portable sandbox, so the job runs unsandboxed as you and
#                 --oauth is a no-op (printed).
#
# Linger (loginctl enable-linger) is printed for the user to run, never run
# silently — it is a host-state change. macOS has no linger equivalent.
set -u

SDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SDIR/.." && pwd)"
DRAINER="$SDIR/extract-drain.sh"
# Source shared helpers for sb_timer_installed/sb_timer_health (--ensure). Fail-soft: the
# print/apply/uninstall paths never touch lib.sh, and --ensure degrades to a plain --apply if
# the helper is somehow unavailable — so a missing lib is non-fatal here.
# shellcheck source=/dev/null
[ -f "$SDIR/lib.sh" ] && . "$SDIR/lib.sh" 2>/dev/null || true
# Stable SHIM + captured ENV-FILE. The scheduler runs a fixed path ($SHIM) that survives plugin
# upgrades: it sources the engine env we capture here, resolves the LATEST installed plugin
# version's extract-drain.sh under the plugin cache, and execs it (vs a version-pinned path that
# goes stale/GC'd after an upgrade — gap #1). The env-file forwards the engine knobs the minimal
# scheduler env drops (gap #2).
SB_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
SHIM="$SB_DIR/bin/sb-extract-drain.sh"
ENV_FILE="$SB_DIR/.extract-timer-env"
# CACHE_BASE is resolved AFTER the arg parser below (it depends on --dev).
TPL_DIR="$REPO/systemd"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SVC="sb-extract-drain.service"
TIMER="sb-extract-drain.timer"

# Default = hardened local-only unit; --oauth opts into the creds-granting one.
# Action + variant are parsed from anywhere in the args so `--apply --oauth`,
# `--oauth --apply`, and bare `--oauth` (print) all work.
VARIANT_SVC="$SVC"; ACTION=print; DEV_TREE=""
for a in "$@"; do
  case "$a" in
    --oauth)     VARIANT_SVC="sb-extract-drain-oauth.service" ;;
    --apply)     ACTION=apply ;;
    --ensure)    ACTION=ensure ;;
    --uninstall) ACTION=uninstall ;;
    --dev)       DEV_TREE="$REPO" ;;
  esac
done
# --dev pins the scheduler to THIS checkout instead of the installed plugin cache. Without it
# the shim resolves ONLY under ~/.claude/plugins/cache. Before 2026-08-23 CACHE_BASE was
# "$REPO/.." unconditionally and searched FIRST, so an installer run from a dev checkout (which
# is what `--ensure` on every SessionStart did on the dev box) silently pinned the 30-minute
# production job to the working tree: whatever branch a concurrent session left checked out,
# half-edited, a syntax error = every tick failing under a hidden wscript launcher with no log.
# Live on the dev box: the 09:56 tick's cmdline was /c/Workplace/Projects/claude-code-plugin.
# A dev pin is a deliberate, visible choice, never a side effect of where you ran a script.
if [ -n "$DEV_TREE" ]; then
  CACHE_BASE="$(cd "$DEV_TREE/.." 2>/dev/null && pwd)"   # dev: this checkout's parent dir
  echo "install-extract-timer: --dev — scheduler pinned to checkout $DEV_TREE (NOT the plugin cache)" >&2
else
  CACHE_BASE=""                                           # production: plugin cache only
fi

# The knowledge dir the out-of-band drainer must read/write. In-session (where --apply is
# normally run) Claude Code sets CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR for a custom dir; the
# scheduled job has no such injection, so we capture it at install time. Empty ⇒ default.
INSTALL_KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-}}"

# Escape a value for the REPLACEMENT half of a sed s### (the # delimiter + & whole-match). MSYS paths
# carry no backslash, so & and # (a rare home-dir char) are the only hazards.
_sed_repl() { printf '%s' "$1" | sed 's/[&#]/\\&/g'; }

render_service() {
  if [ "$VARIANT_SVC" = "sb-extract-drain-oauth.service" ]; then
    echo "# NOTE: --oauth grants this background service read/write of ~/.claude (your OAuth credentials)." >&2
  fi
  # A custom knowledge dir must be BOTH forwarded (Environment=) and granted in the
  # sandbox (the default unit only grants %h/knowledge) — else the out-of-band extraction
  # AND consolidation operate on the wrong tree / are blocked by ProtectHome.
  if [ -n "$INSTALL_KD" ] && [ "$INSTALL_KD" != "$HOME/knowledge" ]; then
    sed -e "s#@EXEC@#bash $(_sed_repl "$SHIM")#g" \
        -e "s#^ReadWritePaths=.*#&  $INSTALL_KD#" \
        -e "/^Environment=PATH=/a Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=$INSTALL_KD" \
        "$TPL_DIR/$VARIANT_SVC"
  else
    sed "s#@EXEC@#bash $(_sed_repl "$SHIM")#g" "$TPL_DIR/$VARIANT_SVC"
  fi
}

# Render the stable shim. Quoted heredoc (no in-shell expansion) + sed substitution of the two
# install-time placeholders (mirrors render_service's sed pattern; # as the delimiter so paths with
# '/' pass through). The shim sources the captured env, then picks the highest-semver installed
# extract-drain.sh under the plugin cache and execs it.
shim_render() {
  sed -e "s#@CACHE_BASE@#$(_sed_repl "$CACHE_BASE")#g" -e "s#@ENV_FILE@#$(_sed_repl "$ENV_FILE")#g" <<'SHIM_EOF'
#!/bin/bash
# sb-extract-drain shim — generated by install-extract-timer.sh (do not hand-edit). Stable path that
# survives plugin upgrades: sources the captured engine env, resolves the LATEST installed plugin
# version's extract-drain.sh, execs it. Regenerated on each --apply.
set -u
ENV_FILE="@ENV_FILE@"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
_d=""
# "@CACHE_BASE@" is EMPTY for a production install (plugin cache only) and a checkout's parent
# only when the installer ran with --dev. An empty first entry is skipped by the -d test.
for _base in "@CACHE_BASE@" "$HOME"/.claude/plugins/cache/*/second-brain; do
  [ -n "$_base" ] && [ -d "$_base" ] || continue
  for _v in $(ls -1 "$_base" 2>/dev/null | { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }); do
    [ -f "$_base/$_v/scripts/extract-drain.sh" ] && _d="$_base/$_v/scripts/extract-drain.sh"
  done
  [ -n "$_d" ] && break
done
[ -n "$_d" ] || { echo "sb-extract-drain shim: no extract-drain.sh found under the plugin cache" >&2; exit 0; }
exec bash "$_d"
SHIM_EOF
}

# Capture the engine knobs into the env-file the shim sources. printf %q quotes each value so a
# space / shell-metachar in a path or URL survives the `.` source. chmod 600 — it may hold
# ANTHROPIC_API_KEY. Empty vars are skipped (the drainer/lib fall back to defaults).
write_env_file() {
  : > "$ENV_FILE"
  # The hardened systemd DEFAULT is creds-free by contract — never persist API creds into ITS env-file.
  # Everywhere else (launchd/windows have no sandbox; systemd --oauth grants creds explicitly) forward them.
  local _hardened=0
  [ "$OS" = systemd ] && [ "$VARIANT_SVC" != "sb-extract-drain-oauth.service" ] && _hardened=1
  for v in SB_EXTRACTOR_LOCAL_URL SB_EXTRACTOR_LOCAL_MODEL SB_EXTRACTOR_ENGINE ANTHROPIC_BASE_URL ANTHROPIC_API_KEY CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR KNOWLEDGE_DIR SB_DRAIN_BATCH; do
    case "$v" in ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL) [ "$_hardened" = 1 ] && continue ;; esac
    eval "val=\${$v:-}"
    [ -n "$val" ] && printf 'export %s=%q\n' "$v" "$val" >> "$ENV_FILE"
  done
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

write_shim() { mkdir -p "$SB_DIR/bin"; shim_render > "$SHIM"; chmod +x "$SHIM" 2>/dev/null || true; write_env_file; }
remove_shim() { rm -f "$SHIM" "$VBS_SHIM" "$ENV_FILE" 2>/dev/null || true; rmdir "$SB_DIR/bin" 2>/dev/null || true; }

# --- Windows: hidden launcher -------------------------------------------------
# schtasks runs the task in the logged-on user's interactive session, so pointing /TR straight at
# bash.exe paints a Git Bash console on the desktop every single tick — every 30 minutes, forever,
# usually showing nothing more interesting than "deferring (consecutive=N)". Users read that as a
# malfunction, and the honest fix is not to silence the message but to stop stealing focus.
#
# wscript.exe + WshShell.Run(cmd, 0, False) is the only launcher that reliably shows NO window:
# `powershell -WindowStyle Hidden` and `cmd /c start /min` both still flash a console host while
# the process starts. //B //Nologo keeps wscript itself silent (no script-error dialogs, which
# would be worse than the console — a modal box on a timer).
#
# Escaping: VBScript string literals escape a double quote by doubling it (""), and the bash and
# shim paths are Windows-form with backslashes, which VBScript does NOT treat as escapes. The
# heredoc is quoted so bash performs no substitution beyond the two explicit expansions.
# Opt out with SB_DRAIN_VISIBLE_WINDOW=1 (useful when debugging a tick interactively).
VBS_SHIM="$SB_DIR/bin/sb-extract-drain-hidden.vbs"
write_vbs_shim() {   # $1 = windows-form bash.exe, $2 = unix-form shim path
  mkdir -p "$SB_DIR/bin"
  local _bash_w="$1" _shim="$2"
  # A literal double quote in either path would close the VBScript string literal early, and
  # `&` is VBScript concatenation — i.e. a path-controlled code-execution primitive. Windows
  # forbids `"` in usernames so the default HOME cannot carry one, and BRAIN_DIR is local
  # install config today; this guard exists so that stays true if BRAIN_DIR is ever sourced
  # from a less-trusted surface. Fail LOUD rather than write a script we cannot reason about.
  case "$_bash_w$_shim" in
    *'"'*)
      echo "error: refusing to generate the VBS launcher — a double quote in the bash or shim path would break out of the VBScript string literal ($_bash_w | $_shim)" >&2
      return 1 ;;
  esac
  {
    printf "' sb-extract-drain hidden launcher — generated by install-extract-timer.sh (do not hand-edit).\r\n"
    printf "' Runs the drainer with NO console window; regenerated on each --apply.\r\n"
    printf 'Set sh = CreateObject("WScript.Shell")\r\n'
    printf 'sh.Run """%s"" -lc ""exec %s""", 0, False\r\n' "$_bash_w" "$_shim"
  } > "$VBS_SHIM"
}

# WSL-safe git-bash resolution for schtasks /TR — returns a Windows-form path. Probe known git-bash
# locations first (git-bash `[ -f "C:\\..." ]` works); only fall back to `command -v bash` if none
# exist, so we don't accidentally schedule the WSL System32\bash.exe (the WSL-bash shadow bug class).
win_bash() {
  local c
  for c in "${PROGRAMFILES:-}\\Git\\bin\\bash.exe" \
           "C:\\Program Files\\Git\\bin\\bash.exe" \
           "C:\\Program Files (x86)\\Git\\bin\\bash.exe" \
           "${LOCALAPPDATA:-}\\Programs\\Git\\bin\\bash.exe"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  cygpath -w "$(command -v bash 2>/dev/null)" 2>/dev/null || echo "bash.exe"
}

# --- OS detection (overridable for tests via SB_INSTALL_OS_OVERRIDE) ----------
OS="${SB_INSTALL_OS_OVERRIDE:-}"
if [ -z "$OS" ]; then
  case "$(uname -s)" in
    Linux)               OS=systemd ;;
    Darwin)              OS=launchd ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)                   OS=unsupported ;;
  esac
fi

# --ensure: the idempotent install-if-needed entrypoint for autonomous setup + session-load
# self-heal. If the scheduler is already registered, no-op; otherwise fall through to the
# normal per-OS --apply body. The command -v guard keeps it safe if lib.sh failed to source
# (degrade to a plain re-apply, which is itself harmless/idempotent).
if [ "$ACTION" = ensure ]; then
  if command -v sb_timer_installed >/dev/null 2>&1 && sb_timer_installed "$OS"; then
    echo "already installed: out-of-band drainer scheduler present ($OS)."
    exit 0
  fi
  ACTION=apply
fi

# Scheduled jobs (launchd / Task Scheduler) get a MINIMAL env — snapshot the engine
# knobs the user set in their shell so the out-of-band job actually sees them.
env_snapshot() {
  local v val
  # Include the knowledge dir (+ BRAIN_DIR) so the out-of-band consolidation/extraction
  # target the user's actual wiki, not the default ~/knowledge (launchd/windows have no
  # sandbox, so forwarding the var is sufficient there).
  for v in SB_EXTRACTOR_LOCAL_URL SB_EXTRACTOR_LOCAL_MODEL SB_EXTRACTOR_ENGINE ANTHROPIC_BASE_URL ANTHROPIC_API_KEY CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR KNOWLEDGE_DIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && printf '%s=%s\n' "$v" "$val"
  done
}

LA_LABEL="sb-extract-drain"
LA_PLIST="$HOME/Library/LaunchAgents/$LA_LABEL.plist"
# XML-escape a value going into a plist <string> (a `&` in e.g. ANTHROPIC_BASE_URL's
# query string, or `<`/`>` in a path, would otherwise make the plist invalid XML).
xml_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
la_render() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict>\n'
  printf '  <key>Label</key><string>%s</string>\n' "$LA_LABEL"
  printf '  <key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array>\n' "$(xml_esc "$SHIM")"
  printf '  <key>StartInterval</key><integer>1800</integer>\n'
  printf '  <key>RunAtLoad</key><true/>\n'
  printf '  <key>EnvironmentVariables</key><dict>\n'
  printf '    <key>HOME</key><string>%s</string>\n' "$(xml_esc "$HOME")"
  printf '    <key>PATH</key><string>%s</string>\n' "$(xml_esc "${PATH:-/usr/local/bin:/usr/bin:/bin}")"
  env_snapshot | while IFS='=' read -r _k _v; do printf '    <key>%s</key><string>%s</string>\n' "$_k" "$(xml_esc "$_v")"; done
  printf '  </dict>\n</dict></plist>\n'
}
la_note() {
  echo "# macOS: a LaunchAgent runs ONLY while you are logged in (no per-user linger equivalent);"
  echo "#        RunAtLoad gives a catch-up drain at next login."
  echo "# No sandbox off Linux — the job runs unsandboxed as you (so --oauth is a no-op here:"
  echo "#        the job can read ~/.claude regardless)."
}

# Non-Linux schedulers run as a branch before the systemd path (which is unchanged).
if [ "$OS" != "systemd" ]; then
  case "$OS" in
    launchd)
      case "$ACTION" in
        apply)
          write_shim
          mkdir -p "$HOME/Library/LaunchAgents"; la_render > "$LA_PLIST"
          launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$LA_PLIST" 2>/dev/null || launchctl load -w "$LA_PLIST"
          echo "applied: launchd agent $LA_LABEL installed."; la_note ;;
        uninstall)
          launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || launchctl unload -w "$LA_PLIST" 2>/dev/null || true
          rm -f "$LA_PLIST"; remove_shim; echo "uninstalled: removed $LA_LABEL" ;;
        *)
          echo "# === launchd LaunchAgent (would be written to $LA_PLIST) ==="
          la_render; echo
          echo "# To install:  bash $0 --apply    |    To remove:  bash $0 --uninstall"
          la_note ;;
      esac ;;
    windows)
      WIN_TASK="sb-extract-drain"
      BASH_W=$(win_bash)
      # Default: launch through the hidden wscript shim so the tick paints no console window.
      # SB_DRAIN_VISIBLE_WINDOW=1 keeps the old direct-bash form for interactive debugging.
      if [ "${SB_DRAIN_VISIBLE_WINDOW:-0}" = "1" ]; then
        WIN_TR="\"$BASH_W\" -lc 'exec \"$SHIM\"'"
      else
        # cygpath is required, not optional: schtasks does NOT validate /TR, so a unix-form path
        # would create the task happily, print "applied", and then silently never run at tick
        # time — a scheduler that reports success and does nothing is the exact failure this
        # repo's fail-loud rule exists to prevent.
        # …but ONLY on a real Windows host. The windows branch is also reached under
        # SB_INSTALL_OS_OVERRIDE=windows, which is how Linux/macOS CI exercises this code — and
        # there cygpath does not exist (nor does schtasks, so nothing could run anyway). Failing
        # hard on the simulated path broke CI on the merge of #87 while passing locally on
        # Windows: the author-verified-on-Windows / CI-runs-elsewhere blind spot. Gate the
        # fail-loud on the ACTUAL platform, so real installs stay protected and the simulation
        # keeps working.
        VBS_W=$(cygpath -w "$VBS_SHIM" 2>/dev/null) || VBS_W=""
        if [ -z "$VBS_W" ]; then
          case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*)
              echo "error: cygpath unavailable — cannot convert $VBS_SHIM to a Windows path for schtasks /TR; the task would be created but never run. Install Git-for-Windows/MSYS cygpath, or use SB_DRAIN_VISIBLE_WINDOW=1." >&2
              exit 1 ;;
            *)
              VBS_W="$VBS_SHIM" ;;   # simulated windows on a non-Windows host: keep the path inspectable
          esac
        fi
        WIN_TR="wscript.exe //B //Nologo \"$VBS_W\""
      fi
      case "$ACTION" in
        apply)
          write_shim
          [ "${SB_DRAIN_VISIBLE_WINDOW:-0}" = "1" ] || write_vbs_shim "$BASH_W" "$SHIM"
          # MSYS_NO_PATHCONV=1: git-bash otherwise rewrites schtasks' /Create /TN /SC /F flags as POSIX
          # paths (/Create -> C:\Program Files\Git\Create), so the task is never created. Fail LOUD if
          # schtasks rejects it — never print "applied" on a silent failure (it leaves no scheduler).
          if MSYS_NO_PATHCONV=1 schtasks /Create /TN "$WIN_TASK" /SC MINUTE /MO 30 /F /TR "$WIN_TR"; then
            echo "applied: Scheduled Task $WIN_TASK (every 30 min)."
            if [ "${SB_DRAIN_VISIBLE_WINDOW:-0}" = "1" ]; then
              echo "# Launching bash directly — a console window WILL appear on every tick (SB_DRAIN_VISIBLE_WINDOW=1)."
            else
              echo "# Launched via wscript so no console window appears; unset with SB_DRAIN_VISIBLE_WINDOW=1."
            fi
            echo "# No sandbox on Windows — the task runs unsandboxed as you (--oauth no-op)."
            # D105: schtasks' /Create has NO flag for power-management settings, and — unlike
            # /RU//RP//TR — `schtasks /Change` cannot alter them either (its documented
            # parameters are /TR /RU /RP /ST /RI /ET /DU /K /ENABLE /DISABLE /Z only). The
            # task's own defaults are "No Start On Batteries" + "Stop On Battery Mode" (verified
            # live via `schtasks /Query ... /FO LIST /V`), so a laptop on battery silently never
            # runs the drainer — no error, no banner, just growing backlog. The ONLY route that
            # works is a full task-XML round trip: export the task we just created (preserves
            # its trigger/action verbatim), flip the two power booleans, re-import over itself.
            # Best-effort: the task above is ALREADY installed and working even if this fails.
            PWR_XML=$(mktemp 2>/dev/null) && PWR_XML_PATCHED=$(mktemp 2>/dev/null)
            if [ -n "${PWR_XML:-}" ] && [ -n "${PWR_XML_PATCHED:-}" ] \
               && MSYS_NO_PATHCONV=1 schtasks /Query /TN "$WIN_TASK" /XML > "$PWR_XML" 2>/dev/null \
               && sed -e 's#<DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>#<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>#' \
                      -e 's#<StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>#<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>#' \
                      "$PWR_XML" > "$PWR_XML_PATCHED" \
               && [ -s "$PWR_XML_PATCHED" ]; then
              # schtasks wants a Windows-form path; without cygpath (the suite's stubbed
              # schtasks on Linux CI) the POSIX path is the only form there is.
              if command -v cygpath >/dev/null 2>&1; then
                PWR_XML_W=$(cygpath -w "$PWR_XML_PATCHED" 2>/dev/null) || PWR_XML_W=""
              else
                PWR_XML_W="$PWR_XML_PATCHED"
              fi
              if [ -n "$PWR_XML_W" ] && MSYS_NO_PATHCONV=1 schtasks /Create /TN "$WIN_TASK" /XML "$PWR_XML_W" /F >/dev/null 2>&1; then
                echo "# Power: set to run on battery too (DisallowStartIfOnBatteries/StopIfGoingOnBatteries -> false)."
              else
                echo "# Power: could not update battery settings — task still runs, but Task Scheduler defaults may skip it on battery (see docs/audits D105)." >&2
              fi
            else
              echo "# Power: could not update battery settings — task still runs, but Task Scheduler defaults may skip it on battery (see docs/audits D105)." >&2
            fi
            rm -f "$PWR_XML" "$PWR_XML_PATCHED" 2>/dev/null
          else
            echo "error: schtasks /Create failed — Scheduled Task $WIN_TASK was NOT installed." >&2
            remove_shim; exit 1
          fi ;;
        uninstall)
          MSYS_NO_PATHCONV=1 schtasks /Delete /TN "$WIN_TASK" /F 2>/dev/null || true
          remove_shim
          echo "uninstalled: removed task $WIN_TASK" ;;
        *)
          echo "# === Windows Scheduled Task ($WIN_TASK) ==="
          echo "MSYS_NO_PATHCONV=1 schtasks /Create /TN $WIN_TASK /SC MINUTE /MO 30 /F /TR $WIN_TR"
          # Show the FULL launcher chain. With the hidden launcher the resolved bash path lives
          # inside the .vbs rather than in /TR, and a dry-run that hides it would conceal exactly
          # the thing worth checking here: that this is git-bash's bash.exe and not WSL's
          # System32\bash.exe (the WSL-shadow bug class win_bash exists to prevent).
          echo "# launcher: wscript -> \"$BASH_W\" -lc \"exec $SHIM\""
          echo "# To install:  bash $0 --apply    |    To remove:  bash $0 --uninstall"
          echo "# No sandbox on Windows — the task runs unsandboxed as you."
          echo "# D105: --apply also does a best-effort XML round trip afterward to flip schtasks'"
          echo "# battery-power defaults (No Start On Batteries / Stop On Battery Mode) to false —"
          echo "# /Create has no flag for this and /Change cannot alter it after the fact." ;;
      esac ;;
    *)
      echo "# Unsupported OS ($(uname -s)) — no out-of-band drainer scheduler available."
      echo "# Frictionless fallback (any OS): export ANTHROPIC_API_KEY=sk-ant-... for in-session capture,"
      echo "# or run '$DRAINER' yourself from cron / a scheduler." ;;
  esac
  exit 0
fi

case "$ACTION" in
  uninstall)
    systemctl --user disable --now "$TIMER" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SVC" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload 2>/dev/null || true
    remove_shim
    echo "uninstalled: removed $SVC + $TIMER"
    ;;
  apply)
    write_shim
    mkdir -p "$UNIT_DIR"
    render_service > "$UNIT_DIR/$SVC"
    cp "$TPL_DIR/$TIMER" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER"
    echo "applied: $SVC + $TIMER installed and timer enabled."
    echo "Run this yourself to keep the timer alive without an active login:"
    echo "    loginctl enable-linger \"$USER\""
    ;;
  *)
    echo "# === $SVC (would be written to $UNIT_DIR) ==="
    render_service
    echo
    echo "# === $TIMER ==="
    cat "$TPL_DIR/$TIMER"
    echo
    echo "# To install:   bash $0 --apply"
    echo "# Then run:     loginctl enable-linger \"${USER:-$(id -un 2>/dev/null || echo "\$USER")}\""
    echo "# To remove:    bash $0 --uninstall"
    ;;
esac
