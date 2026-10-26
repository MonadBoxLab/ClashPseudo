import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:coverage/coverage.dart' as coverage;
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (const bool.fromEnvironment('APP_FUNCTION_COVERAGE')) {
    const output = String.fromEnvironment('APP_COVERAGE_DIRECTORY');
    if (output.isEmpty || !Directory(output).isAbsolute) {
      throw StateError(
        'APP_COVERAGE_DIRECTORY must be an absolute run directory',
      );
    }
    // testMain registers tests; root tearDownAll observes actual suite completion.
    tearDownAll(() async {
      final service = (await developer.Service.getInfo()).serverUri;
      final isolate = developer.Service.getIsolateId(Isolate.current);
      if (service == null || isolate == null) {
        throw StateError('Function coverage requires the test VM service');
      }
      const scope = String.fromEnvironment(
        'APP_COVERAGE_SCOPE',
        defaultValue: 'clash_pseudo',
      );
      final report = await coverage
          .collect(
            service,
            false,
            false,
            false,
            scope.isEmpty ? <String>{} : {scope},
            isolateIds: {isolate},
            functionCoverage: true,
            branchCoverage: true,
            timeout: const Duration(seconds: 30),
          )
          .timeout(const Duration(minutes: 8));
      final scripts = report['coverage'];
      if (scripts is! List ||
          scripts.any(
            (script) =>
                script is! Map ||
                script['hits'] is! List ||
                script['funcHits'] is! List ||
                script['funcNames'] is! List ||
                script['branchHits'] is! List,
          )) {
        throw StateError('Incomplete function/line/branch coverage response');
      }
      final directory = await Directory(output).create(recursive: true);
      final id = isolate.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
      final file = File('${directory.path}/$pid-$id.json');
      if (await file.exists()) {
        throw StateError('Coverage output already exists: ${file.path}');
      }
      await file.writeAsString(
        jsonEncode({
          ...report,
          'collector': {
            'pid': pid,
            'isolate': isolate,
            'scope': scope,
            'functionCoverage': true,
            'branchCoverage': true,
            'completion': 'root-tearDownAll',
          },
        }),
        flush: true,
      );
    });
  }
  await testMain();
}
