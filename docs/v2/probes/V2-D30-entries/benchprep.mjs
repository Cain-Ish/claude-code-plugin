// 06, section 3, S6, check 3: the nudge's worst case for the bench. Two known transcript folders with 150 synthetic
// transcripts each, none read by a dream, so every session start counts 300 and stats 50.
//   node benchprep.mjs <repo> <plugin dir with S6> <data dir> <transcripts dir>
// Then: BENCH_DATA=<data dir> BENCH_TRANSCRIPTS=<transcripts dir>/a node plugin/test/bench.mjs <repo> 200
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [repo, plugin, data, tdir] = process.argv.slice(2).map((p) => path.resolve(p));
const { repoKey } = await import(pathToFileURL(path.join(plugin, 'scripts', 'map.mjs')).href);
const dirs = ['a', 'b'].map((x) => path.join(tdir, x));
for (const d of dirs) {
  fs.rmSync(d, { recursive: true, force: true });
  fs.mkdirSync(d, { recursive: true });
  for (let k = 0; k < 150; k++) fs.writeFileSync(path.join(d, `${String(k).padStart(8, '0')}-0000-4000-8000-000000000000.jsonl`), '{"type":"user"}\n');
}
const sd = path.join(data, 'repos', repoKey(repo));
fs.mkdirSync(sd, { recursive: true });
fs.writeFileSync(path.join(sd, 'dirs.log'), `${dirs.join('\n')}\n`);
fs.writeFileSync(path.join(sd, 'state.json'), JSON.stringify({ seen: {}, lastDream: new Date(Date.now() - 864e5).toISOString() }));
console.log(`300 transcripts in ${dirs.length} known folders; state at ${sd}`);
