import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/app_preferences.dart';
import '../../platform/channel/app_bridge.dart';
import '../navigation/app_shell.dart';
import '../navigation/route_observer.dart';
import '../navigation/workspace_window.dart';
import '../theme/app_theme.dart';
import 'app_controller.dart';
import 'first_run_notice.dart';

class ClashPseudoApp extends StatefulWidget {
  const ClashPseudoApp({super.key, this.createController});

  /// Creates the root-owned controller once; the app disposes it with its State.
  final AppController Function()? createController;

  @override
  State<ClashPseudoApp> createState() => _ClashPseudoAppState();
}

class _ClashPseudoAppState extends State<ClashPseudoApp>
    with WidgetsBindingObserver {
  final _taskRoutes = AppTaskNavigatorObserver();
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
        navigatorObservers: [_taskRoutes],
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
        builder: (context, child) => WorkspaceWindow(
          controller: controller,
          child: Column(
            children: [
              if (controller.state.recoveryRequired)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      key: const ValueKey('core-interruption-banner'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context)
                                  .coreInterruptedMessage,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                key: const ValueKey('application-navigation'),
                child: child!,
              ),
            ],
          ),
        ),
        home: FirstRunNotice(
          controller: controller,
          child: controller.loading
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : AppShell(controller: controller),
        ),
      );
    },
  );
}
