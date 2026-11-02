import 'dart:math';

import 'package:clash_pseudo/src/model/app_platform.dart';

import 'dart:async';

import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/foundation.dart';

import '../../model/delay_result.dart';

/// A popup owns its captured observations until actual calls and release settle.
/// Deadlines report waiting, not a replacement result or an available native slot.
class DelayTestController extends ChangeNotifier {
  DelayTestController(this.platform, this.source, this.group);
  final AppPlatform platform;
  final CoreSnapshot source;
  final String group;

  String? batch;
  bool running = false;
  bool finished = false;
  String? terminalState;
  String? target;
  Object? failure;
  StackTrace? failureStack;
  Object? cleanupFailure;
  StackTrace? cleanupStack;
  String? get error => failure == null && cleanupFailure == null
      ? null
      : [
          if (failure != null) failure.toString(),
          if (cleanupFailure != null) cleanupFailure.toString(),
        ].join('\n');
  Map<String, dynamic>? lastReply;
  Map<String, DelayMemberResult> results = const {};
  Timer? _poll;
  bool _disposed = false;
  bool _abandoned = false;
  bool _starting = false;
  int _requests = 0;
  String? _releasedBatch;
  ({String id, Future<void> future})? _cancelFlight;

  bool get busy => running || _starting || _requests != 0;
  static const pollInterval = Duration(milliseconds: 700);

  bool matches(CoreSnapshot core) => core.ready && source.matchesIdentity(core);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _track<T>(
    Future<T> Function() request, {
    bool cleanup = false,
  }) async {
    _requests++;
    final grace = Timer(const Duration(seconds: 5), () {
      final error = TimeoutException('Delay 请求仍未结束');
      if (cleanup) {
        cleanupFailure = error;
        cleanupStack = StackTrace.current;
      } else {
        failure = error;
        failureStack = StackTrace.current;
      }
      _notify();
    });
    try {
      return await request();
    } finally {
      grace.cancel();
      _requests--;
    }
  }

  Future<void> _cancel(String id) {
    if (_releasedBatch == id) return Future.value();
    final pending = _cancelFlight;
    if (pending?.id == id) return pending!.future;
    final work = () async {
      try {
        await _track(() => platform.cancelDelayTest(id), cleanup: true);
        _releasedBatch = id;
        cleanupFailure = null;
        cleanupStack = null;
      } catch (error, stack) {
        cleanupFailure = error;
        cleanupStack = stack;
        batch ??= id;
      } finally {
        if (_cancelFlight?.id == id) _cancelFlight = null;
        _notify();
      }
    }();
    _cancelFlight = (id: id, future: work);
    return work;
  }

  Future<void> _releaseBatch() async {
    final id = batch;
    batch = null;
    if (id != null) await _cancel(id);
  }

  bool _sameReply(Map<String, dynamic> value) =>
      source.matchesWireIdentity(value) &&
      value['networkRevision'] == source.networkRevision &&
      value['stale'] != true;

