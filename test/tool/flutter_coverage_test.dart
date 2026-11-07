import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory run;

  setUp(() async {
    run = await Directory.systemTemp.createTemp('coverage-path-test-');
  });
  tearDown(() async {
    await run.delete(recursive: true);
  });

  Future<ProcessResult> invoke(
    String output, {
    String? flutter,
    List<String> targets = const [],
  }) => Process.run(
    'dart',
    ['run', 'tool/coverage/flutter.dart', 'collect', output, ...targets],
    environment: {'FLUTTER_BIN': ?flutter},
  );

  Future<({ProcessResult process, Map<String, dynamic> inventory, String lcov})>
  collectFixture({
    int testExit = 0,
    bool interrupted = false,
    bool corrupt = false,
    bool incomplete = false,
    bool noRaw = false,
    bool missing = false,
    bool unmapped = false,
    bool missingEvents = false,
    String? libraryReport,
  }) async {
    final project = await Directory('${run.path}/project').create();
    Future<void> write(String path, String text) async {
      final file = File('${project.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }

    await write('test/flutter_test_config.dart', '');
    await write('test/fixture_test.dart', 'void main() {}');
    await write(
      'lib/sample.dart',
      'int called() => 1;\nint uncalled() => 2;\n',
    );
    if (unmapped || libraryReport != null) {
      await write(
        'lib/unmapped.dart',
        libraryReport == 'empty' || libraryReport == 'foreign'
            ? 'abstract interface class Contract { int value(); }\n'
            : 'int missing() => 3;\n',
      );
    }
    if (libraryReport != null) {
      const script = {
        'type': '@Script',
        'id': 'scripts/unmapped',
        'uri': 'package:clash_pseudo/unmapped.dart',
      };
      await write(
        'source-report.json',
        jsonEncode({
          'collector': {
            'pid': libraryReport == 'foreign' ? 2 : 1,
            'isolate': 'isolates/2',
            'scope': 'clash_pseudo',
            'completion': 'library-loader',
            'forceCompile': true,
            'reportLines': true,
            'libraryFilters': ['package:clash_pseudo/'],
          },
          'loadedScripts': [if (libraryReport != 'unloaded') script],
          'sourceReport': {
            'type': 'SourceReport',
            'scripts': [if (libraryReport == 'executable') script],
            'ranges': [
              if (libraryReport == 'executable')
                {
                  'scriptIndex': 0,
                  'startPos': 0,
                  'endPos': 18,
                  'compiled': true,
                  'coverage': {
                    'hits': <int>[],
                    'misses': [1],
                  },
                  'branchCoverage': {
                    'hits': <int>[],
                    'misses': [1],
                  },
                },
            ],
          },
        }),
      );
    }
    await write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'clash_pseudo',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.9',
          },
        ],
      }),
    );
    final events = [
      {
        'type': 'testStart',
        'test': {'id': 1},
      },
      {
        'type': 'testDone',
        'testID': 1,
        'hidden': false,
        'skipped': false,
        'result': testExit == 0 ? 'success' : 'failure',
      },
      {
        'type': 'testStart',
        'test': {'id': 2},
      },
      if (!interrupted) ...[
        {
          'type': 'testDone',
          'testID': 2,
          'hidden': false,
          'skipped': false,
          'result': 'success',
        },
        {'type': 'done', 'success': testExit == 0},
      ],
    ];
    await write('events.jsonl', '${events.map(jsonEncode).join('\n')}\n');
    for (final id in [1, 2]) {
      await write(
        'raw/$id.json',
        jsonEncode({
          'collector': {
            'pid': 1,
            'isolate': 'isolates/$id',
            'scope': 'clash_pseudo',
            'functionCoverage': true,
            'branchCoverage': true,
            'completion': 'root-tearDownAll',
          },
          'coverage': [
            {
              'source': 'package:clash_pseudo/sample.dart',
              'hits': [1, 1, 2, 0],
              'funcHits': [1, 1, 2, 0],
              'funcNames': [1, 'called', 2, 'uncalled'],
              'branchHits': <int>[],
            },
          ],
        }),
      );
    }
    if (incomplete) {
      final file = File('${project.path}/raw/2.json');
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      (raw['coverage'][0] as Map).remove('funcHits');
      await file.writeAsString(jsonEncode(raw));
    }
    if (corrupt) await write('raw/2.json', '{"coverage":[');
    if (missing) await File('${project.path}/raw/2.json').delete();
    final sdk = File('${project.path}/flutter');
    await sdk.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  case "\$argument" in
    --fail-fast) exit 0 ;;
    --file-reporter=json:*) events=\${argument#--file-reporter=json:} ;;
    --dart-define=APP_COVERAGE_DIRECTORY=*) raw=\${argument#--dart-define=APP_COVERAGE_DIRECTORY=} ;;
    --dart-define=APP_COVERAGE_SOURCE_REPORT=*) source=\${argument#--dart-define=APP_COVERAGE_SOURCE_REPORT=} ;;
    --coverage-path=*) builtin=\${argument#--coverage-path=} ;;
  esac
done
${noRaw ? '' : 'mkdir -p "\$raw"\ncp raw/*.json "\$raw/"'}
${missingEvents ? '' : 'cp events.jsonl "\$events"'}
${libraryReport == null ? '' : 'test -z "\$source" || cp source-report.json "\$source"'}
printf 'SF:lib/only-built-in.dart\\nDA:1,99\\nend_of_record\\n' > "\$builtin"
${interrupted ? 'kill -TERM \$\$' : 'exit $testExit'}
''');
    expect((await Process.run('chmod', ['u+x', sdk.path])).exitCode, 0);
    final output = '${run.path}/result';
    final process = await Process.run(
      'dart',
      [
        'run',
        '${Directory.current.path}/tool/coverage/flutter.dart',
        'collect',
        output,
        'test/fixture_test.dart',
      ],
      workingDirectory: project.path,
      environment: {'FLUTTER_BIN': sdk.path},
    );
    final inventory = jsonDecode(
      await File('$output/inventory.json').readAsString(),
    ) as Map<String, dynamic>;
    final lcov = await File('$output/application.info').readAsString();
    expect(lcov, isNot(contains('only-built-in')));
    if (noRaw) {
      expect(lcov, isEmpty);
    } else {
      expect(lcov, contains('FN:2,uncalled'));
      expect(lcov, contains('FNF:2\nFNH:1\n'));
      expect(RegExp(r'FNDA:[1-9][0-9]*,uncalled').hasMatch(lcov), isFalse);
      expect(lcov, contains('DA:2,0'));
    }
    return (process: process, inventory: inventory, lcov: lcov);
  }

  test('Successful collection records test results and completeness separately and keeps uncalled functions at zero hits', () async {
    final result = await collectFixture();
    expect(result.process.exitCode, 0, reason: '${result.process.stderr}');
    expect(result.inventory['tests'], containsPair('passed', 2));
    expect(result.inventory['tests'], containsPair('failed', 0));
    expect(result.inventory['tests'], containsPair('complete', true));
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['applicationCoverageComplete'], isTrue);
    expect(result.inventory['completedIsolateReports'], 2);
    expect(result.lcov, contains('FNDA:2,called'));
  });

  test('Assertion failures preserve the test exit code and merge all valid raw reports', () async {
    final result = await collectFixture(testExit: 7);
    expect(result.process.exitCode, 7);
    expect(result.inventory['tests'], containsPair('exitCode', 7));
    expect(result.inventory['tests'], containsPair('failed', 1));
    expect(result.inventory['tests'], containsPair('passed', 1));
    expect(result.inventory['tests'], containsPair('success', false));
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['applicationCoverageComplete'], isTrue);
    expect(result.lcov, contains('FNDA:2,called'));
  });

  test('Interrupted processes remain incomplete even with all raw reports and a complete source denominator', () async {
    final result = await collectFixture(interrupted: true);
    expect(result.process.exitCode, 143);
    expect(result.inventory['tests'], containsPair('exitCode', -15));
    expect(result.inventory['tests'], containsPair('doneReceived', false));
    expect(
      result.inventory['tests'],
      containsPair('unfinishedIncludingHidden', 1),
    );
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
  }, skip: Platform.isWindows);

  test('Corrupt raw reports record errors while valid reports still produce partial coverage', () async {
    final result = await collectFixture(corrupt: true, testExit: 7);
    expect(result.process.exitCode, 7);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
    expect(result.inventory['rawErrors'], hasLength(1));
    expect(result.inventory['completedIsolateReports'], 1);
    expect(result.lcov, contains('FNDA:1,called'));
  });

  test('Missing raw reports cannot be replaced by built-in coverage or a complete source denominator', () async {
    final result = await collectFixture(missing: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['expectedIsolateReports'], 2);
    expect(result.inventory['completedIsolateReports'], 1);
  });

  test('Valid raw JSON without function coverage is still corrupt', () async {
    final result = await collectFixture(incomplete: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['rawErrors'], hasLength(1));
    expect(result.inventory['rawErrors'].single, contains('funcHits'));
    expect(result.inventory['completedIsolateReports'], 1);
    expect(result.lcov, contains('FNDA:1,called'));
  });

  test('Missing raw directory produces an incomplete inventory and empty report without built-in coverage', () async {
    final result = await collectFixture(noRaw: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['completedIsolateReports'], 0);
    expect(
      result.inventory['rawErrors'].single,
      contains('Missing raw directory'),
    );
  });

  test('Collection remains incomplete without terminal test records', () async {
    final result = await collectFixture(missingEvents: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['tests'], containsPair('complete', false));
    expect(result.inventory['tests']['reporterErrors'], isNotEmpty);
    expect(result.inventory['collectorComplete'], isFalse);
  });

  test('Collector completion and missing source denominator are recorded separately', () async {
    final result = await collectFixture(unmapped: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
  });

  for (final testExit in [0, 7]) {
    test(
      'Loaded sources without executable VM ranges are listed separately without zero hits: $testExit',
      () async {
        final result = await collectFixture(
          libraryReport: 'empty',
          testExit: testExit,
        );
        expect(
          result.process.exitCode,
          testExit,
          reason: '${result.process.stderr}',
        );
        expect(result.inventory['tests'], containsPair('exitCode', testExit));
        expect(result.inventory['sourceFiles'], contains('lib/unmapped.dart'));
        expect(result.inventory['nonInstrumentableSourceFiles'], [
          'lib/unmapped.dart',
        ]);
        expect(result.inventory['unmappedSourceFiles'], isEmpty);
        expect(result.inventory['denominatorComplete'], isTrue);
        expect(result.inventory['applicationCoverageComplete'], isTrue);
        expect(result.lcov, isNot(contains('unmapped.dart')));
      },
    );
  }

  test('Loaded sources with executable locations retain denominator gaps when raw reports are missing', () async {
    final result = await collectFixture(libraryReport: 'executable');
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
    expect(result.lcov, isNot(contains('unmapped.dart')));
  });

  test(
    'Unloaded sources cannot be excluded because SourceReport has no ranges',
    () async {
      final result = await collectFixture(libraryReport: 'unloaded');
      expect(result.process.exitCode, 1);
      expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
      expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
      expect(result.inventory['denominatorComplete'], isFalse);
    },
  );

  test(
    'Loader source reports must belong to isolates with completed raw reports',
    () async {
      final result = await collectFixture(libraryReport: 'foreign');
      expect(result.process.exitCode, 1);
      expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
      expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
      expect(result.inventory['denominatorComplete'], isFalse);
      expect(result.inventory['sourceReportErrors'], hasLength(1));
    },
  );

  test('coverage rejects checkout output before creating it', () async {
    final output = '${Directory.current.path}/coverage-path-test-$pid';
    expect(await Directory(output).exists(), isFalse);
    final result = await invoke(output);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('outside the project'));
    expect(await Directory(output).exists(), isFalse);
  });

  test('coverage rejects a reused output without overwriting it', () async {
    final marker = File('${run.path}/marker');
    await marker.writeAsString('preserve');
    final result = await invoke(run.path);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('new absolute output directory'));
    expect(await marker.readAsString(), 'preserve');
  });

  test(
    'coverage rejects invalid selected targets before creating output',
    () async {
      for (final target in [
        '--help',
        'test/../test/tool/coverage_library_loading_test.dart',
        'test/missing_coverage_target_test.dart',
        'test/tool/fixtures/coverage_probe.dart',
      ]) {
        final output = '${run.path}/result';
        final result = await invoke(output, targets: [target]);
        expect(result.exitCode, isNot(0), reason: target);
        expect(
          result.stderr,
          contains('existing test/..._test.dart'),
          reason: target,
        );
        expect(await Directory(output).exists(), isFalse, reason: target);
      }
    },
  );

  test(
    'failed SDK loader uses an external hook and cleans only its inputs',
    () async {
      final sdk = File('${run.path}/flutter');
      await sdk.writeAsString(r'''#!/bin/sh
for argument in "$@"; do
  case "$argument" in
    */application_libraries_test.dart)
      printf '%s\n' "$argument"
      test -f "$argument" || exit 8
      cmp "$(dirname "$argument")/flutter_test_config.dart" test/flutter_test_config.dart || exit 9
      if grep -q 'model/application_contract.dart' "$argument"; then exit 10; fi
      grep -q 'model/core_snapshot.dart' "$argument" || exit 11
      grep -q 'ui/locale/message_text.dart.*hide AppMessageText' "$argument" || exit 12
      grep -q 'ui/locale/model_text.dart.*hide ConfigEntryText, OverrideEntryText, AppSnapshotText, CoreSnapshotText, TunnelModeText, StrategyTypeText, StrategyGroupText, ConnectionRecordText' "$argument" || exit 13
      ;;
  esac
