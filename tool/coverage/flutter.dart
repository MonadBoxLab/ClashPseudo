import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart' as coverage;

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 ||
      !['validate', 'collect'].contains(arguments[0]) ||
      (arguments[0] == 'validate' && arguments.length != 2)) {
    stderr.writeln(
      'usage: dart run tool/coverage/flutter.dart <validate|collect> <new-output-directory> [test/..._test.dart ...]',
    );
    exitCode = 64;
    return;
  }
  final root = Directory.current.absolute;
  final output = Directory(arguments[1]);
  if (!output.isAbsolute || await output.exists()) {
    throw ArgumentError('Use a new absolute output directory');
  }
  if (!await File('${root.path}/test/flutter_test_config.dart').exists()) {
    throw StateError('Run from the application repository root');
  }
  final parent = await output.parent.resolveSymbolicLinks();
  final temporary = await Directory.systemTemp.resolveSymbolicLinks();
  bool within(String path, String directory) =>
      path == directory ||
      path.startsWith('$directory${Platform.pathSeparator}');
  if (!within(parent, temporary) || within(parent, root.path)) {
    throw ArgumentError(
      'Use a new directory in the system temporary directory outside the project',
    );
  }
  final targets = arguments.skip(2).toList();
  for (final target in targets) {
    if (!target.startsWith('test/') ||
        !target.endsWith('_test.dart') ||
        target
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !await File(target).exists() ||
        !within(
          await File(target).resolveSymbolicLinks(),
          '${root.path}/test',
        )) {
      throw ArgumentError(
        'Coverage targets must be existing test/..._test.dart files',
      );
    }
  }
  await output.create();
  final inputs = await Directory.systemTemp.createTemp('clash-coverage-');
  final generated = <(File, String)>[];

  Future<File> generate(String name, String text) async {
    final file = File('${inputs.path}/$name');
    if (await file.exists()) throw StateError('Refusing to replace $name');
    generated.add((file, text));
    await file.writeAsString(text, flush: true);
    return file;
  }

  Future<_TestRun> run(
    String name,
    List<String> targets, {
    String scope = 'clash_pseudo',
  }) async {
    final raw = Directory('${output.path}/$name-raw');
    final expected = <String>{};
    for (final target in targets) {
      if (await FileSystemEntity.isDirectory(target)) {
        await for (final file in Directory(target).list(recursive: true)) {
          if (file is File && file.path.endsWith('_test.dart')) {
            expected.add(file.absolute.path);
          }
        }
      } else {
        expected.add(File(target).absolute.path);
      }
    }
    final executable = Platform.environment['FLUTTER_BIN'] ?? 'flutter';
    final command = [
      'test',
      '--no-pub',
      '--reporter=expanded',
      '--file-reporter=json:${output.path}/$name.events.jsonl',
      '--coverage',
      '--branch-coverage',
      '--coverage-path=${output.path}/$name-built-in.info',
      '--dart-define=APP_FUNCTION_COVERAGE=true',
      '--dart-define=APP_COVERAGE_SCOPE=$scope',
      '--dart-define=APP_COVERAGE_DIRECTORY=${raw.path}',
      '--dart-define=APP_COVERAGE_SOURCE_REPORT=${output.path}/$name-source-report.json',
      ...targets,
    ];
    await File('${output.path}/$name-command.json').writeAsString(
      jsonEncode({
        'executable': executable,
        'arguments': command,
        'workingDirectory': root.path,
      }),
    );
    final process = await Process.start(
      executable,
      command,
      workingDirectory: root.path,
    );
    final stdoutDone = process.stdout.pipe(
      File('${output.path}/$name.stdout.log').openWrite(),
    );
    final stderrDone = process.stderr.pipe(
      File('${output.path}/$name.stderr.log').openWrite(),
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln('$name 测试进程退出码：$code；继续处理已完成的 raw');
      exitCode = code < 0 ? 128 - code : code;
    }
    await Future.wait([stdoutDone, stderrDone]);
    final tests = await _testOutcome(
      File('${output.path}/$name.events.jsonl'),
      code,
    );
    await File('${output.path}/$name-run.json').writeAsString(
      jsonEncode({...tests, 'expectedIsolateReports': expected.length}),
    );
    return _TestRun(raw, tests, expected.length);
  }

  Future<Directory> validateRun(String name, String target) async {
    final result = await run(name, [target], scope: '');
    final reports = await _readRaw(result.raw, scope: '');
    if (result.tests['exitCode'] != 0 ||
        result.tests['complete'] != true ||
        reports.errors.isNotEmpty ||
        reports.completed != result.expected) {
      throw StateError('$name 验证未完成：${result.tests}；${reports.errors}');
    }
    return result.raw;
  }

  try {
    if (arguments[0] == 'validate') {
      final probe = await File('test/tool/fixtures/coverage_probe.dart')
          .readAsString();
      const probeName = 'coverage_probe.dart';
      const unusedName = 'coverage_unimported.dart';
      final first = await _scripts(
        await validateRun(
          'probe',
          'test/tool/coverage_collection_probe_test.dart',
        ),
      );
      final script = first.singleWhere(
        (row) => (row['source'] as String).endsWith('/$probeName'),
      );
      final functions = _pairs<String>(script['funcNames']);
      final hits = _pairs<int>(script['funcHits']);
      int functionHits(String name) =>
          hits[functions.entries.singleWhere((e) => e.value == name).key] ?? 0;
      if (functionHits('exercised') == 0 ||
          functionHits('composite') == 0 ||
          functionHits('suiteTeardown') == 0 ||
          functionHits('neverExecuted') != 0) {
        throw StateError(
          'Function hits or root tearDownAll ordering is incorrect',
        );
      }
      final line =
          probe
              .split('\n')
              .indexWhere((text) => text.contains('int firstSameLine()')) +
          1;
      if (!functions.containsKey(line) ||
          (hits[line] ?? 0) == 0 ||
          functions.length != 7) {
        throw StateError('The known same-line function aggregation changed');
      }
      if (first.any(
        (row) => (row['source'] as String).endsWith('/$unusedName'),
      )) {
        throw StateError(
          'The intentionally unimported fixture was already loaded',
        );
      }
      final second = await _scripts(
        await validateRun(
          'loading',
          'test/tool/coverage_library_loading_test.dart',
        ),
      );
      final loaded = second.singleWhere(
        (row) => (row['source'] as String).endsWith('/$unusedName'),
      );
      final names = _pairs<String>(loaded['funcNames']);
      final untouched = names.entries
          .singleWhere((entry) => entry.value == 'untouched')
          .key;
      if (_pairs<int>(loaded['funcHits'])[untouched] != 0) {
        throw StateError('Loading invented a hit for the uncalled function');
      }
      final lines = _pairs<int>(script['hits']);
      final outcomeLines = [
        for (final name in ['trueOutcome', 'falseOutcome'])
          functions.entries.singleWhere((entry) => entry.value == name).key,
      ];
      if (outcomeLines.any((line) => (lines[line] ?? 0) == 0) ||
          functionHits('trueOutcome') == 0 ||
          functionHits('falseOutcome') == 0 ||
          _pairs<int>(script['branchHits']).isEmpty) {
        throw StateError(
          'Known outcome/branch source locations were not measured',
        );
      }
      const evidencePrefix = 'COVERAGE_COMPOUND_EVIDENCE:';
      final evidence =
          (await File('${output.path}/probe.stdout.log').readAsLines())
              .map(
                (line) => line.startsWith('Shell: ') ? line.substring(7) : line,
              )
              .singleWhere((line) => line.startsWith(evidencePrefix));
      final compound = jsonDecode(evidence.substring(evidencePrefix.length));
      if (compound is! List || compound.length != 4) {
        throw StateError('Missing actual compound-condition observations');
      }
      await File('${output.path}/validation.json').writeAsString(
        jsonEncode({
          'passed': true,
          'executedFunctionMeasured': true,
          'uncalledFunctionHasZeroHits': true,
          'suiteTeardownMeasuredBeforeCollection': true,
          'sameLineDeclaredFunctions': 2,
          'sameLineReportedFunctionBuckets': 1,
          'unimportedAbsentBeforeLoading': true,
          'loadedUncalledFunctionHasZeroHits': true,
          'bothOutcomeLinesMeasured': true,
          'branchSourceLocations': _pairs<int>(script['branchHits']).length,
          'compoundConditionObservations': compound,
          'conditionDecisionCoverage': 'not inferred from VM branch records',
        }),
      );
    } else {
      final sources = <String>[];
      final libraries = <String>[];
      final excluded = <String>[];
      await for (final entry in Directory(
        'lib',
      ).list(recursive: true, followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        // 生成的契约文件只包含编译期常量；VM 将覆盖率计入使用这些常量的业务代码。
        if (entry.path == 'lib/src/model/application_contract.dart' ||
            entry.path.startsWith('lib/src/l10n/app_localizations') ||
            entry.path.endsWith('.g.dart') ||
            entry.path.endsWith('.freezed.dart')) {
          excluded.add(entry.path);
          continue;
        }
        sources.add(entry.path);
        if (!RegExp(
          r'^\s*part\s+of\b',
          multiLine: true,
        ).hasMatch(await entry.readAsString())) {
          libraries.add(entry.path);
        }
      }
      sources.sort();
      libraries.sort();
      excluded.sort();
      await File('${output.path}/inventory.json').writeAsString(
        jsonEncode({
          'testTargets': targets.isEmpty ? ['test'] : targets,
          'sourceFiles': sources,
          'loadedLibrariesRequested': libraries,
          'excludedGeneratedFiles': excluded,
          'mappedSourceFiles': <String>[],
          'nonInstrumentableSourceFiles': <String>[],
          'unmappedSourceFiles': sources,
          'sourceReport': '${output.path}/application-source-report.json',
          'sourceReportErrors': <String>[],
          'tests': null,
          'collectorComplete': false,
          'denominatorComplete': false,
          'applicationCoverageComplete': false,
          'completedIsolateReports': 0,
          'coverageInput': '已完成 isolate 的 raw；built-in 仅用于诊断',
        }),
      );
      final text = StringBuffer('// ignore_for_file: unused_import\n');
      text.writeln("import 'dart:convert';");
      text.writeln("import 'dart:developer' as developer;");
      text.writeln("import 'dart:io';");
      text.writeln("import 'dart:isolate';");
      text.writeln("import 'package:flutter_test/flutter_test.dart';");
      text.writeln("import 'package:vm_service/vm_service.dart' as vm;");
      text.writeln("import 'package:vm_service/vm_service_io.dart';");
      for (var index = 0; index < libraries.length; index++) {
        // 隐藏具名扩展以支持延迟导入；loadLibrary 会加载整个库，包括扩展实现。
        final hidden = switch (libraries[index]) {
          'lib/src/ui/locale/message_text.dart' => ' hide AppMessageText',
          'lib/src/ui/locale/model_text.dart' =>
            ' hide ConfigEntryText, OverrideEntryText, AppSnapshotText, '
                'CoreSnapshotText, TunnelModeText, StrategyTypeText, '
                'StrategyGroupText, ConnectionRecordText',
          _ => '',
        };
        text.writeln(
          "import 'package:clash_pseudo/${libraries[index].substring(4)}' deferred as source$index$hidden;",
        );
      }
      text.writeln("void main() { test('加载全部应用库以确定 coverage 源码分母', () async {");
      for (var index = 0; index < libraries.length; index++) {
        text.writeln('await source$index.loadLibrary();');
      }
      text.writeln('''
if (const bool.fromEnvironment('APP_FUNCTION_COVERAGE')) {
  await recordSourceReport();
}
}, timeout: const Timeout(Duration(minutes: 8))); }
''');
      text.writeln(r'''
Future<void> recordSourceReport() async {
  final uri = (await developer.Service.getInfo()).serverUri!;
  final isolate = developer.Service.getIsolateId(Isolate.current)!;
  final websocket = uri.replace(scheme: 'ws', pathSegments: [
    ...uri.pathSegments.where((part) => part.isNotEmpty), 'ws',
  ]);
  final service = await vmServiceConnectUri(websocket.toString());
  try {
    const filters = ['package:clash_pseudo/'];
    final report = await service.getSourceReport(isolate, [
      vm.SourceReportKind.kCoverage, vm.SourceReportKind.kBranchCoverage,
    ], forceCompile: true, reportLines: true, libraryFilters: filters);
    final loaded = (await service.getScripts(isolate)).scripts!;
    final output = File(const String.fromEnvironment('APP_COVERAGE_SOURCE_REPORT'));
    if (await output.exists()) throw StateError('源码报告已经存在');
    await output.writeAsString(jsonEncode({
      'collector': {
        'pid': pid, 'isolate': isolate, 'scope': 'clash_pseudo',
        'completion': 'library-loader', 'forceCompile': true,
        'reportLines': true, 'libraryFilters': filters,
      },
      'vmVersion': (await service.getVM()).version,
      'loadedScripts': [
        for (final script in loaded)
          if (script.uri?.startsWith(filters.single) == true) script.toJson(),
      ],
      'sourceReport': report.toJson(),
    }), flush: true);
  } finally {
    await service.dispose();
  }
}
''');
      final loader = await generate(
        'application_libraries_test.dart',
        text.toString(),
      );
      await generate(
        'flutter_test_config.dart',
        await File('test/flutter_test_config.dart').readAsString(),
      );
      // 收集应用覆盖率前，先通过 Flutter SDK 检查生成的导入语句。
      final loaderCommand = [
        'test',
        '--no-pub',
        '--reporter=expanded',
        '--fail-fast',
        loader.path,
      ];
      final executable = Platform.environment['FLUTTER_BIN'] ?? 'flutter';
      await File('${output.path}/loader-check-command.json').writeAsString(
        jsonEncode({
          'executable': executable,
          'arguments': loaderCommand,
          'workingDirectory': root.path,
        }),
      );
      final checked = await Process.run(
        executable,
        loaderCommand,
        workingDirectory: root.path,
      );
      await File('${output.path}/loader-check.stdout.log')
          .writeAsString(checked.stdout as String);
      await File('${output.path}/loader-check.stderr.log')
          .writeAsString(checked.stderr as String);
      await File('${output.path}/loader-check-run.json')
          .writeAsString(jsonEncode({'exitCode': checked.exitCode}));
      if (checked.exitCode != 0) {
        exitCode = checked.exitCode < 0
            ? 128 - checked.exitCode
            : checked.exitCode;
        throw StateError(
          'Application library loader failed: exit ${checked.exitCode}',
        );
      }
      final result = await run('application', [
        ...(targets.isEmpty ? ['test'] : targets),
        loader.path,
      ]);
      final reports = await _readRaw(result.raw, scope: 'clash_pseudo');
      final merged = reports.merged;
      final errors = reports.errors;
      final completedReports = reports.completed;
      final resolver = await coverage.Resolver.create(packagePath: root.path);
      final include = {
        for (final source in sources) File(source).absolute.path,
      };
      final selected = <String, coverage.HitMap>{};
      final mapped = <String>{};
      for (final entry in merged.entries) {
        final resolved = resolver.resolve(entry.key);
        if (resolved == null ||
            !include.contains(File(resolved).absolute.path)) {
          continue;
        }
        selected[entry.key] = entry.value;
        mapped.add(File(resolved).absolute.path);
      }
      final sourceReport = File(
        '${output.path}/application-source-report.json',
      );
      final sourceFacts = await _nonInstrumentableSources(
        sourceReport,
        reports.identities,
        resolver,
      );
      final nonInstrumentable = sources
          .where(
            (source) =>
                !mapped.contains(File(source).absolute.path) &&
                sourceFacts.files.contains(File(source).absolute.path),
          )
          .toList();
      final missing = sources
          .where(
            (source) =>
                !mapped.contains(File(source).absolute.path) &&
                !nonInstrumentable.contains(source),
          )
          .toList();
      final denominatorComplete = missing.isEmpty && sourceFacts.errors.isEmpty;
      final collectorComplete =
          result.tests['complete'] == true &&
          completedReports == result.expected &&
          completedReports > 0 &&
          errors.isEmpty;
      await File('${output.path}/application.info')
          .writeAsString(selected.formatLcov(resolver, basePath: root.path));
      await File('${output.path}/inventory.json').writeAsString(
        jsonEncode({
          'testTargets': targets.isEmpty ? ['test'] : targets,
          'sourceFiles': sources,
          'loadedLibrariesRequested': libraries,
          'mappedSourceFiles': selected.keys.toList()..sort(),
          'excludedGeneratedFiles': excluded,
          'unmappedSourceFiles': missing,
          'nonInstrumentableSourceFiles': nonInstrumentable,
          'sourceReport': sourceReport.path,
          'sourceReportErrors': sourceFacts.errors,
          'denominatorComplete': denominatorComplete,
          'tests': result.tests,
          'collectorComplete': collectorComplete,
          'expectedIsolateReports': result.expected,
          'completedIsolateReports': completedReports,
          'rawErrors': errors,
          'applicationCoverageComplete':
              collectorComplete && denominatorComplete,
          'coverageInput': '已完成 isolate 的 raw；built-in 仅用于诊断',
          'functionUnit':
              'entry source line; multiple functions on one line may merge',
          'branchUnit': 'VM branch source line; not automatic condition/decision coverage',
        }),
      );
      if (!collectorComplete) {
        stderr.writeln(
          'collector 未完成：有效 raw $completedReports/${result.expected}；'
          '测试终态 ${result.tests['complete']}；${errors.join('; ')}',
        );
      }
      if (missing.isNotEmpty) {
        stderr.writeln('源码分母缺失：${missing.join(', ')}');
      }
      if (sourceFacts.errors.isNotEmpty) {
        stderr.writeln('VM 源码报告无效：${sourceFacts.errors.join('; ')}');
      }
      if ((!collectorComplete || !denominatorComplete) && exitCode == 0) {
        exitCode = 1;
      }
    }
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    if (exitCode == 0) exitCode = 1;
  } finally {
    for (final (file, text) in generated.reversed) {
      if (!await file.exists()) continue;
      if (await FileSystemEntity.isLink(file.path) ||
          await file.readAsString() != text) {
        throw StateError(
          'Generated source changed; refusing to remove ${file.path}',
        );
      }
      await file.delete();
    }
    if (await inputs.exists() && await inputs.list().isEmpty) {
      await inputs.delete();
    }
  }
}

