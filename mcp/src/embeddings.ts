import { pipeline } from "@xenova/transformers";

const MODEL_NAME = "Xenova/all-MiniLM-L6-v2";
export const EMBEDDING_DIM = 384;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let embedder: any = null;

async function getEmbedder() {
  if (!embedder) {
    embedder = await pipeline("feature-extraction", MODEL_NAME, {
      quantized: true,
    });
  }
  return embedder;
}

export async function embed(text: string): Promise<Float32Array> {
  const model = await getEmbedder();
  const output = await model(text, { pooling: "mean", normalize: true });
  return new Float32Array(output.data);
}

export async function embedBatch(texts: string[]): Promise<Float32Array[]> {
  const results: Float32Array[] = [];
  for (const text of texts) {
    results.push(await embed(text));
  }
  return results;
}
