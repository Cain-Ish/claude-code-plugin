#!/usr/bin/env node
// set-autonomy.mjs — the ONLY writer of the autonomy consent tiers in
// ~/.second-brain/config.json. Invoked by /second-brain:setup's consent step
// (under its existing `Bash(node *)` grant — no new permission surface) after
// the operator has EXPLICITLY chosen their tiers. Pure node, zero deps.
//
// Why a writer at all: before 0.28.0 the consent ladder was display-only and
// the operator hand-edited config.json. The autonomy code (auto_improve /
// auto_maintain / auto_accept) shipped but stayed dormant because nothing wrote
// the keys. This makes the opt-in a one-time setup choice instead of a JSON
// edit — WITHOUT ever flipping a default behind the operator's back (setup only
// runs on explicit /setup invocation, and this writes only what was passed).
//
// CONTRACT with the bash readers (scripts/lib.sh sb_config_get / sb_config_bool):
//   - path resolves identically: ${BRAIN_DIR:-$HOME/.second-brain}/config.json
//   - auto_improve / auto_maintain are JSON BOOLEANS (literal true/false). We
//     always emit real booleans so the on-disk config is well-typed (`jq
//     '.k|type' == boolean`). Note: sb_config_bool reads `jq -r`, which strips
//     quotes, so a stringly-typed "true" would still read as on — the type
//     correctness is for the file's integrity and any type-sensitive reader, not
//     a behavioural fix to sb_config_bool itself.
//   - auto_accept is the STRING enum "off" | "safe" | "all".
//   - merge is per-key assignment: every other key (retention.*, etc.) is
//     preserved untouched. We never replace the object wholesale.
//
// Fail-closed posture (operator threat model is supply-chain/credentials P0):
//   - refuse inside a nested plugin-spawned session (SB_NESTED_SPAWN=1) — a
//     headless child must never be able to escalate autonomy.
//   - refuse (write nothing) if the existing config.json is unparseable, rather
//     than clobber a file that may hold user data.
//   - strict value validation; any invalid value is a non-zero exit with no write.
//
// Usage:
//   node set-autonomy.mjs [--auto-improve true|false] \
//                         [--auto-maintain true|false] \
//                         [--auto-accept off|safe|all]
// Only the flags passed are changed (so a single tier can be revised idempotently
// without disturbing the others). Prints the resulting tiers to stdout on success.

import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

function die(msg, code = 1) {
  process.stderr.write(`set-autonomy: ${msg}\n`);
  process.exit(code);
}

// Defense-in-depth: a nested headless session (dream-runner, the LLM maintainer)
// must never enable autonomy. The capture/context hooks no-op under this flag;
// here we fail CLOSED so the escalation simply cannot happen.
if (process.env.SB_NESTED_SPAWN === '1') {
  die('refusing to write autonomy config inside a nested plugin spawn (SB_NESTED_SPAWN=1)', 3);
}

const BOOL = { 'true': true, 'false': false };
const ACCEPT = new Set(['off', 'safe', 'all']);

// --- parse args: only explicitly-passed tiers are touched --------------------
const updates = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const flag = argv[i];
  const val = argv[i + 1];
  switch (flag) {
    case '--auto-improve':
    case '--auto-maintain': {
      if (!(val in BOOL)) die(`${flag} expects true|false, got ${val === undefined ? '(missing)' : val}`);
      updates[flag === '--auto-improve' ? 'auto_improve' : 'auto_maintain'] = BOOL[val];
      i++;
      break;
    }
    case '--auto-accept': {
      if (!ACCEPT.has(val)) die(`--auto-accept expects off|safe|all, got ${val === undefined ? '(missing)' : val}`);
      updates.auto_accept = val;
      i++;
      break;
    }
    default:
      die(`unknown argument: ${flag}`);
  }
}
if (Object.keys(updates).length === 0) {
  die('nothing to do — pass at least one of --auto-improve / --auto-maintain / --auto-accept', 2);
}

// --- resolve the config path exactly like the bash readers do ----------------
const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
const cfgPath = join(brainDir, 'config.json');

// --- load existing config (or {}); refuse to clobber a corrupt file ----------
let cfg = {};
try {
  cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));
  if (cfg === null || typeof cfg !== 'object' || Array.isArray(cfg)) {
    die(`existing ${cfgPath} is not a JSON object — refusing to overwrite`);
  }
} catch (e) {
  if (e && e.code === 'ENOENT') {
    cfg = {};   // absent is fine — ensure-dirs seeds lazily; readers default missing keys
  } else {
    die(`existing ${cfgPath} is not valid JSON (${e.message}) — refusing to overwrite`);
  }
}

// --- per-key merge: preserve every other key (retention.*, etc.) -------------
for (const [k, v] of Object.entries(updates)) cfg[k] = v;

// --- atomic write: tmp in the SAME dir → rename is a true atomic swap --------
try {
  mkdirSync(brainDir, { recursive: true });
  const tmp = join(brainDir, `.config.json.tmp.${process.pid}`);
  writeFileSync(tmp, JSON.stringify(cfg, null, 2) + '\n');
  renameSync(tmp, cfgPath);
} catch (e) {
  die(`failed to write ${cfgPath}: ${e.message}`);
}

// --- report the resulting tiers (setup echoes this back to the operator) -----
process.stdout.write(
  `autonomy written to ${cfgPath}\n` +
  `  auto_improve : ${cfg.auto_improve === true}\n` +
  `  auto_maintain: ${cfg.auto_maintain === true}\n` +
  `  auto_accept  : ${typeof cfg.auto_accept === 'string' ? cfg.auto_accept : 'off'}\n`
);
