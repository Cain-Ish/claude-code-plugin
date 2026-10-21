// V2-D22 run 3: delivery keyed to the file Claude reads. A token is a path, a folder, a bare file name or a glob,
// taken from an entry's applies-when terms. Shared by the hook (onread.mjs) and the scoring and simulation (route.mjs).

// Path-like tokens in one applies-when term: something with a slash, a glob star, or a file extension with a letter.
export function tokensOf(term) {
  return (String(term).match(/[\w.*\-/]+/g) ?? [])
    .map((t) => t.replace(/^\.?\/+/, '').replace(/[.]+$/, ''))
    .filter((t) => t.length > 2 && !/^https?/.test(t) && (t.includes('/') || t.includes('*') || /\.[a-z][a-z0-9]{0,5}$/i.test(t)));
}

// How specifically a token names a repo-relative file: 0 the file itself, 1 its folder, 2 a glob with a folder,
// 3 a glob on the file name alone (a file type); -1 no match.
export function tokenMatch(token, file) {
  const base = file.split('/').pop();
  if (token.includes('*')) {
    const re = new RegExp(`^${token.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\/?/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*')}$`);
    return token.includes('/') ? (re.test(file) ? 2 : -1) : (re.test(base) ? 3 : -1);
  }
  if (token.includes('/')) {
    const t = token.replace(/\/$/, '');
    return file === t ? 0 : file.startsWith(`${t}/`) ? 1 : -1;
  }
  return base === token ? 0 : -1;
}

// keyed: [[entry id, token]]. The entries a read of this file brings, most specific first, then in map order.
export function keyedFor(keyed, file) {
  const best = new Map();
  for (const [id, token] of keyed) {
    const s = tokenMatch(token, file);
    if (s >= 0 && (!best.has(id) || s < best.get(id))) best.set(id, s);
  }
  return [...best].sort((a, b) => a[1] - b[1] || a[0] - b[0]).map(([id]) => id);
}
