import { buildEpisodicIndex } from './episodic-search.js';
import { join } from 'path';

const brainDir = process.env.BRAIN_DIR || join(process.env.HOME ?? '', '.second-brain');
const result = await buildEpisodicIndex(brainDir);

if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