  Future<void> start({List<String>? members}) async {
    if (_disposed || _abandoned || busy) return;
    _starting = true;
    _poll?.cancel();
    try {
      if (batch != null) await _releaseBatch();
      if (cleanupFailure != null || _abandoned || _disposed) return;
      running = true;
      finished = false;
      terminalState = null;
      target = null;
      failure = null;
      failureStack = null;
      results = {
        for (final name in members ?? const <String>[])
          name: DelayMemberResult(name: name),
      };
      _notify();
      final random = Random.secure();
      final requestedId = List.generate(
        4,
        (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
      ).join();
      batch = requestedId;
      final value = await _track(
        () => platform.startDelayTest(source, {
          'id': requestedId,
          'group': group,
          if (members != null && members.isNotEmpty) 'members': members,
        }),
      );
      lastReply = Map.unmodifiable(value);
      final id = (value['start'] as Map?)?['id'];
      if (id is String) batch = id;
      if (!_sameReply(value) || id is! String) {
        throw FormatException('Invalid delay start identity', value);
      }
      failure = null;
      failureStack = null;
      if (_disposed || _abandoned) {
        running = false;
        await _releaseBatch();
        return;
      }
      _poll = Timer.periodic(pollInterval, (_) => unawaited(_read()));
      await _read();
    } catch (error, stack) {
      running = false;
      failure = error;
      failureStack = stack;
      _poll?.cancel();
      await _releaseBatch();
    } finally {
      _starting = false;
      _notify();
    }
  }

  Future<void> _read() async {
    final id = batch;
    if (_disposed || _abandoned || id == null || _requests != 0) return;
    try {
      final value = await _track(() => platform.delayTest(source, id));
      lastReply = Map.unmodifiable(value);
      final data = value['batch'] as Map;
      if (data['id'] != id || data['group'] != group) {
        throw FormatException('Invalid delay batch identity', value);
      }
      final state = data['state'] as String;
      if (!const ['running', 'done', 'cancelled', 'expired'].contains(state)) {
        throw FormatException('Invalid delay batch state', value);
      }
      final next = <String, DelayMemberResult>{};
      for (final item in data['members'] as List) {
        final row = Map<String, dynamic>.from(item as Map);
        final name = row['name'] as String;
        // The source's lifecycle may have expired while the actual probe settled.
        // Keep that measurement separately from its action eligibility.
        final observation = row['result'] as Map? ?? row;
        final status = _status(observation['status'] as String);
        final delay = observation['delay'] as int?;
        if (next.containsKey(name) ||
            (status == DelayMemberStatus.success &&
                (delay == null || delay < 0))) {
          throw FormatException('Invalid delay member result', value);
        }
        next[name] = DelayMemberResult(
          name: name,
          identity: row['identity'] as String? ?? '',
          status: status,
          delay: delay,
          error: observation['error']?.toString(),
          raw: Map.unmodifiable(row),
        );
      }
      results = Map.unmodifiable(next);
      target = data['target'] as String?;
      failure = null;
      failureStack = null;
      final stale = !_sameReply(value) || _abandoned || _disposed;
      running = !stale && state == 'running';
      finished = !running;
      terminalState = stale
          ? 'expired'
          : running
          ? null
          : state;
      if (finished) _poll?.cancel();
      if (stale || state == 'expired' || state == 'cancelled') {
        if (stale) _retireUnfinished();
        await _releaseBatch();
      }
      _notify();
    } catch (error, stack) {
      running = false;
      finished = true;
      terminalState = 'expired';
      _poll?.cancel();
      failure = error;
      failureStack = stack;
      _retireUnfinished();
      await _releaseBatch();
      _notify();
    }
  }

  void _retireUnfinished() {
    results = Map.unmodifiable({
      for (final row in results.values)
        row.name:
            row.status == DelayMemberStatus.pending ||
                row.status == DelayMemberStatus.running
            ? DelayMemberResult(
                name: row.name,
                identity: row.identity,
                status: DelayMemberStatus.expired,
                delay: row.delay,
                error: row.error,
                raw: row.raw,
              )
            : row,
    });
  }

  static DelayMemberStatus _status(String value) => switch (value) {
    'pending' => DelayMemberStatus.pending,
    'running' => DelayMemberStatus.running,
    'success' => DelayMemberStatus.success,
    'failed' => DelayMemberStatus.failed,
    'timeout' => DelayMemberStatus.timeout,
    'expired' => DelayMemberStatus.expired,
    'cancelled' => DelayMemberStatus.cancelled,
    _ => throw FormatException('Invalid delay member status', value),
  };

  /// Revoke actions immediately; late replies still belong to this captured source.
  void abandon() {
    if (_abandoned) return;
    _abandoned = true;
    _poll?.cancel();
    running = false;
    _retireUnfinished();
    unawaited(_releaseBatch());
  }

  @override
  void dispose() {
    _disposed = true;
    abandon();
    super.dispose();
  }
}
