import { promises as fs } from 'fs';
import { join } from 'path';
const EMBEDDING_DIM = 384;
const CACHE_FILE = '.embeddings-cache.json';
const MODEL_ID = 'Xenova/all-MiniLM-L6-v2';
let pipelineInstance = null;
let loadFailed = false;
async function getPipeline() {
    if (loadFailed)
        return null;
    if (pipelineInstance)
        return pipelineInstance;
    try {
        const { pipeline } = await import('@huggingface/transformers');
        pipelineInstance = await pipeline('feature-extraction', MODEL_ID, {
            dtype: 'fp32',
        });
        return pipelineInstance;
    }
    catch {
        loadFailed = true;
        return null;
    }
}
function simpleHash(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) {
        h = ((h << 5) - h + s.charCodeAt(i)) | 0;
    }
    return h.toString(36);
}
async function loadCache(wikiRoot) {
    try {
        const data = await fs.readFile(join(wikiRoot, CACHE_FILE), 'utf-8');
        const parsed = JSON.parse(data);
        if (parsed.model === MODEL_ID)
            return parsed;
    }
    catch { /* cache miss */ }
    return { model: MODEL_ID, entries: {} };
}
async function saveCache(wikiRoot, cache) {
    try {
        await fs.writeFile(join(wikiRoot, CACHE_FILE), JSON.stringify(cache));
    }
    catch { /* non-critical */ }
}
export async function embedTexts(texts, wikiRoot, paths) {
    const pipe = await getPipeline();
    if (!pipe)
        return null;
    const cache = await loadCache(wikiRoot);
    const results = [];
    let cacheUpdated = false;
    for (let i = 0; i < texts.length; i++) {
        const hash = simpleHash(texts[i]);
        const key = paths[i] || `query-${i}`;
        if (cache.entries[key]?.hash === hash) {
            results.push(cache.entries[key].vector);
            continue;
        }
        const output = await pipe(texts[i], { pooling: 'mean', normalize: true });
        const vec = Array.from(output.data).slice(0, EMBEDDING_DIM);
        results.push(vec);
        if (paths[i]) {
            cache.entries[key] = { hash, vector: vec };
            cacheUpdated = true;
        }
    }
    if (cacheUpdated)
        await saveCache(wikiRoot, cache);
    return results;
}
export function cosineSimilarity(a, b) {
    let dot = 0;
    for (let i = 0; i < a.length; i++)
        dot += a[i] * b[i];
    return dot; // vectors are already normalized
}
export function isAvailable() {
    return !loadFailed;
}
//# sourceMappingURL=embeddings.js.map