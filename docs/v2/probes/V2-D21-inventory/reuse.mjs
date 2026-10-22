// V2-D21 part 2 score, per run: does the run's new file take the value from the shared module that already exports
// it? Pass: the file imports the name from that module, uses it, and declares no local constant for the value.
// The file, name, module and value come from a private config, so this script holds none of them.
//   node reuse.mjs <config> <run dir>...   (each run dir holds D20's files.json)
import fs from 'node:fs';

const [cfgPath, ...runs] = process.argv.slice(2);
const { target, importFrom, name, local } = JSON.parse(fs.readFileSync(cfgPath, 'utf8')).reuse;
const imported = new RegExp(`import\\s*\\{[^}]*\\b${name}\\b[^}]*\\}\\s*from\\s*['"]${importFrom}['"]`);
let pass = 0;
for (const dir of runs) {
  const files = JSON.parse(fs.readFileSync(`${dir}/files.json`, 'utf8'));
  const key = Object.keys(files).find((p) => new RegExp(target).test(p));
  const text = key ? files[key] ?? '' : '';
  const ok = imported.test(text) && (text.match(new RegExp(`\\b${name}\\b`, 'g')) ?? []).length >= 2 && !new RegExp(local).test(text);
  if (ok) pass++;
  console.log(dir.split(/[\\/]/).slice(-3).join('/'), key ? (ok ? 'reused' : 'duplicate') : 'no target file');
}
console.log(`${pass} of ${runs.length} reused`);
