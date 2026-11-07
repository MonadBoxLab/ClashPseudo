import 'package:clash_pseudo/src/ui/locale/message_text.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_file.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:cross_file/cross_file.dart';
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

  test('SAF returns bounded bytes and preserves cancellation', () async {
    const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<String, Object?> response = {'status': 'cancelled'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickConfigFile');
      return {...response, 'requestId': call.arguments['requestId']};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await selectConfigFile(), isNull);
    response = {
      'status': 'ready',
      'bytes': Uint8List.fromList(utf8.encode('规则: []\n')),
      'name': '中文.yaml',
    };
    final file = (await selectConfigFile())!;
    expect(file.name, '中文.yaml');
    expect(await readConfigFile(file), '规则: []\n');
    response = {'status': 'failed', 'errorCode': 'textTooLargeImport'};
    await expectLater(selectConfigFile(), throwsA(isA<ConfigFailure>()));
    response = {
      'status': 'ready',
      'retired': true,
      'bytes': Uint8List(1),
      'name': 'stale.yaml',
    };
    expect(await selectConfigFile(), isNull);
  });
  test(
    'cancelling a selection waits for the original document drain reply',
    () async {
      const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final reading = Completer<Map<String, Object?>>();
      final opened = Completer<void>();
      final cancelled = Completer<void>();
      String? requestId;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pickConfigFile') {
          requestId = call.arguments['requestId'] as String;
          opened.complete();
          return reading.future;
        }
        expect(call.method, 'cancelConfigFile');
        expect(call.arguments['requestId'], requestId);
        cancelled.complete();
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final selection = ConfigFileSelection(AppBridge());
      var finished = false;
      final pending = selection.select();
      await opened.future;
      final cancellation = selection.cancel().then((_) => finished = true);
      await cancelled.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      reading.complete({
        'requestId': requestId,
        'status': 'ready',
        'bytes': Uint8List(1),
        'name': 'late.yaml',
      });
      expect(await pending, isNull);
      await cancellation;
      expect(finished, isTrue);
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

  test(
    'filename defaults preserve a complete scalar within the byte budget',
    () {
      expect(configFileName('${'中' * 27}.yaml'), '中' * 26);
      expect(configFileName('${'🌐' * 21}.yaml'), '🌐' * 20);
      expect(configFileName('${'a' * 79}🌐.yaml'), 'a' * 79);
      expect(configFileName('  ${'中' * 26}ab .yml'), '${'中' * 26}ab');
      expect(configFileName('rules.prod.yaml'), 'rules.prod');
    },
  );
}
