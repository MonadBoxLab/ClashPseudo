import 'package:flutter/material.dart';

import '../features/overview/overview_page.dart';
import '../platform/app_bridge.dart';
import 'app_controller.dart';

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
    if (state == AppLifecycleState.resumed) controller.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(seedColor: const Color(0xff315f72));
    return MaterialApp(
      title: 'Clash Pseudo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colors,
        scaffoldBackgroundColor: const Color(0xfff4f6f8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff4f6f8),
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 6),
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: OverviewPage(controller: controller),
    );
  }
}
