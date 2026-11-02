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

  test('collector 成功时分别记录测试结果和完整性，未调用函数保持零命中', () async {
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

  test('断言失败保留测试退出码并合并全部有效 raw', () async {
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

  test('进程中断即使留下全部 raw 和完整源码分母仍标记未完成', () async {
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

  test('损坏 raw 记录错误且有效 raw 仍可生成部分报告', () async {
    final result = await collectFixture(corrupt: true, testExit: 7);
    expect(result.process.exitCode, 7);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
    expect(result.inventory['rawErrors'], hasLength(1));
    expect(result.inventory['completedIsolateReports'], 1);
    expect(result.lcov, contains('FNDA:1,called'));
  });

  test('缺失 raw 不以 built-in 或完整源码分母代替 collector 完成', () async {
    final result = await collectFixture(missing: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isTrue);
    expect(result.inventory['expectedIsolateReports'], 2);
    expect(result.inventory['completedIsolateReports'], 1);
  });

  test('raw JSON 有效但缺少 function coverage 时仍标记损坏', () async {
    final result = await collectFixture(incomplete: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['rawErrors'], hasLength(1));
    expect(result.inventory['rawErrors'].single, contains('funcHits'));
    expect(result.inventory['completedIsolateReports'], 1);
    expect(result.lcov, contains('FNDA:1,called'));
  });

  test('没有 raw 目录时输出未完成清单和空报告，不采用 built-in', () async {
    final result = await collectFixture(noRaw: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isFalse);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['completedIsolateReports'], 0);
    expect(result.inventory['rawErrors'].single, contains('raw 目录缺失'));
  });

  test('缺少测试终态记录时 collector 标记未完成', () async {
    final result = await collectFixture(missingEvents: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['tests'], containsPair('complete', false));
    expect(result.inventory['tests']['reporterErrors'], isNotEmpty);
    expect(result.inventory['collectorComplete'], isFalse);
  });

  test('collector 完成与源码分母缺失分别记录', () async {
    final result = await collectFixture(unmapped: true);
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
  });

  for (final testExit in [0, 7]) {
    test('VM 已加载且无可执行 range 的源码单列，不生成零命中：$testExit', () async {
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
    });
  }

  test('VM 已加载且有可执行位置的源码缺少 raw 时仍保留分母缺口', () async {
    final result = await collectFixture(libraryReport: 'executable');
    expect(result.process.exitCode, 1);
    expect(result.inventory['collectorComplete'], isTrue);
    expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['applicationCoverageComplete'], isFalse);
    expect(result.lcov, isNot(contains('unmapped.dart')));
  });

  test('VM 未加载的源码不能因 SourceReport 没有 range 而排除', () async {
    final result = await collectFixture(libraryReport: 'unloaded');
    expect(result.process.exitCode, 1);
    expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['denominatorComplete'], isFalse);
  });

  test('loader 源码报告必须属于实际完成 raw 的 isolate', () async {
    final result = await collectFixture(libraryReport: 'foreign');
    expect(result.process.exitCode, 1);
    expect(result.inventory['nonInstrumentableSourceFiles'], isEmpty);
    expect(result.inventory['unmappedSourceFiles'], ['lib/unmapped.dart']);
    expect(result.inventory['denominatorComplete'], isFalse);
    expect(result.inventory['sourceReportErrors'], hasLength(1));
  });

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
