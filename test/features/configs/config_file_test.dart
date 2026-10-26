import 'dart:convert';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_file.dart';
import 'package:clash_pseudo/src/features/configs/config_text.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _GrowingFile extends XFile {
  _GrowingFile() : super('fixture');
  bool cancelled = false;
  @override
  Future<int> length() async => 1;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    try {
      yield Uint8List(maxConfigBytes);
      yield Uint8List(1);
      fail('Reader must stop at the byte limit');
    } finally {
      cancelled = true;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'single picker leaves provider MIME unrestricted and preserves cancel',
    () async {
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await selectConfigFile(), isNull);
      expect(calls.single.method, 'openFile');
      expect(calls.single.arguments['acceptedTypeGroups'], isEmpty);
      expect(calls.single.arguments['multiple'], isFalse);
    },
  );
  test('file decoding keeps BOM, empty and malformed YAML as text', () async {
    for (final text in ['', '\u{feff}中文🌐\r\n', '[invalid YAML']) {
      final file = XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        name: 'config.yaml',
      );
      expect(await readConfigFile(file), text);
    }
  });

  test(
    'declared and streamed byte limits reject without partial content',
    () async {
      await expectLater(
        readConfigFile(XFile.fromData(Uint8List(maxConfigBytes + 1))),
        throwsA(isA<ConfigFailure>()),
      );
      final growing = _GrowingFile();
      await expectLater(readConfigFile(growing), throwsA(isA<ConfigFailure>()));
      expect(growing.cancelled, isTrue);
      expect(
        (await readConfigFile(XFile.fromData(Uint8List(maxConfigBytes))))
            .length,
        maxConfigBytes,
      );
    },
  );

  test('invalid UTF-8 file is rejected', () async {
    await expectLater(
      readConfigFile(XFile.fromData(Uint8List.fromList([0xff]))),
      throwsA(isA<ConfigFailure>()),
    );
  });

  for (final language in [AppLanguage.en, AppLanguage.zh]) {
    test('empty filename fallback uses the current language: $language', () {
      setMessageLanguage(language);
      addTearDown(() => setMessageLanguage(AppLanguage.system));
      expect(
        configFileName(''),
        language == AppLanguage.en ? 'Local configuration' : '本地配置',
      );
      expect(
        configFileName('  .yaml'),
        language == AppLanguage.en ? 'Local configuration' : '本地配置',
      );
    });
  }

  test('display name removes only final extension and never becomes empty', () {
    expect(configFileName('rules.prod.yaml'), 'rules.prod');
    expect(configFileName('配置🌐.yml'), '配置🌐');
    expect(configFileName(''), localizedMessages.localConfig);
    expect(configFileName('${'🌐' * 81}.yaml'), '🌐' * 20);
    expect(utf8.encode(configFileName('${'🌐' * 81}.yaml')).length, 80);
  });
}
