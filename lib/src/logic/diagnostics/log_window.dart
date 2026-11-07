import 'dart:collection';
import 'dart:convert';

import '../../model/application_contract.dart';

/// AppRuntime owns the sole log window; transport queues do not retain history.
class LogWindow {
  static const capacity = ApplicationContract.logEntries;
  static const byteCapacity = ApplicationContract.logTextBytes;

  final _entries = Queue<Map<String, dynamic>>();
  final _sizes = Queue<int>();
  String? _source;
  int _bytes = 0;
  int _next = 0;
  int _cleared = 0;
  int _total = 0;
  int _dropped = 0;
  int _transportDropped = 0;
  int _transportCleared = 0;
  int _sequenceDropped = 0;

  String? get source => _source;
  bool get hasWindow => _source != null;
  int get retainedBytes => _bytes;
  int get length => _entries.length;
  int get watermark => _next;

  void begin(String source) {
    if (source.isEmpty) throw ArgumentError.value(source, 'source');
    if (_source == source) return;
    _source = source;
    _entries.clear();
    _sizes.clear();
    _bytes = 0;
    _next = 0;
    _cleared = 0;
    _total = 0;
    _dropped = 0;
    _transportDropped = 0;
    _transportCleared = 0;
    _sequenceDropped = 0;
  }

  void accept(String source, Map<String, dynamic> event) {
    if (_source != source) return;
    final sequence = event['seq'];
    final text = event['text'];
    if (sequence is! int || sequence <= 0 || text is! String) {
      throw const FormatException(
        'Log event is missing its sequence number or text',
      );
    }
    if (sequence <= _next || sequence <= _cleared) return;
    _sequenceDropped += sequence - _next - 1;
    if (_sequenceDropped > _transportDropped) {
      _transportDropped = _sequenceDropped;
    }
    _next = sequence;
    _total++;
    final bytes = utf8.encode(text).length;
    if (bytes > byteCapacity) {
      _dropped++;
      return;
    }
    final row = Map<String, dynamic>.unmodifiable(event);
    _entries.add(row);
    _sizes.add(bytes);
    _bytes += bytes;
    while (_entries.length > capacity || _bytes > byteCapacity) {
      _entries.removeFirst();
      _bytes -= _sizes.removeFirst();
      _dropped++;
    }
  }

  void transportDropped(String source, int count) {
    if (_source != source || count < 0) return;
    if (count > _transportDropped) _transportDropped = count;
  }

  /// In-flight FD events and the transport queue share a watermark; older receipts
  /// cannot lower it.
  void clear(String source, {int? through, int? droppedThrough}) {
    if (_source != source) return;
    final end = through ?? _next;
    if (end < _cleared) return;
    if (droppedThrough != null) transportDropped(source, droppedThrough);
    _cleared = end;
    if (_next < end) _next = end;
    while (_entries.isNotEmpty && (_entries.first['seq'] as int) <= end) {
      _entries.removeFirst();
      _bytes -= _sizes.removeFirst();
    }
    _dropped = 0;
    final baseline = droppedThrough ?? _transportDropped;
    if (baseline > _transportCleared) _transportCleared = baseline;
    _total = _entries.length;
  }

  Map<String, Object?> snapshot() => {
    'window': _source,
    'entries': List<Map<String, dynamic>>.unmodifiable(_entries),
    'next': _next,
    'cleared': _cleared,
    'total': _total,
    'dropped': _transportDropped - _transportCleared,
    'windowDropped': _dropped,
    'retainedBytes': _bytes,
  };
}
