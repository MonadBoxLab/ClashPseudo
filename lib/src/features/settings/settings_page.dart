import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../app/widgets/reading_list.dart';
import 'about_page.dart';
import 'always_on_page.dart';
import 'applications_page.dart';
import '../../l10n/app_localizations.dart';
import '../configs/configs_page.dart';
import '../backup/backup_settings_actions.dart';
import '../connections/connections_page.dart';
import '../overrides/overrides_page.dart';
import '../../model/app_preferences.dart';
import '../diagnostics/runtime_config_page.dart';
import '../diagnostics/logs_page.dart';
import '../diagnostics/nodes_page.dart';
import '../diagnostics/resources_page.dart';
import '../diagnostics/rules_page.dart';
import '../diagnostics/dns_controller.dart';
import '../diagnostics/dns_tool.dart';
import '../diagnostics/strategy_groups_page.dart';
import '../mode/mode_sheet.dart';

import '../../app/app_task.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.app,
    this.active = true,
    this.onOpenTask,
  });
  final AppController app;
  final bool active;
  final ValueChanged<AppTask>? onOpenTask;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get app => widget.app;
  DnsController? _dns;
  final _sectionKeys = <int, GlobalKey>{};

  Future<void> _openMode(AppController owner, int storageEpoch) async {
    if (!mounted ||
        !widget.active ||
        !identical(app, owner) ||
        owner.storageEpoch != storageEpoch ||
        !owner.foreground ||
        !owner.canChangeMode ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: HomePalette.of(context).surface,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ModeSheet(controller: owner, storageEpoch: storageEpoch),
    );
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != app) {
      _dns?.dispose();
      _dns = null;
    }
  }

  @override
  void dispose() {
    _dns?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final owner = app;
      final preferences = app.preferences;
      final storageEpoch = app.storageEpoch;
      final icons = SettingsPalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      return Scaffold(
        appBar: AppBar(title: Text(strings.settings)),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: LayoutBuilder(
                builder: (context, constraints) => ReadingList(
                  key: const PageStorageKey('settings'),
                  // Fixed presentation rows survive Store epochs and inset changes.
                  identity: const ValueKey('settings'),
                  header: const SizedBox.shrink(),
                  items: _groupedRows(context, <Widget>[
                    _heading(context, strings.appearanceAndLanguage),
                    _choice(
                      context,
                      storageEpoch: storageEpoch,
                      icon: Icons.brightness_6_outlined,
                      color: icons.appearance,
                      title: strings.appearance,
                      field: 'appearance',
                      value: preferences.appearance.name,
                      choices: {
                        AppAppearance.system.name: strings.followSystem,
                        AppAppearance.light.name: strings.lightAppearance,
                        AppAppearance.dark.name: strings.darkAppearance,
                      },
                    ),
                    _choice(
                      context,
                      storageEpoch: storageEpoch,
                      icon: Icons.palette_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      title: strings.brandColor,
                      field: 'brand',
                      value: preferences.brand.name,
                      choices: {
                        BrandColor.cinnabar.name: strings.cinnabar,
                        BrandColor.jade.name: strings.jade,
                        BrandColor.cobalt.name: strings.cobalt,
                      },
                    ),
                    _choice(
                      context,
                      storageEpoch: storageEpoch,
                      icon: Icons.translate_rounded,
                      color: icons.language,
                      title: strings.language,
                      field: 'language',
                      value: preferences.language.name,
                      choices: {
                        AppLanguage.system.name: strings.followSystem,
                        AppLanguage.zh.name: '中文',
                        AppLanguage.en.name: 'English',
                      },
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _heading(context, strings.connectionBehavior),
                    ListTile(
                      key: const ValueKey('settings-mode'),
                      enabled: app.canChangeMode,
                      leading: Icon(
                        Icons.alt_route_rounded,
                        color: app.canChangeMode
                            ? icons.network
                            : Theme.of(context).disabledColor,
                      ),
                      title: Text(strings.modeTitle),
                      trailing: const Icon(Icons.expand_more_rounded),
                      onTap: app.canChangeMode
                          ? () => _openMode(owner, storageEpoch)
                          : null,
                    ),
                    SwitchListTile(
                      secondary: Icon(
                        Icons.restart_alt,
                        color: app.canChangePreferences
                            ? icons.network
                            : Theme.of(context).disabledColor,
                      ),
                      title: Text(strings.reconnectOnRoutingChange),
                      subtitle: Text(strings.routingReconnectNotice),
                      value: preferences.reconnectOnRoutingChange,
                      onChanged: app.canChangePreferences
                          ? (value) => app.submit({
                              'action': 'setPreference',
                              'field': 'reconnectOnRoutingChange',
                              'value': value,
                              'storageEpoch': storageEpoch,
                            })
                          : null,
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _heading(context, strings.configurationsAndPlugins),
                    ListTile(
                      leading: Icon(
                        Icons.description_outlined,
                        color: icons.configuration,
                      ),
                      title: Text(strings.configurations),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.configuration,
                      ),
                      onTap: widget.onOpenTask != null
                          ? () => widget.onOpenTask!(AppTask.configurations)
                          : () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => ConfigsPage(controller: app),
                              ),
                            ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.extension_outlined,
                        color: icons.extension,
                      ),
                      title: Text(strings.overridePlugins),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.extension,
                      ),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => OverridesPage(app: app),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.data_object,
                        color: icons.configuration,
                      ),
                      title: Text(strings.runtimeConfiguration),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.configuration,
                      ),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => RuntimeConfigPage(app: app),
                        ),
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _heading(context, strings.routingAndResources),
                    ListTile(
                      leading: Icon(Icons.dns_outlined, color: icons.network),
                      title: Text(strings.proxyNodes),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(builder: (_) => NodesPage(app: app)),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.account_tree_outlined,
                        color: icons.network,
                      ),
                      title: Text(strings.allStrategyGroups),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => StrategyGroupsPage(app: app),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.rule_outlined,
                        color: icons.configuration,
                      ),
                      title: Text(strings.rules),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.configuration,
                      ),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(builder: (_) => RulesPage(app: app)),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.cloud_download_outlined,
                        color: icons.network,
                      ),
                      title: Text(strings.externalResources),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => ResourcesPage(app: app),
                        ),
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _heading(context, strings.diagnosticTools),
                    ListTile(
                      leading: Icon(
                        Icons.swap_vert_rounded,
                        color: icons.network,
                      ),
                      title: Text(strings.recentConnections),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: widget.onOpenTask != null
                          ? () => widget.onOpenTask!(AppTask.connections)
                          : () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => ConnectionsPage(app: app),
                              ),
                            ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.manage_search_outlined,
                        color: icons.network,
                      ),
                      title: Text(strings.dnsTools),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: () {
                        final controller = _dns ??= DnsController(app);
                        showDnsTool(context, app: app, controller: controller);
                      },
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.receipt_long_outlined,
                        color: icons.diagnostics,
                      ),
                      title: Text(strings.coreLogs),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.diagnostics,
                      ),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => CoreLogsPage(app: app),
                        ),
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    BackupSettingsActions(app: app, active: widget.active),
                    const Divider(indent: 16, endIndent: 16),
                    _heading(context, strings.androidSection),
                    ListTile(
                      leading: Icon(
                        Icons.apps_outlined,
                        color: icons.diagnostics,
                      ),
                      title: Text(strings.applicationAccess),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.diagnostics,
                      ),
                      onTap: () {
                        final epoch = app.storageEpoch;
                        Navigator.of(context).push<void>(
                          FocusedPageRoute(
                            builder: (_) =>
                                ApplicationsPage(app: app, storageEpoch: epoch),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.shield_outlined,
                        color: icons.network,
                      ),
                      title: Text(strings.alwaysOnTitle),
                      trailing: Icon(Icons.chevron_right, color: icons.network),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => AlwaysOnPage(app: app),
                        ),
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(
                        Icons.info_outline,
                        color: icons.configuration,
                      ),
                      title: Text(strings.about),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: icons.configuration,
                      ),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => AboutPage(platform: app.platform),
                        ),
                      ),
                    ),
                  ], constraints.maxWidth),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  List<ReadingListItem> _groupedRows(
    BuildContext context,
    List<Widget> rows,
    double width,
  ) {
    final groups = <List<Widget>>[[]];
    for (final row in rows) {
      if (row is Divider) {
        groups.add([]);
      } else {
        groups.last.add(row);
      }
    }
    final minimum = (MediaQuery.textScalerOf(context).scale(16) * 16).clamp(
      360.0,
      double.infinity,
    );
    final columns = width >= 840 && width >= minimum * 2 + 24 ? 2 : 1;
    final result = <ReadingListItem>[];
    for (var start = 0; start < groups.length; start += columns) {
      final first = start;
      final count = (groups.length - first).clamp(0, columns);
      result.add(
        ReadingListItem(
          id: ('settings-row', first),
          anchors: [
            for (var i = first; i < first + count; i++) ('settings-group', i),
          ],
          layoutValues: [columns],
          semanticChildCount: count,
          builder: (context) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var offset = 0; offset < columns; offset++) ...[
                  if (offset > 0) const SizedBox(width: 24),
                  Expanded(
                    child: offset >= count
                        ? const SizedBox.shrink()
                        : KeyedSubtree(
                            key: _sectionKeys.putIfAbsent(
                              first + offset,
                              GlobalKey.new,
                            ),
                            child: IndexedSemantics(
                              index: first + offset,
                              child: Column(
                                key: ValueKey(
                                  'settings-section:${first + offset}',
                                ),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: groups[first + offset],
                              ),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return result;
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _choice(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required int storageEpoch,
    required String title,
    required String field,
    required String value,
    required Map<String, String> choices,
  }) => ChoiceMenuButton<String>(
    enabled: widget.active && app.canChangePreferences,
    identity: storageEpoch,
    value: value,
    tooltip: title,
    options: choices,
    onSelected: (selected) {
      if (selected != value) {
        app.submit({
          'action': 'setPreference',
          'field': field,
          'value': selected,
          'storageEpoch': storageEpoch,
        });
      }
    },
    child: ListTile(
      enabled: app.canChangePreferences,
      leading: Icon(
        icon,
        color: app.canChangePreferences
            ? color
            : Theme.of(context).disabledColor,
      ),
      title: Text(title),
      subtitle: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          );
          var height = 0.0;
          for (final label in choices.values) {
            painter.text = TextSpan(
              text: label,
              style: DefaultTextStyle.of(context).style,
            );
            painter.layout(maxWidth: constraints.maxWidth);
            if (painter.height > height) height = painter.height;
          }
          painter.dispose();
          return SizedBox(height: height, child: Text(choices[value]!));
        },
      ),
      trailing: Icon(
        Icons.unfold_more_rounded,
        color: app.canChangePreferences
            ? color
            : Theme.of(context).disabledColor,
      ),
    ),
  );
}
