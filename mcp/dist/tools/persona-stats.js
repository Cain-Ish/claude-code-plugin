import { promises as fs } from 'fs';
import { join } from 'path';
const DEFAULT_BUDGET = Number(process.env.SB_PERSONA_DAILY_BUDGET ?? '20');
export async function personaStats(args = {}) {
    const dir = args.brainDir ?? join(process.env.HOME ?? process.env.USERPROFILE ?? '', '.second-brain');
    let identity = '';
    let cardBytes = 0;
    try {
        const card = await fs.readFile(join(dir, 'persona-card.md'), 'utf-8');
        cardBytes = Buffer.byteLength(card, 'utf-8');
        identity = card.split('\n').filter(l => l.startsWith('- ')).slice(0, 3).map(l => l.slice(2).trim()).join('; ');
    }
    catch { }
    let ungraduated = 0;
    let graduated = 0;
    try {
        const psl = await fs.readFile(join(dir, 'persona-signals.jsonl'), 'utf-8');
        for (const line of psl.split('\n')) {
            if (!line.trim())
                continue;
            try {
                const j = JSON.parse(line);
                if (j.graduated === true)
                    graduated++;
                else if ((j.count ?? 0) >= 2)
                    ungraduated++;
            }
            catch { }
        }
    }
    catch { }
    let plugins = 0, agents = 0, skills = 0;
    try {
        const cat = JSON.parse(await fs.readFile(join(dir, '.installed-catalog.json'), 'utf-8'));
        plugins = Array.isArray(cat.plugins) ? cat.plugins.length : 0;
        agents = Array.isArray(cat.agents) ? cat.agents.length : 0;
        skills = Array.isArray(cat.skills) ? cat.skills.length : 0;
    }
    catch { }
    let dismissals = 0;
    try {
        const dl = await fs.readFile(join(dir, '.persona-dismissals.jsonl'), 'utf-8');
        const cutoff = Date.now() - 7 * 86400000;
        for (const line of dl.split('\n')) {
            if (!line.trim())
                continue;
            try {
                const j = JSON.parse(line);
                const t = new Date(j.at).getTime();
                if (!Number.isNaN(t) && t > cutoff)
                    dismissals++;
            }
            catch { }
        }
    }
    catch { }
    let spend = 0;
    try {
        const b = JSON.parse(await fs.readFile(join(dir, 'persona-budget.json'), 'utf-8'));
        const today = new Date().toISOString().slice(0, 10);
        if (b.date === today)
            spend = Number(b.today_usd) || 0;
    }
    catch { }
    return {
        identity_summary: identity,
        persona_card_bytes: cardBytes,
        ungraduated_signals: ungraduated,
        graduated_signals: graduated,
        installed_plugins: plugins,
        installed_agents: agents,
        installed_skills: skills,
        dismissals_7d: dismissals,
        today_spend_usd: spend,
        daily_budget_usd: DEFAULT_BUDGET,
    };
}
//# sourceMappingURL=persona-stats.js.map