class _TestRun {
  const _TestRun(this.raw, this.tests, this.expected);

  final Directory raw;
  final Map<String, Object?> tests;
  final int expected;
}

Future<Map<String, Object?>> _testOutcome(File events, int code) async {
  final started = <int>{};
  final finished = <int>{};
  final errors = <String>[];
  var passed = 0;
  var failed = 0;
  var skipped = 0;
  var hidden = 0;
  bool? success;
  try {
    var number = 0;
    await for (final line
        in events
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      number++;
      try {
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (success != null) throw const FormatException('done 之后仍有事件');
        switch (event['type']) {
          case 'testStart':
            if (!started.add((event['test'] as Map)['id'] as int)) {
              throw const FormatException('重复 testStart');
            }
          case 'testDone':
            final id = event['testID'] as int;
            if (!started.contains(id) || !finished.add(id)) {
              throw const FormatException('testDone 没有对应的唯一 testStart');
            }
            if (event['hidden'] == true) {
              hidden++;
            } else if (event['skipped'] == true) {
              skipped++;
            } else if (event['result'] == 'success') {
              passed++;
            } else if (['failure', 'error'].contains(event['result'])) {
              failed++;
            } else {
              throw const FormatException('未知 testDone 结果');
            }
          case 'done':
            success = event['success'] as bool;
        }
      } catch (error) {
        errors.add('${events.path}:$number: $error');
      }
    }
  } catch (error) {
    errors.add('${events.path}: $error');
  }
  final interrupted = code < 0 || code >= 128;
  return {
    'exitCode': code,
    'complete':
        success != null &&
        started.length == finished.length &&
        errors.isEmpty &&
        !interrupted,
    'doneReceived': success != null,
    'success': success,
    'interrupted': interrupted,
    'passed': passed,
    'failed': failed,
    'skipped': skipped,
    'hidden': hidden,
    'startedIncludingHidden': started.length,
    'unfinishedIncludingHidden': started.difference(finished).length,
    'reporterErrors': errors,
  };
}

