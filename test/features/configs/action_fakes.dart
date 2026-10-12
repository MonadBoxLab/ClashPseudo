import 'dart:async';

import 'package:clash_pseudo/features/configs/config_downloader.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/services.dart';

class DownloadFake extends ConfigDownloader {
  String body = 'rules:\n  - MATCH,DIRECT\n';
  bool fail = false;
  int calls = 0;
  Completer<String>? pending;
  final started = Completer<void>();

  @override
  Future<String> download(String source, {required bool allowHttp}) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (fail) throw const ConfigFailure('下载失败');
    return pending == null ? body : pending!.future;
  }
}

class PlatformFake extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final events = <String>[];
  bool grant = true;
  bool failStart = false;
  bool failStop = false;

  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<void> stage(String message) async {}
  @override
  Future<bool> authorize() async {
    events.add('authorize');
    return grant;
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    if (failStop) {
      state = const AppSnapshot(phase: 'UNKNOWN');
      throw PlatformException(code: 'cleanup', message: '停止未确认');
    }
    state = const AppSnapshot(phase: 'STOPPED');
  }

  @override
  Future<void> start({required String id, required int revision}) async {
    events.add('start:$id');
    if (failStart) throw PlatformException(code: 'start', message: '配置无法启动');
    state = AppSnapshot(phase: 'RUNNING', configId: id, revision: revision);
  }
}
