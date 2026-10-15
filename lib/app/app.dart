import 'package:flutter/material.dart';

import 'app_shell.dart';
import '../platform/app_bridge.dart';
import 'app_controller.dart';
import 'app_theme.dart';

class ClashPseudoApp extends StatefulWidget {
  const ClashPseudoApp({super.key});

  @override
  State<ClashPseudoApp> createState() => _ClashPseudoAppState();
}

class _ClashPseudoAppState extends State<ClashPseudoApp>
    with WidgetsBindingObserver {
  late final controller = AppController(AppBridge());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Clash Pseudo',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: ThemeMode.system,
    home: AppShell(controller: controller),
  );
}
