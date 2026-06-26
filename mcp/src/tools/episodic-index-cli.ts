import { buildEpisodicIndex } from './episodic-search.js';
import { resolveBrainDir } from '../brain-paths.js';

const brainDir = resolveBrainDir();
const result = await buildEpisodicIndex(brainDir);

if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
