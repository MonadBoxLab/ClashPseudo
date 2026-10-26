import 'package:clash_pseudo/src/app/widgets/provenance_details.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/app_localizations_en.dart';
import 'package:clash_pseudo/src/model/definition_provenance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/provenance_fakes.dart';

DefinitionProvenance _definition(List<Map<String, dynamic>> sources) =>
    DefinitionProvenance.fromValue(definitionProvenanceWire(sources))!;

Future<void> _show(
  WidgetTester tester,
  DefinitionProvenance? provenance, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool providerDefinition = false,
  ValueNotifier<int>? status,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Before reading anchor', key: ValueKey('before')),
              if (providerDefinition)
                const SelectableText('https://provider.test/…'),
              if (status != null)
                SizedBox(
                  height: 56,
                  child: ValueListenableBuilder<int>(
                    valueListenable: status,
                    builder: (_, state, _) => Text(
                      [
                        'ready',
                        'waiting',
                        'failed',
                        'expired',
                        'recovered',
                      ][state],
                    ),
                  ),
                ),
              ProvenanceDetails(
                provenance: provenance,
                providerDefinition: providerDefinition,
              ),
              const Text('After reading anchor', key: ValueKey('after')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('summary uses captured names, not IDs; main-only adds no label', () {
    final strings = AppLocalizationsEn();
    final main = _definition([
      sourceContributorWire(kind: 'config', id: 'main', name: 'Loaded main'),
    ]);
    expect(provenanceSummary(strings, null), isNull);
    expect(provenanceSummary(strings, main), isNull);
    final one = _definition([
      sourceContributorWire(name: 'Actually loaded name'),
    ]);
    expect(provenanceSummary(strings, one), 'Actually loaded name');
    final local = _definition([
      sourceContributorWire(name: 'Loaded custom name', role: 'localCustom'),
    ]);
    expect(
      provenanceSummary(strings, local),
      'Loaded custom name · Local customizations',
    );
    final two = _definition([
      sourceContributorWire(id: 'first', name: 'Z priority'),
      sourceContributorWire(id: 'second', name: 'A lower priority'),
    ]);
    expect(provenanceSummary(strings, two), '2 contributing plugins');
    expect(
      provenanceDescription(strings, two),
      'Contributing plugins\n1. Z priority\n2. A lower priority',
    );
  });

  testWidgets('main-only has no extra source heading, name or geometry', (
    tester,
  ) async {
    await _show(
      tester,
      _definition([
        sourceContributorWire(kind: 'config', id: 'main', name: 'Loaded main'),
      ]),
    );
    expect(find.text('Loaded main'), findsNothing);
    expect(find.text('Configuration'), findsNothing);
    expect(find.text('Contributing plugins'), findsNothing);
    expect(tester.getSize(find.byType(ProvenanceDetails)).height, 0);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'zh']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'ordered long names wrap at 280px, 2x text, $language $brightness without state-frame movement',
        (tester) async {
          tester.view.physicalSize = const Size(280, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final status = ValueNotifier<int>(0);
          addTearDown(status.dispose);
          final firstName = '运行时记录的本地插件名称' * 5;
          final secondName =
              'Remote plugin captured before a later rename / 远程名称';
          final provenance = _definition([
            sourceContributorWire(
              id: 'first',
              name: firstName,
              role: 'localCustom',
            ),
            sourceContributorWire(id: 'second', name: secondName),
            sourceContributorWire(
              kind: 'config',
              id: 'main',
              name: 'Do not label main',
            ),
          ]);
          await _show(
            tester,
            provenance,
            language: language,
            brightness: brightness,
            scale: 2,
            status: status,
          );
          final first = find.widgetWithText(SelectableText, firstName);
          final second = find.widgetWithText(SelectableText, secondName);
          expect(first, findsOneWidget);
          expect(second, findsOneWidget);
          expect(
            tester.getTopLeft(first).dy,
            lessThan(tester.getTopLeft(second).dy),
          );
          final firstRect = tester.getRect(first);
          final secondRect = tester.getRect(second);
          final after = tester.getRect(find.byKey(const ValueKey('after')));
          expect(firstRect.right, lessThanOrEqualTo(264));
          expect(secondRect.right, lessThanOrEqualTo(264));
          expect(tester.widget<SelectableText>(first).maxLines, isNull);
          expect(find.text('Do not label main'), findsNothing);
          for (final state in [1, 2, 1, 3, 4]) {
            status.value = state;
            for (final duration in [
              Duration.zero,
              const Duration(milliseconds: 16),
              const Duration(milliseconds: 100),
            ]) {
              await tester.pump(duration);
              expect(tester.getRect(first), firstRect);
              expect(tester.getRect(second), secondRect);
              expect(
                tester.getRect(find.byKey(const ValueKey('after'))),
                after,
              );
              expect(tester.takeException(), isNull);
            }
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('provider definition heading is separate from the content URL', (
    tester,
  ) async {
    await _show(
      tester,
      _definition([
        sourceContributorWire(
          name: 'Plugin defining provider',
          path: '/proxy-providers/remote',
        ),
      ]),
      providerDefinition: true,
    );
    expect(find.text('Definition contributors'), findsOneWidget);
    expect(find.text('https://provider.test/…'), findsOneWidget);
    expect(find.text('Plugin defining provider'), findsOneWidget);
    expect(find.text('Contributing plugins'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'locale changes translate only the role, never the captured source name',
    (tester) async {
      final provenance = _definition([
        sourceContributorWire(
          name: 'Actually loaded custom name',
          role: 'localCustom',
        ),
      ]);
      await _show(tester, provenance);
      expect(find.text('Actually loaded custom name'), findsOneWidget);
      expect(find.text('Local customizations'), findsOneWidget);
      await _show(tester, provenance, language: 'zh');
      expect(find.text('Actually loaded custom name'), findsOneWidget);
      expect(find.text('本地自定义'), findsOneWidget);
      expect(find.text('Local customizations'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
