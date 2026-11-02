import 'dart:async';

import '../../model/application_contract.dart';
import '../../model/core_snapshot.dart';
import '../../model/dns_snapshot.dart';
import '../../model/platform_failure.dart';
import '../../platform/core/core_client.dart';

typedef CoreOperationStarter = Future<CoreCall> Function(
  int operation,
  CoreSnapshot source,
  Map<String, Object?> arguments,
);

/// DNS 请求、期限和取消归 AppRuntime；页面只提交草稿和读取结果。
class DnsOperations {
  DnsOperations(this.start, {required this.changed});
  final CoreOperationStarter start;
  final void Function() changed;
  CoreCall? _call;
  CoreSnapshot? _source;
  String? _owner;
  bool _admitting = false;
  bool _cancelling = false;
  bool _cancelRequested = false;
  String? _error;
  String? _detail;
  Object? _cancelError;
  Map<String, dynamic>? _result;

  bool get busy => _admitting || _call != null || _cancelling;
  Map<String, Object?> snapshot() => {
    'busy': busy,
    'queryOwner': _owner,
    'error': _error,
    'errorDetail': _detail,
    'cancelError': _cancelError,
    'cancelRequested': _cancelRequested,
    'exited': !busy,
  };

  Future<Map<String, dynamic>> query(
    CoreSnapshot source, {
    required String name,
    required String type,
    required String owner,
  }) {
    if (!validDnsInput(name, type)) throw const DnsFailure('invalidRequest');
    return _execute(source, ApplicationContract.coreOperationDnsQuery, {
      'name': name,
      'type': type,
    }, owner);
  }

  Future<Map<String, dynamic>> clear(
    CoreSnapshot source, {
    required bool fakeIp,
    required String owner,
  }) => _execute(
    source,
    fakeIp
        ? ApplicationContract.coreOperationFakeIpFlush
        : ApplicationContract.coreOperationDnsCacheClear,
    const {},
    owner,
  );

  Future<Map<String, dynamic>> _execute(
    CoreSnapshot source,
    int operation,
    Map<String, Object?> arguments,
    String owner,
  ) async {
    if (busy) throw const DnsFailure('busy');
    if (!source.ready || !source.hasIdentity) {
      throw const DnsFailure('unavailable');
    }
    _source = source;
    _owner = owner;
    _admitting = true;
    _cancelRequested = false;
    _error = null;
    _detail = null;
    _cancelError = null;
    _result = null;
    changed();
    final queryDeadline = Timer(
      const Duration(milliseconds: ApplicationContract.dnsQueryTimeoutMs),
      () {
        if (_owner != owner || !busy) return;
        _error = 'timeout';
        _cancelRequested = true;
        final call = _call;
        if (call != null) unawaited(_cancel(call));
        changed();
      },
    );
    final bridgeDeadline = Timer(
      const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
      () {
        if (_owner != owner || !busy) return;
        _error = 'timeout';
        _detail = 'DNS 调用尚未退出';
        changed();
      },
    );
    try {
      final call = await start(operation, source, arguments);
      _call = call;
      _admitting = false;
      if (_cancelRequested) unawaited(_cancel(call));
      final result = await call.result(
        maximumBytes: ApplicationContract.dnsResultBytes,
      );
      final value = result.value;
      final actualError =
          result.error ?? (value is Map ? value['error'] : null);
      _error = switch (actualError) {
        null => null,
        String() => actualError,
        Map() when actualError['code'] is String =>
          actualError['code'] as String,
        _ => 'queryFailed',
      };
      _detail = actualError?.toString();
      _cancelError = result.cancelError ?? _cancelError;
      _result = Map.unmodifiable({
        operation == ApplicationContract.coreOperationDnsQuery
                ? 'dns'
                : 'cache':
            value,
        if (result.error != null) 'error': result.error,
        if (_error != null) 'operationError': _error,
        if (_detail != null) 'operationErrorDetail': _detail,
        if (result.stale || (value is Map && value['stale'] == true))
          'stale': true,
        if (_cancelError != null) 'cancelError': _cancelError,
      });
      return _result!;
    } catch (error) {
      _error = switch (error) {
        DnsFailure(:final code) => code,
        PlatformFailure(:final code) => code,
        _ => 'queryFailed',
      };
      _detail = error.toString();
      rethrow;
    } finally {
      queryDeadline.cancel();
      bridgeDeadline.cancel();
      // CoreCall.result 只有真实退出或进程死亡后才结束。
      _call = null;
      _admitting = false;
      changed();
    }
  }

  void setVisible(bool visible) {
    final source = _source;
    final owner = _owner;
    if (!visible && source != null && owner != null) {
      unawaited(cancel(source, owner));
    }
  }

  Future<void> cancel(CoreSnapshot source, String owner) async {
    if (_source?.matchesIdentity(source) != true || _owner != owner || !busy) {
      return;
    }
    _cancelRequested = true;
    final call = _call;
    if (call != null) await _cancel(call);
    changed();
  }

  Future<void> _cancel(CoreCall call) async {
    if (_cancelling || call.hasExited) return;
    _cancelling = true;
    changed();
    try {
      final result = await call.cancel();
      _cancelError = result['cancelError'] ?? result['error'];
    } catch (error, stack) {
      _cancelError = failureValue(error, stack);
    } finally {
      _cancelling = false;
      changed();
    }
  }
}
