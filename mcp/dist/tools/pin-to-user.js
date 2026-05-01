import { promises as fs } from 'fs';
import { join } from 'path';
const MAX_LINES = 30;
export async function pinToUser(args) {
    const dir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
    const file = join(dir, 'USER.md');
    const date = new Date().toISOString().slice(0, 10);
    const newLine = `- [${date}] ${args.text.trim()}`;
    let content = '';
    try {
        content = await fs.readFile(file, 'utf-8');
    }
    catch {
        content = '# USER preferences\n\n## Pinned\n';
    }
    const projected = content + (content.endsWith('\n') ? '' : '\n') + newLine + '\n';
    if (projected.split('\n').filter(Boolean).length > MAX_LINES) {
        return { ok: false, line_added: '', reason: `would exceed ${MAX_LINES}-line cap` };
    }
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(file, projected, 'utf-8');
    return { ok: true, line_added: newLine };
}
//# sourceMappingURL=pin-to-user.js.map