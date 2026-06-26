import { runSb } from './sb.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';

// Canonical cross-OS resolvers (os.homedir() + CR/LF stripping) — see brain-paths.ts.
const brainDir = resolveBrainDir();
const knowledgeDir = resolveKnowledgeDir();

const result = await runSb(process.argv.slice(2), { brainDir, knowledgeDir });
if (result.stdout) process.stdout.write(result.stdout + '\n');
if (result.stderr) process.stderr.write(result.stderr + '\n');
process.exit(result.exitCode);
