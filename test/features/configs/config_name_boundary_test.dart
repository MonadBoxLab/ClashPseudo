import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_actions.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_file.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/configs/widgets/config_field_dialog.dart';
import 'package:clash_pseudo/src/features/configs/widgets/import_dialog.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_fakes.dart';

void main() {
  final cases = [
    (name: 'a' * 80, bytes: 80, valid: true, label: 'ASCII boundary'),
    (name: 'a' * 81, bytes: 81, valid: false, label: 'ASCII overflow'),
    (name: '${'中' * 26}ab', bytes: 80, valid: true, label: 'CJK boundary'),
    (name: '中' * 27, bytes: 81, valid: false, label: 'CJK overflow'),
    (name: '🌐' * 20, bytes: 80, valid: true, label: 'emoji boundary'),
    (name: '🌐' * 21, bytes: 84, valid: false, label: 'emoji overflow'),
    (
      name: '${'é' * 26}ab',
      bytes: 80,
      valid: true,
      label: 'combining boundary',
    ),
    (name: 'é' * 27, bytes: 81, valid: false, label: 'combining overflow'),
    (
      name: '  ${'🌐' * 20}\t',
      bytes: 80,
      valid: true,
      label: 'trimmed boundary',
    ),
  ];

  for (final sample in cases) {
    test('model and Store name boundary: ${sample.label}', () async {
      final directory = await Directory.systemTemp.createTemp(
        'pseudo-name-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final configs = ConfigStore(directory);
      final overrides = OverrideStore(directory);
      const original = ConfigEntry(
        id: 'one',
        name: 'Original',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
      );
      const originalPart = OverrideEntry(
        id: 'part',
        name: 'Original',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
        enabled: false,
      );
      await configs.save(ConfigCollection(entries: [original]));
      await overrides.save([originalPart]);
      final candidate = original.renamed(sample.name);
      final part = originalPart.changed(name: sample.name);
      if (sample.valid) {
        expect(ConfigEntry.fromJson(candidate.toJson()).name, sample.name);
        expect(OverrideEntry.fromJson(part.toJson()).name, sample.name);
        await configs.save(ConfigCollection(entries: [candidate]));
        await overrides.save([part]);
        expect((await configs.read()).entries.single.name, sample.name);
        expect((await overrides.read()).single.name, sample.name);
      } else {
        expect(
          () => ConfigEntry.fromJson(candidate.toJson()),
          throwsFormatException,
        );
        expect(
          () => OverrideEntry.fromJson(part.toJson()),
          throwsFormatException,
        );
        final configFile = File('${directory.path}/configurations.json');
        final overrideFile = File('${directory.path}/overrides.json');
        final configBefore = await configFile.readAsBytes();
        final overrideBefore = await overrideFile.readAsBytes();
        await expectLater(
          configs.save(ConfigCollection(entries: [candidate])),
          throwsFormatException,
        );
        await expectLater(overrides.save([part]), throwsFormatException);
        expect(await configFile.readAsBytes(), configBefore);
        expect(await overrideFile.readAsBytes(), overrideBefore);
      }
    });
    for (final operation in [
      'saveLocal',
      'renameConfig',
      'import',
      'saveOverride',
      'changeOverride',
      'importOverride',
    ]) {
      test('$operation uses UTF-8 bytes: ${sample.label}', () async {
        expect(utf8.encode(sample.name.trim()).length, sample.bytes);
        final directory = await Directory.systemTemp.createTemp('pseudo-name-');
        addTearDown(() => directory.delete(recursive: true));
        final configs = ConfigStore(directory);
        final overrides = OverrideStore(directory);
        final platform = PlatformFake();
        final download = DownloadFake();
        final configActions = ConfigActions(
          configs,
          download,
          platform,
          File('${directory.path}/input'),
        );
        final overrideActions = OverrideActions(
          overrides,
          download,
          platform,
          runInput: File('${directory.path}/input'),
        );
        const local = ConfigEntry(
          id: 'local',
          name: 'Original',
          kind: ConfigKind.local,
          revision: 7,
          body: 'unchanged',
        );
        const part = OverrideEntry(
          id: 'part',
          name: 'Original',
          kind: ConfigKind.local,
          revision: 7,
          body: '{}',
          enabled: false,
        );
        await configs.save(
          ConfigCollection(entries: [local], selectedId: local.id),
        );
        await overrides.save([part]);
        final configBefore = await File('${directory.path}/configurations.json')
            .readAsBytes();
        final overridesBefore = await File('${directory.path}/overrides.json')
            .readAsBytes();
        final command = <String, dynamic>{
          'action': operation,
          'name': sample.name,
          'body': '{}',
          if (operation == 'renameConfig') 'id': local.id,
          if (operation == 'changeOverride') 'id': part.id,
          if (operation == 'import' || operation == 'importOverride')
            'source': 'https://fixture.test/data',
        };
        final configOperation = [
          'saveLocal',
          'renameConfig',
          'import',
        ].contains(operation);
        final pending = configOperation
            ? configActions.execute(command)
            : overrideActions.execute(command);
        if (!sample.valid) {
          await expectLater(pending, throwsA(isA<ConfigFailure>()));
          expect(
            await File('${directory.path}/configurations.json').readAsBytes(),
            configBefore,
          );
          expect(
            await File('${directory.path}/overrides.json').readAsBytes(),
            overridesBefore,
          );
          expect(download.calls, 0);
        } else {
          await pending;
          if (configOperation) {
            final saved = await configs.read();
            expect(saved.selectedId, local.id);
            final entry = operation == 'renameConfig'
                ? saved.selected!
                : saved.entries.last;
            expect(entry.name, sample.name.trim());
            expect(entry.revision, operation == 'renameConfig' ? 7 : 1);
            if (operation == 'renameConfig') {
              expect(entry.body, local.body);
              expect(entry.updatedAt, isNull);
            }
          } else {
            final saved = await overrides.read();
            final entry = operation == 'changeOverride'
                ? saved.first
                : saved.last;
            expect(entry.name, sample.name.trim());
            expect(entry.revision, operation == 'changeOverride' ? 7 : 1);
            if (operation == 'changeOverride') {
              expect(entry.body, part.body);
              expect(entry.enabled, isFalse);
              expect(entry.updatedAt, isNull);
            }
          }
        }
        expect(platform.events, isEmpty);
      });
    }

    for (final language in ['en', 'zh']) {
      for (final kind in ['name', 'config import', 'plugin import']) {
        for (final semantics in [false, true]) {
          testWidgets(
            '$language $kind UTF-8 counter semantics=$semantics: ${sample.label}',
            (tester) async {
              final handle = tester.ensureSemantics();
              try {
                await tester.pumpWidget(
                  MaterialApp(
                    locale: Locale(language),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    home: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => kind == 'name'
                                ? const ConfigFieldDialog(initial: '')
                                : ImportDialog(
                                    fragment: kind == 'plugin import',
                                  ),
                          ),
                          child: const Text('Open'),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.tap(find.text('Open'));
                await tester.pumpAndSettle();
                final strings = AppLocalizations.of(
                  tester.element(find.byType(AlertDialog)),
                );
                final field = find.byType(TextField).at(kind == 'name' ? 0 : 1);
                if (semantics) {
                  await tester.tap(field);
                  await tester.pumpAndSettle();
                  final owner = tester
                      .element(field)
                      .findRenderObject()!
                      .owner!
                      .semanticsOwner!;
                  final inputs = <SemanticsNode>[];
                  void visit(SemanticsNode node) {
                    if (node.getSemanticsData().flagsCollection.isTextField) {
                      inputs.add(node);
                    }
                    node.visitChildren((child) {
                      visit(child);
                      return true;
                    });
                  }

                  visit(owner.rootSemanticsNode!);
                  expect(
                    inputs,
                    hasLength(
                      kind == 'name'
                          ? 1
                          : kind == 'config import'
                          ? 2
                          : 3,
                    ),
                  );
                  final node = inputs[kind == 'name' ? 0 : 1];
                  expect(
                    node.getSemanticsData().hasAction(SemanticsAction.setText),
                    isTrue,
                  );
                  owner.performAction(
                    node.id,
                    SemanticsAction.setText,
                    sample.name,
                  );
                } else {
                  await tester.enterText(field, sample.name);
                }
                await tester.pump();
                expect(find.text('${sample.bytes}/80 B'), findsOneWidget);
                final button = kind == 'name'
                    ? find.widgetWithText(TextButton, strings.save)
                    : find.widgetWithText(
                        FilledButton,
                        strings.downloadAndSave,
                      );
                final enabled = kind == 'name'
                    ? tester.widget<TextButton>(button).onPressed != null
                    : tester.widget<FilledButton>(button).onPressed != null;
                expect(enabled, sample.valid);
                expect(
                  tester.widget<TextField>(field).controller!.text,
                  sample.name,
                );
                if (kind == 'name') {
                  expect(
                    tester.widget<TextField>(field).decoration!.labelText,
                    strings.definitionFormName,
                  );
                }
                expect(tester.takeException(), isNull);
              } finally {
                handle.dispose();
              }
            },
          );
        }
      }
    }
  }

  for (final fragment in [false, true]) {
    test('blank remote name uses a bounded host, fragment=$fragment', () async {
      final directory = await Directory.systemTemp.createTemp(
        'pseudo-host-name-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = 'https://${'a' * 60}.${'b' * 60}.test/data';
      final expected = '${'a' * 60}.${'b' * 19}';
      final platform = PlatformFake();
      final download = DownloadFake();
      if (fragment) {
        await OverrideActions(
          OverrideStore(directory),
          download,
          platform,
          runInput: File('${directory.path}/input'),
        ).execute({'action': 'importOverride', 'source': source, 'name': '  '});
        expect((await OverrideStore(directory).read()).single.name, expected);
      } else {
        await ConfigActions(
          ConfigStore(directory),
          download,
          platform,
          File('${directory.path}/input'),
        ).execute({'action': 'import', 'source': source, 'name': '  '});
        expect((await ConfigStore(directory).read()).selected!.name, expected);
      }
      expect(download.calls, 1);
      expect(platform.events, isEmpty);
    });
  }

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
