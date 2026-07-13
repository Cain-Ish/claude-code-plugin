// Dependency-free content-hash primitive (node crypto only). Lives OUTSIDE
// doc-sources.ts so importers that need only the hash (raw-inbox → the
// raw-capture CLI bundle) do not drag doc-sources' glob tree into their
// esbuild bundles (209KB vs 6KB peers before this split).
import { createHash } from 'crypto';

export function hashContent(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}
