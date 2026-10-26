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
      expect(result.exitCode, isNot(0));
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
