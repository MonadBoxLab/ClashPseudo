const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const publish = require('../../.github/scripts/publish-release.cjs');

async function fixture(t, version = '0.1.0+3') {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'clash-release-action-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const environment = { ...process.env };
  t.after(() => { process.env = environment; });
  const metadata = [`Application: ${version}`, 'Mihomo: v1.19.33', `Source: ${'a'.repeat(40)}`];
  const names = ['universal.apk', 'arm64-v8a.apk', 'armeabi-v7a.apk', 'x86_64.apk',
    'sources.tar.gz', 'licenses.tar.gz', 'SHA256SUMS'];
  const assets = [];
  for (const name of names) {
    const data = Buffer.from(`original ${name}`);
    const file = path.join(directory, name);
    await fs.writeFile(file, data);
    assets.push({ name, path: file, bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') });
  }
  const plan = { version, kernel: 'v1.19.33', tag: `v${version}`, commit: 'a'.repeat(40),
    body: `## Android 通用版（推荐）\n\n${metadata.join('\n')}`, assets };
  process.env.GITHUB_ACTIONS = 'true';
  process.env.CLASH_AUTOMATIC_RELEASES_ENABLED = 'true';
  process.env.RELEASE_PLAN = path.join(directory, 'release.json');
  await fs.writeFile(process.env.RELEASE_PLAN, JSON.stringify(plan));
  const state = { release: null, assets: [], uploads: [], deleted: [], creates: 0, publishes: 0,
    tag: plan.commit, getTagCalls: 0, downloaded: 0 };
  const missing = () => Object.assign(new Error('missing'), { status: 404 });
  const repos = {
    getReleaseByTag: async () => {
      if (!state.release) throw missing();
      return { data: state.release };
    },
    createRelease: async input => {
      state.creates++;
      state.release = { id: 42, body: input.body, draft: input.draft, prerelease: input.prerelease };
      return { data: state.release };
    },
    listReleaseAssets: async () => ({ data: state.assets }),
    deleteReleaseAsset: async input => {
      state.deleted.push(input.asset_id);
      state.assets = state.assets.filter(asset => asset.id !== input.asset_id);
    },
    uploadReleaseAsset: async input => {
      state.uploads.push(input.name);
      const data = input.data;
      const asset = { name: input.name, id: state.assets.length + 1, state: 'uploaded', size: data.length,
        digest: `sha256:${createHash('sha256').update(data).digest('hex')}` };
      state.assets.push(asset);
      return { data: asset };
    },
    getReleaseAsset: async input => {
      state.downloaded++;
      const asset = state.assets.find(item => item.id === input.asset_id);
      return { data: await fs.readFile(plan.assets.find(item => item.name === asset.name).path) };
    },
    getRelease: async () => ({ data: state.release }),
    updateRelease: async input => {
      state.publishes++;
      state.release = { ...state.release, ...input };
      return { data: state.release };
    },
  };
  const github = { rest: { repos, git: {
    getRef: async () => {
      state.getTagCalls++;
      return { data: { object: { type: 'commit', sha: state.tag } } };
    },
  } }, paginate: async () => state.assets };
  const args = { github, context: { repo: { owner: 'owner', repo: 'repo' } },
    core: { info() {}, setOutput() {} } };
  const existing = () => {
    state.release = { id: 42, body: plan.body, draft: true, prerelease: version.startsWith('0.') };
    state.assets = assets.map((asset, index) => ({ name: asset.name, id: index + 1, state: 'uploaded',
      size: asset.bytes, digest: `sha256:${asset.sha256}` }));
  };
  return { args, state, plan, existing };
}

test('Actions creates a draft and publishes only after all seven verified assets', async t => {
  const { args, state, plan } = await fixture(t);
  await publish(args);
  assert.equal(state.creates, 1);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.equal(state.publishes, 1);
  assert.equal(state.getTagCalls, 2);
  assert.equal(state.release.draft, false);
  assert.equal(state.release.prerelease, true);
});

test('an explicitly prepared stable version is published without the prerelease flag', async t => {
  const { args, state } = await fixture(t, '1.0.0+4');
  await publish(args);
  assert.equal(state.release.draft, false);
  assert.equal(state.release.prerelease, false);
});

test('retry repairs a development Release flag without rebuilding or replacing its assets', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.release.draft = false;
  state.release.prerelease = false;
  await publish(args);
  assert.equal(state.release.prerelease, true);
  assert.equal(state.creates, 0);
  assert.deepEqual(state.uploads, []);
  assert.deepEqual(state.deleted, []);
});

test('retry uploads a recovered missing file and preserves successful remote assets', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets.shift();
  await publish(args);
  assert.equal(state.creates, 0);
  assert.deepEqual(state.uploads, ['universal.apk']);
  assert.deepEqual(state.deleted, []);
  assert.equal(state.publishes, 1);
});

test('an interrupted starter upload can be replaced, successful assets remain intact', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets[0].state = 'starter';
  await publish(args);
  assert.deepEqual(state.deleted, [1]);
  assert.deepEqual(state.uploads, ['universal.apk']);
});

test('a mismatched remote asset stops publication without clobbering it', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets[0].digest = `sha256:${'0'.repeat(64)}`;
  await assert.rejects(publish(args), /远程资产摘要不同/);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, []);
  assert.deepEqual(state.deleted, []);
});

test('old assets without server digest are downloaded and hashed', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  delete state.assets[0].digest;
  await publish(args);
  assert.equal(state.downloaded, 1);
  assert.deepEqual(state.uploads, []);
});

test('a moved tag or foreign Release stops before remote writes', async t => {
  const { args, state, plan, existing } = await fixture(t);
  state.tag = 'b'.repeat(40);
  await assert.rejects(publish(args), /远程 tag/);
  state.tag = plan.commit;
  existing();
  state.release.body += '\nSource: another';
  await assert.rejects(publish(args), /源码归属不同/);
  assert.equal(state.creates, 0);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, []);
});

test('local invocation and changed local files cannot perform Release writes', async t => {
  const { args, state, plan } = await fixture(t);
  process.env.GITHUB_ACTIONS = 'false';
  await assert.rejects(publish(args), /仅由已启用的 GitHub Actions/);
  process.env.GITHUB_ACTIONS = 'true';
  await fs.writeFile(plan.assets[0].path, 'changed');
  await assert.rejects(publish(args), /待上传资产与核验结果不同/);
  assert.equal(state.creates, 0);
  assert.equal(state.publishes, 0);
});
