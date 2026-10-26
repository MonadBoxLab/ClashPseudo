import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/app_message.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/runtime_fakes.dart' show TestApp;

class AccessBridge extends AppBridge {
  List<Map<String, dynamic>> installed = [
    {'package': 'app.alpha', 'label': 'Alpha', 'system': false},
    {'package': 'app.beta', 'label': 'Beta', 'system': false},
    {'package': 'android.system', 'label': 'System', 'system': true},
  ];
  bool fail = false;
  bool statusFails = false;
  bool openFails = false;
  int listCalls = 0;
  int statusCalls = 0;
  Completer<List<Map<String, dynamic>>>? listReply;
  Completer<Map<String, dynamic>>? statusReply;
  Map<String, Object?> status = const {'alwaysOn': true, 'lockdown': false};
  final opened = <String>[];

  @override
  Future<List<Map<String, dynamic>>> applications() async {
    listCalls++;
    if (listReply case final reply?) return reply.future;
    if (fail) throw StateError('list failed');
    return installed;
  }

  final icons = <String>[];
  Future<Uint8List?> Function(String package)? iconReply;

  @override
  Future<Uint8List?> applicationIcon(String package) async {
    icons.add(package);
    return iconReply?.call(package);
  }

  @override
  Future<Map<String, dynamic>> vpnStatus() async {
    statusCalls++;
    if (statusReply case final reply?) return reply.future;
    if (statusFails) throw StateError('status failed');
    return Map<String, dynamic>.from(status);
  }

  @override
  Future<void> openVpnSettings() async {
    if (openFails) throw StateError('settings failed');
    opened.add('settings');
  }
}

class AccessApp extends TestApp {
  AccessApp(super.platform) {
    preferencesLoaded = true;
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: state.generation,
      core: state.core,
      runningApplicationAccess: RunningApplicationAccess(
        generation: state.generation,
        access: ApplicationAccess.all,
        packages: [],
      ),
    );
  }

  bool reject = false;

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    await super.submit(command, automatic: automatic);
    if (!reject) return 'operation-${commands.length}';
    lastCommand = Map.of(command);
    lastCommandAutomatic = automatic;
    commandErrorMessage = const AppMessage('requestNotAccepted');
    notifyListeners();
    return null;
  }
}

Future<Uint8List> createApplicationPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xff2858af), ui.BlendMode.src);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(2, 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<void> show(
  WidgetTester tester,
  Widget page, {
  Locale locale = const Locale('zh'),
  bool dark = false,
}) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    theme: dark ? AppTheme.dark : AppTheme.light,
    home: page,
  ),
);
