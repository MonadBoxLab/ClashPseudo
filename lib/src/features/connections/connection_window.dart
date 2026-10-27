import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'connection_snapshot.dart';
import '../../model/application_contract.dart';

class ConnectionWindow {
  static const activeLimit = ApplicationContract.connectionActiveEntries;
  static const inactiveLimit = ApplicationContract.connectionInactiveEntries;
  static const retentionMs = ApplicationContract.connectionInactiveRetentionMs;
  static const maxSpeedIntervalMs = 5000;

  final _records = <String, _ObservedConnection>{};
  _ObservedConnection? _detail;
  String? _pin;
  String? missingDetailId;
  bool limited = false;
  DateTime? observedAt;

  List<ConnectionRecord> get records =>
      _records.values.map((row) => row.record).toList();
  ConnectionRecord? get detail =>
      _pin == null ? null : (_records[_pin] ?? _detail)?.record;
  bool get isNotEmpty => _records.isNotEmpty;
  String? get pin => _pin;

  Map<String, Object?> get parameters => {
    'limit': activeLimit,
    'previousActiveIds': [
      for (final row in _records.values)
        if (row.record.active) row.record.id,
    ],
    if (_pin != null) 'detailId': _pin,
  };

  void pinDetail(String? id) {
    if (_pin == id) return;
    _pin = id;
    missingDetailId = null;
    _detail = id == null ? null : _records[id];
  }

  void clear() {
    _records.clear();
    _detail = null;
    _pin = null;
    missingDetailId = null;
    limited = false;
    observedAt = null;
  }

  void invalidate() {
    for (final row in {..._records.values, ?_detail}) {
      row.baselineMs = null;
      if (row.record.active) row.record = row.record.observed(active: true);
    }
  }

  void accept(
    Map<String, dynamic> value,
    CoreSnapshot core,
    Map<String, Object?> request,
  ) {
    final snapshot = ConnectionSnapshot.fromMap(value);
    final elapsed = value['elapsedMs'];
    final stamp = value['observedAt'];
    final presence = value['presence'];
    if (value['complete'] != true ||
        !snapshot.matches(core) ||
        snapshot.records.length > activeLimit ||
        snapshot.records.any((row) => !row.active) ||
        elapsed is! int ||
        elapsed < 0 ||
        stamp is! int ||
        presence is! Map ||
        presence.length >
            activeLimit + ApplicationContract.connectionExtraDetails) {
      throw const FormatException('Incomplete connection sample');
    }
    final watched = <String>{
      ...request['previousActiveIds'] as List<String>,
      if (request['detailId'] is String) request['detailId'] as String,
    };
    if (watched.any((id) => presence[id] is! bool)) {
      throw const FormatException('Missing connection presence');
    }
    final selected = snapshot.records.map((row) => row.id).toSet();
    if (selected.any((id) => presence[id] == false) ||
        (snapshot.detail != null &&
            (snapshot.detail!.id != request['detailId'] ||
                presence[snapshot.detail!.id] != true ||
                selected.contains(snapshot.detail!.id)))) {
      throw const FormatException('Inconsistent connection sample');
    }
    if (request['detailId'] is String &&
        presence[request['detailId']] == true &&
        !selected.contains(request['detailId']) &&
        snapshot.detail == null) {
      throw const FormatException('Missing pinned connection');
    }
    if (_records.values.any(
      (row) =>
          row.record.active &&
          !selected.contains(row.record.id) &&
          presence[row.record.id] is! bool,
    )) {
      throw const FormatException('Unconfirmed missing connection');
    }
    final at = DateTime.fromMillisecondsSinceEpoch(stamp);
    final next = <String, _ObservedConnection>{};
    for (final row in _records.values) {
      if (!row.record.active) {
        next[row.record.id] = row;
      } else if (!selected.contains(row.record.id)) {
        if (presence[row.record.id] == false) {
          row.end(elapsed);
          next[row.record.id] = row;
        } else if (presence[row.record.id] != true) {
          throw const FormatException('Unconfirmed missing connection');
        }
      }
    }
    for (final record in snapshot.records) {
      final old =
          _records[record.id] ??
          (_detail?.record.id == record.id ? _detail : null);
      next[record.id] = _observe(record, old, elapsed, at);
    }
    if (_pin != null && _pin == request['detailId']) {
      missingDetailId = presence[_pin] == false ? _pin : null;
      if (next[_pin] != null) {
        _detail = next[_pin];
      } else if (presence[_pin] == false) {
        _detail?.end(elapsed);
      } else if (snapshot.detail != null) {
        _detail = _observe(snapshot.detail!, _detail, elapsed, at);
      } else if (presence[_pin] == true) {
        throw const FormatException('Missing pinned connection');
      }
    }
    _records
      ..clear()
      ..addAll(next);
    observedAt = at;
    limited = snapshot.limited;
    prune(elapsed);
  }

  _ObservedConnection _observe(
    ConnectionRecord record,
    _ObservedConnection? old,
    int elapsed,
    DateTime at,
  ) {
    final interval = old?.baselineMs == null
        ? null
        : elapsed - old!.baselineMs!;
    double? speed(int? value, int? before) =>
        interval != null &&
            interval > 0 &&
            interval <= maxSpeedIntervalMs &&
            old!.record.active &&
            value != null &&
            before != null &&
            value >= before
        ? (value - before) * 1000 / interval
        : null;
    return _ObservedConnection(
      record
          .retainingRulesFrom(old?.record)
          .observed(
            active: true,
            at: at,
            uploadSpeed: speed(record.upload, old?.record.upload),
            downloadSpeed: speed(record.download, old?.record.download),
          ),
      elapsed,
    );
  }

  void end(String id, int now) {
    final row = _records[id] ?? (_detail?.record.id == id ? _detail : null);
    if (row == null) return;
    row.end(now);
    _records[id] = row;
    prune(now);
  }

  void stop(int now) {
    for (final row in {..._records.values, ?_detail}) {
      row.end(now);
    }
    prune(now);
  }

  void prune(int now) {
    _records.removeWhere(
      (_, row) => row.endedMs != null && now - row.endedMs! >= retentionMs,
    );
    final inactive = _records.values
        .where((row) => row.endedMs != null)
        .toList();
    if (inactive.length <= inactiveLimit) return;
    inactive.sort((a, b) {
      final ended = a.endedMs!.compareTo(b.endedMs!);
      if (ended != 0) return ended;
      final started = (a.record.start?.millisecondsSinceEpoch ?? 0).compareTo(
        b.record.start?.millisecondsSinceEpoch ?? 0,
      );
      return started != 0 ? started : b.record.id.compareTo(a.record.id);
    });
    for (var i = 0; i < inactive.length - inactiveLimit; i++) {
      _records.remove(inactive[i].record.id);
    }
  }

  int? nextExpiry(int now) {
    int? next;
    for (final row in _records.values) {
      if (row.endedMs == null) continue;
      final delay = (row.endedMs! + retentionMs - now).clamp(0, retentionMs);
      if (next == null || delay < next) next = delay;
    }
    return next;
  }
}

class _ObservedConnection {
  _ObservedConnection(this.record, this.baselineMs);
  ConnectionRecord record;
  int? baselineMs;
  int? endedMs;

  void end(int now) {
    if (!record.active) return;
    record = record.observed(active: false);
    baselineMs = null;
    endedMs = now;
  }
}
