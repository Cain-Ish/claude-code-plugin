#!/bin/bash
# Phase 1 — dependency audit lock (task 8). Pins every audit-flagged transitive to
# its patched floor via mcp/package.json "overrides", so `npm audit --omit=dev` stays
# clean on the next bump. ORACLE: read mcp/package-lock.json DIRECTLY with node (never
# through any plugin reader) and assert each resolved version satisfies its floor via an
# inline semver compare — a real lockfile fact, not a re-assertion of plugin code.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
LOCK="$ROOT/mcp/package-lock.json"
PKG="$ROOT/mcp/package.json"
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

# overrides block present with each key
while read -r pkg floor; do
  [ -n "$pkg" ] || continue
  has=$(node -e "const p=require('$PKG');process.stdout.write(String(!!(p.overrides&&p.overrides['$pkg'])))" 2>/dev/null)
  [ "$has" = "true" ] && pass "override declared: $pkg" || fail "override MISSING for $pkg"
done <<< "$FLOORS"

# every RESOLVED instance in the lockfile satisfies the floor (inline semver gte)
while read -r pkg floor; do
  [ -n "$pkg" ] || continue
  res=$(node -e '
    const l=require("'"$LOCK"'");
    const want="'"$pkg"'";
    const gte=(a,b)=>{const A=a.split(".").map(Number),B=b.split(".").map(Number);for(let i=0;i<3;i++){if((A[i]||0)>(B[i]||0))return true;if((A[i]||0)<(B[i]||0))return false;}return true;};
    let bad=[],seen=0;
    for(const[k,v]of Object.entries(l.packages||{})){
      if(k.endsWith("node_modules/"+want)&&v.version){seen++;if(!gte(v.version.replace(/[^0-9.].*$/,""),"'"$floor"'"))bad.push(v.version);}
    }
    process.stdout.write(seen===0?"absent":(bad.length?("BAD:"+bad.join(",")):"ok"));
  ' 2>/dev/null)
  case "$res" in
    ok)     pass "$pkg resolves >= $floor (patched)";;
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
