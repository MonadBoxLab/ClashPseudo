import 'dart:async';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import '../../../support/dns_wire_fixtures.dart';

export '../../../support/dns_wire_fixtures.dart';

class DnsTestBridge extends AppBridge {
  final queries =
      <({CoreSnapshot core, String name, String type, String queryOwner})>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  final cancellations = <({CoreSnapshot core, String queryOwner})>[];
  final clears = <bool>[];
  Completer<Map<String, dynamic>>? clearPending;
  Map<String, dynamic>? clearValue;
  Object? cancellationError;
  Completer<void>? cancellationPending;

  @override
  Future<Map<String, dynamic>> dnsQuery(
    CoreSnapshot core, {
    required String name,
    required String type,
    required String queryOwner,
  }) {
    queries.add((core: core, name: name, type: type, queryOwner: queryOwner));
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }

  @override
  Future<void> cancelDnsQuery(
    CoreSnapshot core, {
    required String queryOwner,
  }) async {
    cancellations.add((core: core, queryOwner: queryOwner));
    if (cancellationPending case final pending?) await pending.future;
    if (cancellationError case final error?) throw error;
  }

  @override
  Future<Map<String, dynamic>> clearDnsCache(CoreSnapshot core) {
    clears.add(false);
    return clearPending?.future ??
        Future.value(clearValue ?? dnsCacheReply(core: core));
  }

  @override
  Future<Map<String, dynamic>> flushFakeIp(CoreSnapshot core) {
    clears.add(true);
    return clearPending?.future ??
        Future.value(clearValue ?? dnsCacheReply(core: core, fakeIp: true));
  }
}

class DnsTestApp extends AppController {
  DnsTestApp(super.platform) {
    loading = false;
    configsLoaded = true;
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      core: dnsCore(),
      networkEpoch: 1,
    );
  }
  final commands = <Map<String, Object?>>[];
  int refreshes = 0;
  Completer<void>? refreshPending;
  void Function()? onRefresh;

  void publish({
    CoreSnapshot? core,
    String phase = 'RUNNING',
    int generation = 1,
    int? network = 1,
    bool dnsBusy = false,
  }) {
    state = AppSnapshot(
      phase: phase,
      generation: generation,
      core: core ?? dnsCore(),
      networkEpoch: network,
      dnsBusy: dnsBusy,
    );
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    if (refreshPending != null) await refreshPending!.future;
    onRefresh?.call();
    notifyListeners();
  }

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    return 'controlled-operation';
  }
}
