import { join } from 'path';
import { runSb } from './sb.js';
import { cleanEnvPath } from '../path-guard.js';

// cleanEnvPath strips CR/LF from every env-derived path (Windows CRLF-tainted env → a
// trailing \r makes fs.stat/readdir ENOENT on a dir that exists). USERPROFILE is the
// Windows HOME fallback.
const home = cleanEnvPath(process.env.HOME ?? process.env.USERPROFILE);
const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(home, '.second-brain');
const knowledgeDir = cleanEnvPath(process.env.KNOWLEDGE_DIR) || cleanEnvPath(process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR) || join(home, 'knowledge');

const result = await runSb(process.argv.slice(2), { brainDir, knowledgeDir });
if (result.stdout) process.stdout.write(result.stdout + '\n');
if (result.stderr) process.stderr.write(result.stderr + '\n');
process.exit(result.exitCode);
