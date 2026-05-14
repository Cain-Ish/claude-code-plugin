import { join } from 'path';
import { runSb } from './sb.js';
const brainDir = process.env.BRAIN_DIR || join(process.env.HOME ?? process.env.USERPROFILE ?? '', '.second-brain');
const knowledgeDir = process.env.KNOWLEDGE_DIR || process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || join(process.env.HOME ?? process.env.USERPROFILE ?? '', 'knowledge');
const result = await runSb(process.argv.slice(2), { brainDir, knowledgeDir });
if (result.stdout)
    process.stdout.write(result.stdout + '\n');
if (result.stderr)
    process.stderr.write(result.stderr + '\n');
process.exit(result.exitCode);
//# sourceMappingURL=sb-entry.js.map