import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Api, downloadHash, repository, synchronizeRelease, validateAssets } from './sync_gitee_release.mjs';

const hash = 'a'.repeat(64);
const asset = { id: 10, name: 'expert-chat-arm64.apk', size: 3, state: 'uploaded', digest: 'sha256:' + hash };
function fixture({ existing = [], targetHash = hash, sourceHash = hash, assets = [asset] } = {}) {
  const calls = [];
  return {
    calls, tag: 'v3.7.0', folder: '/scratch', log() {},
    source: {
      async release() { return { id: 1, tag_name: 'v3.7.0', name: 'Release 3.7', body: 'Notes', prerelease: false }; },
      async assets() { return assets; },
    },
    pushTag: async tag => { calls.push(['tag', tag]); return 'commit123'; },
    target: {
      async find() { return existing.length ? { id: 2 } : null; },
      async create(body) { calls.push(['create', body]); return { id: 2 }; },
      async assets() { return existing; },
      async upload(id, file) { calls.push(['upload', file.name]); return { id: 20, name: file.name }; },
      async update(id, body) { calls.push(['update', body]); },
    },
    files: {
      async source() { calls.push(['download']); return sourceHash; },
      async target() { calls.push(['verify']); return targetHash; },
    },
  };
}
test('copies the exact tag, metadata and binaries then verifies the upload', async () => {
  const f = fixture();
  assert.deepEqual(await synchronizeRelease(f), { tag: 'v3.7.0', total: 1, uploaded: 1, unchanged: 0 });
  assert.deepEqual(f.calls.map(c => c[0]), ['download', 'tag', 'create', 'upload', 'verify', 'update']);
  assert.equal(f.calls[2][1].target_commitish, 'commit123');
  assert.equal(f.calls[2][1].body, 'Notes');
});
test('rerunning verifies matching existing bytes and skips uploading', async () => {
  const f = fixture({ existing: [{ id: 20, name: asset.name }] });
  assert.equal((await synchronizeRelease(f)).unchanged, 1);
  assert(!f.calls.some(c => c[0] === 'upload' || c[0] === 'create'));
});
test('different same-name content fails without overwrite or deletion', async () => {
  const f = fixture({ existing: [{ id: 20, name: asset.name }], targetHash: 'b'.repeat(64) });
  await assert.rejects(synchronizeRelease(f), /no file was overwritten/);
  assert(!f.calls.some(c => c[0] === 'upload' || c[0] === 'update'));
});
test('source digest failure prevents all remote changes', async () => {
  const f = fixture({ sourceHash: 'b'.repeat(64) });
  await assert.rejects(synchronizeRelease(f), /digest mismatch/);
  assert.deepEqual(f.calls.map(c => c[0]), ['download']);
});
test('failed upload can be rerun without replacing the completed attachment', async () => {
  const second = { ...asset, id: 11, name: 'windows.zip' };
  const f = fixture({ existing: [{ id: 20, name: asset.name }], assets: [asset, second] });
  assert.deepEqual(await synchronizeRelease(f), { tag: 'v3.7.0', total: 2, uploaded: 1, unchanged: 1 });
  assert.deepEqual(f.calls.filter(c => c[0] === 'upload'), [['upload', 'windows.zip']]);
});
test('drafts and assetless releases cannot create a Gitee release', async () => {
  const f = fixture({ assets: [] });
  await assert.rejects(synchronizeRelease(f), /no uploaded assets/);
  assert.deepEqual(f.calls, []);
  f.source.release = async () => ({ tag_name: f.tag, draft: true });
  await assert.rejects(synchronizeRelease(f), /published GitHub release/);
});
test('unsafe and duplicate filenames are rejected', () => {
  for (const name of ['../app.apk', 'a\\b.apk', 'name\n::error::oops']) {
    assert.throws(() => validateAssets([{ ...asset, name }]), /invalid assets/);
  }
  assert.throws(() => validateAssets([asset, asset]), /invalid assets/);
  assert.throws(() => repository('https://gitee.com/user/repo'));
  assert.throws(() => repository('user/repo;echo token'));
  assert.equal(repository('user/expert_chat'), 'user/expert_chat');
});
test('API errors do not expose server bodies or authentication values', async () => {
  const api = new Api('https://gitee.com/api/v5', 'synthetic-token', async (url, options) => {
    assert.equal(options.headers.Authorization, 'Bearer synthetic-token');
    assert.equal(options.redirect, 'error');
    return new Response('echo synthetic-token', { status: 403 });
  });
  await assert.rejects(api.request('/user'), error => !error.message.includes('synthetic-token') && error.message.includes('HTTP 403'));
});
test('pagination reads all attachments and only a 404 means missing', async () => {
  let count = 0;
  const api = new Api('https://gitee.com/api/v5', 'token', async () => {
    count++;
    return Response.json(count === 1 ? Array(100).fill({ id: 1 }) : [{ id: 2 }]);
  });
  assert.equal((await api.pages('/assets')).length, 101);
  const missing = new Api('https://gitee.com/api/v5', 'token', async () => new Response('', { status: 404 }));
  assert.equal(await missing.request('/release', { missing: true }), null);
});
test('streamed downloads verify size and strip credentials on CDN redirects', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'release-mirror-test-'));
  try {
    const calls = [];
    const fetcher = async (url, options) => {
      calls.push({ url, headers: options.headers });
      return calls.length === 1
        ? new Response(null, { status: 302, headers: { location: 'https://cdn.example/asset' } })
        : new Response(new Uint8Array([1, 2, 3]));
    };
    const path = join(folder, 'asset');
    const actual = await downloadHash('https://api.github.com/asset', path, { size: 3, token: 'synthetic-token', fetcher });
    assert.equal(actual, createHash('sha256').update(new Uint8Array([1, 2, 3])).digest('hex'));
    assert.equal(calls[0].headers.Authorization, 'Bearer synthetic-token');
    assert.equal(calls[1].headers.Authorization, undefined);
    assert.deepEqual([...await readFile(path)], [1, 2, 3]);
    await assert.rejects(downloadHash('https://api.github.com/asset', join(folder, 'short'),
      { size: 4, fetcher: async () => new Response(new Uint8Array([1, 2, 3])) }), /size mismatch/);
    await assert.rejects(downloadHash('http://example/asset', join(folder, 'http')), /HTTPS/);
  } finally { await rm(folder, { recursive: true, force: true }); }
});