Future<
  ({
    Map<String, coverage.HitMap> merged,
    int completed,
    List<String> errors,
    Set<String> identities,
  })
>
_readRaw(Directory directory, {required String scope}) async {
  final merged = <String, coverage.HitMap>{};
  final errors = <String>[];
  var completed = 0;
  final identities = <String>{};
  final resolver = await coverage.Resolver.create(
    packagePath: Directory.current.path,
  );
  if (!await directory.exists()) {
    return (
      merged: merged,
      completed: 0,
      errors: ['raw 目录缺失：${directory.path}'],
      identities: identities,
    );
  }
  final files = await directory.list().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    try {
      if (file is! File || !file.path.endsWith('.json')) {
        throw const FormatException('raw 目录含有未完成或未知文件');
      }
      final report =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final collector = report['collector'] as Map<String, dynamic>;
      if (collector['completion'] != 'root-tearDownAll' ||
          collector['functionCoverage'] != true ||
          collector['branchCoverage'] != true ||
          collector['scope'] != scope ||
          collector['pid'] is! int ||
          collector['isolate'] is! String) {
        throw const FormatException('raw 缺少完整的 collector 元数据');
      }
      final identity = '${collector['pid']}:${collector['isolate']}';
      if (identities.contains(identity)) {
        throw FormatException('重复的 isolate 报告：$identity');
      }
      final scripts = (report['coverage'] as List).cast<Map<String, dynamic>>();
      for (final script in scripts) {
        if (script['source'] is! String) {
          throw const FormatException('raw 缺少源码 URI');
        }
        for (final key in ['hits', 'funcHits', 'funcNames', 'branchHits']) {
          final values = script[key];
          if (values is! List || values.length.isOdd) {
            throw FormatException('$key 不是完整的成对记录');
          }
          for (var index = 0; index < values.length; index += 2) {
            final line = values[index];
            final value = values[index + 1];
            if (line is! int ||
                line <= 0 ||
                (key == 'funcNames'
                    ? value is! String
                    : value is! int || value < 0)) {
              throw FormatException('$key 含有无效行号或值');
            }
          }
        }
      }
      final parsed = coverage.HitMap.parseJsonSync(
        scripts,
        checkIgnoredLines: false,
        ignoredLinesInFilesCache: {},
        resolver: resolver,
        scopeOutput: scope.isEmpty ? {} : {scope},
      );
      merged.merge(parsed);
      identities.add(identity);
      completed++;
    } catch (error) {
      errors.add('${file.path}: $error');
    }
  }
  if (files.isEmpty) errors.add('raw 目录为空：${directory.path}');
  return (
    merged: merged,
    completed: completed,
    errors: errors,
    identities: identities,
  );
}

