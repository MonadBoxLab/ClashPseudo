import 'dart:convert';

import 'package:clash_pseudo/src/model/storage_json.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UTF-8 and escaped JSON use actual encoded bytes at the boundary', () {
    final value = {'text': '日🔐\n"\\'};
    final expected = utf8.encode(jsonEncode(value));
    final bytes = encodeStorageJson('fixture.json', value, expected.length);
    expect(bytes, expected);
    expect(
      () => encodeStorageJson('fixture.json', value, expected.length - 1),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('fixture.json'),
        ),
      ),
    );
  });

  test('quoted brackets and escapes do not consume structure depth', () {
    final value = {'text': '${'[' * 100}\\"${']' * 100}'};
    final bytes = encodeStorageJson('quoted.json', value, 4096);
    expect(jsonDecode(utf8.decode(bytes)), value);
  });

  test('depth and node budgets apply before standard JSON decoding', () {
    final depth = ApplicationContract.backupJsonDepth;
    final exact = utf8.encode('${'[' * depth}0${']' * depth}');
    checkStorageJson('depth.json', exact, exact.length);
    final over = utf8.encode('[${utf8.decode(exact)}]');
    expect(
      () => checkStorageJson('depth.json', over, over.length),
      throwsFormatException,
    );
    final nodes = ApplicationContract.backupJsonNodes;
    final array = '[${List.filled(nodes - 1, '0').join(',')}]';
    final bytes = utf8.encode(array);
    checkStorageJson('nodes.json', bytes, bytes.length);
    final extra = utf8.encode('[0,${array.substring(1)}');
    expect(
      () => checkStorageJson('nodes.json', extra, extra.length),
      throwsFormatException,
    );
  });
}
