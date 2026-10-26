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

  Future<Directory> run(
    String name,
    List<String> targets, {
    String scope = 'clash_pseudo',
  }) async {
    final raw = Directory('${output.path}/$name-raw');
    final process = await Process.start(
      Platform.environment['FLUTTER_BIN'] ?? 'flutter',
      [
        'test',
        '--no-pub',
        '--reporter=expanded',
        '--fail-fast',
        '--coverage',
        '--branch-coverage',
        '--coverage-path=${output.path}/$name-built-in.info',
        '--dart-define=APP_FUNCTION_COVERAGE=true',
        '--dart-define=APP_COVERAGE_SCOPE=$scope',
        '--dart-define=APP_COVERAGE_DIRECTORY=${raw.path}',
        ...targets,
      ],
      workingDirectory: root.path,
    );
    final stdoutDone = process.stdout.pipe(
      File('${output.path}/$name.stdout.log').openWrite(),
    );
    final stderrDone = process.stderr.pipe(
      File('${output.path}/$name.stderr.log').openWrite(),
    );
    final code = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (code != 0) {
      throw StateError('$name tests/collection failed: exit $code');
    }
    if (!await raw.exists() || await raw.list().isEmpty) {
      throw StateError('$name produced no completed-isolate coverage');
    }
    return raw;
  }

  try {
    if (arguments[0] == 'validate') {
      final probe = await File('test/tool/fixtures/coverage_probe.dart')
          .readAsString();
      const probeName = 'coverage_probe.dart';
      const unusedName = 'coverage_unimported.dart';
      final first = await _scripts(
        await run('probe', [
          'test/tool/coverage_collection_probe_test.dart',
        ], scope: ''),
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
        await run('loading', [
          'test/tool/coverage_library_loading_test.dart',
        ], scope: ''),
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
        // 生成契约只含编译期常量，VM沿业务消费者记录实际执行。
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
      final text = StringBuffer('// ignore_for_file: unused_import\n');
      text.writeln("import 'package:flutter_test/flutter_test.dart';");
      for (var index = 0; index < libraries.length; index++) {
        // Hide the named extension to permit deferred import; loadLibrary loads
        // the complete library, including the extension implementation.
        final hidden = libraries[index] == 'lib/src/l10n/messages.dart'
            ? ' hide AppMessageText'
            : '';
        text.writeln(
          "import 'package:clash_pseudo/${libraries[index].substring(4)}' deferred as source$index$hidden;",
        );
      }
      text.writeln(
        "void main() { test('load every application library for the coverage denominator', () async {",
      );
      for (var index = 0; index < libraries.length; index++) {
        text.writeln('await source$index.loadLibrary();');
      }
      text.writeln('}); }');
      final loader = await generate(
        'application_libraries_test.dart',
        text.toString(),
      );
      await generate(
        'flutter_test_config.dart',
        await File('test/flutter_test_config.dart').readAsString(),
      );
      // Validate generated imports through the SDK before full collection.
      final checked = await Process.run(
        Platform.environment['FLUTTER_BIN'] ?? 'flutter',
        ['test', '--no-pub', '--reporter=expanded', '--fail-fast', loader.path],
        workingDirectory: root.path,
      );
      await File('${output.path}/loader-check.stdout.log')
          .writeAsString(checked.stdout as String);
      await File('${output.path}/loader-check.stderr.log')
          .writeAsString(checked.stderr as String);
      if (checked.exitCode != 0) {
        throw StateError(
          'Application library loader failed: exit ${checked.exitCode}',
        );
      }
      final raw = await run('application', [
        ...(targets.isEmpty ? ['test'] : targets),
        loader.path,
      ]);
      final files = await raw
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final merged = await coverage.HitMap.parseFiles(
        files,
        packagePath: root.path,
        scopeOutput: {'clash_pseudo'},
      );
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
      final missing = sources
          .where((source) => !mapped.contains(File(source).absolute.path))
          .toList();
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
          'denominatorComplete': missing.isEmpty,
          'completedIsolateReports': files.length,
          'functionUnit':
              'entry source line; multiple functions on one line may merge',
          'branchUnit': 'VM branch source line; not automatic condition/decision coverage',
        }),
      );
      if (missing.isNotEmpty) {
        stderr.writeln('Unmapped sources: ${missing.join(', ')}');
        exitCode = 1;
      }
    }
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
