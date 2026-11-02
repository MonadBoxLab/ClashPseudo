import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../../model/messages.dart';
import '../../../model/application_contract.dart';
import '../../../logic/diagnostics/core_collection_page.dart';

class NodesController extends ChangeNotifier {
  NodesController(this.app, {this.provider, this.expectedSource}) {
    app.addListener(_changed);
  }
  final AppController app;
  final String? provider;
  final CoreSnapshot? expectedSource;
  bool sourceExpired = false;
  List<Map<String, dynamic>> nodes = const [];
  Map<String, dynamic>? data;
  Map<String, Object?>? dataQuery;
  AppMessage? readError;
  int total = 0;
  int offset = 0;
  int nextOffset = -1;
  String search = '';
  String? token;
  bool loading = false;
  bool failed = false;
  bool current = false;
  bool _visible = false;
  bool _disposed = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _source;
  String? _loadedSearch;
  Timer? _debounce;
  Timer? _retry;
  Timer? _deadline;
  bool _reading = false;
  int? _queuedStart;
  int _retryMs = 250;

  String _localIdentity = '';
  String? _loadedLocalIdentity;
  List<Map<String, dynamic>> _definitions = const [];
  bool localCurrent = false;

  void setDefinitions(String identity, List<Map<String, dynamic>> definitions) {
    if (_disposed || _localIdentity == identity) return;
    _localIdentity = identity;
    _definitions = definitions;
    _loadedSearch = null;
    _observed = null;
    _changed();
  }

  void _localPage(int start) {
    if (_localIdentity.isEmpty ||
        (_definitions.isEmpty &&
            nodes.any((row) => !row.containsKey('entryId')))) {
      localCurrent = false;
      return;
    }
    final matches =
        (provider == null ? _definitions : const <Map<String, dynamic>>[])
            .where((row) => DefinitionRows.matches(row, search));
    total = matches.length;
    offset = start.clamp(0, total);
    nodes = List.unmodifiable(matches.skip(offset).take(pageSize));
    nextOffset = offset + nodes.length < total ? offset + nodes.length : -1;
    token = DefinitionRows.pageToken('', _localIdentity);
    localCurrent = _localIdentity.isNotEmpty && provider == null;
    current = false;
  }

