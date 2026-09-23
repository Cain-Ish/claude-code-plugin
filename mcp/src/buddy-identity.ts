/**
 * buddy-identity — deterministic companion "bones" from an account id.
 *
 * Reproduces the roll Claude Code's native `/buddy` (v2.1.89–v2.1.96) used, so a user who had a
 * buddy gets the same one back: `accountUuid + SALT` → wyhash (Bun.hash, Zig std wyhash v4.2,
 * seed 0) → low 32 bits → mulberry32 → rolls in strict order: rarity, species, eye, hat, shiny.
 * The native roll continued with five "stats"; this plugin stops at shiny — the buddy here is a
 * visible layer between Claude and the knowledge base, not a pet with a stat sheet, and the
 * earlier rolls are unaffected by dropping the later ones. Species list is the ORIGINAL 18 in
 * the original order — `pick()` divides by list length, so appending a species would silently
 * change every roll after it. Ported from the MIT-licensed ramarivera/coding-buddy engine.
 *
 * Pure: no I/O. `resolveSeed()` in buddy-identity-cli.ts decides where the id comes from.
 * Design: docs/plans/2026-09-22-buddy-companion.md §4.
 */

export const SALT = 'friend-2026-401';

export const SPECIES = [
  'duck', 'goose', 'blob', 'cat', 'dragon', 'octopus', 'owl', 'penguin', 'turtle', 'snail',
  'ghost', 'axolotl', 'capybara', 'cactus', 'robot', 'rabbit', 'mushroom', 'chonk',
] as const;
export type Species = (typeof SPECIES)[number];

export const RARITIES = ['common', 'uncommon', 'rare', 'epic', 'legendary'] as const;
export type Rarity = (typeof RARITIES)[number];
export const RARITY_WEIGHTS: Record<Rarity, number> = { common: 60, uncommon: 25, rare: 10, epic: 4, legendary: 1 };
export const RARITY_STARS: Record<Rarity, string> = {
  common: '★', uncommon: '★★', rare: '★★★', epic: '★★★★', legendary: '★★★★★',
};

export const EYES = ['·', '✦', '×', '◉', '@', '°'] as const;
export type Eye = (typeof EYES)[number];

export const HATS = ['none', 'crown', 'tophat', 'propeller', 'halo', 'wizard', 'beanie', 'tinyduck'] as const;
export type Hat = (typeof HATS)[number];

export interface BuddyBones {
  rarity: Rarity;
  species: Species;
  eye: Eye;
  hat: Hat;
  shiny: boolean;
}

// ─── wyhash (Zig std v4.2 == Bun.hash), pure BigInt ────────────────────────────────────────
const MASK64 = (1n << 64n) - 1n;
const SECRET: readonly bigint[] = [0xa0761d6478bd642fn, 0xe7037ed1a0b428dbn, 0x8ebc6af09c88c6e3n, 0x589965cc75374cc3n];

function mum(a: bigint, b: bigint): [bigint, bigint] {
  const x = (a & MASK64) * (b & MASK64);
  return [x & MASK64, (x >> 64n) & MASK64];
}
function mix(a: bigint, b: bigint): bigint { const [lo, hi] = mum(a, b); return (lo ^ hi) & MASK64; }
function r8(b: Uint8Array, o: number): bigint { let v = 0n; for (let i = 0; i < 8; i++) v |= BigInt(b[o + i]) << BigInt(i * 8); return v; }
function r4(b: Uint8Array, o: number): bigint { let v = 0n; for (let i = 0; i < 4; i++) v |= BigInt(b[o + i]) << BigInt(i * 8); return v; }

export function wyhash64(input: string | Uint8Array, seed = 0n): bigint {
  const buf = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  const len = buf.length;
  let s0 = (seed ^ mix((seed ^ SECRET[0]) & MASK64, SECRET[1])) & MASK64;
  let s1 = s0, s2 = s0;
  let a: bigint, b: bigint;
  if (len <= 16) {
    if (len >= 4) {
      const q = (len >> 3) << 2;
      a = ((r4(buf, 0) << 32n) | r4(buf, q)) & MASK64;
      b = ((r4(buf, len - 4) << 32n) | r4(buf, len - 4 - q)) & MASK64;
    } else if (len > 0) {
      a = (BigInt(buf[0]) << 16n) | (BigInt(buf[len >> 1]) << 8n) | BigInt(buf[len - 1]);
      b = 0n;
    } else { a = 0n; b = 0n; }
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

/** Low 32 bits of wyhash — what Claude Code seeds the PRNG with. */
export function hashString(s: string): number { return Number(wyhash64(s) & 0xffffffffn); }

// ─── mulberry32 ─────────────────────────────────────────────────────────────────────────────
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ─── the roll ───────────────────────────────────────────────────────────────────────────────
function pick<T>(rng: () => number, arr: readonly T[]): T { return arr[Math.floor(rng() * arr.length)]; }

function rollRarity(rng: () => number): Rarity {
  let roll = rng() * 100;
  for (const r of RARITIES) { roll -= RARITY_WEIGHTS[r]; if (roll < 0) return r; }
  return 'common';
}

export function generateBones(userId: string, salt: string = SALT): BuddyBones {
  const rng = mulberry32(hashString(userId + salt));
  const rarity = rollRarity(rng);
  const species = pick(rng, SPECIES);
  const eye = pick(rng, EYES);
  const hat: Hat = rarity === 'common' ? 'none' : pick(rng, HATS);
  const shiny = rng() < 0.01;
  return { rarity, species, eye, hat, shiny };
}

// ─── default name ───────────────────────────────────────────────────────────────────────────
// The native buddy asked the model for a name at hatch; this plugin spends no tokens on cosmetics,
// so the default name is one more deterministic pick — its own salt keeps the bones roll intact.
// The user renames with `sb buddy name <x>`; a stored name always wins over this.
export const NAMES = [
  'Pip', 'Ziutek', 'Mochi', 'Bolt', 'Nimbus', 'Tofu', 'Widget', 'Juniper', 'Sprocket', 'Pebble',
  'Fennel', 'Byte', 'Clover', 'Dash', 'Ember', 'Fig', 'Gizmo', 'Hazel', 'Ivy', 'Jinx',
  'Kelp', 'Lumen', 'Maple', 'Nori', 'Olive', 'Quill', 'Rune', 'Sage', 'Tinker', 'Umber',
  'Vesper', 'Wren', 'Yarrow', 'Zephyr', 'Bramble', 'Cinder', 'Dot', 'Echo', 'Flint', 'Glim',
] as const;
export function defaultName(userId: string): string {
  const rng = mulberry32(hashString(userId + SALT + ':name'));
  return NAMES[Math.floor(rng() * NAMES.length)];
}

/** The one-line identity `sb buddy` prints; no I/O. */
export function renderCard(bones: BuddyBones, name: string): string {
  return `${name}  —  ${bones.shiny ? '✨ ' : ''}${bones.rarity} ${bones.species} ${RARITY_STARS[bones.rarity]}` +
    (bones.hat !== 'none' ? `  (hat: ${bones.hat})` : '');
}
