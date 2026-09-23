#!/usr/bin/env node

// src/tools/buddy-identity-cli.ts
import { promises as fs } from "fs";
import { join as join2 } from "path";
import { homedir as homedir2, hostname, userInfo } from "os";

// src/brain-paths.ts
import { join, isAbsolute } from "path";
import { homedir } from "os";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}

// src/brain-paths.ts
function resolveBrainDir(override) {
  if (override) return override;
  return cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
}

// src/buddy-identity.ts
var SALT = "friend-2026-401";
var SPECIES = [
  "duck",
  "goose",
  "blob",
  "cat",
  "dragon",
  "octopus",
  "owl",
  "penguin",
  "turtle",
  "snail",
  "ghost",
  "axolotl",
  "capybara",
  "cactus",
  "robot",
  "rabbit",
  "mushroom",
  "chonk"
];
var RARITIES = ["common", "uncommon", "rare", "epic", "legendary"];
var RARITY_WEIGHTS = { common: 60, uncommon: 25, rare: 10, epic: 4, legendary: 1 };
var RARITY_STARS = {
  common: "\u2605",
  uncommon: "\u2605\u2605",
  rare: "\u2605\u2605\u2605",
  epic: "\u2605\u2605\u2605\u2605",
  legendary: "\u2605\u2605\u2605\u2605\u2605"
};
var EYES = ["\xB7", "\u2726", "\xD7", "\u25C9", "@", "\xB0"];
var HATS = ["none", "crown", "tophat", "propeller", "halo", "wizard", "beanie", "tinyduck"];
var MASK64 = (1n << 64n) - 1n;
var SECRET = [0xa0761d6478bd642fn, 0xe7037ed1a0b428dbn, 0x8ebc6af09c88c6e3n, 0x589965cc75374cc3n];
function mum(a, b) {
  const x = (a & MASK64) * (b & MASK64);
  return [x & MASK64, x >> 64n & MASK64];
}
function mix(a, b) {
  const [lo, hi] = mum(a, b);
  return (lo ^ hi) & MASK64;
}
function r8(b, o) {
  let v = 0n;
  for (let i = 0; i < 8; i++) v |= BigInt(b[o + i]) << BigInt(i * 8);
  return v;
}
function r4(b, o) {
  let v = 0n;
  for (let i = 0; i < 4; i++) v |= BigInt(b[o + i]) << BigInt(i * 8);
  return v;
}
function wyhash64(input, seed = 0n) {
  const buf = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const len = buf.length;
  let s0 = (seed ^ mix((seed ^ SECRET[0]) & MASK64, SECRET[1])) & MASK64;
  let s1 = s0, s2 = s0;
  let a, b;
  if (len <= 16) {
    if (len >= 4) {
      const q = len >> 3 << 2;
      a = (r4(buf, 0) << 32n | r4(buf, q)) & MASK64;
      b = (r4(buf, len - 4) << 32n | r4(buf, len - 4 - q)) & MASK64;
    } else if (len > 0) {
      a = BigInt(buf[0]) << 16n | BigInt(buf[len >> 1]) << 8n | BigInt(buf[len - 1]);
      b = 0n;
    } else {
      a = 0n;
      b = 0n;
    }
  } else {
    let i = 0;
    if (len >= 48) {
      while (i + 48 < len) {
        s0 = mix((r8(buf, i) ^ SECRET[1]) & MASK64, (r8(buf, i + 8) ^ s0) & MASK64);
        s1 = mix((r8(buf, i + 16) ^ SECRET[2]) & MASK64, (r8(buf, i + 24) ^ s1) & MASK64);
        s2 = mix((r8(buf, i + 32) ^ SECRET[3]) & MASK64, (r8(buf, i + 40) ^ s2) & MASK64);
        i += 48;
      }
      s0 = (s0 ^ s1 ^ s2) & MASK64;
    }
    while (i + 16 < len) {
      s0 = mix((r8(buf, i) ^ SECRET[1]) & MASK64, (r8(buf, i + 8) ^ s0) & MASK64);
      i += 16;
    }
    a = r8(buf, len - 16);
    b = r8(buf, len - 8);
  }
  a = (a ^ SECRET[1]) & MASK64;
  b = (b ^ s0) & MASK64;
  [a, b] = mum(a, b);
  return mix((a ^ SECRET[0] ^ BigInt(len)) & MASK64, (b ^ SECRET[1]) & MASK64);
}
function hashString(s) {
  return Number(wyhash64(s) & 0xffffffffn);
}
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = a + 1831565813 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function pick(rng, arr) {
  return arr[Math.floor(rng() * arr.length)];
}
function rollRarity(rng) {
  let roll = rng() * 100;
  for (const r of RARITIES) {
    roll -= RARITY_WEIGHTS[r];
    if (roll < 0) return r;
  }
  return "common";
}
function generateBones(userId, salt = SALT) {
  const rng = mulberry32(hashString(userId + salt));
  const rarity = rollRarity(rng);
  const species = pick(rng, SPECIES);
  const eye = pick(rng, EYES);
  const hat = rarity === "common" ? "none" : pick(rng, HATS);
  const shiny = rng() < 0.01;
  return { rarity, species, eye, hat, shiny };
}
var NAMES = [
  "Pip",
  "Ziutek",
  "Mochi",
  "Bolt",
  "Nimbus",
  "Tofu",
  "Widget",
  "Juniper",
  "Sprocket",
  "Pebble",
  "Fennel",
  "Byte",
  "Clover",
  "Dash",
  "Ember",
  "Fig",
  "Gizmo",
  "Hazel",
  "Ivy",
  "Jinx",
  "Kelp",
  "Lumen",
  "Maple",
  "Nori",
  "Olive",
  "Quill",
  "Rune",
  "Sage",
  "Tinker",
  "Umber",
  "Vesper",
  "Wren",
  "Yarrow",
  "Zephyr",
  "Bramble",
  "Cinder",
  "Dot",
  "Echo",
  "Flint",
  "Glim"
];
function defaultName(userId) {
  const rng = mulberry32(hashString(userId + SALT + ":name"));
  return NAMES[Math.floor(rng() * NAMES.length)];
}
function renderCard(bones, name) {
  return `${name}  \u2014  ${bones.shiny ? "\u2728 " : ""}${bones.rarity} ${bones.species} ${RARITY_STARS[bones.rarity]}` + (bones.hat !== "none" ? `  (hat: ${bones.hat})` : "");
}

