import 'dart:convert';

import '../../model/application_contract.dart';
import '../../model/platform_failure.dart';
import '../../model/definition_provenance.dart';
import '../../platform/core/core_client.dart';

/// Associates source definitions with runtime records only through exact provenance.
class DefinitionRows {
  DefinitionRows(Iterable<Map<String, dynamic>> definitions)
    : _definitions = {
        for (final row in definitions) row['localDefinition'] as String: row,
      };

  final Map<String, Map<String, dynamic>> _definitions;
  final Set<String> _matched = {};

  Map<String, dynamic> associate(Map<String, dynamic> record) {
    // Downloaded provider content cannot be edited as a direct definition.
    if (record['sourceKind'] == 'proxyProvider') return record;
    final provenance = DefinitionProvenance.tryFromValue(record['provenance']);
    if (provenance == null) return record;
    for (final contribution in provenance.contributors) {
      if (!contribution.isLocalCustom) continue;
      for (final entry in _definitions.entries) {
        final row = entry.value;
        if (row['entryId'] == contribution.id &&
            row['revision'] == contribution.revision &&
            row['definitionPath'] == contribution.path &&
            (row['kind'] == null || row['kind'] == record['kind']) &&
            _matched.add(entry.key)) {
          return {...record, 'localDefinition': entry.key};
        }
      }
    }
    return record;
  }

  Iterable<Map<String, dynamic>> get remaining => _definitions.entries
      .where((entry) => !_matched.contains(entry.key))
      .map((entry) => entry.value);

  static List<Map<String, dynamic>> merge(
    Iterable<Map<String, dynamic>> records,
    Iterable<Map<String, dynamic>> definitions,
  ) {
    final projection = DefinitionRows(definitions);
    return [...records.map(projection.associate), ...projection.remaining];
  }

  static bool matches(Map<String, dynamic> row, String search) {
    final query = search.trim().toLowerCase();
    if (query.isEmpty) return true;
    const keys = [
      'name',
      'type',
      'source',
      'sourceName',
      'index',
      'payload',
      'target',
      'kind',
      'vehicleType',
      'behavior',
      'format',
      'providers',
      'resources',
    ];
    for (final key in keys) {
      final value = row[key];
      if (value is String && value.toLowerCase().contains(query)) return true;
      if (value is num && value.toString().contains(query)) return true;
      if (value is List &&
          value.whereType<String>().any(
            (item) => item.toLowerCase().contains(query),
          )) {
        return true;
      }
    }
    return false;
  }

  static String pageToken(String native, String local) =>
      local.isEmpty ? native : jsonEncode([native, local]);
}

/// Searches every record in the full public export, retaining only the current page and
/// counts.
class CoreCollectionPage {
  const CoreCollectionPage({
    required this.rows,
    required this.total,
    required this.offset,
    required this.source,
    required this.metadata,
    required this.terminal,
  });
  final List<Map<String, dynamic>> rows;
  final int total;
  final int offset;
  final String source;
  final Map<String, dynamic> metadata;
  final Map<String, dynamic> terminal;

  int get nextOffset =>
      offset + rows.length < total ? offset + rows.length : -1;

  static Future<CoreCollectionPage> read(
    CoreCall call, {
    required int offset,
    required int limit,
    required String search,
    String token = '',
    String localIdentity = '',
    Iterable<Map<String, dynamic>> definitions = const [],
    Map<String, dynamic> Function(Map<String, dynamic>)? project,
  }) async {
    final projection = DefinitionRows(definitions);
    final rows = <Map<String, dynamic>>[];
    final metadata = <String, dynamic>{};
    Map<String, dynamic>? terminal;
    var seen = 0;
    var matched = 0;
    void accept(Map<String, dynamic> row) {
      if (!DefinitionRows.matches(row, search)) return;
      if (matched >= offset && rows.length < limit) {
        rows.add(Map.unmodifiable(row));
      }
      matched++;
    }

    try {
      if (offset < 0 || limit < 1 || limit > 1000) {
        throw const FormatException('Invalid page range');
      }
      await for (final frame in call.frames()) {
        switch (frame.kind) {
          case ApplicationContract.coreIpcFrameMetadata:
            metadata.addAll(frame.object);
          case ApplicationContract.coreIpcFrameRecord:
            seen++;
            final record = frame.object;
            accept(projection.associate(project?.call(record) ?? record));
          case ApplicationContract.coreIpcFrameTerminal:
            terminal = frame.object;
          default:
            throw const FormatException(
              'Collection export contains an invalid frame',
            );
        }
      }
      if (terminal != null) terminal = await call.finish(terminal);
      final source = terminal?['source'];
      if (terminal?['error'] != null) {
        throw PlatformFailure(
          code: ApplicationContract.coreErrorCallFailed,
          details: {
            'error': terminal!['error'],
            if (terminal['cancelError'] != null)
              'cancelError': terminal['cancelError'],
            if (terminal['nativeReceipt'] != null)
              'nativeReceipt': terminal['nativeReceipt'],
          },
        );
      }
      if (terminal == null ||
          terminal['complete'] != true ||
          terminal['recordCount'] != seen ||
          source is! String ||
          source.isEmpty ||
          terminal['stale'] == true ||
          metadata['source'] != null && metadata['source'] != source ||
          token.isNotEmpty &&
              token != DefinitionRows.pageToken(source, localIdentity)) {
        final reason =
            'Collection source changed or export is incomplete: '
            'complete=${terminal?["complete"] is bool ? terminal!["complete"] : "invalid"}, '
            'recordCount=${terminal?["recordCount"] is int ? terminal!["recordCount"] : "invalid"}, '
            'read=$seen, stale=${terminal?["stale"] == true}, '
            'metadataSource=${metadata["source"] is String ? metadata["source"] : "invalid"}, '
            'source=${source is String ? source : "invalid"}, '
            'tokenMismatch=${token.isNotEmpty && source is String && token != DefinitionRows.pageToken(source, localIdentity)}';
        final receipt = terminal?['nativeReceipt'];
        if (terminal?['cancelError'] != null ||
            receipt is Map && receipt.isNotEmpty) {
          throw PlatformFailure(
            code: ApplicationContract.coreErrorCallFailed,
            details: {
              'error': reason,
              if (terminal?['cancelError'] != null)
                'cancelError': terminal!['cancelError'],
              if (terminal?['nativeReceipt'] != null)
                'nativeReceipt': terminal!['nativeReceipt'],
            },
          );
        }
        throw FormatException(reason);
      }
      projection.remaining.forEach(accept);
      if (metadata['scopes'] case final List scopes
          when definitions.any(
            (row) =>
                (row['definitionPath'] as String? ?? '').startsWith('/rules/'),
          )) {
        metadata['scopes'] = [
          for (final scope in scopes)
            if (scope is Map && scope['kind'] == 'main')
              {...scope, 'count': seen + projection.remaining.length}
            else
              scope,
        ];
      }
    } catch (error, stack) {
      return call.fail(error, stack);
    }
    return CoreCollectionPage(
      rows: List.unmodifiable(rows),
      total: matched,
      offset: offset,
      source: terminal['source'] as String,
      metadata: Map.unmodifiable(metadata),
      terminal: Map.unmodifiable(terminal),
    );
  }
}
