#!/bin/bash
# Phase 1 — dependency audit lock (task 8). Pins every audit-flagged transitive to
# its patched floor via mcp/package.json "overrides", so `npm audit --omit=dev` stays
# clean on the next bump. ORACLE: read mcp/package-lock.json DIRECTLY with node (never
# through any plugin reader) and assert each resolved version satisfies its floor via an
# inline semver compare — a real lockfile fact, not a re-assertion of plugin code.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# Node.js on Windows (Git-Bash) cannot use MSYS2 POSIX paths (/c/foo); it needs
# Windows-style paths (C:/foo).  Convert once here so both PKG and LOCK are
# node-compatible.  On POSIX the sed is a no-op.
NODE_ROOT="$(printf '%s' "$ROOT" | sed 's|^/\([a-zA-Z]\)/|\U\1:/|')"
LOCK="$NODE_ROOT/mcp/package-lock.json"
PKG="$NODE_ROOT/mcp/package.json"
command -v node >/dev/null 2>&1 || { echo "SKIP: node absent"; exit 0; }
[ -f "$LOCK" ] || { echo "SKIP: no package-lock.json"; exit 0; }
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# floor list: "<pkg> <minVersion>"  (the patched floors the overrides guarantee)
FLOORS="fast-uri 3.1.2
brace-expansion 5.0.6
hono 4.12.25
ip-address 10.2.0
protobufjs 7.6.3
qs 6.15.2
vite 8.0.16"

echo "=== dependency-audit floors (lockfile oracle) ==="

# overrides block present AND its DECLARED floor is >= the audited floor — a weakened override
# (e.g. dropping qs below its advisory floor) must FAIL even if the lockfile still resolves high.
while read -r pkg floor; do
  [ -n "$pkg" ] || continue
  res=$(node -e '
    const p=require("'"$PKG"'"), want="'"$pkg"'", floor="'"$floor"'";
    const o=(p.overrides||{})[want];
    if(!o){process.stdout.write("missing");process.exit(0);}
    const v=String(o).replace(/^[^0-9]*/,"").replace(/[^0-9.].*$/,"");   // strip >=/~/^ and range tail
    const gte=(a,b)=>{const A=a.split(".").map(Number),B=b.split(".").map(Number);for(let i=0;i<3;i++){if((A[i]||0)>(B[i]||0))return true;if((A[i]||0)<(B[i]||0))return false;}return true;};
    process.stdout.write(gte(v,floor)?"ok":("WEAK:"+o));
  ' 2>/dev/null)
  case "$res" in
    ok)      pass "override floor OK: $pkg >= $floor";;
    missing) fail "override MISSING for $pkg";;
    *)       fail "override for $pkg is BELOW the audited floor $floor: $res";;
  esac
done <<< "$FLOORS"

# every RESOLVED instance in the lockfile satisfies the floor — fail-closed on a sub-floor
# PRERELEASE (1.2.3-rc < 1.2.3, so a prerelease whose numeric part equals the floor is BELOW it).
while read -r pkg floor; do
  [ -n "$pkg" ] || continue
  res=$(node -e '
    const l=require("'"$LOCK"'"), want="'"$pkg"'", floor="'"$floor"'";
    const cmp=(a,b)=>{const A=a.split(".").map(Number),B=b.split(".").map(Number);for(let i=0;i<3;i++){if((A[i]||0)>(B[i]||0))return 1;if((A[i]||0)<(B[i]||0))return -1;}return 0;};
    const sat=(ver)=>{const pre=ver.includes("-"),num=ver.replace(/[^0-9.].*$/,""),c=cmp(num,floor);return c>0||(c===0&&!pre);};
    let bad=[],seen=0;
    for(const[k,v]of Object.entries(l.packages||{})){
      if(k.endsWith("node_modules/"+want)&&v.version){seen++;if(!sat(v.version))bad.push(v.version);}
    }
    process.stdout.write(seen===0?"absent":(bad.length?("BAD:"+bad.join(",")):"ok"));
  ' 2>/dev/null)
  case "$res" in
    ok)     pass "$pkg resolves >= $floor (patched, no sub-floor prerelease)";;
    absent) pass "$pkg not in tree (nothing to patch)";;
    *)      fail "$pkg has a version below the $floor floor: $res";;
  esac
done <<< "$FLOORS"

# no raw `tar` (the onnxruntime hardlink-escape transitive must not appear)
TARN=$(node -e "const l=require('$LOCK');process.stdout.write(String(Object.keys(l.packages||{}).filter(k=>k.endsWith('node_modules/tar')).length))" 2>/dev/null)
[ "${TARN:-0}" = "0" ] && pass "no vulnerable 'tar' in the tree" || fail "unexpected tar transitive ($TARN) — re-check onnxruntime"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
