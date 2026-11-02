import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app/app_controller.dart';
import '../theme/app_theme.dart';
import '../components/input/choice_menu_button.dart';
import '../components/collections/reading_list.dart';
import 'about_page.dart';
import 'always_on_page.dart';
import 'applications_page.dart';
import '../../l10n/app_localizations.dart';
import '../configs/configs_page.dart';
import 'lan_proxy_page.dart';
import 'storage_data_page.dart';
import '../connections/connections_page.dart';
import '../overrides/overrides_page.dart';
import '../../model/app_preferences.dart';
import '../diagnostics/configuration/runtime_config_page.dart';
import '../diagnostics/logs/logs_page.dart';
import '../diagnostics/nodes/nodes_page.dart';
import '../diagnostics/resources/resources_page.dart';
import '../diagnostics/rules/rules_page.dart';
import '../diagnostics/dns/dns_controller.dart';
import '../diagnostics/dns/dns_tool.dart';
import '../strategies/strategy_groups_page.dart';
import '../strategies/mode_sheet.dart';

import '../navigation/task_activity.dart';
import '../navigation/page_route.dart';

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

  bool get _eligible =>
      mounted &&
      widget.active &&
      app.interactive &&
      AppTaskActivity.isActive(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (ModalRoute.of(context)?.isActive ?? true) &&
      ModalRoute.of(context)?.animation?.status != AnimationStatus.reverse;

  void _openPage(AppController owner, WidgetBuilder builder) {
    if (!_eligible || !identical(app, owner)) return;
    Navigator.of(context).push<void>(FocusedPageRoute(builder: builder));
  }

  void _openTask(AppController owner, AppTask task, WidgetBuilder fallback) {
    if (!_eligible || !identical(app, owner)) return;
    final open = widget.onOpenTask;
    if (open == null) {
      _openPage(owner, fallback);
    } else {
      open(task);
    }
  }

  Future<void> _openMode(AppController owner, int storageEpoch) async {
    if (!_eligible ||
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
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
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
      ModalRoute.isCurrentOf(context);
      final active = _eligible;
      final strings = AppLocalizations.of(context);
      final owner = app;
      final preferences = app.preferences;
      final storageEpoch = app.storageEpoch;
      final icons = SettingsPalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      return IgnorePointer(
        ignoring: !active,
        child: ExcludeFocus(
          excluding: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: Scaffold(
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
                        header: const SizedBox(height: 16),
                        items: _groupedRows(
                          context,
                          <List<Widget>>[
                            [
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
                                  AppAppearance.system.name:
                                      strings.followSystem,
                                  AppAppearance.light.name:
                                      strings.lightAppearance,
                                  AppAppearance.dark.name:
                                      strings.darkAppearance,
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
                            ],
                            [
                              _heading(context, strings.connectionBehavior),
                              ListTile(
                                key: const ValueKey('settings-lan-proxy'),
                                leading: Icon(
                                  Icons.lan_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.lanProxyTitle),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => LanProxyPage(app: owner),
                                ),
                              ),
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
                                onChanged: active && app.canChangePreferences
                                    ? (value) {
                                        if (!_eligible ||
                                            !identical(app, owner)) {
                                          return;
                                        }
                                        owner.submit({
                                          'action': 'setPreference',
                                          'field': 'reconnectOnRoutingChange',
                                          'value': value,
                                          'storageEpoch': storageEpoch,
                                        });
                                      }
                                    : null,
                              ),
                            ],
                            [
                              _heading(context, strings.configurationsAndData),
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
                                onTap: () => _openTask(
                                  owner,
                                  AppTask.configurations,
                                  (_) => ConfigsPage(controller: owner),
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
                                onTap: () => _openPage(
                                  owner,
                                  (routeContext) => OverridesPage(
                                    app: owner,
                                    active:
                                        mounted &&
                                        identical(app, owner) &&
                                        owner.interactive &&
                                        (AppTaskScope.maybeOf(routeContext)
                                                    ?.task ==
                                                null
                                            ? widget.active
                                            : AppTaskScope.maybeOf(
                                                    routeContext,
                                                  )!.task ==
                                                  AppTask.settings) &&
                                        (ModalRoute.of(routeContext)
                                                ?.isActive ??
                                            true) &&
                                        ModalRoute.of(routeContext)
                                                ?.animation
                                                ?.status !=
                                            AnimationStatus.reverse,
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
                                onTap: () => _openPage(
                                  owner,
                                  (_) => RuntimeConfigPage(app: owner),
                                ),
                              ),
                              ListTile(
                                key: const ValueKey('settings-storage-data'),
                                leading: Icon(
                                  Icons.storage_outlined,
                                  color: icons.configuration,
                                ),
                                title: Text(strings.storageData),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.configuration,
                                ),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => StorageDataPage(app: owner),
                                ),
                              ),
                            ],
                            [
                              _heading(context, strings.routingAndResources),
                              ListTile(
                                leading: Icon(
                                  Icons.dns_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.proxyNodes),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => NodesPage(app: owner),
                                ),
                              ),
                              ListTile(
                                leading: Icon(
                                  Icons.account_tree_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.allStrategyGroups),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => StrategyGroupsPage(app: owner),
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
                                onTap: () => _openPage(
                                  owner,
                                  (_) => RulesPage(app: owner),
                                ),
                              ),
                              ListTile(
                                leading: Icon(
                                  Icons.cloud_download_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.externalResources),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => ResourcesPage(app: owner),
                                ),
                              ),
                            ],
                            [
                              _heading(context, strings.diagnosticTools),
                              ListTile(
                                leading: Icon(
                                  Icons.swap_vert_rounded,
                                  color: icons.network,
                                ),
                                title: Text(strings.recentConnections),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () => _openTask(
                                  owner,
                                  AppTask.connections,
                                  (_) => ConnectionsPage(app: owner),
                                ),
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
                                onTap: () => _openPage(
                                  owner,
                                  (_) => CoreLogsPage(app: owner),
                                ),
                              ),
                              ListTile(
                                leading: Icon(
                                  Icons.manage_search_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.dnsTools),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () {
                                  if (!_eligible || !identical(app, owner)) {
                                    return;
                                  }
                                  final controller = _dns ??= DnsController(
                                    owner,
                                  );
                                  showDnsTool(
                                    context,
                                    app: owner,
                                    controller: controller,
                                  );
                                },
                              ),
                            ],
                            [
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
                                onTap: () => _openPage(
                                  owner,
                                  (_) => ApplicationsPage(
                                    app: owner,
                                    storageEpoch: storageEpoch,
                                  ),
                                ),
                              ),
                              ListTile(
                                leading: Icon(
                                  Icons.shield_outlined,
                                  color: icons.network,
                                ),
                                title: Text(strings.alwaysOnTitle),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: icons.network,
                                ),
                                onTap: () => _openPage(
                                  owner,
                                  (_) => AlwaysOnPage(app: owner),
                                ),
                              ),
                            ],
                          ],
                          constraints.maxWidth,
                          footer: Material(
                            key: const ValueKey('settings-about-surface'),
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              leading: Icon(
                                Icons.info_outline,
                                color: icons.configuration,
                              ),
                              title: Text(strings.about),
                              trailing: Icon(
                                Icons.chevron_right,
                                color: icons.configuration,
                              ),
                              onTap: () => _openPage(
                                owner,
                                (_) => AboutPage(platform: owner.platform),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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
    List<List<Widget>> groups,
    double width, {
    required Widget footer,
  }) {
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
            padding: const EdgeInsets.only(bottom: 24),
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
                              child: _SettingsSectionMotion(
                                columns: columns,
                                child: ListTileTheme.merge(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  minTileHeight: 56,
                                  child: Column(
                                    key: ValueKey(
                                      'settings-section:${first + offset}',
                                    ),
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: groups[first + offset],
                                  ),
                                ),
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
    result.add(
      ReadingListItem(
        id: 'settings-about',
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: footer,
        ),
      ),
    );
    return result;
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        container: true,
        header: true,
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    ),
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
  }) {
    final owner = app;
    return ChoiceMenuButton<String>(
      enabled: _eligible && app.canChangePreferences,
      identity: storageEpoch,
      value: value,
      tooltip: title,
      options: choices,
      onSelected: (selected) {
        if (_eligible && identical(app, owner) && selected != value) {
          owner.submit({
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
}

class _SettingsSectionMotion extends StatefulWidget {
  const _SettingsSectionMotion({required this.columns, required this.child});

  final int columns;
  final Widget child;

  @override
  State<_SettingsSectionMotion> createState() => _SettingsSectionMotionState();
}

class _SettingsSectionMotionState extends State<_SettingsSectionMotion>
    with SingleTickerProviderStateMixin {
  late final _position = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 180),
  );
  final _content = GlobalKey();
  Object? _layout;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final reduced =
          media.disableAnimations || !TickerMode.valuesOf(context).enabled;
      final layout = (
        widget.columns,
        constraints.maxWidth,
        media.size,
        media.textScaler,
        media.padding,
        media.viewInsets,
        Localizations.localeOf(context),
      );
      if (_layout != layout) {
        final first = _layout == null;
        _layout = layout;
        if (first || reduced) {
          _position.value = 1;
        } else {
          _position.forward(from: 0);
        }
      } else if (reduced && _position.value != 1) {
        _position.value = 1;
      }
      final content = SizedBox(
        key: _content,
        width: constraints.maxWidth,
        child: OverflowBox(
          fit: OverflowBoxFit.deferToChild,
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: AnimatedContainer(
            width: constraints.maxWidth,
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeInOutCubic,
            child: widget.child,
          ),
        ),
      );
      return _SectionPosition(
        animation: _position,
        layout: layout,
        immediate: reduced,
        scroll: Scrollable.maybeOf(context)?.position,
        child: AnimatedBuilder(
          animation: _position,
          child: reduced
              ? content
              : AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.topLeft,
                  child: content,
                ),
          builder: (context, child) {
            // A regrouped cell can paint across another row until it settles.
            // Keep scrolling live without letting that paint hit a sibling.
            final moving = !reduced && _position.isAnimating;
            return ExcludeFocus(
              excluding: moving,
              child: IgnorePointer(
                ignoring: moving,
                child: ExcludeSemantics(excluding: moving, child: child!),
              ),
            );
          },
        ),
      );
    },
  );

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }
}

