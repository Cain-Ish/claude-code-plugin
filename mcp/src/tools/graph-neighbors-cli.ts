// CLI bridge so session-load.sh can fetch a slug's current dependency
// neighbourhood without a node import dance. Prints one line per edge:
//   <type>\t<from>\t<to>\t<hops>
// Usage: KNOWLEDGE_DIR=... node graph-neighbors-cli.bundle.js <slug> [depth] [direction]
import { knowledgeNeighbors } from './knowledge-neighbors.js';

const slug = process.argv[2] || '';
if (!slug) process.exit(0);
const depth = parseInt(process.argv[3] || '1', 10);
const direction = (process.argv[4] as 'out' | 'in' | 'both') || 'both';
const knowledgeDir = process.env.KNOWLEDGE_DIR;
if (!knowledgeDir) process.exit(0);

const r = await knowledgeNeighbors({ slug, depth, direction, knowledgeDir });
for (const e of r.edges) {
  console.log(`${e.type}\t${e.from}\t${e.to}\t${e.hops}`);
}
