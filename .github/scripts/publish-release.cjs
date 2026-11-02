const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');

const sha256 = data => createHash('sha256').update(data).digest('hex');
const requireCondition = (condition, message) => {
  if (!condition) throw new Error(message);
};

// GitHub Actions 在全部构建和检查完成后调用此步骤。
module.exports = async ({ github, context, core }) => {
  requireCondition(process.env.GITHUB_ACTIONS === 'true' && !process.env.ACT &&
    process.env.CLASH_LOCAL_EXECUTION !== 'true' &&
    process.env.CLASH_AUTOMATIC_RELEASES_ENABLED === 'true', 'Release 写操作仅由已启用的 GitHub Actions 执行');
  const plan = JSON.parse(await fs.readFile(process.env.RELEASE_PLAN, 'utf8'));
  requireCondition(!plan.local && !plan.workingTree, '本地工作树材料不能用于远程发布');
  const repo = context.repo;
  requireCondition(/^\d+\.\d+\.\d+\+\d+$/.test(plan.version) &&
    plan.tag === `v${plan.version}` && /^[0-9a-f]{40}$/.test(plan.commit), '发布输入的版本或提交无效');
  requireCondition(plan.assets.length === 7 && new Set(plan.assets.map(asset => asset.name)).size === 7,
    '发布输入必须包含四个 APK、对应源码、许可材料和校验文件');
  const prerelease = plan.version.startsWith('0.');
  const metadata = [`Application: ${plan.version}`, `Mihomo: ${plan.kernel}`, `Source: ${plan.commit}`];
  const owns = release => JSON.stringify((release.body || '').split(/\r?\n/)
    .filter(line => /^(?:Application|Mihomo|Source):/.test(line))) === JSON.stringify(metadata);
  const checkTag = async () => {
    let object = (await github.rest.git.getRef({ ...repo, ref: `tags/${plan.tag}` })).data.object;
    while (object.type === 'tag') {
      object = (await github.rest.git.getTag({ ...repo, tag_sha: object.sha })).data.object;
    }
    requireCondition(object.type === 'commit' && object.sha === plan.commit, '远程 tag 指向的提交与已核验的源码提交不一致');
  };
  for (const asset of plan.assets) {
    requireCondition(path.basename(asset.name) === asset.name && path.basename(asset.path) === asset.name,
      '发布附件的路径无效');
    const data = await fs.readFile(asset.path);
    requireCondition(data.length === asset.bytes && sha256(data) === asset.sha256,
      `待上传附件的大小或摘要与核验记录不一致：${asset.name}`);
  }
  await checkTag();
  let release;
  try {
    release = (await github.rest.repos.getReleaseByTag({ ...repo, tag: plan.tag })).data;
    requireCondition(owns(release), '现有 Release 的版本、内核版本或源码提交与本次发布不一致');
  } catch (error) {
    if (error.status !== 404) throw error;
    try {
      release = (await github.rest.repos.createRelease({ ...repo, tag_name: plan.tag,
        name: `Clash Pseudo ${plan.version}`, body: plan.body, draft: true, prerelease })).data;
    } catch (conflict) {
      if (conflict.status !== 422) throw conflict;
      release = (await github.rest.repos.getReleaseByTag({ ...repo, tag: plan.tag })).data;
      requireCondition(owns(release), '另一任务创建的 Release 的版本、内核版本或源码提交与本次发布不一致');
    }
  }
  const listAssets = async () => {
    const assets = await github.paginate(github.rest.repos.listReleaseAssets, { ...repo, release_id: release.id });
    requireCondition(new Set(assets.map(asset => asset.name)).size === assets.length, '远程 Release 包含同名附件');
    return new Map(assets.map(asset => [asset.name, asset]));
  };
  const existing = await listAssets();
  const verifyRemote = async (remote, expected) => {
    requireCondition(remote.state === 'uploaded' && remote.size === expected.bytes,
      `远程附件尚未上传完成，或大小与本地记录不一致：${expected.name}`);
    let digest = remote.digest;
    if (!digest) {
      const response = await github.rest.repos.getReleaseAsset({ ...repo, asset_id: remote.id,
        headers: { accept: 'application/octet-stream' } });
      digest = `sha256:${sha256(Buffer.from(response.data))}`;
    }
    requireCondition(digest === `sha256:${expected.sha256}`, `远程附件的 SHA-256 与本地记录不一致：${expected.name}`);
  };
  for (const expected of plan.assets) {
    let remote = existing.get(expected.name);
    if (remote && remote.state !== 'uploaded') {
      const current = (await listAssets()).get(expected.name);
      if (current?.state === 'uploaded') {
        remote = current;
      } else {
        requireCondition(!current || current.id === remote.id,
          `尚未上传完成的附件已被另一任务替换：${expected.name}`);
        if (current) {
          try {
            await github.rest.repos.deleteReleaseAsset({ ...repo, asset_id: current.id });
          } catch (conflict) {
            if (conflict.status !== 404) throw conflict;
          }
        }
        remote = undefined;
      }
    }
    if (remote) {
      await verifyRemote(remote, expected);
    } else {
      const data = await fs.readFile(expected.path);
      requireCondition(sha256(data) === expected.sha256, `附件内容在上传前发生变化：${expected.name}`);
      try {
        remote = (await github.rest.repos.uploadReleaseAsset({ ...repo, release_id: release.id,
          name: expected.name, data, headers: { 'content-type': expected.name.endsWith('.apk')
            ? 'application/vnd.android.package-archive' : 'application/octet-stream', 'content-length': data.length } })).data;
      } catch (conflict) {
        if (conflict.status !== 422) throw conflict;
        remote = (await listAssets()).get(expected.name);
        requireCondition(remote, `另一任务上传后找不到待校验附件：${expected.name}`);
      }
      await verifyRemote(remote, expected);
    }
    core.info(`已核对发布附件：${expected.name}`);
  }
  await checkTag();
  const finalAssets = await listAssets();
  for (const expected of plan.assets) {
    const remote = finalAssets.get(expected.name);
    requireCondition(remote, `发布前缺少附件：${expected.name}`);
    await verifyRemote(remote, expected);
  }
  const fresh = (await github.rest.repos.getRelease({ ...repo, release_id: release.id })).data;
  requireCondition(owns(fresh), 'Release版本与源码信息在发布前发生变化');
  await github.rest.repos.updateRelease({ ...repo, release_id: release.id, body: plan.body,
    draft: false, prerelease });
  core.setOutput('version', plan.version);
  core.info(`已通过 GitHub Actions 发布 ${plan.tag}`);
};