Future<({Set<String> files, List<String> errors})> _nonInstrumentableSources(
  File file,
  Set<String> completedIdentities,
  coverage.Resolver resolver,
) async {
  if (!await file.exists()) return (files: <String>{}, errors: <String>[]);
  try {
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final collector = value['collector'] as Map<String, dynamic>;
    if (collector['completion'] != 'library-loader' ||
        collector['scope'] != 'clash_pseudo' ||
        collector['forceCompile'] != true ||
        collector['reportLines'] != true ||
        collector['pid'] is! int ||
        collector['isolate'] is! String ||
        !completedIdentities.contains(
          '${collector['pid']}:${collector['isolate']}',
        ) ||
        jsonEncode(collector['libraryFilters']) !=
            jsonEncode(['package:clash_pseudo/'])) {
      throw const FormatException('源码报告没有对应的完整 loader isolate');
    }
    final loaded = (value['loadedScripts'] as List)
        .cast<Map<String, dynamic>>();
    final report = value['sourceReport'] as Map<String, dynamic>;
    if (report['type'] != 'SourceReport') {
      throw const FormatException('缺少 VM SourceReport');
    }
    final scripts = (report['scripts'] as List).cast<Map<String, dynamic>>();
    final ranged = <String>{};
    for (final range
        in (report['ranges'] as List).cast<Map<String, dynamic>>()) {
      ranged.add(scripts[range['scriptIndex'] as int]['uri'] as String);
    }
    final files = <String>{};
    for (final script in loaded) {
      final uri = script['uri'] as String;
      if (!uri.startsWith('package:clash_pseudo/') || ranged.contains(uri)) {
        continue;
      }
      final resolved = resolver.resolve(uri);
      if (resolved != null) files.add(File(resolved).absolute.path);
    }
    return (files: files, errors: <String>[]);
  } catch (error) {
    return (files: <String>{}, errors: ['${file.path}: $error']);
  }
}

Map<int, T> _pairs<T>(Object? raw) {
  final values = raw! as List;
  return {
    for (var i = 0; i < values.length; i += 2)
      values[i] as int: values[i + 1] as T,
  };
}

Future<List<Map<String, dynamic>>> _scripts(Directory directory) async {
  final rows = <Map<String, dynamic>>[];
  await for (final file in directory.list()) {
    if (file is! File || !file.path.endsWith('.json')) continue;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    rows.addAll((json['coverage'] as List).cast<Map<String, dynamic>>());
  }
  return rows;
}
