import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('coverage-summary-');
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<ProcessResult> summarize(String input) async {
    final file = File('${scratch.path}/lcov.info')..writeAsStringSync(input);
    return Process.run('dart', ['tool/coverage/summary.dart', file.path]);
  }

  test(
    'counts FNDA hits before names, including names containing commas',
    () async {
      final result = await summarize('''
SF:lib/example.dart
FN:1,first
FN:4,Generic<A,B>.method
FN:7,uncovered
FNDA:2,first
FNDA:1,Generic<A,B>.method
FNDA:0,uncovered
DA:1,2
DA:4,1
DA:7,0
end_of_record
''');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('functions=2/3 66.7%'));
      expect(result.stdout, contains('lines=2/3 66.7%'));
      expect(result.stdout, contains('branches=n/a'));
    },
  );

  test(
    'reads DA hit counts rather than optional checksums across files',
    () async {
      final result = await summarize('''
SF:lib/first.dart
DA:10,1,checksum-not-a-number
DA:11,0,9999
BRDA:10,0,0,2
BRDA:10,0,1,0
BRDA:11,1,0,-
end_of_record
SF:lib/second.dart
DA:20,0
DA:21,3,0
DA:22,1
end_of_record
''');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('files=2'));
      expect(
        result.stdout,
        contains('functions=n/a (no FN records in this lcov)'),
      );
      expect(result.stdout, contains('lines=3/5 60.0%'));
      expect(result.stdout, contains('branches=1/3 33.3%'));
      expect(result.stdout, contains('50.0% 1/2 lib/first.dart'));
      expect(result.stdout, contains('66.7% 2/3 lib/second.dart'));
    },
  );

  test(
    'an executed entry does not imply a hit for an uncalled function',
    () async {
      final result = await summarize('''
SF:lib/known.dart
FN:1,called
FN:5,uncalled
FNDA:1,called
DA:1,1
DA:5,0
end_of_record
''');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('functions=1/2 50.0%'));
      expect(result.stdout, contains('condition/decision=n/a'));
    },
  );

  test(
    'repeated source records must be merged rather than counted twice',
    () async {
      final result = await summarize('''
SF:lib/known.dart
DA:1,1
end_of_record
SF:lib/known.dart
DA:1,0
end_of_record
''');
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Expected one merged record per source'));
    },
  );

  for (final invalid in ['FNDA:-1,called', 'DA:1,-1', 'BRDA:1,0,0,-1']) {
    test(
      'negative measured hit counts are not silently interpreted: $invalid',
      () async {
        final result = await summarize(
          'SF:lib/known.dart\nFN:1,called\n$invalid\nend_of_record\n',
        );
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Negative coverage hit count'));
      },
    );
  }

  test('does not invent coverage for an empty input', () async {
    final result = await summarize('');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('files=0'));
    expect(
      result.stdout,
      contains('functions=n/a (no FN records in this lcov)'),
    );
    expect(result.stdout, contains('lines=0/0 n/a'));
    expect(result.stdout, contains('branches=n/a'));
  });
}
