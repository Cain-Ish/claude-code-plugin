// CLI bridge so merge-project-update.sh (bash, capture-time) can render an authored ai-block
// deterministically without a node import dance. Reads JSON {type, block} on stdin, prints
// the marked region to stdout (nothing when no schema field has a value). Fail-safe: invalid
// input → emit nothing, exit 0.
//   echo '{"type":"learnings","block":{"claim":"c","action":"a"}}' | node ai-block-render-cli.bundle.js
import { renderAiBlock } from './ai-block.js';
let input = '';
process.stdin.setEncoding('utf-8');
for await (const chunk of process.stdin)
    input += chunk;
try {
    const { type, block } = JSON.parse(input || '{}');
    if (type && block && typeof block === 'object') {
        const out = renderAiBlock(String(type), block);
        if (out)
            process.stdout.write(out + '\n');
    }
}
catch { /* invalid input → emit nothing */ }
//# sourceMappingURL=ai-block-render-cli.js.map