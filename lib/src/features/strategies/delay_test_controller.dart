import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/app_bridge.dart';

import 'delay_result.dart';

/// Owns one popup's batch. Native retains the actual proxy identities and
/// expires the results if a provider replaces a member, even with the same name.
class DelayTestController extends ChangeNotifier {
  DelayTestController(this.platform, this.source, this.group);
  final AppBridge platform;
  final CoreSnapshot source;
  final String group;

  String? batch;
  bool running = false;
  bool finished = false;
  String? terminalState;
  String? target;
  String? error;
  Map<String, DelayMemberResult> results = const {};
  Timer? _poll;
  int _token = 0;
  bool _disposed = false;
  bool _inFlight = false;

  bool get busy => running || _inFlight;
  static const pollInterval = Duration(milliseconds: 700);
  static const _requestTimeout = Duration(seconds: 5);

  bool matches(CoreSnapshot core) => core.ready && source.matchesIdentity(core);

  // Retain ownership until the actual channel call settles, including after UI
  // timeout.
  Future<T> _track<T>(Future<T> request) {
    _inFlight = true;
    return request.whenComplete(() {
      _inFlight = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _cancel(String id) {
    unawaited(platform.cancelDelayTest(id).catchError((_) {}));
  }

  void _releaseBatch() {
    final id = batch;
    batch = null;
    if (id != null) _cancel(id);
  }

  bool _sameReply(Map<String, dynamic> value) =>
      value['generation'] == source.generation &&
      value['composition'] == source.composition;

  Future<void> start({List<String>? members}) async {
    if (_disposed || busy) return;
    _poll?.cancel();
    _releaseBatch();
    final token = ++_token;
    running = true;
    finished = false;
    terminalState = null;
    target = null;
    error = null;
    results = {
      for (final name in members ?? const <String>[])
        name: DelayMemberResult(name: name),
    };
    notifyListeners();
    try {
      final pending = platform
          .startDelayTest(source, {
            'group': group,
            if (members != null && members.isNotEmpty) 'members': members,
          })
          .then((value) {
            // Closing, invalidating or timing out the popup may happen before the
            // native batch ID is delivered. It still needs an explicit release.
            if (_disposed || token != _token || !_sameReply(value)) {
              final id = (value['start'] as Map?)?['id'];
              if (id is String) _cancel(id);
            }
            return value;
          });
      final value = await _track(pending).timeout(_requestTimeout);
      if (_disposed || token != _token) return;
      if (!_sameReply(value)) throw const FormatException();
      batch = (value['start'] as Map)['id'] as String?;
      if (batch == null) throw const FormatException();
      _poll = Timer.periodic(pollInterval, (_) => unawaited(_read()));
      await _read();
    } catch (_) {
      if (_disposed || token != _token) return;
      _token++;
      _poll?.cancel();
      _releaseBatch();
      running = false;
      error = 'start';
      notifyListeners();
    }
  }

  Future<void> _read() async {
    final id = batch;
    if (_disposed || id == null || _inFlight) return;
    final token = _token;
    try {
      final value = await _track(platform.delayTest(source, id))
          .timeout(_requestTimeout);
      if (_disposed || token != _token) return;
      if (!_sameReply(value) || value['batch'] is! Map) {
        throw const FormatException();
      }
      final data = value['batch'] as Map;
      if (data['id'] != id || data['group'] != group) {
        throw const FormatException();
      }
      final state = data['state'] as String;
      if (!const ['running', 'done', 'cancelled', 'expired'].contains(state)) {
        throw const FormatException();
      }
      final next = <String, DelayMemberResult>{};
      for (final item in data['members'] as List) {
        final row = item as Map;
        final name = row['name'] as String;
        final status = _status(row['status'] as String);
        final delay = row['delay'] as int?;
        if (next.containsKey(name) ||
            (status == DelayMemberStatus.success &&
                (delay == null || delay < 0))) {
          throw const FormatException();
        }
        next[name] = DelayMemberResult(
          name: name,
          identity: row['identity'] as String? ?? '',
          status: status,
          delay: delay,
        );
      }
      final nextTarget = data['target'] as String?;
      results = Map.unmodifiable(next);
      target = nextTarget;
      running = state == 'running';
      finished = !running;
      terminalState = running ? null : state;
      if (state == 'expired' || state == 'cancelled') {
        _poll?.cancel();
        _releaseBatch();
      }
      // Continue reading completed batches while visible and validate provider
      // identities within the current core/composition.
      notifyListeners();
    } catch (_) {
      if (_disposed || token != _token) return;
      _token++;
      running = false;
      finished = true;
      _poll?.cancel();
      _releaseBatch();
      error = 'read';
      results = {
        for (final name in results.keys)
          name: DelayMemberResult(
            name: name,
            status: DelayMemberStatus.expired,
          ),
      };
      notifyListeners();
    }
  }

  static DelayMemberStatus _status(String value) => switch (value) {
    'pending' => DelayMemberStatus.pending,
    'running' => DelayMemberStatus.running,
    'success' => DelayMemberStatus.success,
    'failed' => DelayMemberStatus.failed,
    'timeout' => DelayMemberStatus.timeout,
    'expired' => DelayMemberStatus.expired,
    'cancelled' => DelayMemberStatus.cancelled,
    _ => throw const FormatException(),
  };

  /// Preserve visible settled results after context expiry; accept further replies only
  /// for the same current batch identity.
  void abandon() {
    if (_disposed) return;
    _token++;
    _poll?.cancel();
    running = false;
    _releaseBatch();
  }

  @override
  void dispose() {
    abandon();
    _disposed = true;
    super.dispose();
  }
}