// Presentation only: the existing grouped rows still decide columns and height.
// Retaining paint positions does not measure or rebalance the settings groups.
class _SectionPosition extends SingleChildRenderObjectWidget {
  const _SectionPosition({
    required this.animation,
    required this.layout,
    required this.immediate,
    required this.scroll,
    required super.child,
  });

  final Animation<double> animation;
  final Object layout;
  final bool immediate;
  final ScrollPosition? scroll;

  @override
  _RenderSectionPosition createRenderObject(BuildContext context) =>
      _RenderSectionPosition(animation, layout, immediate, scroll);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSectionPosition renderObject,
  ) => renderObject.update(animation, layout, immediate, scroll);
}

class _RenderSectionPosition extends RenderProxyBox {
  _RenderSectionPosition(
    this._animation,
    this._layout,
    this._immediate,
    this._scroll,
  );

  Animation<double> _animation;
  Object _layout;
  bool _immediate;
  ScrollPosition? _scroll;
  bool _relocated = false;
  Offset? _lastVisual;
  double _lastPixels = 0;
  Offset _from = Offset.zero;
  Offset _delta = Offset.zero;

  void update(
    Animation<double> animation,
    Object layout,
    bool immediate,
    ScrollPosition? scroll,
  ) {
    if (_animation != animation) {
      if (attached) _animation.removeListener(_tick);
      _animation = animation;
      if (attached) _animation.addListener(_tick);
    }
    if (_layout != layout) _relocated = true;
    _layout = layout;
    _immediate = immediate;
    _scroll = scroll;
    _tick();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(_tick);
  }

  @override
  void detach() {
    _animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = localToGlobal(Offset.zero);
    final pixels = _scroll?.pixels ?? 0;
    if (_relocated) {
      _from = _lastVisual == null
          ? Offset.zero
          : _lastVisual! - target - Offset(0, pixels - _lastPixels);
      _relocated = false;
    }
    _delta = _immediate
        ? Offset.zero
        : _from * (1 - Curves.easeInOutCubic.transform(_animation.value));
    _lastVisual = target + _delta;
    _lastPixels = pixels;
    if (child case final child?) context.paintChild(child, offset + _delta);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _delta,
        position: position,
        hitTest: (result, position) =>
            child?.hitTest(result, position: position) ?? false,
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_delta.dx, _delta.dy, 0, 1);
  }
}
