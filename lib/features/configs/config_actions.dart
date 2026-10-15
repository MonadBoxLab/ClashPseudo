import 'dart:io';
import 'dart:math';

import '../../platform/app_bridge.dart';
import '../../platform/core_input.dart';
import '../mode/tunnel_mode.dart';
import 'config_downloader.dart';
import 'config_entry.dart';
import 'config_store.dart';

class ConfigActions {
  ConfigActions(this.store, this.downloader, this.platform, this.runInput);

  final ConfigStore store;
  final ConfigDownloader downloader;
  final AppBridge platform;
  final File runInput;

  Future<String> execute(Map<String, dynamic> command) async {
    final action = command['action'];
    if (action == 'stop') {
      await platform.stage('正在停止接管');
      await platform.stop();
      return '接管已停止。';
    }
    final state = await platform.snapshot();
    if (!state.confirmed) throw const ConfigFailure('接管状态尚未确认，请先核实状态。');
    final collection = await store.read();
    switch (action) {
      case 'prepareStrategies':
        final selected = collection.selected;
        if (selected == null) throw const ConfigFailure('请先导入并选择配置。');
        if (command['id'] != selected.id ||
            command['revision'] != selected.revision) {
          throw const ConfigFailure('当前配置已变化，请等待策略重新加载。');
        }
        if (state.core.blocked) throw const ConfigFailure('内核资源尚未确认，暂时无法加载策略。');
        if (state.running) {
          if (state.configId != selected.id ||
              state.revision != selected.revision) {
            throw const ConfigFailure('当前运行配置与预览请求不一致。');
          }
          return '';
        }
        await platform.stage('正在加载策略配置');
        final input = CoreInput(runInput);
        try {
          await input.write(selected, collection.mode);
          await platform.prepareStrategies(
            id: selected.id,
            revision: selected.revision,
            mode: collection.mode,
          );
        } finally {
          await input.clear();
        }
        return '';
      case 'setMode':
        return _setMode(collection, state, TunnelMode.parse(command['mode']));
      case 'import':
        return _import(collection, state, command);
      case 'select':
        return _select(collection, state, command['id'] as String);
      case 'delete':
        return _delete(collection, state, command['id'] as String);
      case 'start':
        if (state.running) throw const ConfigFailure('接管已经运行，无需重复启动。');
        final selected = collection.selected;
        if (selected == null) throw const ConfigFailure('请先导入并选择配置。');
        await _start(selected, collection.mode);
        return '接管已启动。';
      default:
        throw const ConfigFailure('无法识别此操作。');
    }
  }

  Future<String> _import(
    ConfigCollection collection,
    AppSnapshot state,
    Map<String, dynamic> command,
  ) async {
    final source = ConfigDownloader.sourceUri(command['source'] as String)
        .toString();
    final existing = collection.entries
        .where((entry) => entry.source == source)
        .firstOrNull;
    if (existing != null && command['replace'] != true) {
      throw const ConfigFailure('该来源已保存，请先确认是否覆盖更新。');
    }
    final replacesCurrent =
        existing != null && existing.id == collection.selectedId;
    var invalidated = false;
    try {
      if (existing != null) {
        // Retire the old body before I/O: process death must not revive it after
        // an accepted update. The running core owns its already-loaded resources.
        collection = collection.replace(
          existing.withContent(null, error: '更新未完成，请重新导入此来源。'),
        );
        await store.save(collection);
        invalidated = true;
        if (replacesCurrent &&
            !state.running &&
            state.core.purpose == 'PREVIEW') {
          await platform.releasePreview();
        }
      }
      await platform.stage(existing == null ? '正在下载配置' : '正在更新配置');
      final body = await downloader.download(
        source,
        allowHttp: command['allowHttp'] == true,
      );
      if (existing == null) {
        final entry = ConfigEntry(
          id: '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}',
          name: _name(command['name'] as String?, source),
          source: source,
          revision: 1,
          body: body,
        );
        collection = ConfigCollection(
          entries: [...collection.entries, entry],
          selectedId: collection.selectedId ?? entry.id,
          mode: collection.mode,
        );
      } else {
        collection = collection.replace(
          collection.find(existing.id)!.withContent(body),
        );
      }
      await store.save(collection);
    } catch (_) {
      if (replacesCurrent && state.running) {
        await platform.stop();
      }
      if (existing != null && !invalidated) {
        throw const ConfigFailure('无法保存更新状态，更新未开始；旧记录未修改，请修复存储问题后重试。');
      }
      rethrow;
    }
    if (replacesCurrent && state.running) {
      await platform.stage('正在停止旧接管');
      await platform.stop();
      await _start(collection.selected!, collection.mode);
      return '配置已更新并重新启动。';
    }
    return existing == null ? '配置已保存，启动时由内核解析。' : '配置已更新。';
  }

