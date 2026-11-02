import 'package:clash_pseudo/src/logic/diagnostics/log_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('日志窗口按整条限制为 1000 条', () {
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

  test('日志正文按 UTF-8 字节限制为 1 MiB，单条超限计入遗漏', () {
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

  test('清空后旧事件和其他进程事件不能回填', () {
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

  test('快照和日志条目只读', () {
    final window = LogWindow()..begin('process-a');
    window.accept('process-a', {'seq': 1, 'text': 'entry'});
    final entries = window.snapshot()['entries'] as List;
    expect(() => entries.clear(), throwsUnsupportedError);
    expect(() => entries.first['text'] = 'changed', throwsUnsupportedError);
  });
}
