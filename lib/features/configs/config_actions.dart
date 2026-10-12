import 'dart:io';
import 'dart:math';

import '../../platform/app_bridge.dart';
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
        await _start(selected);
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
      await _start(collection.selected!);
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
      ConfigCollection(entries: collection.entries, selectedId: id),
    );
    if (state.running) {
      await _start(entry);
      return '已切换接管配置。';
    }
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
        selectedId: collection.selectedId == id
            ? remaining.firstOrNull?.id
            : collection.selectedId,
      ),
    );
    return '配置已删除，未启动接管。';
  }

  Future<void> _start(ConfigEntry entry) async {
    if (entry.body == null) throw const ConfigFailure('该配置没有可用正文，请重新导入更新。');
    await platform.stage('正在等待 VPN 授权');
    if (!await platform.authorize()) throw const ConfigFailure('授权已取消，接管保持停止。');
    await platform.stage('正在启动接管');
    await runInput.parent.create(recursive: true);
    try {
      await runInput.writeAsString(entry.body!, flush: true);
      await platform.start(id: entry.id, revision: entry.revision);
    } finally {
      if (await runInput.exists()) await runInput.delete();
    }
  }

  ConfigEntry _entry(ConfigCollection collection, String id) =>
      collection.find(id) ?? (throw const ConfigFailure('配置已不存在，请刷新列表。'));

  String _name(String? value, String source) {
    final name = value?.trim() ?? '';
    return name.isEmpty ? Uri.parse(source).host : name;
  }
}
