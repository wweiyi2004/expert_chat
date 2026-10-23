import { createHash } from 'node:crypto';
import { createWriteStream, openAsBlob } from 'node:fs';
import { appendFile, chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const exec = promisify(execFile);
const enc = encodeURIComponent;

export function repository(value) {
  if (!/^[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(value ?? '')) {
    throw new Error('Repository must have the form owner/repository.');
  }
  return value.split('/').map(enc).join('/');
}

export function validateAssets(assets) {
  if (!Array.isArray(assets) || assets.length === 0) {
    throw new Error('The GitHub release has no uploaded assets. Upload files before publishing, then rerun.');
  }
  const names = new Set();
  for (const asset of assets) {
    if (typeof asset.name !== 'string' || !asset.name ||
        /[\\/\x00-\x1f\x7f]/.test(asset.name) || names.has(asset.name) ||
        !Number.isSafeInteger(asset.size) || asset.size <= 0 ||
        (asset.state && asset.state !== 'uploaded')) {
      throw new Error('Release contains duplicate, unfinished or invalid assets.');
    }
    names.add(asset.name);
  }
}

function numericId(id) {
  if (!/^\d+$/.test(String(id)) || Number(id) <= 0) throw new Error('Invalid release or attachment ID.');
  return String(id);
}

export class Api {
  constructor(base, token, fetcher = fetch) {
    this.base = base;
    this.token = token;
    this.fetcher = fetcher;
  }
  async request(path, { method = 'GET', body, missing = false } = {}) {
    const multipart = body instanceof FormData;
    let response;
    try {
      response = await this.fetcher(this.base + path, {
        method, redirect: 'error',
        headers: {
          Authorization: 'Bearer ' + this.token,
          Accept: 'application/json',
          'User-Agent': 'expert-chat-release-mirror',
          ...(body && !multipart ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? (multipart ? body : JSON.stringify(body)) : undefined,
        signal: AbortSignal.timeout(multipart ? 20 * 60_000 : 60_000),
      });
    } catch {
      // Never print request objects, bearer tokens or server-controlled bodies.
      throw new Error(new URL(this.base).host + ': request failed or timed out; rerun the workflow.');
    }
    if (response.status === 404 && missing) return null;
    if (!response.ok) {
      throw new Error(new URL(this.base).host + ': HTTP ' + response.status +
        ' during ' + method + ' request. Check repository access, token scope and attachment limits.');
    }
    if (response.status === 204) return null;
    return response.json();
  }
  async pages(path) {
    const items = [];
    for (let page = 1; page <= 100; page++) {
      const batch = await this.request(path + '?per_page=100&page=' + page);
      if (!Array.isArray(batch)) throw new Error('Unexpected paginated API response.');
      items.push(...batch);
      if (batch.length < 100) return items;
    }
    throw new Error('Attachment list exceeds pagination limit.');
  }
}

// Only the first API request receives credentials. Redirects to asset/CDN
// hosts are always unauthenticated; require HTTPS at every hop.
export async function downloadHash(url, path, { token, size, fetcher = fetch } = {}) {
  const signal = AbortSignal.timeout(20 * 60_000);
  let response;
  for (let hop = 0; hop < 10; hop++) {
    const uri = new URL(url);
    if (uri.protocol !== 'https:' || uri.username || uri.password) {
      throw new Error('Asset download requires an HTTPS URL without embedded credentials.');
    }
    response = await fetcher(uri.href, {
      redirect: 'manual', signal,
      headers: {
        Accept: 'application/octet-stream',
        ...(hop === 0 && token ? { Authorization: 'Bearer ' + token } : {}),
      },
    });
    if (![301, 302, 303, 307, 308].includes(response.status)) break;
    const location = response.headers.get('location');
    await response.body?.cancel();
    if (!location) throw new Error('Asset redirect has no destination.');
    url = new URL(location, uri).href;
  }
  if (!response?.ok || !response.body) throw new Error('Unable to download release attachment.');
  let bytes = 0;
  const hash = createHash('sha256');
  const meter = new Transform({
    transform(chunk, encoding, callback) {
      bytes += chunk.length;
      if (size !== undefined && bytes > size) return callback(new Error('Attachment exceeds expected size.'));
      hash.update(chunk);
      callback(null, chunk);
    },
  });
  await pipeline(Readable.fromWeb(response.body), meter, createWriteStream(path, { flags: 'wx' }), { signal });
  if (size !== undefined && bytes !== size) throw new Error('Attachment size mismatch.');
  return hash.digest('hex');
}

export async function synchronizeRelease({ source, target, files, pushTag, tag, folder, log = console.log }) {
  const release = await source.release(tag);
  if (release.draft || release.tag_name !== tag) throw new Error('Select a published GitHub release with the exact tag.');
  const assets = await source.assets(release.id);
  validateAssets(assets);

  // Download and verify every source before creating remote release state.
  const prepared = [];
  for (const [index, asset] of assets.entries()) {
    const path = join(folder, 'source-' + index);
    const hash = await files.source(asset, path);
    if (asset.digest != null && asset.digest !== '' &&
        asset.digest.toLowerCase() !== 'sha256:' + hash) {
      throw new Error('GitHub attachment digest mismatch: ' + asset.name);
    }
    prepared.push({ asset, path, hash });
  }

  const commit = await pushTag(tag);
  let mirrored = await target.find(tag);
  const metadata = {
    tag_name: tag,
    target_commitish: commit,
    name: release.name || tag,
    body: release.body || ('Mirror of ' + release.html_url),
    prerelease: Boolean(release.prerelease),
  };
  if (!mirrored) mirrored = await target.create(metadata);
  const existing = await target.assets(mirrored.id);
  let uploaded = 0;
  for (const [index, entry] of prepared.entries()) {
    const { asset, path, hash } = entry;
    const matches = existing.filter(file => file.name === asset.name);
    if (matches.length > 1) throw new Error('Duplicate Gitee attachment name: ' + asset.name);
    let remote = matches[0];
    if (remote) {
      const actual = await files.target(mirrored.id, remote, join(folder, 'existing-' + index), asset.size);
      if (actual !== hash) {
        throw new Error('Gitee already has different bytes for ' + asset.name + '; no file was overwritten.');
      }
      log('Verified existing attachment: ' + asset.name);
      continue;
    }
    remote = await target.upload(mirrored.id, asset, path);
    const actual = await files.target(mirrored.id, remote, join(folder, 'uploaded-' + index), asset.size);
    if (actual !== hash) throw new Error('Gitee upload verification failed: ' + asset.name);
    uploaded++;
    log('Uploaded and verified: ' + asset.name);
  }
  await target.update(mirrored.id, metadata);
  return { tag, total: prepared.length, uploaded, unchanged: prepared.length - uploaded };
}

async function main() {
  const sourceRepo = repository(process.env.GITHUB_REPOSITORY);
  const targetRepo = repository(process.env.GITEE_REPO);
  const githubToken = process.env.GITHUB_TOKEN;
  const giteeToken = process.env.GITEE_TOKEN;
  const tag = process.env.RELEASE_TAG;
  if (!githubToken || !giteeToken || !tag) throw new Error('Configure GITEE_TOKEN, GITEE_REPO and a release tag.');
  // Validate before using tag in git arguments, URLs or output.
  await exec('git', ['check-ref-format', 'refs/tags/' + tag]);
  const gh = new Api('https://api.github.com', githubToken);
  const gt = new Api('https://gitee.com/api/v5', giteeToken);
  const root = '/repos/' + targetRepo;
  const folder = await mkdtemp(join(tmpdir(), 'expert-chat-release-'));
  try {
    const source = {
      release: value => gh.request('/repos/' + sourceRepo + '/releases/tags/' + enc(value)),
      assets: id => gh.pages('/repos/' + sourceRepo + '/releases/' + numericId(id) + '/assets'),
    };
    const target = {
      find: value => gt.request(root + '/releases/tags/' + enc(value), { missing: true }),
      create: body => gt.request(root + '/releases', { method: 'POST', body }),
      update: (id, body) => gt.request(root + '/releases/' + numericId(id), { method: 'PATCH', body }),
      assets: id => gt.pages(root + '/releases/' + numericId(id) + '/attach_files'),
      upload: async (id, asset, path) => {
        const form = new FormData();
        form.set('file', await openAsBlob(path), asset.name);
        return gt.request(root + '/releases/' + numericId(id) + '/attach_files', { method: 'POST', body: form });
      },
    };
    const files = {
      source: (asset, path) => downloadHash(
        'https://api.github.com/repos/' + sourceRepo + '/releases/assets/' + numericId(asset.id),
        path, { token: githubToken, size: asset.size }),
      target: (releaseId, asset, path, size) => downloadHash(
        'https://gitee.com/api/v5' + root + '/releases/' + numericId(releaseId) +
        '/attach_files/' + numericId(asset.id) + '/download',
        path, { token: giteeToken, size }),
    };
    const pushTag = async value => {
      const user = await gt.request('/user');
      if (typeof user.login !== 'string' || !user.login) throw new Error('Unable to resolve Gitee login.');
      const askpass = join(folder, 'askpass.cjs');
      await writeFile(askpass,
        '#!/usr/bin/env node\nprocess.stdout.write(/username/i.test(process.argv[2] || "") ? process.env.GITEE_LOGIN : process.env.GITEE_TOKEN);\n');
      await chmod(askpass, 0o700);
      const ref = 'refs/tags/' + value;
      const { stdout } = await exec('git', ['rev-parse', '--verify', ref + '^{commit}']);
      try {
        await exec('git', ['-c', 'credential.helper=', 'push', '--porcelain',
          'https://gitee.com/' + targetRepo + '.git', ref + ':' + ref], {
          env: { ...process.env, GIT_ASKPASS: askpass, GIT_TERMINAL_PROMPT: '0', GITEE_LOGIN: user.login },
          timeout: 10 * 60_000,
        });
      } catch {
        throw new Error('Cannot push the release tag to Gitee. Check repository permissions and conflicting tags; force push is disabled.');
      }
      return stdout.trim();
    };
    const result = await synchronizeRelease({ source, target, files, pushTag, tag, folder });
    console.log('Mirror completed: ' + result.total + ' verified assets; ' + result.uploaded + ' uploaded.');
    if (process.env.GITHUB_STEP_SUMMARY) {
      await appendFile(process.env.GITHUB_STEP_SUMMARY,
        'Gitee release mirror completed. Assets: ' + result.total + '; uploaded: ' +
        result.uploaded + '; already identical: ' + result.unchanged + '.\n');
    }
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    let message = error instanceof Error ? error.message : 'Release synchronization failed.';
    for (const secret of [process.env.GITHUB_TOKEN, process.env.GITEE_TOKEN]) {
      if (secret) message = message.split(secret).join('[REDACTED]');
    }
    console.error(message);
    process.exitCode = 1;
  });
}
