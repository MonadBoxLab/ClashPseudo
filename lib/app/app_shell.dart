import 'package:flutter/material.dart';

import '../features/overview/overview_page.dart';
import '../features/strategies/strategies_page.dart';
import '../features/strategies/strategy_controller.dart';
import 'app_controller.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final strategies = StrategyController(widget.controller);
  int index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: index,
      children: [
        TickerMode(
          enabled: index == 0,
          child: OverviewPage(
            controller: widget.controller,
            active: index == 0,
          ),
        ),
        StrategiesPage(controller: strategies, active: index == 1),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => setState(() => index = value),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '总览',
        ),
        NavigationDestination(
          icon: Icon(Icons.alt_route_outlined),
          selectedIcon: Icon(Icons.alt_route_rounded),
          label: '策略',
        ),
      ],
    ),
  );

  @override
  void dispose() {
    strategies.dispose();
    super.dispose();
  }
}
