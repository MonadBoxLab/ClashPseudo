import 'package:flutter/foundation.dart';

/// 记录系统打开总览的请求及各路由的离开确认回调，不持有 Navigator 或业务状态。
class SystemNavigationRequests {
  SystemNavigationRequests(this._changed);

  final VoidCallback _changed;
  bool _overviewRequested = false;
  final _leaves = <Object, Future<bool> Function()>{};
  bool _disposed = false;

  void requestOverview() {
    if (_disposed) return;
    _overviewRequested = true;
    _changed();
  }

  bool takeOverviewRequest() {
    final requested = _overviewRequested;
    _overviewRequested = false;
    return requested;
  }

  void registerLeave(Object route, Future<bool> Function() leave) {
    if (!_disposed) _leaves[route] = leave;
  }

  void unregisterLeave(Object route, Future<bool> Function() leave) {
    if (identical(_leaves[route], leave)) _leaves.remove(route);
  }

  Future<bool> Function()? leaveFor(Object route) => _leaves[route];

  void dispose() {
    _disposed = true;
    _overviewRequested = false;
    _leaves.clear();
  }
}
