import 'package:flutter/material.dart';

import '../model/app_preferences.dart';
import '../l10n/app_localizations.dart';
import 'app_shell.dart';
import '../platform/app_bridge.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'workspace_window.dart';

class ClashPseudoApp extends StatefulWidget {
  const ClashPseudoApp({super.key, this.createController});

  /// Creates the root-owned controller once; the app disposes it with its State.
  final AppController Function()? createController;

  @override
  State<ClashPseudoApp> createState() => _ClashPseudoAppState();
}

class _ClashPseudoAppState extends State<ClashPseudoApp>
    with WidgetsBindingObserver {
  late final controller =
      widget.createController?.call() ?? AppController(AppBridge());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setInteractive(state == AppLifecycleState.resumed);
    controller.setForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final preferences = controller.preferences;
      return MaterialApp(
        title: 'Clash Pseudo',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: switch (preferences.language) {
          AppLanguage.system => null,
          AppLanguage.zh => const Locale('zh'),
          AppLanguage.en => const Locale('en'),
        },
        theme: AppTheme.forBrightness(Brightness.light, preferences.brand),
        darkTheme: AppTheme.forBrightness(Brightness.dark, preferences.brand),
        themeMode: switch (preferences.appearance) {
          AppAppearance.system => ThemeMode.system,
          AppAppearance.light => ThemeMode.light,
          AppAppearance.dark => ThemeMode.dark,
        },
        builder: (context, child) =>
            WorkspaceWindow(controller: controller, child: child!),
        home: controller.loading
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : AppShell(controller: controller),
      );
    },
  );
}