  static const pageSize = 50;
  bool get active => !_disposed && _visible && app.foreground;
  bool get canRead =>
      active &&
      !sourceExpired &&
      !app.busy &&
      app.platformError == null &&
      app.state.confirmed;
  bool get canPage => active && (current || localCurrent) && !loading;
  bool get preview => _source?.purpose == 'PREVIEW';
  CoreSnapshot? get source => _source;

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    if (!active) _attempted = null;
    final core = app.state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      _localIdentity,
      app.storageEpoch,
      app.busy,
      app.platformErrorMessage,
      app.state.phase,
      app.state.confirmed,
      core.identity,
      core.phase,
      core.errorMessage,
      app.configsCurrent,
      selected?.id,
      selected?.revision,
      app.commandErrorMessage,
      app.state.resultId,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    _debounce?.cancel();
    _retry?.cancel();
    _queuedStart = null;
    _retryMs = 250;
    loading = _reading;
    current = false;
    final expected = expectedSource;
    if (sourceExpired ||
        (expected != null &&
            (!core.ready || !core.matchesIdentity(expected)))) {
      sourceExpired = true;
      failed = false;
      notifyListeners();
      return;
    }
    if (!canRead) {
      failed = active && !app.busy;
    } else if (core.ready) {
      _attempted = null;
      final sameSource =
          _source?.matchesIdentity(core) == true && _loadedSearch == search;
      unawaited(_read(sameSource ? offset : 0));
      return;
    } else if (core.blocked ||
        core.errorMessage != null ||
        !app.configsCurrent) {
      failed = true;
    } else if (!app.state.running &&
        core.phase == 'EMPTY' &&
        selected?.body != null) {
      final identity = (selected!.id, selected.revision);
      if (_attempted != identity) {
        _attempted = identity;
        failed = false;
        unawaited(
          app.submit({
            'action': 'prepareStrategies',
            'id': selected.id,
            'revision': selected.revision,
          }, automatic: true),
        );
      } else {
        failed = true;
      }
    }
    if (!core.ready || failed) _localPage(0);
    notifyListeners();
  }

  void filter(String value) {
    if (search == value || _disposed) return;
    search = value;
    _request++;
    current = false;
    loading = _reading;
    failed = false;
    _queuedStart = null;
    _retryMs = 250;
    _retry?.cancel();
    _debounce?.cancel();
    if (canRead && app.state.core.ready) {
      _debounce = Timer(const Duration(milliseconds: 250), () => _read(0));
    } else {
      _localPage(0);
    }
    notifyListeners();
  }

  Future<void> _read(int start) async {
    if (!canRead || !app.state.core.ready || (localCurrent && start > 0)) {
      _localPage(start);
      notifyListeners();
      return;
    }
    localCurrent = false;
    if (_reading) {
      // Retain the latest intent while the native read slot is occupied.
      _queuedStart = start;
      notifyListeners();
      return;
    }
    _reading = true;
    _queuedStart = null;
    _retry?.cancel();
    var waiting = false;
    final expected = app.state.core;
    final querySearch = search;
    final queryToken = start == 0 ? '' : token;
    final request = ++_request;
    loading = true;
    current = false;
    failed = false;
    notifyListeners();
    const grace = Duration(
      milliseconds: ApplicationContract.operationUiGraceMs,
    );
    final deadline = _deadline = Timer(grace, () {
      if (_disposed) return;
      readError = messages.coreContextUnconfirmed.withDetail(
        TimeoutException('Node read is still pending', grace),
      );
      notifyListeners();
    });
    try {
      final query = {
        if (provider != null) 'source': provider,
        'offset': start,
        'limit': pageSize,
        'search': querySearch,
        'token': queryToken,
        if (provider == null) ...{
          'localIdentity': _localIdentity,
          'definitions': _definitions,
        },
      };
      final value = await app.platform.nodes(expected, query);
      if (_disposed) return;
      data = Map.unmodifiable(value);
      dataQuery = Map.unmodifiable(query);
      if (value['readPending'] == true) {
        if (!expected.matchesWireIdentity(value)) {
          throw const FormatException('Node read slot identity changed');
        }
        if (request == _request && canRead && value['stale'] != true) {
          waiting = true;
          _retry = Timer(Duration(milliseconds: _retryMs), () => _read(start));
          _retryMs = (_retryMs * 2).clamp(250, 1000);
        }
        return;
      }
      final page = value['page'] as Map;
      final count = page['total'] as int;
      final next = page['nextOffset'] as int;
      final version = page['token'] as String;
      final rows = (page['nodes'] as List)
          .map((item) => Map<String, dynamic>.unmodifiable(item as Map))
          .toList();
      if (count < start + rows.length ||
          (start > 0 && version != queryToken) ||
          (next != -1 &&
              (next != start + rows.length || next >= count || rows.isEmpty))) {
        throw const FormatException('Node page changed');
      }
      nodes = List.unmodifiable(rows);
      total = count;
      offset = start;
      nextOffset = next;
      token = version;
      _source = expected;
      _loadedSearch = querySearch;
      _retryMs = 250;
      _loadedLocalIdentity = _localIdentity;
      readError = null;
      current =
          canRead &&
          request == _request &&
          value['stale'] != true &&
          expected.matchesIdentity(app.state.core) &&
          expected.matchesWireIdentity(value);
    } catch (error) {
      if (_disposed) return;
      readError = error is PlatformFailure
          ? messageFromFailure(error, fallback: messages.operationFailed)
          : messages.operationFailed.withDetail(error);
      failed = true;
      if (_source?.matchesIdentity(app.state.core) != true ||
          _loadedSearch != search ||
          _loadedLocalIdentity != _localIdentity) {
        _localPage(0);
      }
    } finally {
      deadline.cancel();
      _deadline = null;
      _reading = false;
      if (!_disposed) {
        loading = waiting;
        notifyListeners();
        final queued = _queuedStart;
        _queuedStart = null;
        if (queued != null && canRead && app.state.core.ready) {
          unawaited(_read(queued));
        }
      }
    }
  }

  Future<void> next() async {
    if (canPage && nextOffset >= 0) await _read(nextOffset);
  }

  Future<void> previous() async {
    if (canPage && offset > 0) {
      await _read((offset - pageSize).clamp(0, offset));
    }
  }

  Future<void> refresh() async {
    if (!active || loading || app.busy) return;
    _attempted = null;
    _observed = null;
    _loadedSearch = null;
    await app.refresh();
    if (!active) return;
    final selected = app.collection.selected;
    if (!app.busy &&
        !app.state.running &&
        app.state.core.phase == 'EMPTY' &&
        app.state.core.errorMessage != null &&
        app.configsCurrent &&
        selected?.body != null) {
      _attempted = (selected!.id, selected.revision);
      await app.submit({
        'action': 'prepareStrategies',
        'id': selected.id,
        'revision': selected.revision,
      });
    } else {
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _debounce?.cancel();
    _retry?.cancel();
    _deadline?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
