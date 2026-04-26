import { pipeline } from "@xenova/transformers";
const MODEL_NAME = "Xenova/all-MiniLM-L6-v2";
export const EMBEDDING_DIM = 384;
let embedder = null;
async function getEmbedder() {
    if (!embedder) {
        embedder = (await pipeline("feature-extraction", MODEL_NAME, {
            quantized: true,
        }));
    }
    return embedder;
}
export async function embed(text) {
    const model = await getEmbedder();
    const output = await model(text, { pooling: "mean", normalize: true });
    return new Float32Array(output.data);
}
//# sourceMappingURL=embeddings.js.map