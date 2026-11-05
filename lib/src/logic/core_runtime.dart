import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/platform_failure.dart';

import '../model/application_contract.dart';
import '../model/core_snapshot.dart';
import '../model/dns_snapshot.dart';
import '../model/config_entry.dart';
import '../model/messages.dart';
import '../model/strategy_choice.dart';
import '../model/strategy_snapshot.dart';
import '../model/app_platform.dart';
import '../platform/core/core_client.dart';
import 'diagnostics/core_collection_page.dart';
import 'diagnostics/dns_operations.dart';
import 'diagnostics/log_window.dart';
import 'strategies/delay_batches.dart';
import 'overrides/lan_proxy_settings.dart';
import '../platform/core/core_input.dart';

/// 唯一 AppRuntime 的内核操作协调，不参与界面草稿与导航生命周期。
class CoreRuntime implements RuntimeCore {
  CoreRuntime(this.platform, {required this.changed, required this.client}) {
    dns = DnsOperations(_begin, changed: changed);
    delays = DelayBatches(_begin, strategies, changed: changed);
  }

  final AppPlatform platform;
  final void Function() changed;
  final CoreClient client;
  late final DnsOperations dns;
  late final DelayBatches delays;
  final logs = LogWindow();
  Map<String, dynamic>? _input;
  CoreSnapshot? _inputSource;
  Object? _cancelledRefresh;
  CoreSnapshot? _logSource;
  CoreCall? _logCall;
  Object? logError;
  final _unrestored = <String, String>{};
  Map<String, Object?>? _mode;
  String? _restoredProcess;
  Future<void>? _restoreFlight;
  Map<String, dynamic>? _refresh;
  bool _refreshAdmitting = false;
  bool _refreshQueued = false;
  Timer? _refreshRetry;
  final _readFlights = <String, CoreSnapshot>{};

