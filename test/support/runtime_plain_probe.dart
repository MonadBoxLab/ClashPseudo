import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/app_runtime.dart';
import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/platform_port.dart';
import 'package:clash_pseudo/src/platform/core/core_client.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

class _Port implements PlatformPort {
  _Port(this.directory);
  final Directory directory;
  final calls = <String>[];
  bool hangStatus = false;

  @override
  Future<T?> invoke<T>(String method, [Object? arguments]) async {
    calls.add(method);
    final Object? value;
    switch (method) {
      case ApplicationContract.coreChannelStatus:
        if (hangStatus) return Completer<T?>().future;
        value = {'phase': 'disconnected', 'generation': 0};
      case 'paths':
        value = {
          'configs': directory.path,
          'runInput': '${directory.path}/run.input',
          'storageEpoch': 0,
        };
      case 'publishStore':
        final name = (arguments as Map)['file'] as String;
        await File('${directory.path}/$name.tmp')
            .rename('${directory.path}/$name');
        value = {'saved': true, 'durable': true, 'epoch': 0};
      case 'checkOperation':
      case 'refreshStrings':
        value = null;
      default:
        throw PlatformFailure(
          code: 'unexpected',
          details: {'method': method, 'arguments': arguments},
        );
    }
    return value as T?;
  }
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'pseudo-runtime-plain-',
  );
  final port = _Port(directory);
  final platform = AppPlatform(port: port, coreClient: CoreClient(port));
  final runtime = AppRuntime(platform);
  try {
    await runtime.start();
    port.calls.clear();
    port.hangStatus = true;
    final memory = jsonDecode(
      await runtime.handle('appMemory', const {}) as String,
    ) as Map;
    require(
      memory['valid'] == true && (memory['processRssBytes'] as int) >= 0,
      'app RSS was not returned',
    );
    require(
      port.calls.isEmpty,
      'app RSS read core status or started a process',
    );
    final result = await runtime.handle('execute', {
      'owner': 'plain-operation',
      'admittedAt': 7,
      'deadline': 60007,
      'action': 'setPreference',
      'field': 'appearance',
      'value': 'dark',
    }) as Map;
    require(
      result['success'] == true,
      'Store save without Binding failed: $result',
    );
    final saved = jsonDecode(
      await File('${directory.path}/preferences.json').readAsString(),
    ) as Map;
    require(saved['appearance'] == 'dark', 'Actions did not save preferences');
    require(
      !port.calls.contains(ApplicationContract.coreChannelHandshake),
      'Save started the core',
    );
    port.hangStatus = false;
    var rejected = false;
    try {
      await runtime.handle('coreMemory', {'processId': 'missing-core'});
    } on PlatformFailure catch (error) {
      rejected = error.code == ApplicationContract.coreErrorIdentityMismatch;
    }
    require(rejected, 'core memory did not reject an exited identity');
    require(
      !port.calls.contains(ApplicationContract.coreChannelHandshake),
      'core memory created a process',
    );
    stdout.writeln(
      'plain Dart runtime: app RSS, Actions/Store save, and existing-core identity checks passed',
    );
  } finally {
    runtime.dispose();
    await directory.delete(recursive: true);
  }
}
