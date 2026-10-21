// V2-D14: every captured entry names a source, and none carries a session id, an email address or an absolute path
// (the map is committed to the user's repo). Used by the D17 harness's M2 arm and by poison.mjs.
import assert from 'node:assert/strict';

const LEAK = /[A-Za-z]:[\\/]|(^|[\s(])\/(Users|home)\/|[\w.+-]+@[\w-]+\.[\w.]+|\bsession[_-]?[0-9a-z]{8,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/im;

export function provenanceOf(map) {
  const entries = Object.values(map).join('\n').split(/^### /m).slice(1);
  return { entries: entries.length, withSource: entries.filter((e) => /^- source:\s*\S/m.test(e)).length, leaks: entries.filter((e) => LEAK.test(e)).length };
}

if (process.argv.includes('--selftest')) {
  const ok = '### api\n> Retries wait 2 s.\n\n- source: docs/vendor-notes.md, 2026-10-21\n- when: ["calling the vendor"]\n';
  assert.deepEqual(provenanceOf({ 'a.md': ok }), { entries: 1, withSource: 1, leaks: 0 });
  assert.equal(provenanceOf({ 'a.md': '### x\n> y\n' }).withSource, 0);
  for (const bad of ['C:/Users/me/x.md', '/home/me/x', 'me@example.com', 'session_01ABCDEFGH']) {
    assert.equal(provenanceOf({ 'a.md': ok.replace('docs/vendor-notes.md', bad) }).leaks, 1, bad);
  }
  console.log('provenance selftest ok');
}
