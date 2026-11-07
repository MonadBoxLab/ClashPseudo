import 'package:clash_pseudo/src/logic/diagnostics/log_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('log window retains at most 1000 complete entries', () {
    final window = LogWindow()..begin('process-a');
    for (var i = 1; i <= 1001; i++) {
      window.accept('process-a', {'seq': i, 'level': 'info', 'text': '$i'});
    }
    final data = window.snapshot();
    expect(window.length, 1000);
    expect((data['entries'] as List).first['seq'], 2);
    expect(data['dropped'], 0);
    expect(data['windowDropped'], 1);
  });

  test('log text is limited to 1 MiB of UTF-8 bytes and oversized entries count as dropped', () {
    final window = LogWindow()..begin('process-a');
    window.accept('process-a', {'seq': 1, 'text': '中' * 100000});
    window.accept('process-a', {'seq': 2, 'text': '中' * 300000});
    expect(window.length, 1);
    expect(window.retainedBytes, 900000);
    window.accept('process-a', {
      'seq': 3,
      'text': 'x' * (LogWindow.byteCapacity + 1),
    });
    expect(window.length, 1);
    expect(window.snapshot()['dropped'], 0);
    expect(window.snapshot()['windowDropped'], 2);
    expect(window.watermark, 3);
  });

  test('old events and other-process events cannot backfill after clear', () {
    final window = LogWindow()..begin('process-a');
    window.accept('process-a', {'seq': 1, 'text': 'before'});
    window.clear('process-a', through: 3);
    window.accept('process-a', {'seq': 2, 'text': 'late'});
    window.accept('process-b', {'seq': 4, 'text': 'wrong source'});
    expect(window.length, 0);
    window.accept('process-a', {'seq': 4, 'text': 'after'});
    expect(window.length, 1);
    expect(window.snapshot()['cleared'], 3);
    expect(window.snapshot()['dropped'], 0);
  });

  test('snapshots and log entries are read-only', () {
    final window = LogWindow()..begin('process-a');
    window.accept('process-a', {'seq': 1, 'text': 'entry'});
    final entries = window.snapshot()['entries'] as List;
    expect(() => entries.clear(), throwsUnsupportedError);
    expect(() => entries.first['text'] = 'changed', throwsUnsupportedError);
  });
}
