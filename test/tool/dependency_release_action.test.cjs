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
  delete process.env.ACT;
  delete process.env.CLASH_LOCAL_EXECUTION;
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

test('Actions先创建草稿，核对全部七项附件后发布', async t => {
  const { args, state, plan } = await fixture(t);
  await publish(args);
  assert.equal(state.creates, 1);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.equal(state.publishes, 1);
  assert.equal(state.getTagCalls, 2);
  assert.equal(state.release.draft, false);
  assert.equal(state.release.prerelease, true);
});

test('显式准备的稳定版本发布时不设置prerelease标记', async t => {
  const { args, state } = await fixture(t, '1.0.0+4');
  await publish(args);
  assert.equal(state.release.draft, false);
  assert.equal(state.release.prerelease, false);
});

test('重新运行时修正开发版本的Release标记并保留已有附件', async t => {
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

test('重新运行时上传恢复的缺失文件并保留已上传附件', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets.shift();
  await publish(args);
  assert.equal(state.creates, 0);
  assert.deepEqual(state.uploads, ['universal.apk']);
  assert.deepEqual(state.deleted, []);
  assert.equal(state.publishes, 1);
});

test('重新上传未完成的starter附件并保留已上传附件', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets[0].state = 'starter';
  await publish(args);
  assert.deepEqual(state.deleted, [1]);
  assert.deepEqual(state.uploads, ['universal.apk']);
});

test('远程附件内容不符时停止发布并保留该附件', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets[0].digest = `sha256:${'0'.repeat(64)}`;
  await assert.rejects(publish(args), /远程附件的 SHA-256 与本地记录不一致/);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, []);
  assert.deepEqual(state.deleted, []);
});

test('部分上传失败后保留草稿，重新运行时复用已上传附件', async t => {
  const { args, state, plan } = await fixture(t);
  const upload = args.github.rest.repos.uploadReleaseAsset;
  const failure = new Error('synthetic upload failure');
  args.github.rest.repos.uploadReleaseAsset = async input => {
    if (input.name === plan.assets[2].name) throw failure;
    return upload(input);
  };
  await assert.rejects(publish(args), error => error === failure);
  assert.equal(state.creates, 1);
  assert.equal(state.release.draft, true);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, plan.assets.slice(0, 2).map(asset => asset.name));
  assert.deepEqual(state.deleted, []);

  args.github.rest.repos.uploadReleaseAsset = upload;
  await publish(args);
  assert.equal(state.creates, 1);
  assert.equal(state.release.draft, false);
  assert.equal(state.publishes, 1);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.deepEqual(state.deleted, []);
});

test('上传后tag指向变化时保留草稿，重新运行时复用已校验附件', async t => {
  const { args, state, plan } = await fixture(t);
  const getRef = args.github.rest.git.getRef;
  args.github.rest.git.getRef = async input => {
    const result = await getRef(input);
    if (state.getTagCalls === 1) state.tag = 'b'.repeat(40);
    return result;
  };
  await assert.rejects(publish(args), /远程 tag/);
  assert.equal(state.creates, 1);
  assert.equal(state.release.draft, true);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.deepEqual(state.deleted, []);

  state.tag = plan.commit;
  await publish(args);
  assert.equal(state.creates, 1);
  assert.equal(state.release.draft, false);
  assert.equal(state.publishes, 1);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.deepEqual(state.deleted, []);
});

test('上传后Release版本或源码信息变化时停止发布草稿', async t => {
  const { args, state, plan } = await fixture(t);
  args.github.rest.repos.getRelease = async () => ({
    data: { ...state.release, body: `${plan.body}\nSource: another` },
  });
  await assert.rejects(publish(args), /Release版本与源码信息在发布前发生变化/);
  assert.equal(state.release.draft, true);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, plan.assets.map(asset => asset.name));
  assert.deepEqual(state.deleted, []);
});

test('下载未提供服务端摘要的旧附件并计算摘要', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  delete state.assets[0].digest;
  await publish(args);
  assert.equal(state.downloaded, 2); // 初次核对及发布前重新核对。
  assert.deepEqual(state.uploads, []);
});

test('tag指向变化或Release源码身份不符时，在写入前停止', async t => {
  const { args, state, plan, existing } = await fixture(t);
  state.tag = 'b'.repeat(40);
  await assert.rejects(publish(args), /远程 tag/);
  state.tag = plan.commit;
  existing();
  state.release.body += '\nSource: another';
  await assert.rejects(publish(args), /现有 Release 的版本、内核版本或源码提交与本次发布不一致/);
  assert.equal(state.creates, 0);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.uploads, []);
});

