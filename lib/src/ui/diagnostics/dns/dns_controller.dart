import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../../model/messages.dart';
import '../../../model/core_snapshot.dart';
import '../../../model/dns_snapshot.dart';

enum DnsStatus { ready, preparing, unavailable, empty, querying, stale, failed }

/// 查询草稿和阅读状态留在页面；执行、期限和取消排空由 AppRuntime 持有。
class DnsController extends ChangeNotifier {
  DnsController(this.app) {
    app.addListener(_changed);
  }

  final AppController app;
  String name = '';
  String type = 'A';
  DnsStatus status = DnsStatus.ready;
  DnsResponse? response;
  String? errorCode;
  String? errorDetail;
  String? cancellationError;
  bool stale = false;
  bool clearing = false;
  bool? clearingFakeIp;
  bool _visible = false;
  bool _disposed = false;
  bool _submitting = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _queryCore;
  String? _queryOwner;

  bool get active => !_disposed && _visible && app.foreground;
  int get contextVersion => _request;
  bool get queryBusy => _submitting || app.state.dnsBusy;
  bool get busy => queryBusy || clearing;
  bool get available =>
      active &&
      !app.busy &&
      app.platformError == null &&
      app.state.confirmed &&
      app.state.core.ready &&
      app.state.core.hasIdentity &&
      app.state.networkEpoch != null;
  bool get canQuery => available && !busy;
  bool get canRefresh => active && !_submitting && !clearing && !app.busy;

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _changed();
  }

  void setName(String value) {
    if (_disposed || value == name) return;
    name = value;
    _edited();
  }

  void setType(String value) {
    if (_disposed || !dnsRecordTypes.contains(value) || value == type) return;
    type = value;
    _edited();
  }

  void _edited() {
    if (response != null) stale = true;
    if (errorCode == 'invalidRequest') {
      errorCode = null;
      errorDetail = null;
      status = response == null ? DnsStatus.ready : DnsStatus.stale;
    }
    notifyListeners();
  }

  void _changed() {
    if (_disposed) return;
    final operation = app.state.dnsOperation;
    if (_queryOwner != null && operation['queryOwner'] == _queryOwner) {
      if (operation['error'] is String &&
          (_submitting || operation['busy'] == true)) {
        errorCode = operation['error'] as String;
        errorDetail = operation['errorDetail']?.toString();
        status = DnsStatus.failed;
      }
      cancellationError = operation['cancelError']?.toString();
    }
    final core = app.state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.platformError,
      app.configsCurrent,
      app.state.phase,
      app.state.storageEpoch,
      app.state.networkEpoch,
      core.identity,
      core.networkRevision,
      core.phase,
      core.errorMessage,
      selected?.id,
      selected?.revision,
    );
    if (_observed == key) {
      notifyListeners();
      return;
    }
    _observed = key;
    _request++;
    _cancelQuery();
    if (response != null) stale = true;
    if (!active || app.busy) {
      status = response == null ? DnsStatus.unavailable : DnsStatus.stale;
    } else if (app.platformError != null ||
        !app.state.confirmed ||
        core.blocked ||
        app.state.recoveryRequired) {
      status = DnsStatus.unavailable;
    } else if (core.ready && core.hasIdentity) {
      status = queryBusy
          ? DnsStatus.querying
          : response == null
          ? DnsStatus.ready
          : DnsStatus.stale;
    } else if (!app.configsCurrent || core.errorMessage != null) {
      status = DnsStatus.unavailable;
    } else if (!app.state.forwarding &&
        core.phase == 'EMPTY' &&
        selected != null) {
      final identity = (selected.id, selected.revision, app.state.storageEpoch);
      if (_attempted != identity) {
        _attempted = identity;
        status = DnsStatus.preparing;
        unawaited(
          app.submit({
            'action': 'prepareStrategies',
            'id': selected.id,
            'revision': selected.revision,
          }, automatic: true),
        );
      } else {
        status = DnsStatus.unavailable;
      }
    } else {
      status = DnsStatus.empty;
    }
    notifyListeners();
  }

  bool _current(int request, CoreSnapshot core, int? network) =>
      active &&
      request == _request &&
      available &&
      core.matchesIdentity(app.state.core) &&
      core.networkRevision == app.state.core.networkRevision &&
      app.state.networkEpoch == network;

  bool _envelopeMatches(
    Map<String, dynamic> value,
    CoreSnapshot core,
    int? network,
  ) =>
      core.matchesWireIdentity(value) &&
      value['networkRevision'] == core.networkRevision &&
      value['networkEpoch'] == network;

  Future<void> query() async {
    if (!canQuery) return;
    final core = app.state.core;
    final network = app.state.networkEpoch;
    final request = ++_request;
    final queriedName = name;
    final queriedType = type;
    final random = Random.secure();
    final owner = List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    _submitting = true;
    _queryCore = core;
    _queryOwner = owner;
    errorCode = null;
    errorDetail = null;
    cancellationError = null;
    stale = response != null;
    status = DnsStatus.querying;
    notifyListeners();
    try {
      final value = await app.platform.dnsQuery(
        core,
        name: queriedName,
        type: queriedType,
        queryOwner: owner,
      );
      if (_disposed) return;
      if (!_envelopeMatches(value, core, network)) {
        throw DnsFailure('invalidResponse', detail: value.toString());
      }
      final result = DnsResponse.fromMap(value);
      response = result;
      errorCode = result.errorCode;
      errorDetail = result.errorDetail;
      cancellationError = (value['cancelError'] ?? result.cancellationError)
          ?.toString();
      stale =
          result.stale ||
          !_current(request, core, network) ||
          name != queriedName ||
          type != queriedType;
      status = errorCode != null
          ? DnsStatus.failed
          : stale
          ? DnsStatus.stale
          : DnsStatus.ready;
    } catch (error) {
      if (_disposed) return;
      errorCode = _code(error);
      errorDetail = _detail(error);
      stale |= !_current(request, core, network);
      status = stale || errorCode == 'obsolete'
          ? DnsStatus.stale
          : DnsStatus.failed;
    } finally {
      _queryCore = null;
      _submitting = false;
      if (!_disposed) {
        await app.refresh();
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<DnsCacheResult?> clearCache({required bool fakeIp}) async {
    if (!canQuery) return null;
    final core = app.state.core;
    final network = app.state.networkEpoch;
    clearing = true;
    clearingFakeIp = fakeIp;
    notifyListeners();
    try {
      final value = await (fakeIp
          ? app.platform.flushFakeIp(core)
          : app.platform.clearDnsCache(core));
      if (!_envelopeMatches(value, core, network)) {
        throw DnsFailure('invalidResponse', detail: value.toString());
      }
      return DnsCacheResult.fromMap(value, fakeIp: fakeIp);
    } on PlatformFailure catch (error) {
      if (error.code != 'resultTooLarge') rethrow;
      throw DnsFailure('resultTooLarge', detail: _detail(error));
    } finally {
      clearing = false;
      clearingFakeIp = null;
      if (!_disposed) {
        await app.refresh();
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _attempted = null;
    _observed = null;
    await app.refresh();
    if (active) _changed();
  }

  void _cancelQuery() {
    final core = _queryCore;
    final owner = _queryOwner;
    if (core == null || owner == null) return;
    unawaited(
      app.platform.cancelDnsQuery(core, queryOwner: owner).catchError((
        Object error,
      ) {
        if (_disposed || _queryOwner != owner) return;
        cancellationError = _detail(error);
        notifyListeners();
      }),
    );
  }

  String? _detail(Object error) => switch (error) {
    DnsFailure(:final detail) => detail,
    PlatformFailure() =>
      messageFromFailure(
            error,
            fallback: messages.androidErrorCoreReadFailed,
          ).detail ??
          error.toString(),
    _ => error.toString(),
  };

  String _code(Object error) => switch (error) {
    DnsFailure(:final code) => code,
    PlatformFailure(code: 'resultTooLarge') => 'resultTooLarge',
    PlatformFailure(code: 'invalidRequest') => 'invalidRequest',
    PlatformFailure(code: 'timeout') => 'timeout',
    _ => 'queryFailed',
  };

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _cancelQuery();
    app.removeListener(_changed);
    super.dispose();
  }
}