  Future<String> _select(
    ConfigCollection collection,
    AppSnapshot state,
    String id,
  ) async {
    final entry = _entry(collection, id);
    if (entry.body == null) throw const ConfigFailure('该配置没有可用正文，请重新导入更新。');
    if (state.running) {
      await platform.stage('正在停止旧接管');
      await platform.stop();
    }
    await store.save(
      ConfigCollection(
        entries: collection.entries,
        selectedId: id,
        mode: collection.mode,
      ),
    );
    if (state.running) {
      await _start(entry, collection.mode);
      return '已切换接管配置。';
    }
    if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
    return '已选择配置，尚未启动接管。';
  }

  Future<String> _delete(
    ConfigCollection collection,
    AppSnapshot state,
    String id,
  ) async {
    _entry(collection, id);
    if (state.running &&
        (state.configId == id || collection.selectedId == id)) {
      throw const ConfigFailure('请先停止接管，再删除当前使用的配置。');
    }
    final remaining = collection.entries
        .where((entry) => entry.id != id)
        .toList();
    await store.save(
      ConfigCollection(
        entries: remaining,
        mode: collection.mode,
        selectedId: collection.selectedId == id
            ? remaining.firstOrNull?.id
            : collection.selectedId,
      ),
    );
    if (!state.running &&
        state.core.purpose == 'PREVIEW' &&
        state.core.configId == id) {
      await platform.releasePreview();
    }
    return '配置已删除，未启动接管。';
  }

  Future<String> _setMode(
    ConfigCollection collection,
    AppSnapshot state,
    TunnelMode mode,
  ) async {
    if (collection.mode != mode) {
      await store.save(
        ConfigCollection(
          entries: collection.entries,
          selectedId: collection.selectedId,
          mode: mode,
        ),
      );
    }
    if (!state.running) return '模式已保存，下次启动生效。';
    if (state.mode == mode) return '运行模式已确认。';
    try {
      await platform.stage('正在切换运行模式');
      final actual = await platform.setMode(mode, state.generation);
      if (actual != mode) throw const FormatException('Mode not confirmed');
    } catch (_) {
      throw const ConfigFailure('模式已保存供下次启动使用；本次切换未确认。');
    }
    return '运行模式已切换。';
  }

  Future<void> _start(ConfigEntry entry, TunnelMode mode) async {
    if (entry.body == null) throw const ConfigFailure('该配置没有可用正文，请重新导入更新。');
    await platform.stage('正在等待 VPN 授权');
    if (!await platform.authorize()) throw const ConfigFailure('授权已取消，接管保持停止。');
    await platform.stage('正在启动接管');
    final input = CoreInput(runInput);
    try {
      await input.write(entry, mode);
      await platform.start(id: entry.id, revision: entry.revision, mode: mode);
    } finally {
      await input.clear();
    }
  }

  ConfigEntry _entry(ConfigCollection collection, String id) =>
      collection.find(id) ?? (throw const ConfigFailure('配置已不存在，请刷新列表。'));

  String _name(String? value, String source) {
    final name = value?.trim() ?? '';
    return name.isEmpty ? Uri.parse(source).host : name;
  }
}