  Future<Object?> _diagnosticRead(
    String method,
    CoreSnapshot source,
    AppPlatform operation,
    Future<Object?> Function(
      Map<String, int> timing,
      void Function()? beforeSubmit,
    )
    read,
  ) async {
    final pending = _readFlights[method];
    if (pending != null) {
      return jsonEncode({...envelope(pending), 'readPending': true});
    }
    _readFlights[method] = source;
    final close = method == 'closeConnection';
    final reply = Completer<Object?>();
    var queued = close;
    Timer? deadlineTimer;
    StreamSubscription<void>? cancellation;
    Stopwatch? clock;
    Duration? budget;

    PlatformFailure expired() => PlatformFailure(
      code: 'expired',
      details: messages.operationFinished.toMap(),
    );
    void expire() {
      if (queued && !reply.isCompleted) reply.completeError(expired());
    }

    void beforeSubmit() {
      operation.checkCancellation();
      if (reply.isCompleted || (budget != null && clock!.elapsed >= budget!)) {
        throw expired();
      }
      // 提交后由 receipt 和实际退出决定结果，取消不能覆盖 native 的结果。
      queued = false;
      deadlineTimer?.cancel();
    }

    if (close) {
      cancellation = operation.whenCancelled.asStream().listen((_) => expire());
    }
    final work = () async {
      try {
        await operation.checkOperation();
        final state = await platform.snapshot();
        if (!source.matchesIdentity(state.core) ||
            source.networkRevision != state.core.networkRevision) {
          throw PlatformFailure(
            code: ApplicationContract.coreErrorIdentityMismatch,
          );
        }
        final timing = operation.operationId == null
            ? <String, int>{
                'admittedAt': state.elapsedRealtimeMs ?? 0,
                'deadline':
                    (state.elapsedRealtimeMs ?? 0) +
                    ApplicationContract.operationOrdinaryTimeoutMs,
              }
            : await operation.operationTiming();
        if (close) {
          budget = Duration(
            milliseconds:
                timing['deadline']! -
                (state.elapsedRealtimeMs ?? 0) -
                state.uptimeSampleAgeMilliseconds,
          );
          clock = Stopwatch()..start();
          deadlineTimer = Timer(budget!, expire);
        }
        await operation.checkOperation();
        return await read(timing, close ? beforeSubmit : null);
      } finally {
        deadlineTimer?.cancel();
        clock?.stop();
        await cancellation?.cancel();
        // 业务应答可以提前结束，slot 只随实际 work 释放。
        _readFlights.remove(method);
      }
    }();
    if (!close) return work;
    operation.retainUntil(
      work.then<void>(
        (value) {
          if (!reply.isCompleted) reply.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!reply.isCompleted) reply.completeError(error, stack);
        },
      ),
    );
    return reply.future;
  }

  Future<bool> _readStale(CoreSnapshot source) async {
    final current = (await platform.snapshot()).core;
    return !current.ready ||
        !source.matchesIdentity(current) ||
        source.networkRevision != current.networkRevision;
  }

  bool refreshCurrent(Map<String, dynamic> command) {
    final pending = _refresh;
    return pending != null &&
        pending['processId'] == command['processId'] &&
        pending['inputId'] == command['inputId'] &&
        (pending['networkChanged'] == true ||
            pending['specificationChanged'] == true);
  }

  void refreshFinished() {
    _refreshQueued = false;
    unawaited(flushRefresh());
  }

  Future<void> flushRefresh() async {
    if (_refresh == null || _refreshAdmitting || _refreshQueued) return;
    _refreshRetry?.cancel();
    _refreshAdmitting = true;
    try {
      final state = await platform.snapshot();
      final pending = _refresh;
      if (pending == null) return;
      if (pending['processId'] != state.core.processId ||
          pending['inputId'] != state.core.inputId ||
          state.recoveryRequired) {
        _refresh = null;
        return;
      }
      if (pending['networkChanged'] != true &&
          pending['specificationChanged'] != true) {
        return;
      }
      if (state.busy || !state.core.ready) {
        _refreshRetry = Timer(
          const Duration(milliseconds: 100),
          () => unawaited(flushRefresh()),
        );
        return;
      }
      if (!state.forwarding &&
          state.core.purpose != ApplicationContract.corePurposePreview) {
        return;
      }
      _refreshQueued = true;
      final admission = await platform.submit({
        'action': 'refreshRuntime',
        ...envelope(state.core),
        'sessionGeneration': state.generation,
        'storageEpoch': state.storageEpoch,
      });
      if (admission == null) _refreshQueued = false;
    } on PlatformFailure catch (error) {
      _refreshQueued = false;
      if (error.code == 'busy') {
        _refreshRetry = Timer(
          const Duration(milliseconds: 100),
          () => unawaited(flushRefresh()),
        );
      } else {
        _refresh = null;
        logError = error;
        changed();
      }
    } finally {
      _refreshAdmitting = false;
    }
  }

  void _refreshEvent(Map<String, dynamic> event) {
    if (event['event'] == 'cancelRefresh') {
      final source = _inputSource;
      if (source == null ||
          event['processId'] != source.processId ||
          event['inputId'] != source.inputId ||
          event['generation'] != source.generation ||
          event['networkRevision'] != source.networkRevision) {
        return;
      }
      _cancelledRefresh = source.identity;
      _refresh = null;
      _refreshRetry?.cancel();
      return;
    }
    final kind = event['event'];
    if (kind != 'networkChanged' && kind != 'specificationChanged') return;
    if (_cancelledRefresh == _inputSource?.identity) return;
    if (event['processId'] != _inputSource?.processId ||
        event['inputId'] != _input?['inputId']) {
      return;
    }
    final revisionKey = kind == 'networkChanged'
        ? 'nextNetworkRevision'
        : 'specificationRevision';
    final revision = event[revisionKey];
    if (revision is! int || event['changed'] is! bool) return;
    final pending =
        _refresh ??
        {'processId': event['processId'], 'inputId': event['inputId']};
    final previous = pending[revisionKey];
    if (previous is int && revision < previous) return;
    _refresh = {
      ...pending,
      revisionKey: revision,
      kind as String: event['changed'],
    };
  }

  Future<void> refreshPreview(AppPlatform operation, File file) async {
    final source = (await operation.snapshot()).core;
    final record = await _readInput(source);
    if (record == null) throw ConfigFailure(messages.coreContextUnconfirmed);
    await CoreInput(file)
        .writeRecord({...record, 'inputId': CoreInput.newInputId()});
    try {
      await _prepare(
        {
          'owner': operation.operationId,
          'admittedAt': operation.admittedAt,
          'deadline': operation.deadline,
          'id': record['id'],
          'revision': record['revision'],
          'path': file.path,
          'force': true,
          'explicitStart': false,
        },
        preview: true,
        operation: operation,
      );
    } finally {
      await CoreInput(file).clear();
    }
  }

  Future<void> restoreExisting() async {
    final status = await client.status();
    final source = CoreSnapshot.fromMap(status);
    if (!source.ready || !source.hasIdentity) return;
    try {
      await _restoreExisting(source);
    } catch (error) {
      logError = error;
      final current = (await platform.snapshot()).core;
      if (current.ready && source.matchesIdentity(current)) {
        _mode = {
          ...envelope(source),
          'actual': null,
          'fallback': _input?['mode'],
          'error': messages.coreContextUnconfirmed.withDetail(error).toMap(),
        };
      }
      changed();
    }
  }

  Future<void> _restoreExisting(CoreSnapshot source) async {
    if (_restoredProcess == source.processId) return;
    final flight = _restoreFlight;
    if (flight != null) {
      await flight;
      if (_restoredProcess == source.processId) return;
    }
    final work = () async {
      _requireSuccess(
        await _result(source, ApplicationContract.coreOperationSnapshot),
      );
      final current = (await platform.snapshot()).core;
      if (!current.ready || !source.matchesIdentity(current)) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorIdentityMismatch,
        );
      }
      await _readInput(source);
      await _readMode(source);
      final after = (await platform.snapshot()).core;
      if (!after.ready || !source.matchesIdentity(after)) return;
      if (_logCall?.identity.processId != source.processId) {
        await _subscribeLogs(source);
      }
      _restoredProcess = source.processId;
    }();
    _restoreFlight = work;
    try {
      await work;
    } finally {
      if (_restoreFlight == work) _restoreFlight = null;
    }
  }

  Object? _freeze(Object? value) => switch (value) {
    Map() => Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, _freeze(item))),
    ),
    List() => List<Object?>.unmodifiable(value.map(_freeze)),
    _ => value,
  };

  bool get retained =>
      dns.busy || delays.busy || _logCall != null || logs.hasWindow;
  Map<String, Object?> get projection => {
    'retain': retained,
    'dnsBusy': dns.busy,
    'dnsOperation': dns.snapshot(),
    if (_mode != null) 'mode': _mode,
    if (_logSource != null) 'logSource': envelope(_logSource!),
  };

  Map<String, Object?> envelope(CoreSnapshot source) => {
    'processId': source.processId,
    'inputId': source.inputId,
    'generation': source.generation,
    'configId': source.configId,
    'revision': source.revision,
    'composition': source.composition,
    'purpose': source.purpose,
    'phase': source.phase,
    'networkRevision': source.networkRevision,
    'networkEpoch': source.networkRevision,
    if (source.logWindow != null) 'logWindow': source.logWindow,
  };

  CoreIdentity identity(CoreSnapshot source) => CoreIdentity(
    processId: source.processId ?? '',
    generation: source.generation,
    inputId: source.inputId,
    composition: source.composition,
    networkRevision: source.networkRevision,
  );

  Future<CoreCall> _begin(
    int operation,
    CoreSnapshot source,
    Map<String, Object?> arguments,
  ) => client.submit(operation, identity(source), arguments: arguments);

  Future<CoreResult> _result(
    CoreSnapshot source,
    int opcode, {
    Map<String, Object?> arguments = const {},
    int maximumBytes = ApplicationContract.coreIpcFrameBytes,
    String? owner,
    AppPlatform? operation,
    void Function()? beforeSubmit,
  }) async {
    final authority = operation?.operationId == null ? null : operation;
    if (authority != null) await authority.checkOperation();
    final timing = authority == null
        ? const <String, int>{}
        : await authority.operationTiming();
    final requestedDeadline = arguments['deadline'];
    final originalDeadline = timing['deadline'];
    if (beforeSubmit != null) {
      final state = await platform.snapshot();
      final current = state.core;
      if (!current.ready ||
          !source.matchesIdentity(current) ||
          source.networkRevision != current.networkRevision) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorIdentityMismatch,
        );
      }
      if (originalDeadline != null &&
          state.elapsedRealtimeMs != null &&
          state.elapsedRealtimeMs! >= originalDeadline) {
        throw PlatformFailure(
          code: 'expired',
          details: messages.operationFinished.toMap(),
        );
      }
      beforeSubmit();
    }
    final call = await client.submit(
      opcode,
      identity(source),
      arguments: {
        ...arguments,
        ...timing,
        if (requestedDeadline is int &&
            originalDeadline is int &&
            requestedDeadline < originalDeadline)
          'deadline': requestedDeadline,
      },
      owner: owner,
    );
    return call.result(maximumBytes: maximumBytes);
  }

  Future<CoreSnapshot> _source(Map<String, Object?> arguments) async {
    final state = await platform.snapshot();
    final source = state.core;
    if (!source.ready ||
        !source.hasIdentity ||
        source.processId?.isNotEmpty != true ||
        source.inputId?.isNotEmpty != true ||
        !source.matchesWireIdentity(Map<String, dynamic>.from(arguments)) ||
        arguments['networkRevision'] != source.networkRevision) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorIdentityMismatch,
      );
    }
    await _restoreExisting(source);
    return source;
  }

  @override
  Future<Map<String, dynamic>?> inputFor(CoreSnapshot source) async {
    if (source.purpose != ApplicationContract.corePurposeRunning) return null;
    return _readInput(source);
  }

  Future<Map<String, dynamic>?> _readInput(CoreSnapshot source) async {
    if (!source.ready || source.inputId == null || source.processId == null) {
      return null;
    }
    final cached = _input;
    if (cached != null &&
        _inputSource?.processId == source.processId &&
        cached['inputId'] == source.inputId &&
        cached['composition'] == source.composition) {
      return cached;
    }
    final record = await client.readRunInputRecord(source.inputId!);
    if (record['inputId'] != source.inputId ||
        record['saved'] != true ||
        record['path'] is! String) {
      return null;
    }
    final input = jsonDecode(
      await File(record['path'] as String).readAsString(),
    );
    if (input is! Map<String, dynamic> ||
        input['inputId'] != source.inputId ||
        input['composition'] != source.composition ||
        input['id'] != source.configId ||
        input['revision'] != source.revision) {
      return null;
    }
    _input = _freeze(input) as Map<String, dynamic>;
    _inputSource = source;
    return _input;
  }

  @override
  Future<Object?> read(
    String method,
    Map<String, Object?> arguments, {
    AppPlatform? operation,
  }) async {
    operation ??= platform.forOperation(
      operationId: arguments['owner'] as String?,
      admittedAt: arguments['admittedAt'] as int?,
      deadline: arguments['deadline'] as int?,
    );
    if (method == 'setMode' &&
        !const ['rule', 'global', 'direct'].contains(arguments['mode'])) {
      throw FormatException('运行模式无效', arguments['mode']);
    }
    if (const ['start', 'prepareStrategies'].contains(method) &&
        arguments['mode'] != null &&
        !const ['rule', 'global', 'direct'].contains(arguments['mode'])) {
      throw FormatException('运行模式无效', arguments['mode']);
    }
    if (const ['dnsQuery', 'cancelDnsQuery'].contains(method)) {
      final queryOwner = arguments['queryOwner'];
      if (queryOwner is! String ||
          queryOwner.isEmpty ||
          utf8.encode(queryOwner).length > 128) {
        throw const DnsFailure('invalidRequest', detail: 'DNS queryOwner 无效');
      }
    }
    switch (method) {
      case 'start':
        await _prepare(arguments, preview: false, operation: operation);
        return null;
      case 'prepareStrategies':
        return _prepare(arguments, preview: true, operation: operation);
      case 'stop':
        await _stop(arguments, operation: operation);
        return null;
      case 'systemRevoked':
        return _stop(arguments, operation: operation, revoked: true);
      case 'releasePreview':
        final state = await platform.snapshot();
        if (state.core.purpose == ApplicationContract.corePurposePreview) {
          await _exit(
            state.core,
            arguments,
            reason: 'previewExpired',
            operation: operation,
          );
        }
        return null;
      case 'coreCleanupCandidates':
        return _cleanupCandidates();
      case 'appMemory':
        return jsonEncode(_appMemory());
      case 'coreMemory':
        return jsonEncode(await _coreMemory(arguments['processId'] as String?));
      case 'cancelDnsQuery':
        final captured = CoreSnapshot.fromMap({...arguments, 'phase': 'READY'});
        await dns.cancel(captured, arguments['queryOwner'] as String);
        return null;
      case 'delayRead':
        return jsonEncode(await delays.read(arguments['batch'] as String));
      case 'delayCancel':
        await delays.cancel(arguments['batch'] as String);
        return null;
      case 'logs':
        final query = Map<String, Object?>.from(
          arguments['query'] as Map? ?? const {},
        );
        final source = _logSource;
        if (source == null || query['window'] != logs.source) {
          throw PlatformFailure(
            code: ApplicationContract.coreErrorIdentityMismatch,
          );
        }
        var captured = logs.snapshot();
        var capturedError = logError;
        if (query['clear'] == true) {
          await _clearLogs(source);
          if (logs.source == query['window']) {
            captured = logs.snapshot();
            capturedError = logError;
          }
        }
        final stale =
            await _readStale(source) || logs.source != query['window'];
        return jsonEncode({
          ...envelope(source),
          'logs': captured,
          'stale': stale,
          if (capturedError != null)
            'error': switch (capturedError) {
              Map() || String() => capturedError,
              _ => _failureValue(capturedError),
            },
        });
      default:
        final source = await _source(arguments);
        final owner = arguments['owner'] as String?;
        switch (method) {
          case 'strategies':
            return jsonEncode(await _strategyResponse(source));
          case 'nodes':
          case 'rules':
            return _diagnosticRead(
              method,
              source,
              operation,
              (timing, _) async => jsonEncode(
                await _page(source, method, arguments, timing: timing),
              ),
            );
          case 'delayStart':
            final query = Map<String, Object?>.from(arguments['query'] as Map);
            return jsonEncode(await delays.startBatch(source, query));
          case 'dnsQuery':
            final query = Map<String, Object?>.from(arguments['query'] as Map);
            final value = await dns.query(
              source,
              name: query['name'] as String,
              type: query['type'] as String,
              owner: arguments['queryOwner'] as String,
            );
            return _dnsReply(source, value);
          case 'clearDnsCache':
          case 'flushFakeIp':
            final value = await dns.clear(
              source,
              fakeIp: method == 'flushFakeIp',
              owner: 'cache-${DateTime.now().microsecondsSinceEpoch}',
            );
            return _dnsReply(source, value);
          case 'setStrategy':
            try {
              final result = await _result(
                source,
                ApplicationContract.coreOperationStrategySelect,
                arguments: {
                  'group': arguments['name'],
                  'choice': arguments['choice'],
                },
                owner: owner,
                operation: operation,
              );
              _requireSuccess(result);
              _unrestored.remove(arguments['name']);
              return null;
            } finally {
              changed();
            }
          case 'setMode':
            try {
              final result = await _result(
                source,
                ApplicationContract.coreOperationModeSet,
                arguments: {'mode': arguments['mode']},
                owner: owner,
                operation: operation,
              );
              _requireSuccess(result);
              final actual = result.object['mode'];
              if (!const ['rule', 'global', 'direct'].contains(actual)) {
                throw PlatformFailure(
                  code: ApplicationContract.coreErrorCallFailed,
                  details: {
                    'message': '内核返回的模式无效',
                    if (actual is String || actual is num || actual is bool)
                      'actual': actual,
                  },
                );
              }
              if (!source.matchesIdentity((await platform.snapshot()).core)) {
                if (actual != arguments['mode']) {
                  throw PlatformFailure(
                    code: ApplicationContract.coreErrorCallFailed,
                    details: {
                      ...envelope(source),
                      'expected': arguments['mode'],
                      'actual': actual,
                      'stale': true,
                      if (result.cancelError != null)
                        'cancelError': result.cancelError,
                      if (result.terminal['nativeReceipt'] != null)
                        'nativeReceipt': result.terminal['nativeReceipt'],
                    },
                  );
                }
                return actual;
              }
              return await _readMode(
                source,
                expected: arguments['mode'] as String,
                strict: true,
                notify: false,
              );
            } finally {
              changed();
            }
          case 'resources':
            return _diagnosticRead(method, source, operation, (
              timing,
              _,
            ) async {
              final call = await _begin(
                ApplicationContract.coreOperationResources,
                source,
                timing,
              );
              final resources = <Map<String, dynamic>>[];
              final metadata = <String, dynamic>{};
              Map<String, dynamic>? terminal;
              try {
                await for (final frame in call.frames()) {
                  if (frame.kind == ApplicationContract.coreIpcFrameMetadata) {
                    metadata.addAll(frame.object);
                  } else if (frame.kind ==
                      ApplicationContract.coreIpcFrameRecord) {
                    resources.add(frame.object);
                  } else if (frame.terminal) {
                    terminal = frame.object;
                  } else {
                    throw const FormatException('资源导出包含无效帧');
                  }
                }
                if (terminal != null) terminal = await call.finish(terminal);
                final token = terminal?['source'];
                if (terminal == null ||
                    terminal['complete'] != true ||
                    terminal['recordCount'] != resources.length ||
                    terminal['error'] != null ||
                    terminal['stale'] == true ||
                    token is! String ||
                    token.isEmpty ||
                    metadata['source'] != token) {
                  throw _exportFailure(
                    '资源导出来源变化或未完整返回',
                    metadata,
                    terminal,
                    resources.length,
                  );
                }
                return jsonEncode({
                  ...envelope(source),
                  'resources': resources,
                  'stale': await _readStale(source),
                  if (terminal['cancelError'] != null)
                    'cancelError': terminal['cancelError'],
                });
              } catch (error, stack) {
                return call.fail(error, stack);
              }
            });
          case 'runtimeConfig':
          case 'updateResource':
            return _diagnosticRead(method, source, operation, (
              timing,
              _,
            ) async {
              final query = Map<String, Object?>.from(
                arguments['query'] as Map? ?? const {},
              );
              final result = await _result(
                source,
                method == 'runtimeConfig'
                    ? ApplicationContract.coreOperationRuntimeConfig
                    : ApplicationContract.coreOperationResourceUpdate,
                arguments: {...query, ...timing},
                maximumBytes: method == 'runtimeConfig'
                    ? 4 * ApplicationContract.configurationTextBytes
                    : ApplicationContract.coreIpcFrameBytes,
                owner: owner,
                operation: operation,
              );
              _requireSuccess(result);
              final resultValue = result.value;
              if (method == 'runtimeConfig' && resultValue is! String) {
                throw const FormatException('运行配置不是文本');
              }
              final value = method == 'runtimeConfig'
                  ? <String, dynamic>{'configuration': resultValue}
                  : <String, dynamic>{
                      'update': resultValue is Map
                          ? {
                              for (final key in ['status', 'error', 'detail'])
                                if (resultValue.containsKey(key))
                                  key: resultValue[key],
                            }
                          : null,
                      if (resultValue != null && resultValue is! Map)
                        'updateType': resultValue.runtimeType.toString(),
                    };
              return jsonEncode({
                ...value,
                ...envelope(source),
                'stale': result.stale || await _readStale(source),
                if (result.cancelError != null)
                  'cancelError': result.cancelError,
                if (result.cancelError != null &&
                    result.terminal['nativeReceipt'] != null)
                  'nativeReceipt': result.terminal['nativeReceipt'],
              });
            });
          case 'sampleConnections':
          case 'closeConnection':
            return _diagnosticRead(method, source, operation, (
              timing,
              beforeSubmit,
            ) async {
              final opcode = method == 'sampleConnections'
                  ? ApplicationContract.coreOperationConnections
                  : ApplicationContract.coreOperationConnectionClose;
              final query = Map<String, Object?>.from(
                arguments['query'] as Map? ?? const {},
              );
              final sampledState = method == 'sampleConnections'
                  ? await platform.snapshot()
                  : null;
              var readTiming = timing;
              final authority = operation!;
              if (method == 'sampleConnections' &&
                  (query.containsKey('admittedAt') ||
                      query.containsKey('deadline'))) {
                final admittedAt = query['admittedAt'];
                final deadline = query['deadline'];
                if (admittedAt is! int ||
                    deadline is! int ||
                    admittedAt < 0 ||
                    deadline < admittedAt) {
                  throw const FormatException('连接采样没有有效的原受理时钟');
                }
                final originalDeadline = timing['deadline']!;
                final end = deadline < originalDeadline
                    ? deadline
                    : originalDeadline;
                final admitted = authority.operationId == null
                    ? admittedAt
                    : timing['admittedAt']!;
                if (sampledState!.elapsedRealtimeMs == null ||
                    end < admitted ||
                    sampledState.elapsedRealtimeMs! >= end) {
                  throw PlatformFailure(code: 'expired');
                }
                readTiming = {'admittedAt': admitted, 'deadline': end};
              }
              final observedAt = DateTime.now().millisecondsSinceEpoch;
              final result = await _result(
                source,
                opcode,
                arguments: method == 'closeConnection'
                    ? {'id': arguments['connectionId']}
                    : {...query, ...readTiming},
                maximumBytes: method == 'sampleConnections'
                    ? ApplicationContract.connectionResponseBytes
                    : ApplicationContract.coreIpcFrameBytes,
                owner: owner,
                operation: authority,
                beforeSubmit: beforeSubmit,
              );
              _requireSuccess(result);
              final value = result.value is Map
                  ? Map<String, dynamic>.from(result.value as Map)
                  : {'result': result.value};
              final sampleState = method == 'sampleConnections'
                  ? await platform.snapshot()
                  : null;
              if (sampleState != null &&
                  !source.matchesIdentity(sampleState.core)) {
                throw PlatformFailure(
                  code: ApplicationContract.coreErrorIdentityMismatch,
                );
              }
              return jsonEncode({
                ...value,
                ...envelope(source),
                if (sampleState != null) ...{
                  'elapsedMs': sampledState?.elapsedRealtimeMs,
                  'observedAt': observedAt,
                  'wallTimeMs': observedAt,
                  'sessionGeneration': sampleState.generation,
                },
                if (result.stale) 'stale': true,
                if (result.cancelError != null)
                  'cancelError': result.cancelError,
              });
            });
          default:
            throw UnsupportedError('AppRuntime 不支持 $method');
        }
    }
  }

  String _dnsReply(CoreSnapshot source, Map<String, dynamic> value) {
    final encoded = jsonEncode({...value, ...envelope(source)});
    final bytes = utf8.encode(encoded).length;
    if (bytes > ApplicationContract.dnsResultBytes) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorResultTooLarge,
        details: {
          ...envelope(source),
          'error':
              'DNS result exceeds ${ApplicationContract.dnsResultBytes} bytes',
          'actualBytes': bytes,
          'maximumBytes': ApplicationContract.dnsResultBytes,
          'result': value,
        },
      );
    }
    return encoded;
  }

  Object? _failureValue(Object error) => switch (error) {
    PlatformFailure() => error.toMap(),
    ConfigFailure() => failureValue(error),
    FormatException() => {'message': error.message, 'offset': error.offset},
    _ => error.toString(),
  };

  PlatformFailure _exportFailure(
    String message,
    Map<String, dynamic> metadata,
    Map<String, dynamic>? terminal,
    int records,
  ) => PlatformFailure(
    code: ApplicationContract.coreErrorCallFailed,
    details: {
      'message': message,
      'recordsRead': records,
      for (final key in ['complete', 'stale', 'exited'])
        if (terminal?[key] is bool) key: terminal![key],
      if (terminal?['recordCount'] is int)
        'recordCount': terminal!['recordCount'],
      if (terminal?['source'] is String) 'source': terminal!['source'],
      if (metadata['source'] is String) 'metadataSource': metadata['source'],
      for (final key in ['error', 'cancelError', 'nativeReceipt'])
        if (terminal?[key] != null) key: terminal![key],
    },
  );

  Map<String, Object?> _prepareActual(CoreResult result) {
    final value = result.value;
    final platform = value is Map ? value['platform'] : null;
    final vpn = platform is Map ? platform['vpn'] : null;
    final lan = platform is Map ? platform['lan'] : null;
    return {
      'value': value is Map
          ? {
              for (final key in [
                'prepared',
                'attached',
                'vpnIntent',
                'lanIntent',
                'vpnRunning',
                'lanRunning',
                'processId',
                'inputId',
                'generation',
                'networkRevision',
                'phase',
                'purpose',
                'configId',
                'revision',
                'composition',
              ])
                if (value[key] is String ||
                    value[key] is num ||
                    value[key] is bool)
                  key: value[key],
              if (vpn is Map && vpn['running'] is bool ||
                  lan is Map && lan['running'] is bool)
                'platform': {
                  if (vpn is Map && vpn['running'] is bool)
                    'vpn': {'running': vpn['running']},
                  if (lan is Map && lan['running'] is bool)
                    'lan': {'running': lan['running']},
                },
            }
          : null,
      if (value != null && value is! Map)
        'valueType': value.runtimeType.toString(),
      'terminal': {
        for (final key in [
          'complete',
          'exited',
          'stale',
          'recordCount',
          'source',
          'error',
          'cancelError',
          'nativeReceipt',
          'cancellation',
        ])
          if (result.terminal.containsKey(key)) key: result.terminal[key],
      },
    };
  }

  void _requireSuccess(CoreResult result) {
    if (!result.complete || result.error != null) {
      final value = result.value is Map ? result.value as Map : const {};
      throw PlatformFailure(
        code: ApplicationContract.coreErrorCallFailed,
        details: {
          for (final key in [
            'complete',
            'exited',
            'stale',
            'error',
            'cancelError',
            'nativeReceipt',
          ])
            if (result.terminal[key] != null) key: result.terminal[key],
          for (final key in [
            'status',
            'mode',
            'committed',
            'ready',
            'updated',
            'error',
            'detail',
          ])
            if (value[key] != null &&
                (key == 'error' ||
                    key == 'detail' ||
                    value[key] is String ||
                    value[key] is num ||
                    value[key] is bool))
              'result.$key': value[key],
        },
      );
    }
  }

  Future<Map<String, dynamic>> _page(
    CoreSnapshot source,
    String method,
    Map<String, Object?> arguments, {
    required Map<String, int> timing,
  }) async {
    final query = Map<String, Object?>.from(arguments['query'] as Map);
    final request = <String, Object?>{
      ...timing,
      if (method == 'nodes' && query['source'] != null)
        'source': query['source'],
      if (method == 'rules') 'kind': query['kind'] ?? 'main',
      if (method == 'rules' && query['name'] != null) 'name': query['name'],
    };
    final call = await client.submit(
      method == 'nodes'
          ? ApplicationContract.coreOperationNodes
          : ApplicationContract.coreOperationRules,
      identity(source),
      arguments: request,
    );
    final page = await CoreCollectionPage.read(
      call,
      offset: query['offset'] as int? ?? 0,
      limit: query['limit'] as int? ?? 50,
      search: query['search'] as String? ?? '',
      token: query['token'] as String? ?? '',
      localIdentity: query['localIdentity'] as String? ?? '',
      definitions:
          ((method == 'nodes' && query['source'] == null ||
                      method == 'rules' && (query['kind'] ?? 'main') == 'main')
                  ? query['definitions'] as List? ?? const []
                  : const [])
              .map((row) => Map<String, dynamic>.from(row as Map)),
      project: method == 'nodes'
          ? (record) => {...record, 'source': record['sourceName'] ?? ''}
          : null,
    );
    return {
      ...envelope(source),
      'stale': await _readStale(source),
      if (page.terminal['cancelError'] != null)
        'cancelError': page.terminal['cancelError'],
      'page': {
        ...page.metadata,
        'total': page.total,
        'offset': page.offset,
        'nextOffset': page.nextOffset,
        'token': DefinitionRows.pageToken(
          page.source,
          query['localIdentity'] as String? ?? '',
        ),
        'sourceToken': page.source,
        if (method == 'nodes') 'nodes': page.rows,
        if (method == 'rules') ...{
          'rows': page.rows,
          'origin': page.metadata['origin'] ?? '',
          'scopes': page.metadata['scopes'] ?? const [],
        },
      },
    };
  }

  Future<StrategySnapshot> strategies(CoreSnapshot source) async =>
      StrategySnapshot.fromMap(await _strategyResponse(source));

  Future<Map<String, dynamic>> _strategyResponse(CoreSnapshot source) async {
    final call = await _begin(
      ApplicationContract.coreOperationStrategies,
      source,
      const {},
    );
    final groups = <Map<String, dynamic>>[];
    final metadata = <String, dynamic>{};
    Map<String, dynamic>? terminal;
    var records = 0;
    var stale = false;
    try {
      await for (final frame in call.frames()) {
        if (frame.kind == ApplicationContract.coreIpcFrameMetadata) {
          metadata.addAll(frame.object);
        } else if (frame.kind == ApplicationContract.coreIpcFrameRecord) {
          records++;
          final record = frame.object;
          groups.add({
            for (final key in [
              'name',
              'type',
              'hidden',
              'now',
              'currentIdentity',
              'sourceIdentity',
              'fixed',
              'icon',
              'provenance',
            ])
              if (record.containsKey(key)) key: record[key],
            'members': [
              for (final member in record['members'] as List)
                {
                  for (final key in ['name', 'type', 'identity'])
                    if ((member as Map).containsKey(key)) key: member[key],
                },
            ],
          });
        } else if (frame.terminal) {
          terminal = frame.object;
        } else {
          throw const FormatException('策略导出包含无效帧');
        }
      }
      if (terminal != null) terminal = await call.finish(terminal);
      if (terminal == null ||
          terminal['complete'] != true ||
          terminal['recordCount'] != records ||
          terminal['error'] != null ||
          terminal['stale'] == true ||
          terminal['source'] is! String ||
          (terminal['source'] as String).isEmpty ||
          metadata['source'] != null &&
              metadata['source'] != terminal['source']) {
        throw _exportFailure('策略导出未完整返回', metadata, terminal, records);
      }
      stale = !source.matchesIdentity((await platform.snapshot()).core);
    } catch (error, stack) {
      return call.fail(error, stack);
    }
    return {
      ...envelope(source),
      if (metadata.containsKey('mode')) 'mode': metadata['mode'],
      'groups': groups,
      'stale': stale,
      'globalReferenced': metadata['globalReferenced'] == true,
      if (terminal['cancelError'] != null)
        'cancelError': terminal['cancelError'],
      if (terminal['cancelError'] != null && terminal['nativeReceipt'] != null)
        'nativeReceipt': terminal['nativeReceipt'],
      'unrestored': [
        for (final item in _unrestored.entries)
          {'group': item.key, 'reason': item.value},
      ],
    };
  }

  Future<List<Map<String, Object?>>> _lanInterfaces(
    Map<String, dynamic> record, {
    required bool preview,
  }) async {
    if (preview || record['lanIntent'] != true) return const [];
    final parts = (record['overrides'] as List).cast<Map>();
    final part = parts.where((part) => part['role'] == 'lanProxy').single;
    final settings = LanProxySettings.fromBody(part['body'] as String);
    if (settings.addresses.isEmpty) throw const FormatException('请选择局域网接口地址');
    final current = await client.localInterfaces();
    final addresses = (current['addresses'] as List).cast<Map>();
    return [
      for (final address in settings.addresses)
        (() {
          final interfaceName = settings.interfaces[address];
          final found = addresses
              .where(
                (row) =>
                    row['address'] == address &&
                    row['interfaceName'] == interfaceName &&
                    row['available'] == true &&
                    row['selectable'] == true,
              )
              .firstOrNull;
          if (found == null) throw FormatException('所选局域网接口地址已失效', address);
          return <String, Object?>{
            'listenerName': LanProxySettings.listenerName(
              address,
              interfaceName: interfaceName!,
            ),
            'interfaceName': interfaceName,
            'interfaceIndex': found['interfaceIndex'],
            'address': address,
          };
        })(),
    ];
  }

  Future<Map<String, Object?>?> _prepare(
    Map<String, Object?> arguments, {
    required bool preview,
    AppPlatform? operation,
  }) async {
    final owner = arguments['owner'] as String?;
    operation ??= platform.forOperation(
      operationId: owner,
      admittedAt: arguments['admittedAt'] as int?,
      deadline: arguments['deadline'] as int?,
    );
    final paths = await operation.paths();
    final file = File(
      arguments['path'] as String? ?? paths['runInput'] as String,
    );
    final record =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final inputId = record['inputId'];
    if (inputId is! String ||
        inputId.isEmpty ||
        record['id'] != arguments['id'] ||
        record['revision'] != arguments['revision']) {
      throw const FormatException('装载记录身份不匹配');
    }
    StrategyChoice.decode(record['choices']);
    final lanInterfaces = await _lanInterfaces(record, preview: preview);
    final current = (await platform.snapshot()).core;
    if (preview &&
        arguments['force'] != true &&
        current.ready &&
        current.purpose == ApplicationContract.corePurposePreview) {
      final loaded = await _readInput(current);
      const fields = [
        'id',
        'revision',
        'name',
        'source',
        'body',
        'composition',
        'mode',
        'routingOverride',
        'overrides',
        'choices',
        'access',
        'packages',
      ];
      if (loaded != null &&
          fields.every(
            (key) => jsonEncode(loaded[key]) == jsonEncode(record[key]),
          )) {
        await operation.checkOperation();
        if (current.matchesIdentity((await platform.snapshot()).core)) {
          return null;
        }
      }
    }
    await operation.checkOperation();
    final publication = await client.publishRunInput(file.path, inputId);
    if (publication['durable'] != true) {
      throw ConfigFailure(
        messages.storageSyncUnconfirmed.withDetail({
          if (publication['saved'] is bool) 'saved': publication['saved'],
          if (publication['durable'] is bool) 'durable': publication['durable'],
          if (publication['inputId'] is String)
            'inputId': publication['inputId'],
          if (publication['path'] is String) 'path': publication['path'],
          if (publication['error'] != null) 'error': publication['error'],
        }),
      );
    }
    final previous = await client.status();
    final previousId = previous['processId'];
    final unprepared =
        previous['phase'] == 'connected' &&
        previous['generation'] == 0 &&
        previous['inputId'] == null;
    if (previousId is String &&
        previousId.isNotEmpty &&
        !unprepared &&
        !const ['disconnected', 'exited'].contains(previous['phase'])) {
      await _exit(
        CoreSnapshot(processId: previousId),
        arguments,
        reason: 'reconnect',
        operation: operation,
      );
    }
    await operation.checkOperation();
    final handshake = await client.handshake();
    final state = await operation.snapshot();
    final timing = owner == null
        ? {
            'admittedAt': state.elapsedRealtimeMs ?? 0,
            'deadline':
                (state.elapsedRealtimeMs ?? 0) +
                ApplicationContract.operationOrdinaryTimeoutMs,
          }
        : await operation.operationTiming();
    final generation = (handshake['generation'] as int? ?? 0) + 1;
    final source = CoreSnapshot(
      generation: generation,
      processId: handshake['processId'] as String,
      inputId: inputId,
      phase: 'LOADING',
      purpose: preview
          ? ApplicationContract.corePurposePreview
          : ApplicationContract.corePurposeRunning,
      configId: record['id'] as String,
      revision: record['revision'] as int,
      composition: record['composition'] as String,
      networkRevision:
          handshake['networkRevision'] as int? ?? state.networkEpoch ?? 0,
      logWindow: '${handshake['processId']}/$inputId',
    );
    await operation.checkOperation();
    final authority = operation;
    final reply = Completer<Map<String, Object?>?>();
    CoreResult? preparedResult;
    CoreCall? call;
    Object? cleanupFailure;
    StackTrace? cleanupStack;
    Future<void>? cleanup;
    Future<void>? interruption;
    Timer? deadlineTimer;
    StreamSubscription<void>? cancellation;

    Future<void> cleanUp() => cleanup ??= () async {
      try {
        await _exit(
          source,
          arguments,
          reason: 'reconnect',
          operation: authority,
        );
      } catch (error, stack) {
        cleanupFailure = error;
        cleanupStack = stack;
      }
    }();

    Future<void> interrupt() => interruption ??= () async {
      bool? started;
      try {
        final cancelled = await call!.cancel();
        final value = cancelled[ApplicationContract.coreFieldStarted];
        if (value is bool) started = value;
      } catch (error, stack) {
        if (error is PlatformFailure) {
          Object? value = error.details;
          if (value is String) {
            try {
              value = jsonDecode(value);
            } on FormatException {
              value = null;
            }
          }
          if (value is Map &&
              value[ApplicationContract.coreFieldStarted] is bool) {
            started = value[ApplicationContract.coreFieldStarted] as bool;
          }
        }
        if (started == false && !reply.isCompleted) {
          reply.completeError(error, stack);
        }
      }
      await cleanUp();
      // 只有 CANCEL 确认原工作尚未开始，才允许在 drain 前交付清理错误。
      if (started == false && cleanupFailure != null && !reply.isCompleted) {
        reply.completeError(cleanupFailure!, cleanupStack);
      }
    }();

    void completeActual() {
      if (reply.isCompleted) return;
      reply.complete({
        'actual': _prepareActual(preparedResult!),
        if (cleanupFailure != null)
          'cleanupError': failureValue(cleanupFailure!, cleanupStack),
      });
    }

    final work = () async {
      try {
        call = await client.submit(
          ApplicationContract.coreOperationPrepare,
          identity(source),
          inputId: inputId,
          owner: owner,
          arguments: {
            'purpose': source.purpose,
            'vpnIntent': !preview && record['vpnIntent'] == true,
            'lanIntent': !preview && record['lanIntent'] == true,
            ...timing,
            'lanInterfaces': lanInterfaces,
            'access': record['access'],
            'packages': record['packages'],
            'configId': record['id'],
            'revision': record['revision'],
            'mode': record['mode'],
            'explicitStart': arguments['explicitStart'] != false && !preview,
          },
        );
        cancellation = authority.whenCancelled.asStream().listen((_) {
          unawaited(interrupt());
        });
        deadlineTimer = Timer(
          Duration(
            milliseconds:
                timing['deadline']! -
                (state.elapsedRealtimeMs ?? 0) -
                state.uptimeSampleAgeMilliseconds,
          ),
          authority.cancel,
        );
        _input = _freeze(record) as Map<String, dynamic>;
        _inputSource = source;
        _unrestored.clear();
        try {
          await _subscribeLogs(source);
        } catch (error) {
          logError = error;
        }
        preparedResult = await call!.result(
          maximumBytes: ApplicationContract.coreIpcFrameBytes,
        );
        _requireSuccess(preparedResult!);
        if (interruption != null) {
          await interruption;
          completeActual();
          return;
        }
        final loaded = (await platform.snapshot()).core;
        await authority.checkOperation();
        if (loaded.processId != source.processId ||
            loaded.inputId != inputId ||
            !loaded.ready) {
          final actual = CoreSnapshot.fromMap(preparedResult!.object);
          if (actual.ready &&
              actual.processId == source.processId &&
              actual.inputId == inputId) {
            changed();
            reply.complete(null);
            return;
          }
          throw ConfigFailure(
            messages.coreContextUnconfirmed.withDetail({
              'expected': envelope(source),
              'platform': envelope(loaded),
              'actual': _prepareActual(preparedResult!)['value'],
            }),
          );
        }
        _restoredProcess = source.processId;
        _logSource = _withLogWindow(loaded);
        await _restoreChoices(loaded, record, operation: authority);
        await _readMode(loaded);
        changed();
        if (!reply.isCompleted) reply.complete(null);
      } catch (error, stack) {
        if (preparedResult?.complete == true &&
            preparedResult?.error == null &&
            error is PlatformFailure &&
            error.code == 'expired') {
          await interrupt();
          completeActual();
          return;
        }
        await interruption;
        await cleanUp();
        if (reply.isCompleted) return;
        if (preparedResult != null || cleanupFailure != null) {
          reply.completeError(
            PlatformFailure(
              code: error is PlatformFailure
                  ? error.code
                  : ApplicationContract.coreErrorCallFailed,
              message: error is PlatformFailure
                  ? error.message
                  : error.toString(),
              stacktrace: error is PlatformFailure ? error.stacktrace : null,
              details: {
                'error': failureValue(error, stack),
                if (preparedResult != null)
                  'actual': _prepareActual(preparedResult!),
                if (cleanupFailure != null)
                  'cleanupError': failureValue(cleanupFailure!, cleanupStack),
              },
            ),
            stack,
          );
        } else {
          reply.completeError(error, stack);
        }
      } finally {
        deadlineTimer?.cancel();
        await cancellation?.cancel();
      }
    }();
    // 业务应答与实际 work 共用原 operation；提前应答不解除执行占用。
    authority.retainUntil(work);
    return reply.future;
  }

  Future<void> _restoreChoices(
    CoreSnapshot source,
    Map<String, dynamic> input, {
    AppPlatform? operation,
  }) async {
    final choices = input['choices'];
    if (choices is! Map || choices.isEmpty) return;
    final before = await strategies(source);
    for (final item in choices.entries) {
      final name = item.key as String;
      try {
        final choice = StrategyChoice.fromJson(
          Map<String, dynamic>.from(item.value as Map),
        );
        final group = before.find(name);
        if (group == null ||
            group.type != choice.type ||
            !group.selectable ||
            choice.member != null && !group.hasMember(choice.member!)) {
          _unrestored[name] = '策略组或成员已变化';
          continue;
        }
        final unchanged = choice.type.automatic
            ? group.fixed == (choice.member ?? '')
            : group.now == choice.member;
        if (!unchanged) {
          _requireSuccess(
            await _result(
              source,
              ApplicationContract.coreOperationStrategySelect,
              arguments: {
                'group': name,
                'choice': choice.toJson(),
                'restore': true,
              },
              owner: operation?.operationId,
              operation: operation,
            ),
          );
        }
      } catch (error) {
        _unrestored[name] = error.toString();
      }
    }
    final after = await strategies(source);
    for (final item in choices.entries) {
      if (_unrestored.containsKey(item.key)) continue;
      final choice = StrategyChoice.fromJson(
        Map<String, dynamic>.from(item.value as Map),
      );
      final actual = after.find(item.key as String);
      if (actual == null ||
          actual.type != choice.type ||
          (choice.type.automatic
              ? actual.fixed != (choice.member ?? '')
              : actual.now != choice.member)) {
        _unrestored[item.key as String] = '策略选择未确认';
      }
    }
  }

  Future<void> _exit(
    CoreSnapshot source,
    Map<String, Object?> arguments, {
    required String reason,
    AppPlatform? operation,
  }) async {
    if (source.processId == null) return;
    final owner = arguments['owner'] as String?;
    operation ??= platform.forOperation(
      operationId: owner,
      admittedAt: arguments['admittedAt'] as int?,
      deadline: arguments['deadline'] as int?,
    );
    final state = await platform.snapshot();
    final timing = owner == null
        ? {
            'admittedAt': state.elapsedRealtimeMs ?? 0,
            'deadline':
                (state.elapsedRealtimeMs ?? 0) +
                ApplicationContract.operationOrdinaryTimeoutMs,
          }
        : await operation.operationTiming();
    final result = await client.exit(
      processId: source.processId!,
      admittedAt: timing['admittedAt']!,
      deadline: timing['deadline']!,
      reason: reason,
    );
    if (result['exited'] != true) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorCommunicationLost,
        details: result,
      );
    }
    _sourceExited(source.processId!);
  }

  Future<bool> _stop(
    Map<String, Object?> arguments, {
    required AppPlatform operation,
    bool revoked = false,
  }) async {
    final state = await platform.snapshot();
    final source = state.core;
    if (source.processId == null) return false;
    if (revoked &&
        (!source.ready ||
            !source.matchesWireIdentity(Map<String, dynamic>.from(arguments)) ||
            arguments['networkRevision'] != source.networkRevision)) {
      return false;
    }
    final record = await inputFor(source);
    if (revoked) {
      if (record?['lanIntent'] != true) return false;
      final current = (await platform.snapshot()).core;
      if (!source.matchesIdentity(current) ||
          source.networkRevision != current.networkRevision) {
        return false;
      }
    } else if (arguments['preserveLan'] != false &&
        record?['lanIntent'] == true &&
        record?['vpnIntent'] != true) {
      return false;
    }
    await _exit(
      source,
      arguments,
      reason: revoked ? 'revoked' : 'stop',
      operation: operation,
    );
    if (arguments['preserveLan'] != false && record?['lanIntent'] == true) {
      if (revoked) {
        final current = (await platform.snapshot()).core;
        if (current.processId != null &&
            current.processId != source.processId) {
          return false;
        }
      }
      await operation.checkOperation();
      final paths = await operation.paths();
      final input = {
        ...record!,
        'inputId': CoreInput.newInputId(),
        'vpnIntent': false,
      };
      final file = File(paths['runInput'] as String);
      await CoreInput(file).writeRecord(input);
      try {
        await _prepare(
          {
            ...arguments,
            'id': input['id'],
            'revision': input['revision'],
            'explicitStart': false,
          },
          preview: false,
          operation: operation,
        );
        return true;
      } finally {
        await CoreInput(file).clear();
      }
    }
    return false;
  }

  CoreSnapshot _withLogWindow(CoreSnapshot source, {bool stopped = false}) =>
      CoreSnapshot(
        generation: source.generation,
        processId: source.processId,
        inputId: source.inputId,
        networkRevision: source.networkRevision,
        phase: stopped ? 'EMPTY' : source.phase,
        purpose: source.purpose,
        configId: source.configId,
        revision: source.revision,
        composition: source.composition,
        logWindow: logs.source,
      );

  Future<void> _clearLogs(CoreSnapshot source) async {
    final window = logs.source;
    if (window == null || source.logWindow != window) return;
    final status = await client.status();
    if (_logCall == null ||
        _logCall!.hasExited ||
        status['processId'] != source.processId ||
        status['inputId'] != source.inputId ||
        const ['exited', 'disconnected'].contains(status['phase'])) {
      logs.clear(window);
      return;
    }
    final result = await _result(
      source,
      ApplicationContract.coreOperationLogs,
      arguments: const {'watermark': true},
    );
    _requireSuccess(result);
    final value = result.object;
    if (value['source'] != window ||
        value['next'] is! int ||
        (value['next'] as int) < 0 ||
        value['dropped'] is! int ||
        (value['dropped'] as int) < 0) {
      throw FormatException(
        '日志 watermark 无效: ${{'expectedSource': window, if (value['source'] is String) 'source': value['source'], if (value['source'] is! String) 'sourceType': value['source'].runtimeType.toString(), if (value['next'] is int) 'next': value['next'], if (value['next'] is! int) 'nextType': value['next'].runtimeType.toString(), if (value['dropped'] is int) 'dropped': value['dropped'], if (value['dropped'] is! int) 'droppedType': value['dropped'].runtimeType.toString(), if (value['error'] != null) 'error': value['error']}}',
      );
    }
    logs.clear(
      window,
      through: value['next'] as int,
      droppedThrough: value['dropped'] as int,
    );
  }

  Future<void> _subscribeLogs(CoreSnapshot source) async {
    final call = await _begin(
      ApplicationContract.coreOperationLogs,
      source,
      const {},
    );
    _logCall = call;
    logs.begin('${source.processId}/${source.inputId}');
    _logSource = _withLogWindow(source);
    logError = null;
    unawaited(() async {
      try {
        await for (final frame in call.frames()) {
          if (_logCall != call) continue;
          if (frame.kind == ApplicationContract.coreIpcFrameRecord) {
            logs.accept(logs.source!, frame.object);
            changed();
          } else if (frame.kind == ApplicationContract.coreIpcFrameMetadata) {
            final dropped = frame.object['dropped'];
            if (dropped is int) logs.transportDropped(logs.source!, dropped);
          } else if (frame.terminal && frame.object['error'] != null) {
            _recordLogError(frame.object['error']!);
          }
        }
      } catch (error) {
        _recordLogError(error);
      } finally {
        await call.exited;
        if (_logCall == call) {
          _logCall = null;
          if (_logSource != null) {
            _logSource = _withLogWindow(_logSource!, stopped: true);
          }
          changed();
        }
      }
    }());
  }

  void event(Map<String, dynamic> event) {
    if (event['event'] == 'uiVisibility' && event['visible'] is bool) {
      final visible = event['visible'] as bool;
      dns.setVisible(visible);
      delays.setVisible(visible);
    }
    client.event(event);
    _refreshEvent(event);
    if (event['exited'] == true &&
        event['requestId'] == null &&
        event['processId'] is String) {
      _sourceExited(event['processId'] as String);
    }
    changed();
    unawaited(flushRefresh());
  }

  void _recordLogError(Object error) {
    final previous = logError;
    logError = previous == null
        ? error
        : {
            'error': switch (error) {
              Map() || String() => error,
              _ => _failureValue(error),
            },
            'previous': switch (previous) {
              Map() || String() => previous,
              _ => _failureValue(previous),
            },
          };
  }

  void _sourceExited(String processId) {
    delays.sourceExited(processId);
    final mode = _mode;
    if (mode != null && mode['processId'] == processId) {
      if (mode['error'] != null) _recordLogError(mode['error']!);
      _mode = {'actual': null, 'fallback': mode['fallback'], 'error': null};
    }
    final source = _logSource;
    if (source != null && source.processId == processId) {
      _logSource = _withLogWindow(source, stopped: true);
    }
  }

  Future<Map<String, Object?>> _cleanupCandidates() async {
    final before = await client.status();
    final existing =
        before['processId'] is String &&
        !const [
          'disconnected',
          'exited',
          'recoveryRequired',
        ].contains(before['phase']);
    final status = await client.handshake();
    final source = CoreSnapshot.fromMap(status);
    try {
      final result = await _result(
        source,
        ApplicationContract.coreOperationPaths,
      );
      _requireSuccess(result);
      final value = result.object;
      final home = Directory(value['home'] as String).absolute.uri
          .normalizePath();
      final candidates = <Map<String, Object?>>[];
      for (final key in const ['cache', 'geoip', 'mmdb', 'asn', 'geosite']) {
        final raw = value[key];
        if (raw is! String || raw.isEmpty) continue;
        final uri = home.resolve(raw).normalizePath();
        if (!uri.path.startsWith(home.path) || uri.path == home.path) continue;
        final relative = Uri.decodeComponent(
          uri.path.substring(home.path.length),
        );
        if (candidates.any((row) => row['path'] == relative)) continue;
        candidates.add({'kind': key, 'path': relative});
      }
      return Map.unmodifiable({
        'home': value['home'],
        'items': List.unmodifiable(candidates),
      });
    } finally {
      if (!existing) await _exit(source, const {}, reason: 'idle');
    }
  }

  Future<String?> _readMode(
    CoreSnapshot source, {
    String? expected,
    bool strict = false,
    bool notify = true,
  }) async {
    String? actual;
    try {
      final result = await _result(
        source,
        ApplicationContract.coreOperationMode,
      );
      _requireSuccess(result);
      final value = result.object['mode'];
      if (!const ['rule', 'global', 'direct'].contains(value)) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorCallFailed,
          details: {
            'message': '内核返回的模式无效',
            if (value is String || value is num || value is bool)
              'actual': value,
          },
        );
      }
      actual = value as String;
      final current = (await platform.snapshot()).core;
      if (current.ready && source.matchesIdentity(current)) {
        _mode = {
          ...envelope(source),
          'actual': actual,
          'fallback': _input?['mode'],
          'error': null,
        };
      }
      if (expected != null && actual != expected) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorCallFailed,
          details: {
            ...envelope(source),
            'expected': expected,
            'actual': actual,
            if (result.cancelError != null) 'cancelError': result.cancelError,
            if (result.terminal['nativeReceipt'] != null)
              'nativeReceipt': result.terminal['nativeReceipt'],
          },
        );
      }
      return actual;
    } catch (error) {
      final current = (await platform.snapshot()).core;
      if (current.ready && source.matchesIdentity(current)) {
        _mode = {
          ...envelope(source),
          'actual': actual,
          'fallback': _input?['mode'],
          'error': messages.temporaryModeUnknown.withDetail(error).toMap(),
        };
      } else {
        _recordLogError(error);
      }
      if (strict) rethrow;
      return null;
    } finally {
      if (notify) changed();
    }
  }

  void dispose() {
    _refreshRetry?.cancel();
    _refresh = null;
  }

  Map<String, dynamic> _appMemory() => {
    'valid': true,
    'processRssBytes': ProcessInfo.currentRss,
    'sampledAt': DateTime.now().millisecondsSinceEpoch,
  };

  Future<Map<String, dynamic>> _coreMemory(String? processId) async {
    if (processId == null || processId.isEmpty) {
      throw const PlatformFailure(
        code: ApplicationContract.coreErrorIdentityMismatch,
      );
    }
    final status = await client.status();
    if (status['processId'] != processId ||
        const [
          'disconnected',
          'exited',
          'recoveryRequired',
        ].contains(status['phase'])) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorIdentityMismatch,
        details: {
          'expectedProcessId': processId,
          if (status['processId'] is String) 'processId': status['processId'],
          if (status['phase'] is String) 'phase': status['phase'],
          if (status['error'] != null) 'error': status['error'],
        },
      );
    }
    final result = await _result(
      CoreSnapshot.fromMap(status),
      ApplicationContract.coreOperationMemory,
    );
    _requireSuccess(result);
    final after = await client.status();
    if (after['processId'] != processId ||
        const [
          'disconnected',
          'exited',
          'recoveryRequired',
        ].contains(after['phase'])) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorIdentityMismatch,
        details: {
          'expectedProcessId': processId,
          if (after['processId'] is String) 'processId': after['processId'],
          if (after['phase'] is String) 'phase': after['phase'],
          if (after['error'] != null) 'error': after['error'],
        },
      );
    }
    final value = result.object;
    if (value['valid'] != true ||
        value['processRssBytes'] is! int ||
        (value['processRssBytes'] as int) < 0 ||
        value['sampledAt'] is! int) {
      throw FormatException(
        '内核内存读取失败: ${{if (value['valid'] is bool) 'valid': value['valid'], if (value['valid'] is! bool) 'validType': value['valid'].runtimeType.toString(), if (value['processRssBytes'] is int) 'processRssBytes': value['processRssBytes'], if (value['processRssBytes'] is! int) 'processRssBytesType': value['processRssBytes'].runtimeType.toString(), if (value['sampledAt'] is int) 'sampledAt': value['sampledAt'], if (value['sampledAt'] is! int) 'sampledAtType': value['sampledAt'].runtimeType.toString(), if (value['error'] != null) 'error': value['error']}}',
      );
    }
    return {
      'valid': true,
      'processRssBytes': value['processRssBytes'],
      'sampledAt': value['sampledAt'],
      'processId': processId,
    };
  }
}