// src/tools/buddy-identity-cli.ts
async function resolveSeed(userIdArg) {
  if (userIdArg && userIdArg.trim()) return { seed: userIdArg.trim(), source: "arg" };
  const cfgDir = cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || homedir2();
  for (const f of [join2(cfgDir, ".claude.json"), join2(homedir2(), ".claude.json")]) {
    try {
      const j = JSON.parse(await fs.readFile(f, "utf-8"));
      const id = j?.oauthAccount?.accountUuid;
      if (typeof id === "string" && /^[0-9a-f-]{16,64}$/i.test(id)) return { seed: id, source: "account" };
    } catch {
    }
  }
  let user = "";
  try {
    user = userInfo().username;
  } catch {
  }
  return { seed: `sb:${hostname()}:${user}`, source: "fallback" };
}
function hatch(seed, source) {
  return { ...generateBones(seed), seed_source: source, hatched_at: (/* @__PURE__ */ new Date()).toISOString(), default_name: defaultName(seed), version: 1 };
}
async function writeIdentity(brainDir, identity) {
  const file = join2(brainDir, "buddy.json");
  let cfg = {};
  try {
    const j = JSON.parse(await fs.readFile(file, "utf-8"));
    if (j && typeof j === "object" && !Array.isArray(j)) cfg = j;
  } catch {
  }
  cfg.identity = identity;
  await fs.mkdir(brainDir, { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(cfg, null, 2) + "\n", "utf-8");
  await fs.rename(tmp, file);
  return file;
}
async function readConfig(brainDir) {
  try {
    const j = JSON.parse(await fs.readFile(join2(brainDir, "buddy.json"), "utf-8"));
    if (j && typeof j === "object" && !Array.isArray(j)) return j;
  } catch {
  }
  return {};
}
async function patchConfig(brainDir, patch) {
  const cfg = await readConfig(brainDir);
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete cfg[k];
    else cfg[k] = v;
  }
  await fs.mkdir(brainDir, { recursive: true });
  const file = join2(brainDir, "buddy.json");
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(cfg, null, 2) + "\n", "utf-8");
  await fs.rename(tmp, file);
  return cfg;
}
function buddyName(cfg, identity) {
  if (typeof cfg.name === "string" && cfg.name.trim()) return cfg.name.trim().slice(0, 14);
  return identity?.default_name || "buddy";
}
function settingsPath() {
  const cfgDir = cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || join2(homedir2(), ".claude");
  return join2(cfgDir, "settings.json");
}
var posix = (p) => p.replace(/\\/g, "/");
var shq = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
function shimPath(brainDir) {
  return join2(brainDir, "bin", "buddy-statusline.sh");
}
function statuslineCommand(brainDir, chain) {
  const env = chain ? `SB_BUDDY_CHAIN=${shq(chain)} ` : "";
  return `${env}bash "${posix(shimPath(brainDir))}"`;
}
function shimBody(devRoot) {
  return `#!/bin/bash
# buddy-statusline shim \u2014 generated by \`sb buddy install\` (do not hand-edit). Stable path that
# survives plugin upgrades: resolves the newest installed second-brain version's renderer and
# execs it with this process's stdin (the statusline JSON) and env (SB_BUDDY_CHAIN, COLUMNS).
set -u
_r=""
for _base in ${devRoot ? `"${posix(devRoot)}"` : '""'} "$HOME"/.claude/plugins/cache/*/second-brain; do
  [ -n "$_base" ] && [ -d "$_base" ] || continue
  if [ -f "$_base/scripts/buddy-statusline.sh" ]; then _r="$_base/scripts/buddy-statusline.sh"; break; fi
  for _v in $(ls -1 "$_base" 2>/dev/null | { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }); do
    [ -f "$_base/$_v/scripts/buddy-statusline.sh" ] && _r="$_base/$_v/scripts/buddy-statusline.sh"
  done
  [ -n "$_r" ] && break
done
[ -n "$_r" ] || exit 0
exec bash "$_r"
`;
}
async function installStatusline(brainDir, pluginRoot) {
  const file = settingsPath();
  let settings = {};
  let raw = "";
  try {
    raw = await fs.readFile(file, "utf-8");
  } catch {
  }
  if (raw.trim()) {
    const j = JSON.parse(raw);
    if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error(`${file} is not a JSON object`);
    settings = j;
  }
  const inCache = /[\\/]\.claude[\\/]plugins[\\/]cache[\\/]/.test(pluginRoot);
  const shim = shimPath(brainDir);
  await fs.mkdir(join2(brainDir, "bin"), { recursive: true });
  await fs.writeFile(shim, shimBody(inCache ? null : pluginRoot), { encoding: "utf-8", mode: 493 });
  const prev = settings.statusLine;
  const prevCmd = prev && prev.type === "command" && typeof prev.command === "string" ? prev.command : "";
  const ours = prevCmd.includes("buddy-statusline");
  const cfg = await readConfig(brainDir);
  let chained = ours ? typeof cfg.chain === "string" && cfg.chain ? cfg.chain : null : prevCmd || null;
  const command = statuslineCommand(brainDir, chained);
  if (prevCmd === command) return { settings: file, backup: null, chained, command, shim };
  if (chained && !ours) await patchConfig(brainDir, { chain: chained });
  let backup = null;
  if (raw.trim()) {
    backup = `${file}.bak-${(/* @__PURE__ */ new Date()).toISOString().replace(/[:.]/g, "-")}`;
    await fs.writeFile(backup, raw, "utf-8");
  }
  settings.statusLine = { type: "command", command };
  await fs.mkdir(join2(file, ".."), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(settings, null, 2) + "\n", "utf-8");
  await fs.rename(tmp, file);
  return { settings: file, backup, chained, command, shim };
}
async function uninstallStatusline(brainDir) {
  const file = settingsPath();
  let settings = {};
  let raw = "";
  try {
    raw = await fs.readFile(file, "utf-8");
  } catch {
    return { settings: file, restored: null };
  }
  if (raw.trim()) settings = JSON.parse(raw);
  const cur = settings.statusLine;
  if (!cur || typeof cur.command !== "string" || !cur.command.includes("buddy-statusline")) return { settings: file, restored: null };
  const cfg = await readConfig(brainDir);
  const restored = typeof cfg.chain === "string" && cfg.chain ? cfg.chain : null;
  if (restored) settings.statusLine = { type: "command", command: restored };
  else delete settings.statusLine;
  await patchConfig(brainDir, { chain: null });
  const tmp = `${file}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(settings, null, 2) + "\n", "utf-8");
  await fs.rename(tmp, file);
  try {
    await fs.unlink(shimPath(brainDir));
  } catch {
  }
  return { settings: file, restored };
}
async function readCached(brainDir) {
  try {
    const j = JSON.parse(await fs.readFile(join2(brainDir, "buddy.json"), "utf-8"));
    return j?.identity && typeof j.identity.species === "string" ? j.identity : null;
  } catch {
    return null;
  }
}
async function main(argv) {
  const flag = (n) => argv.includes(n);
  const val = (n) => {
    const i = argv.indexOf(n);
    return i >= 0 ? argv[i + 1] : void 0;
  };
  const brainDir = resolveBrainDir(val("--brain-dir"));
  let identity = flag("--rehatch") ? null : await readCached(brainDir);
  if (!identity) {
    const { seed, source } = await resolveSeed(val("--user-id"));
    identity = hatch(seed, source);
    if (flag("--write") || flag("--rehatch")) await writeIdentity(brainDir, identity);
  }
  if (flag("--card")) {
    const name = buddyName(await readConfig(brainDir), identity);
    process.stdout.write(renderCard(identity, name) + `
  seed: ${identity.seed_source}${identity.seed_source === "fallback" ? " (no Claude login found \u2014 log in and run: sb buddy --rehatch)" : ""}
`);
  } else {
    process.stdout.write(JSON.stringify(identity) + "\n");
  }
  return 0;
}
var invokedDirectly = process.argv[1] && /buddy-identity-cli/.test(process.argv[1]);
if (invokedDirectly) {
  main(process.argv.slice(2)).then((c) => process.exit(c)).catch((e) => {
    process.stderr.write(`buddy-identity: ${e.message}
`);
    process.exit(1);
  });
}
export {
  buddyName,
  hatch,
  installStatusline,
  patchConfig,
  readCached,
  readConfig,
  resolveSeed,
  settingsPath,
  shimBody,
  shimPath,
  statuslineCommand,
  uninstallStatusline,
  writeIdentity
};