done
exit 7
''');
      final permissions = await Process.run('chmod', ['u+x', sdk.path]);
      expect(permissions.exitCode, 0);
      final before = {
        for (final directory in ['lib', 'test'])
          await for (final file in Directory(directory).list(recursive: true))
            file.path,
      };
      final output = '${run.path}/result';
      final result = await invoke(output, flutter: sdk.path);
      expect(result.exitCode, 7);
      final inventory = jsonDecode(
        await File('$output/inventory.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(inventory['collectorComplete'], isFalse);
      expect(inventory['denominatorComplete'], isFalse);
      expect(inventory['applicationCoverageComplete'], isFalse);
      expect(inventory['tests'], isNull);
      expect(
        result.stderr,
        contains('Application library loader failed: exit 7'),
      );
      final loader = (await File(
        '$output/loader-check.stdout.log',
      ).readAsString()).trim();
      expect(loader, startsWith('${Directory.systemTemp.path}/'));
      expect(loader.startsWith('${Directory.current.path}/'), isFalse);
      expect(await File(loader).exists(), isFalse);
      expect(
        await File('${File(loader).parent.path}/flutter_test_config.dart')
            .exists(),
        isFalse,
      );
      expect(await File('$output/loader-check.stderr.log').exists(), isTrue);
      final after = {
        for (final directory in ['lib', 'test'])
          await for (final file in Directory(directory).list(recursive: true))
            file.path,
      };
      expect(after, before);
    },
    skip: Platform.isWindows,
  );
}
