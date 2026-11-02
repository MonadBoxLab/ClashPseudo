import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../../model/platform_failure.dart';

import '../../model/application_contract.dart';
import '../../model/core_snapshot.dart';
import '../../model/strategy_snapshot.dart';
import '../../platform/core/core_client.dart';
import '../diagnostics/dns_operations.dart';

/// 测速批次与四个实际调用名额由 AppRuntime 统一持有。
class DelayBatches {
  DelayBatches(this.start, this.strategies, {required this.changed});
  final CoreOperationStarter start;
  final Future<StrategySnapshot> Function(CoreSnapshot) strategies;
  final void Function() changed;
  static const concurrency = 4;
  static const memberTimeout = Duration(seconds: 5);
  static const batchTimeout = Duration(seconds: 120);
  final _batches = <String, _DelayBatch>{};
  final _jobs = Queue<(_DelayBatch, String)>();
  int _active = 0;
  bool _admitting = false;
  String? _admittingId;
  bool _visible = false;
  final _cancelledStarts = <String>{};

  bool get busy => _admitting || _active != 0 || _jobs.isNotEmpty;

  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    if (value) return;
    final pending = _admittingId;
    if (pending != null) _cancelledStarts.add(pending);
    for (final batch in _batches.values.toList()) {
      batch.sourceExpired = true;
      if (!batch.exited) unawaited(_cancelBatch(batch, release: false));
    }
    changed();
  }

  Future<Map<String, dynamic>> startBatch(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    if (!_visible) throw const PlatformFailure(code: 'expired');
    if (_admitting) throw StateError('测速批次正在准备');
    _admitting = true;
    final id = query['id'] as String? ?? _id();
    _admittingId = id;
    var expired = false;
    _DelayBatch? accepted;
    final deadline = Timer(batchTimeout, () {
      expired = true;
      final batch = accepted;
      if (batch != null) {
        batch.timedOut = true;
        unawaited(_cancelBatch(batch, release: false));
      }
    });
    changed();
    try {
      final groupName = query['group'] as String;
      final existing = _batches.values
          .where(
            (batch) =>
                batch.source.matchesIdentity(source) &&
                batch.group == groupName &&
                !batch.exited,
          )
          .firstOrNull;
      if (existing != null) {
        if (existing.id == id) return _startReply(existing);
        throw StateError('测速批次尚未退出');
      }
      final snapshot = await strategies(source);
      if (expired || _cancelledStarts.contains(id)) {
        throw const PlatformFailure(code: 'expired');
      }
      final group = snapshot.find(groupName);
      if (snapshot.stale || !snapshot.matches(source) || group == null) {
        throw const FormatException('测速来源已变化');
      }
      final requested = query['members'] as List?;
      final members = requested == null || requested.isEmpty
          ? group.members.map((member) => member.name).toSet().toList()
          : requested.cast<String>().toSet().toList();
      if (members.any((name) => !group.hasMember(name))) {
        throw const FormatException('测速成员已变化');
      }
      final batch = _DelayBatch(id, source, groupName, group.sourceIdentity, {
        for (final member in group.members)
          if (members.contains(member.name)) member.name: member.identity,
      }, query['url'] as String?);
      _batches[batch.id] = batch;
      accepted = batch;
      batch.deadline = deadline;
      for (final name in members) {
        _jobs.add((batch, name));
      }
      _pump();
      if (members.isEmpty) _complete(batch);
      return _startReply(batch);
    } finally {
      if (accepted == null) deadline.cancel();
      _cancelledStarts.remove(id);
      _admittingId = null;
      _admitting = false;
      changed();
    }
  }

  String _id() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  Map<String, dynamic> _envelope(_DelayBatch batch) => {
    'processId': batch.source.processId,
    'inputId': batch.source.inputId,
    'generation': batch.source.generation,
    'composition': batch.source.composition,
    'configId': batch.source.configId,
    'revision': batch.source.revision,
    'purpose': batch.source.purpose,
    'networkRevision': batch.source.networkRevision,
    'stale': batch.sourceExpired,
  };

  Map<String, dynamic> _startReply(_DelayBatch batch) => {
    ..._envelope(batch),
    'start': {'id': batch.id},
  };

  Future<Map<String, dynamic>> read(String id) async {
    final batch = _batches[id];
    if (batch == null) throw StateError('测速批次不存在');
    if (batch.reading) throw StateError('测速来源正在读取');
    batch.reading = true;
    final revision = batch.revision;
    try {
      await _refreshSource(batch);
      if (revision != batch.revision || _batches[id] != batch) {
        throw const PlatformFailure(code: 'expired');
      }
      return jsonDecode(
        jsonEncode({
          ..._envelope(batch),
          'batch': {
            'id': batch.id,
            'group': batch.group,
            'currentIdentity': batch.identity,
            'state': batch.sourceExpired
                ? 'expired'
                : batch.cancelRequested
                ? 'cancelled'
                : !batch.exited
                ? 'running'
                : 'done',
            'cancelRequested': batch.cancelRequested,
            'exited': batch.exited,
            if (batch.url != null) 'target': batch.url,
            'members': [
              for (final row in batch.members.values)
                Map<String, dynamic>.from(row),
            ],
          },
        }),
      ) as Map<String, dynamic>;
    } finally {
      batch.reading = false;
    }
  }

  Future<void> _refreshSource(_DelayBatch batch) async {
    if (batch.sourceExpired) return;
    try {
      final snapshot = await strategies(batch.source);
      final group = snapshot.find(batch.group);
      if (!snapshot.stale &&
          snapshot.matches(batch.source) &&
          group?.sourceIdentity == batch.identity &&
          batch.members.entries.every(
            (item) => group!.members.any(
              (member) =>
                  member.name == item.key &&
                  member.identity == item.value['identity'],
            ),
          )) {
        return;
      }
    } catch (error) {
      batch.sourceError = _errorValue(error);
    }
    batch.sourceExpired = true;
    if (!batch.exited) unawaited(_cancelBatch(batch, release: false));
  }

  Future<void> cancel(String id) async {
    final batch = _batches[id];
    if (batch == null) {
      if (_admittingId == id) _cancelledStarts.add(id);
      return;
    }
    final existing = batch.releasing;
    if (existing != null) return existing;
    final work = _cancelBatch(batch, release: true);
    batch.releasing = work;
    try {
      await work;
    } finally {
      if (batch.releasing == work) batch.releasing = null;
    }
  }

  Future<void> _cancelBatch(_DelayBatch batch, {required bool release}) async {
    if (release && !batch.cancelRequested) {
      batch.cancelRequested = true;
      batch.revision++;
    }
    final retired = batch.sourceExpired
        ? 'expired'
        : batch.timedOut
        ? 'timeout'
        : 'cancelled';
    for (final row in batch.members.values) {
      if (row['exited'] != true) row.addAll({'status': retired, 'delay': 0});
    }
    _jobs.removeWhere((job) {
      if (!identical(job.$1, batch)) return false;
      batch.members[job.$2]!['exited'] = true;
      return true;
    });
    final failures = await Future.wait([
      for (final call in {
        ...batch.calls.values,
        ...batch.failedCancellations.values,
      })
        _cancelCall(batch, call, retry: release),
    ]);
    _complete(batch);
    changed();
    if (release) await batch.drained.future;
    final errors = failures.whereType<Object>().toList();
    if (release && errors.isNotEmpty) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorCallFailed,
        details: {'cancelErrors': errors.map(_errorValue).toList()},
      );
    }
    if (release) {
      _batches.remove(batch.id);
    }
  }

  Object? _errorValue(Object error) => error is PlatformFailure
      ? error.toMap()
      : error is Map || error is List
      ? error
      : error.toString();

  Future<Object?> _cancelCall(
    _DelayBatch batch,
    CoreCall call, {
    bool retry = false,
  }) {
    final pending = batch.cancelling[call.requestId];
    if (pending != null) return pending;
    if (call.hasExited &&
        !(retry && batch.cancelErrors.containsKey(call.requestId))) {
      return Future.value();
    }
    final work = () async {
      try {
        final reply = await call.cancel();
        final error = reply['cancelError'] ?? reply['error'];
        if (error != null) {
          batch.cancelErrors[call.requestId] = error;
          batch.failedCancellations[call.requestId] = call;
          return error;
        }
        batch.cancelErrors.remove(call.requestId);
        batch.failedCancellations.remove(call.requestId);
        return null;
      } catch (error) {
        final value = _errorValue(error);
        batch.cancelErrors[call.requestId] = value;
        batch.failedCancellations[call.requestId] = call;
        return value;
      } finally {
        batch.cancelling.remove(call.requestId);
      }
    }();
    batch.cancelling[call.requestId] = work;
    return work;
  }

  void sourceExited(String processId) {
    for (final batch in _batches.values.toList()) {
      if (batch.source.processId != processId) continue;
      batch.sourceExpired = true;
      if (!batch.exited) unawaited(_cancelBatch(batch, release: false));
    }
    changed();
  }

  void _pump() {
    while (_active < concurrency && _jobs.isNotEmpty) {
      final job = _jobs.removeFirst();
      if (job.$1.cancelRequested) continue;
      _active++;
      job.$1.active++;
      job.$1.members[job.$2]!['status'] = 'running';
      unawaited(_run(job.$1, job.$2));
    }
    changed();
  }

  Future<void> _run(_DelayBatch batch, String name) async {
    CoreCall? call;
    Timer? deadline;
    final row = batch.members[name]!;
    var timedOut = false;
    deadline = Timer(memberTimeout, () {
      timedOut = true;
      row['status'] = 'timeout';
      final activeCall = call;
      if (activeCall != null) unawaited(_cancelCall(batch, activeCall));
      changed();
    });
    try {
      call = await start(
        ApplicationContract.coreOperationUrlTest,
        batch.source,
        {
          'name': name,
          'group': batch.group,
          'identity': row['identity'],
          if (batch.url != null) 'url': batch.url,
          'timeoutMs': memberTimeout.inMilliseconds,
        },
      );
      batch.calls[name] = call;
      if (batch.cancelRequested || batch.sourceExpired || timedOut) {
        unawaited(_cancelCall(batch, call));
      }
      final result = await call.result(
        maximumBytes: ApplicationContract.coreIpcFrameBytes,
      );
      final value = result.value is Map
          ? Map<String, dynamic>.from(result.value as Map)
          : <String, dynamic>{'delay': result.value};
      final delay = value['delay'];
      final error = result.error ?? value['error'];
      final status = error == null && delay is int && delay >= 0
          ? 'success'
          : timedOut ||
                error is Map &&
                    const ['timedOut', 'timeout'].contains(error['code'])
          ? 'timeout'
          : 'failed';
      final observation = {
        ...value,
        'status': status,
        'error': ?error,
        'terminal': result.terminal,
        if (result.cancelError != null) 'cancelError': result.cancelError,
        if (result.stale) 'stale': true,
      };
      if (!batch.sourceExpired && !batch.cancelRequested) {
        row.addAll({
          'status': status,
          if (delay is int) 'delay': delay,
          'error': ?error,
        });
      }
      row['result'] = observation;
      if (result.cancelError != null) row['cancelError'] = result.cancelError;
    } catch (error) {
      final failure = _errorValue(error);
      if (!batch.sourceExpired && !batch.cancelRequested) {
        row['status'] = timedOut ? 'timeout' : 'failed';
        row['error'] = failure;
      }
      row['result'] = {
        'status': timedOut ? 'timeout' : 'failed',
        'error': failure,
      };
    } finally {
      deadline.cancel();
      if (call != null) {
        await call.exited;
        final cancelError = batch.cancelErrors[call.requestId];
        if (cancelError != null) row['cancelError'] = cancelError;
      }
      row['exited'] = true;
      batch.calls.remove(name);
      batch.active--;
      _active--;
      _complete(batch);
      _pump();
    }
  }

  void _complete(_DelayBatch batch) {
    if (batch.active == 0 &&
        !batch.members.values.any(
          (row) => row['status'] == 'pending' || row['status'] == 'running',
        )) {
      batch.exited = true;
      if (!batch.drained.isCompleted) batch.drained.complete();
      batch.deadline?.cancel();
    }
  }
}

class _DelayBatch {
  _DelayBatch(
    this.id,
    this.source,
    this.group,
    this.identity,
    Map<String, String> identities,
    this.url,
  ) : members = {
        for (final member in identities.entries)
          member.key: {
            'name': member.key,
            'identity': member.value,
            'status': 'pending',
          },
      };
  final String id;
  final CoreSnapshot source;
  final String group;
  final String identity;
  final String? url;
  final Map<String, Map<String, dynamic>> members;
  final calls = <String, CoreCall>{};
  final cancelErrors = <int, Object?>{};
  final failedCancellations = <int, CoreCall>{};
  final cancelling = <int, Future<Object?>>{};
  bool reading = false;
  int revision = 0;
  final drained = Completer<void>();
  Future<void>? releasing;
  Timer? deadline;
  bool cancelRequested = false;
  bool timedOut = false;
  bool sourceExpired = false;
  Object? sourceError;
  bool exited = false;
  int active = 0;
}
