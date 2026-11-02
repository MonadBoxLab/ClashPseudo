import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../logic/configs/config_downloader_test.dart'
    show downloadFailure;

class _FailingClient implements HttpClient {
  _FailingClient(this.failure);
  final Object failure;
  final opened = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    opened.add(url);
    throw failure;
  }

  @override
  void close({bool force = false}) => closed = force;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const secretSource =
      'https://UserCanary:PasswordCanary@example.test/config?token=QueryCanary&sig=SignatureCanary';
  const detail = 'ErrorCanary request=$secretSource';
  for (final (kind, id, injected) in <(String, String, Object)>[
    ('socket', 'downloadFailed', const SocketException(detail)),
    (
      'http',
      'downloadFailed',
      HttpException(detail, uri: Uri.parse(secretSource)),
    ),
    ('tls', 'tlsFailed', const HandshakeException(detail)),
    ('format', 'downloadNotUtf8', const FormatException(detail, secretSource)),
    ('timeout', 'downloadTimeout', TimeoutException(detail)),
    ('client creation', 'trustedRootsUnavailable', StateError(detail)),
  ]) {
    testWidgets(
      'retains complete $kind errors in localized feedback without emitting logs',
      (tester) async {
        final logs = <String>[];
        final client = _FailingClient(injected);
        final previousPrint = debugPrint;
        late ConfigFailure failure;
        try {
          debugPrint = (message, {wrapWidth}) {
            if (message != null) logs.add(message);
          };
          failure = await runZoned(
            () => downloadFailure(
              ConfigDownloader(
                createClient: () {
                  if (kind == 'client creation') throw injected;
                  return client;
                },
              ).download(secretSource),
            ),
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) => logs.add(line),
            ),
          );
        } finally {
          debugPrint = previousPrint;
        }
        expect(injected.toString(), contains(detail));
        expect(failure.message.toMap(), {
          'id': id,
          'args': <String, Object?>{},
          'detail': injected.toString(),
        });
        expect(failure.toString(), '$id: $injected');
        if (kind == 'client creation') {
          expect(client.opened, isEmpty);
        } else {
          expect(client.opened, [
            Uri.parse(secretSource).replace(userInfo: ''),
          ]);
          expect(client.closed, isTrue);
        }
        final locale = ValueNotifier(const Locale('en'));
        final routes = AppTaskNavigatorObserver();
        addTearDown(locale.dispose);
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => MaterialApp(
              navigatorObservers: [routes],
              locale: value,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAppMessage(context, failure.message),
                    child: const Text('Show failure'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Show failure'));
        await tester.pumpAndSettle();
        final dialog = tester.element(find.byType(AlertDialog));
        final rendered = <String>[];
        for (final language in ['en', 'zh']) {
          locale.value = Locale(language);
          await tester.pumpAndSettle();
          expect(tester.element(find.byType(AlertDialog)), same(dialog));
          final strings = AppLocalizations.of(dialog);
          final expected = switch (id) {
            'downloadFailed' => strings.downloadFailed,
            'tlsFailed' => strings.tlsFailed,
            'downloadNotUtf8' => strings.downloadNotUtf8,
            'downloadTimeout' => strings.downloadTimeout,
            'trustedRootsUnavailable' => strings.trustedRootsUnavailable,
            _ => throw StateError('Unexpected message ID'),
          };
          final content = tester.widget<SelectableText>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(SelectableText),
                )
                .first,
          );
          expect(content.data, expected);
          final technicalText = find.byKey(
            const ValueKey('operation-technical-text'),
          );
          if (technicalText.evaluate().isEmpty) {
            await tester.tap(
              find.byKey(const ValueKey('operation-technical-details')),
            );
            await tester.pumpAndSettle();
          }
          final technical = tester.widget<SelectableText>(technicalText);
          expect(technical.data, injected.toString());
          final complete = '${content.data}\n${technical.data}';
          expect(complete, '$expected\n$injected');
          expect(failure.message.resolve(strings), complete);
          rendered.add(complete);
        }
        expect(rendered[0], isNot(rendered[1]));
        expect(logs, isEmpty);
        for (final text in [
          ...rendered,
          failure.toString(),
          jsonEncode(failure.message.toMap()),
        ]) {
          for (final value in [
            'UserCanary',
            'PasswordCanary',
            'QueryCanary',
            'SignatureCanary',
            'ErrorCanary',
          ]) {
            expect(text, contains(value), reason: '$kind retains $value');
          }
        }
        await tester.tap(find.text(AppLocalizations.of(dialog).close));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
