import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../features/connections/connection_snapshot.dart';
import '../features/overview/traffic_window.dart';
import '../features/mode/tunnel_mode.dart';
import '../features/strategies/strategy_choice.dart';
import '../features/strategies/strategy_snapshot.dart';
import '../l10n/messages.dart';
import '../model/application_contract.dart';
import '../model/operation_admission.dart';

class AppBridge {
  AppBridge({this.operationId});

  static const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
  final String? operationId;
  final _cancelled = Completer<void>();
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) {
    if (_cancelled.isCompleted) {
      return Future.error(
        PlatformException(
          code: 'expired',
          details: messages.operationFinished.toMap(),
        ),
      );
    }
    final pending = channel.invokeMethod<T>(method, {
      ...?arguments,
      if (operationId != null) 'owner': operationId,
    });
    if (operationId == null) return pending;
    return Future.any([
      pending,
      _cancelled.future.then<T?>(
        (_) => throw PlatformException(
          code: 'expired',
          details: messages.operationFinished.toMap(),
        ),
      ),
    ]);
  }

  /// Re-reads the saved language for Android-owned notification text.
  /// Application messages remain untranslated until displayed.
  Future<void> refreshStrings() async {
    if (operationId == null) return;
    await _call<void>('refreshStrings');
  }

  Future<void> checkOperation() async {
    if (operationId != null) await _call<void>('checkOperation');
  }

  Future<Duration> operationRemaining() async {
    final milliseconds = await _call<int>('operationRemaining');
    if (milliseconds == null ||
        milliseconds < 0 ||
        milliseconds > ApplicationContract.operationBackupTimeoutMs) {
      throw const FormatException('Invalid operation budget');
    }
    return Duration(milliseconds: milliseconds);
  }

  Future<void> uiReady() => _call<void>('uiReady');

  Future<Map<String, dynamic>> paths() async =>
      Map<String, dynamic>.from(await _call<Map>('paths') ?? {});

  Future<bool> publishStore(String file, int epoch) async {
    if (operationId == null || _cancelled.isCompleted) {
      throw PlatformException(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    // Cancellation and rename arbitrate natively. Once submitted, wait for the
    // actual publication result; Future.any would hide a commit that won first.
    final value = await channel.invokeMethod<Map>('publishStore', {
      'owner': operationId,
      'file': file,
      'epoch': epoch,
    });
    if (value?['saved'] != true ||
        value?['epoch'] is! int ||
        value?['epoch'] != epoch ||
        value?['durable'] is! bool) {
      throw PlatformException(
        code: 'storage',
        details: messages.storageUnavailable.toMap(),
      );
    }
    return value!['durable'] as bool;
  }

  Future<Map<String, dynamic>> backupPrepareExport({
    required String requestId,
    required int createdAtMillis,
    required int expectedEpoch,
    required Map<String, String> defaults,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('backupPrepareExport', {
          'requestId': requestId,
          'createdAtMillis': createdAtMillis,
          'expectedEpoch': expectedEpoch,
          'defaults': defaults,
        }) ??
        {},
  );

  Future<Map<String, dynamic>> backupCandidate(String token) async =>
      Map<String, dynamic>.from(
        await _call<Map>('backupCandidate', {'token': token}) ?? {},
      );

  Future<Map<String, dynamic>> backupInstall(
    String token, {
    required int expectedEpoch,
  }) async {
    if (operationId == null || _cancelled.isCompleted) {
      throw PlatformException(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    // Preserve the actual committed restore result through Dart waiter cancellation.
    final value = await channel.invokeMethod<Map>('backupInstall', {
      'owner': operationId,
      'token': token,
      'expectedEpoch': expectedEpoch,
    });
    return Map<String, dynamic>.from(value ?? {});
  }

  Future<Map<String, dynamic>> backupPickImport(String requestId) async =>
      Map<String, dynamic>.from(
        await _call<Map>('backupPickImport', {'requestId': requestId}) ?? {},
      );

  Future<Map<String, dynamic>> backupSaveExport({
    required String requestId,
    required String token,
    required String title,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('backupSaveExport', {
          'requestId': requestId,
          'token': token,
          'title': title,
        }) ??
        {},
  );

  Future<void> backupCancel(String requestId) =>
      _call<void>('backupCancel', {'requestId': requestId});

  Future<void> backupDiscard(String token) =>
      _call<void>('backupDiscard', {'token': token});

  Future<Uint8List> trustRoots() async {
    final roots = await _call<Uint8List>('trustRoots');
    if (roots == null) {
      throw PlatformException(
        code: 'trust',
        details: const AppMessage('trustedRootsUnavailable').toMap(),
      );
    }
    return roots;
  }

  Future<Map<String, dynamic>> applicationInfo() async =>
      Map<String, dynamic>.from(await _call<Map>('appInfo') ?? {});

  Future<AppSnapshot> snapshot() async => AppSnapshot.fromMap(
    Map<String, dynamic>.from(await _call<Map>('snapshot') ?? {}),
  );

  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    final Map<String, Object?> request;
    if (const [
      'saveLocalDefinition',
      'deleteLocalDefinition',
    ].contains(command['action'])) {
      final payload = <String, Object?>{
        for (final entry in command.entries)
          if (!const ['action', 'storageEpoch', 'owner'].contains(entry.key))
            entry.key: entry.value,
      };
      request = {
        'action': command['action'],
        if (command.containsKey('storageEpoch'))
          'storageEpoch': command['storageEpoch'],
        // Validate nested strings and mapping keys as well as the final YAML body.
        'definitionPayload': utf8.encode(jsonEncode(payload)),
      };
    } else {
      request = {
        ...command,
        // StandardMessageCodec's string decoder consumes a leading UTF-8 BOM.
        if (command['action'] == 'saveLocal' ||
            command['action'] == 'saveOverride')
          'body': utf8.encode(command['body'] as String),
      };
    }
    final value = await _call<Map>('submit', request);
    return value == null ? null : OperationAdmission.fromMap(value);
  }

  Future<void> stage(AppMessage message) =>
      _call<void>('stage', {'message': message.toMap()});
  Future<bool> authorize() async => await _call<bool>('authorize') ?? false;
  Future<void> stop() => _call<void>('stop');
  Future<void> finishScheduledDownload(
    AppSnapshot expected, {
    required String kind,
    required String id,
  }) => _call<void>('finishScheduledDownload', {
    'kind': kind,
    'id': id,
    'sessionGeneration': expected.generation,
    'generation': expected.core.generation,
    'composition': expected.core.composition,
    'configId': expected.configId,
    'revision': expected.revision,
  });
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
  }) => _call<void>('start', {
    'id': id,
    'revision': revision,
    'mode': mode?.name,
  });
  Future<StrategySnapshot> strategies(int generation) async {
    final value = await _call<String>('strategies', {'generation': generation});
    return StrategySnapshot.fromMap(jsonDecode(value!) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> nodes(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('nodes', {
      'generation': core.generation,
      'composition': core.composition,
      'query': query,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> rules(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('rules', {
      'generation': core.generation,
      'composition': core.composition,
      'query': query,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> runtimeConfiguration(CoreSnapshot core) async {
    final value = await _call<String>('runtimeConfig', {
      'generation': core.generation,
      'composition': core.composition,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  /// Owner-controlled, memory-only input of the actual running lease for an isolated
  /// periodic update.
  Future<Map<String, dynamic>> runningInput(CoreSnapshot core) async {
    final value = await _call<Uint8List>('runningInput', {
      'generation': core.generation,
      'composition': core.composition,
    });
    return jsonDecode(utf8.decode(value!)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> resources(CoreSnapshot core) async {
    final value = await _call<String>('resources', {
      'generation': core.generation,
      'composition': core.composition,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startDelayTest(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('delayStart', {
      'generation': core.generation,
      'composition': core.composition,
      'query': query,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    final value = await _call<String>('delayRead', {
      'generation': core.generation,
      'composition': core.composition,
      'batch': batch,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<void> cancelDelayTest(String batch) =>
      _call<void>('delayCancel', {'batch': batch});

  Future<Map<String, dynamic>> logs(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('logs', {
      'generation': core.generation,
      'composition': core.composition,
      'query': {...query, 'window': core.logWindow},
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateResource(
    CoreSnapshot core, {
    required String kind,
    required String name,
  }) async {
    final value = await _call<String>('updateResource', {
      'generation': core.generation,
      'composition': core.composition,
      'configId': core.configId,
      'revision': core.revision,
      'purpose': core.purpose,
      'query': {'kind': kind, 'name': name},
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<TrafficSnapshot> traffic() async {
    final value = await _call<Map>('traffic');
    return TrafficSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<Map<String, dynamic>> processMemory() async {
    final value = await _call<String>('processMemory');
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Map<String, Object?> _dnsIdentity(CoreSnapshot core) => {
    'generation': core.generation,
    'composition': core.composition,
    'configId': core.configId,
    'revision': core.revision,
    'purpose': core.purpose,
  };

  Future<Map<String, dynamic>> dnsQuery(
    CoreSnapshot core, {
    required String name,
    required String type,
    required String queryOwner,
  }) async {
    final value = await _call<String>('dnsQuery', {
      ..._dnsIdentity(core),
      'queryOwner': queryOwner,
      'query': {'name': name, 'type': type},
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> clearDnsCache(CoreSnapshot core) async {
    final value = await _call<String>('clearDnsCache', _dnsIdentity(core));
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> flushFakeIp(CoreSnapshot core) async {
    final value = await _call<String>('flushFakeIp', _dnsIdentity(core));
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<void> cancelDnsQuery(
    CoreSnapshot core, {
    required String queryOwner,
  }) => _call<void>('cancelDnsQuery', {
    ..._dnsIdentity(core),
    'queryOwner': queryOwner,
  });

  Future<void> releaseConnectionDetail() => _call<void>('releaseDetail');

  Future<List<Map<String, dynamic>>> applications() async {
    final value = await _call<List>('applications') ?? const [];
    return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  /// One installed application's icon as PNG bytes, or null when unavailable.
  Future<Uint8List?> applicationIcon(String package) async {
    final value = await _call<Uint8List>('applicationIcon', {
      'package': package,
    });
    return value;
  }

  Future<Map<String, dynamic>> vpnStatus() async =>
      Map<String, dynamic>.from(await _call<Map>('vpnStatus') ?? {});

  Future<void> openVpnSettings() => _call<void>('openVpnSettings');

  /// Publishes the enabled remote targets; the platform keeps one unique
  /// periodic task per target and cancels everything missing from this list.
  Future<void> syncSchedules(List<Map<String, Object?>> targets) =>
      _call<void>('syncSchedules', {'targets': targets});

  Future<Map<String, dynamic>> refreshSchedule({
    required String kind,
    required String id,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('refreshSchedule', {'kind': kind, 'id': id}) ?? {},
  );

  Future<Map<String, dynamic>> runtimeState() async =>
      Map<String, dynamic>.from(await _call<Map>('runtimeState') ?? {});

  Future<void> retainObservation(bool value) =>
      _call<void>('retain', {'value': value});

  Future<Map<String, dynamic>> sampleConnections(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('sampleConnections', {
      'generation': core.generation,
      'configId': core.configId,
      'revision': core.revision,
      'query': query,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
  }) async {
    final value = await _call<Map>('connections', {'detail': detail});
    return ConnectionSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<String> closeConnection(CoreSnapshot core, String id) async {
    final value = await _call<String>('closeConnection', {
      'generation': core.generation,
      'configId': core.configId,
      'revision': core.revision,
      'connectionId': id,
    });
    return (jsonDecode(value!) as Map<String, dynamic>)['status'] as String;
  }

  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode? mode,
  }) => _call<void>('prepareStrategies', {
    'id': id,
    'revision': revision,
    'mode': mode?.name,
  });
  Future<void> releasePreview() => _call<void>('releasePreview');
  Future<void> setStrategy(
    int generation,
    String name,
    StrategyChoice choice,
  ) => _call<void>('setStrategy', {
    'generation': generation,
    'name': name,
    'choice': choice.toJson(),
  });

  Future<TunnelMode> setMode(TunnelMode mode, int generation) async =>
      TunnelMode.parse(
        await _call<String>('setMode', {
          'mode': mode.name,
          'generation': generation,
        }),
      );
}
