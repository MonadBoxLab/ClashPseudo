import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../model/core_snapshot.dart';
import '../../model/application_contract.dart';
import 'dns_snapshot.dart';

enum DnsStatus { ready, preparing, unavailable, empty, querying, stale, failed }

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
  bool stale = false;
  bool clearing = false;
  bool? clearingFakeIp;
  bool _visible = false;
  bool _disposed = false;
  bool _flight = false;
  bool _draining = false;
  bool _drainRead = false;
  bool _sawDrainBusy = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _queryCore;
  String? _queryOwner;
  Timer? _deadline;

  bool get active => !_disposed && _visible && app.foreground;
  int get contextVersion => _request;
  bool get queryBusy => _flight || _draining || app.state.dnsBusy;
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
  bool get canRefresh => active && !_flight && !clearing && !app.busy;

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
    // Draft editing updates local input only.
    if (response != null) stale = true;
    if (errorCode == 'invalidRequest') {
      errorCode = null;
      status = response == null ? DnsStatus.ready : DnsStatus.stale;
    }
    notifyListeners();
  }

  void _changed() {
    if (_disposed) return;
    if (_draining) {
      if (app.state.dnsBusy) _sawDrainBusy = true;
      if (_sawDrainBusy && !app.state.dnsBusy && app.platformError == null) {
        _draining = false;
        _sawDrainBusy = false;
      }
    }
    final core = app.state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.platformError,
      app.configsCurrent,
      app.state.phase,
      app.state.generation,
      app.state.storageEpoch,
      app.state.networkEpoch,
      core.identity,
      core.phase,
      core.errorMessage,
      selected?.id,
      selected?.revision,
    );
    if (_observed == key) {
      notifyListeners(); // A native drain notification can change only dnsBusy.
      return;
    }
    _observed = key;
    _request++;
    _deadline?.cancel();
    _cancelQuery();
    if (response != null) stale = true;
    errorCode = null;
    if (!active || app.busy) {
      status = response == null ? DnsStatus.unavailable : DnsStatus.stale;
    } else if (app.platformError != null ||
        !app.state.confirmed ||
        core.blocked) {
      status = DnsStatus.unavailable;
    } else if (core.ready && core.hasIdentity) {
      status = response == null ? DnsStatus.ready : DnsStatus.stale;
    } else if (!app.configsCurrent || core.error != null) {
      status = DnsStatus.unavailable;
    } else if (!app.state.running &&
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
    if (active && _draining) unawaited(_refreshDrain());
  }

  bool _current(int request, CoreSnapshot core, int? network) =>
      active &&
      request == _request &&
      available &&
      core.matchesIdentity(app.state.core) &&
      app.state.networkEpoch == network;

  bool _envelopeMatches(
    Map<String, dynamic> value,
    CoreSnapshot core,
    int? network,
  ) => core.matchesWireIdentity(value) && value['networkEpoch'] == network;

  Future<void> query() async {
    if (!canQuery) return;
    if (!validDnsInput(name, type)) {
      errorCode = 'invalidRequest';
      status = DnsStatus.failed;
      notifyListeners();
      return;
    }
    final core = app.state.core;
    final network = app.state.networkEpoch;
    final request = ++_request;
    final queriedName = name;
    final queriedType = type;
    final random = Random.secure();
    final queryOwner = List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    _flight = true;
    _queryCore = core;
    _queryOwner = queryOwner;
    errorCode = null;
    stale = response != null;
    status = DnsStatus.querying;
    notifyListeners();
    // Keep both gates through the actual bridge Future's completion.
    _deadline = Timer(
      const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
      () {
        if (!_current(request, core, network)) return;
        errorCode = 'timeout';
        status = DnsStatus.failed;
        _cancelQuery();
        notifyListeners();
      },
    );
    var needsDrain = false;
    try {
      final value = await app.platform.dnsQuery(
        core,
        name: queriedName,
        type: queriedType,
        queryOwner: queryOwner,
      );
      if (!_current(request, core, network)) return;
      if (errorCode == 'timeout') {
        needsDrain = true;
        return;
      }
      if (!_envelopeMatches(value, core, network)) {
        throw const DnsFailure('obsolete');
      }
      final result = DnsResponse.fromMap(value);
      response = result;
      stale = name != queriedName || type != queriedType;
      status = stale ? DnsStatus.stale : DnsStatus.ready;
    } catch (error) {
      needsDrain = true;
      if (!_current(request, core, network)) return;
      errorCode = errorCode == 'timeout' ? 'timeout' : _code(error);
      status = errorCode == 'obsolete' ? DnsStatus.stale : DnsStatus.failed;
    } finally {
      _deadline?.cancel();
      _queryCore = null;
      _queryOwner = null;
      _flight = false;
      if (!_disposed) {
        // A bridge timeout/cancel can precede the actual resolver return. Read
        // the native gate and wait for its normal changed notification to drain.
        if (needsDrain || request != _request) await _refreshDrain();
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<DnsCacheResult?> clearCache({required bool fakeIp}) async {
    if (!canQuery) return null;
    final request = _request;
    final core = app.state.core;
    final network = app.state.networkEpoch;
    clearing = true;
    clearingFakeIp = fakeIp;
    notifyListeners();
    var completed = false;
    try {
      final value = await (fakeIp
          ? app.platform.flushFakeIp(core)
          : app.platform.clearDnsCache(core));
      if (!_current(request, core, network)) throw const DnsFailure('obsolete');
      if (!_envelopeMatches(value, core, network)) {
        throw const DnsFailure('obsolete');
      }
      final result = DnsCacheResult.fromMap(value, fakeIp: fakeIp);
      completed = true;
      return result;
    } finally {
      if (!_disposed && !completed) await _refreshDrain();
      clearing = false;
      clearingFakeIp = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _refreshDrain() async {
    _draining = true;
    _sawDrainBusy |= app.state.dnsBusy;
    notifyListeners();
    // Use the actual cancelled-query completion as the barrier before refresh.
    if (_drainRead || !app.foreground) return;
    _drainRead = true;
    try {
      await app.refresh();
      if (!_disposed &&
          app.foreground &&
          app.platformError == null &&
          !app.state.dnsBusy) {
        _draining = false;
        _sawDrainBusy = false;
      }
    } catch (_) {
      // Keep the gate closed. An explicit refresh can establish completion.
    } finally {
      _drainRead = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    if (_draining) {
      await _refreshDrain();
      if (!_disposed) notifyListeners();
      return;
    }
    _attempted = null;
    _observed = null;
    await app.refresh();
    if (!active) return;
    final selected = app.collection.selected;
    if (!app.busy &&
        !app.state.running &&
        app.state.core.phase == 'EMPTY' &&
        app.state.core.error != null &&
        app.configsCurrent &&
        selected != null) {
      _attempted = (selected.id, selected.revision, app.state.storageEpoch);
      await app.submit({
        'action': 'prepareStrategies',
        'id': selected.id,
        'revision': selected.revision,
      });
    } else {
      _changed();
    }
  }

  void _cancelQuery() {
    final core = _queryCore;
    final queryOwner = _queryOwner;
    if (core != null && queryOwner != null) {
      unawaited(
        app.platform
            .cancelDnsQuery(core, queryOwner: queryOwner)
            .catchError((Object _) {}),
      );
    }
  }

  String _code(Object error) => switch (error) {
    DnsFailure(:final code) => code,
    PlatformException(code: 'timeout') => 'timeout',
    _ => 'queryFailed',
  };

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _deadline?.cancel();
    _cancelQuery();
    app.removeListener(_changed);
    super.dispose();
  }
}