test('ACT、本地模式和工作树发布计划在调用API前被拒绝', async t => {
  const { args, state, plan } = await fixture(t);
  let calls = 0;
  args.github.rest.git.getRef = async () => { calls++; throw new Error('API forbidden'); };
  for (const value of ['true', 'false']) {
    process.env.ACT = value;
    await assert.rejects(publish(args), /仅由已启用的 GitHub Actions/);
  }
  delete process.env.ACT;
  process.env.CLASH_LOCAL_EXECUTION = 'true';
  await assert.rejects(publish(args), /仅由已启用的 GitHub Actions/);
  delete process.env.CLASH_LOCAL_EXECUTION;
  for (const key of ['local', 'workingTree']) {
    await fs.writeFile(process.env.RELEASE_PLAN, JSON.stringify({ ...plan, [key]: true }));
    await assert.rejects(publish(args), /本地工作树材料/);
  }
  assert.equal(calls, 0);
  assert.equal(state.creates, 0);
});

test('并发创建的草稿通过版本和源码身份校验后复用', async t => {
  const { args, state, existing } = await fixture(t);
  args.github.rest.repos.createRelease = async () => {
    existing();
    throw Object.assign(new Error('already exists'), { status: 422 });
  };
  await publish(args);
  assert.equal(state.publishes, 1);
  assert.deepEqual(state.uploads, []);
  state.release = null;
  args.github.rest.repos.createRelease = async () => {
    existing();
    state.release.body += '\nSource: foreign';
    throw Object.assign(new Error('already exists'), { status: 422 });
  };
  await assert.rejects(publish(args), /另一任务创建的 Release 的版本、内核版本或源码提交与本次发布不一致/);
  assert.equal(state.publishes, 1);
});

test('并发上传冲突时保留并校验已完成的远程附件', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets.shift();
  const upload = args.github.rest.repos.uploadReleaseAsset;
  args.github.rest.repos.uploadReleaseAsset = async input => {
    await upload(input);
    throw Object.assign(new Error('already exists'), { status: 422 });
  };
  await publish(args);
  assert.equal(state.publishes, 1);
  assert.deepEqual(state.uploads, ['universal.apk']);
  assert.deepEqual(state.deleted, []);
});

test('并发附件摘要不符或发布前附件消失时停止发布', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets.shift();
  const upload = args.github.rest.repos.uploadReleaseAsset;
  args.github.rest.repos.uploadReleaseAsset = async input => {
    await upload(input);
    state.assets.at(-1).digest = `sha256:${'0'.repeat(64)}`;
    throw Object.assign(new Error('already exists'), { status: 422 });
  };
  await assert.rejects(publish(args), /远程附件的 SHA-256 与本地记录不一致/);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.deleted, []);
  existing();
  let lists = 0;
  args.github.paginate = async () => (++lists === 2 ? state.assets.slice(1) : state.assets);
  await assert.rejects(publish(args), /发布前缺少附件/);
  assert.equal(state.publishes, 0);
});

test('并发完成的starter附件经校验后复用', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets[0].state = 'starter';
  let lists = 0;
  args.github.paginate = async () => {
    if (++lists === 2) state.assets[0].state = 'uploaded';
    return state.assets;
  };
  await publish(args);
  assert.equal(state.publishes, 1);
  assert.deepEqual(state.deleted, []);
  assert.deepEqual(state.uploads, []);
});

test('远程附件名称重复时停止发布', async t => {
  const { args, state, existing } = await fixture(t);
  existing();
  state.assets.push({ ...state.assets[0], id: 99 });
  await assert.rejects(publish(args), /远程 Release 包含同名附件/);
  assert.equal(state.publishes, 0);
  assert.deepEqual(state.deleted, []);
});

test('本地调用或本地文件变化时停止写入Release', async t => {
  const { args, state, plan } = await fixture(t);
  process.env.GITHUB_ACTIONS = 'false';
  await assert.rejects(publish(args), /仅由已启用的 GitHub Actions/);
  process.env.GITHUB_ACTIONS = 'true';
  await fs.writeFile(plan.assets[0].path, 'changed');
  await assert.rejects(publish(args), /待上传附件的大小或摘要与核验记录不一致/);
  assert.equal(state.creates, 0);
  assert.equal(state.publishes, 0);
});
