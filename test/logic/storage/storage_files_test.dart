import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/storage/storage_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-json-budget-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('bounded reads preserve the original file on failure', () async {
    final file = File('${directory.path}/value.json');
    const original = '{"text":"日🔐"}';
    await file.writeAsString(original);
    final size = utf8.encode(original).length;
    expect(await readStorageJson(file, size), {'text': '日🔐'});
    await expectLater(readStorageJson(file, size - 1), throwsFormatException);
    expect(await file.readAsString(), original);
    await file.writeAsString('{broken');
    await expectLater(readStorageJson(file, 4096), throwsFormatException);
    expect(await file.readAsString(), '{broken');
  });
}
