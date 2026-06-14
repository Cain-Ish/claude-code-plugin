#!/usr/bin/env bash
# sb_strip_ansi must strip pty ANSI/VT escapes PORTABLY (0.28.2). The control
# bytes are built in bash ($'\xNN', bash 3.2-safe) and matched as LITERAL bytes,
# so it works on BSD/macOS sed too — where the old `\x1b` GNU-hex stripped
# NOTHING and pty escape codes leaked into the extracted wiki content.
#
# ORACLE: feed REAL escape bytes (printf), assert (a) the visible text survives
# and (b) NO ESC/BEL/CR control bytes remain — a byte-level filesystem fact, not
# a re-read of the implementation's claim.
set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
. "$REPO/scripts/lib.sh" >/dev/null 2>&1

IN=$(mktemp); trap 'rm -f "$IN"' EXIT
# CSI color, OSC-BEL title, OSC-ST title (ESC \), ESC single-char (ESC 7), CR.
printf 'a\x1b[31mRED\x1b[0mb\x1b]0;title\x07c\x1b]2;t\x1b\\d\x1b7e\rf' > "$IN"

OUT=$(sb_strip_ansi "$IN")
EXP='aREDbcdef'   # only the escape SEQUENCES are removed; visible text stays
[ "$OUT" = "$EXP" ] || fail "expected [$EXP], got [$OUT]"

# No ESC (0x1b) / BEL (0x07) / CR (0x0d) byte may survive — independent byte check.
if printf '%s' "$OUT" | LC_ALL=C grep -q "[$(printf '\x1b\x07\r')]"; then
  fail "control bytes survived stripping: $(printf '%s' "$OUT" | od -c | head -2)"
fi
echo "PASS: sb_strip_ansi strips CSI/OSC-BEL/OSC-ST/ESC/CR to clean text (portable literal-byte impl)"

# Idempotent: already-clean text is unchanged.
printf 'plain text 123\n' > "$IN"
[ "$(sb_strip_ansi "$IN")" = "plain text 123" ] || fail "altered already-clean text"
echo "PASS: clean text passes through unchanged"

echo "ALL PASS"
