import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../../model/app_message.dart';
import '../components/feedback/operation_notice.dart';
import '../locale/message_text.dart';
import '../navigation/task_activity.dart';
import '../navigation/route_observer.dart';
import '../theme/app_theme.dart';
import '../configs/configs_page.dart';
import '../configs/dialogs/import_dialog.dart';
import '../connections/connections_page.dart';
import '../strategies/mode_sheet.dart';
import 'traffic_controller.dart';
import 'widgets/status_hero.dart';
import 'widgets/traffic_panel.dart';
import '../settings/core_cleanup_action.dart';
import '../../l10n/app_localizations.dart';
import '../navigation/page_route.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.controller,
    this.active = true,
    this.onOpenTask,
  });
  final AppController controller;
  final bool active;
  final ValueChanged<AppTask>? onOpenTask;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  static const _networkReadingWidth = 840.0;
  static const _networkReadingHeight = 720.0;
  static const _networkPadding = EdgeInsets.fromLTRB(24, 20, 24, 8);

  late TrafficController _traffic;
  final _hero = GlobalKey();
  final _network = GlobalKey();
  final _viewport = GlobalKey();
  bool _networkVisible = false;
  final _scroll = ScrollController();
  bool _heroVisible = true;
  bool _covered = false;
  int _presentation = 0;
  bool _foreground = true;
  final _owner = ValueNotifier<int>(0);
  bool _ownerNotificationPending = false;

  bool _ownsPresentation({Route<dynamic>? ownedPopup}) =>
      mounted &&
      widget.active &&
      widget.controller.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: ownedPopup);

  bool get _current {
    if (!_ownsPresentation() || _covered) return false;
    final route = ModalRoute.of(context);
    return (route?.isActive ?? true) &&
        (route?.isCurrent ?? true) &&
        route?.animation?.status != AnimationStatus.reverse;
  }

  Object? _noticeSource;
  final _readFaults = <String>{};
  bool _noticeScheduled = false;

  Map<String, AppMessage> get _readErrors {
    final app = widget.controller;
    return {
      if (app.errorMessage case final error?)
        if (!identical(error, app.commandErrorMessage)) 'application': error,
      'traffic': ?_traffic.errorMessage,
      'memory': ?_traffic.memoryErrorMessage,
    };
  }

  Object get _feedbackSource => (
    widget.controller,
    widget.controller.storageEpoch,
    widget.controller.state.generation,
    widget.controller.state.core.identity,
    _presentation,
  );

  void _scheduleReadNotice() {
    if (_noticeScheduled || !mounted) return;
    _noticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _noticeScheduled = false;
      if (!mounted) return;
      final source = _feedbackSource;
      if (_noticeSource != source) {
        _noticeSource = source;
        _readFaults.clear();
      }
      final errors = _readErrors;
      final recovery = widget.controller.state.recoveryRequired;
      _readFaults.removeWhere(
        (key) => key == 'recovery' ? !recovery : !errors.containsKey(key),
      );
      if (!_current) return;
      final fresh = Map.of(errors)
        ..removeWhere((key, _) => _readFaults.contains(key));
      final recoveryNotice = recovery && !_readFaults.contains('recovery');
      if (fresh.isEmpty && !recoveryNotice) return;
      _readFaults.addAll(fresh.keys);
      if (recoveryNotice) _readFaults.add('recovery');
      unawaited(
        showLocalizedOperationNotice(
          context,
          (strings) => {
            if (recoveryNotice) strings.coreInterruptedTitle,
            ...fresh.values.map((error) => error.summary(strings)),
          }.join('\n'),
          onDetails: recovery ? _showRecovery : null,
          technicalDetail: (strings) {
            final details = fresh.values
                .map((error) => error.technicalDetail(strings))
                .whereType<String>()
                .toList();
            return details.isEmpty ? null : details.join('\n\n');
          },
          eligibilityChanges: Listenable.merge([
            widget.controller,
            _traffic,
            _owner,
          ]),
          isCurrent: () =>
              source == _feedbackSource &&
              _current &&
              (recoveryNotice && widget.controller.state.recoveryRequired ||
                  fresh.keys.any(_readErrors.containsKey)),
          isCurrentWithPopup: (popup) =>
              source == _feedbackSource &&
              _ownsPresentation(ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(
                ModalRoute.of(context),
                ownedPopup: popup,
              ) &&
              (recoveryNotice && widget.controller.state.recoveryRequired ||
                  fresh.keys.any(_readErrors.containsKey)),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _syncOwner() {
    _scheduleReadNotice();
    if (_foreground && !widget.controller.foreground) _presentation++;
    _foreground = widget.controller.foreground;
    // An owned popup lives in another Overlay entry, not below this State.
    // Defer only its visual notification during build; callbacks read live gates.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_ownerNotificationPending) {
        _ownerNotificationPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _ownerNotificationPending = false;
          if (mounted) _owner.value++;
        });
      }
    } else {
      _owner.value++;
    }
    if (!widget.active || !_foreground) _traffic.setVisible(false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!AppTaskActivity.isActive(context)) _traffic.setVisible(false);
    _syncOwner();
  }

  @override
  void initState() {
    super.initState();
    _traffic = TrafficController(widget.controller, isCurrent: () => _current);
    _traffic.addListener(_scheduleReadNotice);
    widget.controller.addListener(_syncOwner);
    _scroll.addListener(_checkVisible);
  }

  @override
  void didUpdateWidget(OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.controller != widget.controller) {
      _presentation++;
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncOwner);
      _traffic.dispose();
      _traffic = TrafficController(
        widget.controller,
        isCurrent: () => _current,
      );
      _traffic.addListener(_scheduleReadNotice);
      widget.controller.addListener(_syncOwner);
    }
    _syncOwner();
  }

  void _checkVisible() {
    if (!mounted) return;
    final box = _hero.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final visible = bounds.overlaps(screen);
    final network = _network.currentContext?.findRenderObject() as RenderBox?;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final networkVisible =
        network != null &&
        network.hasSize &&
        viewport != null &&
        viewport.hasSize &&
        (network.localToGlobal(Offset.zero) & network.size).overlaps(
          (viewport.localToGlobal(Offset.zero) & viewport.size).intersect(
            screen,
          ),
        );
    _traffic.setVisible(networkVisible && _current);
    if (visible != _heroVisible || networkVisible != _networkVisible) {
      setState(() {
        _heroVisible = visible;
        _networkVisible = networkVisible;
      });
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    if (!_current) return;
    _traffic.setVisible(false);
    setState(() => _covered = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _covered = false);
    }
  }

  Future<void> _manage() async {
    if (!_current) return;
    final controller = widget.controller;
    if (widget.onOpenTask case final open?) {
      open(AppTask.configurations);
      return;
    }
    await _open(
      () => Navigator.of(context).push<void>(
        FocusedPageRoute(builder: (_) => ConfigsPage(controller: controller)),
      ),
    );
  }

  Future<void> _connections() async {
    if (!_current) return;
    final controller = widget.controller;
    if (widget.onOpenTask case final open?) {
      open(AppTask.connections);
      return;
    }
    await _open(
      () => Navigator.of(context).push<void>(
        FocusedPageRoute(builder: (_) => ConnectionsPage(app: controller)),
      ),
    );
  }

  Widget _modeSurface(
    BuildContext popupContext,
    int presentation,
    Widget child,
  ) {
    final route = ModalRoute.of(popupContext)!;
    bool current({Route<dynamic>? ownedPopup}) =>
        presentation == _presentation &&
        _ownsPresentation(ownedPopup: ownedPopup ?? route) &&
        AppTaskActivity.routeIsActive(route, ownedPopup: ownedPopup);
    return ListenableBuilder(
      listenable: Listenable.merge([route.animation!, _owner]),
      builder: (context, _) {
        final active = current();
        return AppTaskActivity(
          active: active,
          isActiveNow: () => current(),
          isActiveWithPopup: (popup) => current(ownedPopup: popup),
          child: IgnorePointer(
            ignoring: !active,
            child: ExcludeFocus(
              excluding: !active,
              child: ExcludeSemantics(excluding: !active, child: child),
            ),
          ),
        );
      },
    );
  }

  Future<void> _mode() async {
    if (!_current) return;
    final controller = widget.controller;
    final epoch = controller.storageEpoch;
    final presentation = _presentation;
    await _open(
      () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: HomePalette.of(context).surface,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (popupContext) => _modeSurface(
          popupContext,
          presentation,
          ModeSheet(controller: controller, storageEpoch: epoch),
        ),
      ),
    );
  }

  Widget _control(
    double progress, {
    required bool compact,
    required double width,
  }) {
    final presentation = _presentation;
    return ConstrainedBox(
      key: _hero,
      constraints: BoxConstraints(
        minHeight: compact ? 320 : 460,
        maxWidth: 1200,
      ),
      child: ListenableBuilder(
        listenable: _traffic,
        builder: (context, _) => StatusHero(
          traffic: _traffic,
          controller: widget.controller,
          runningProgress: progress,
          compact: compact,
          contentWidth: width,
          visible: _heroVisible && _current,
          isCurrent: () =>
              presentation == _presentation && _heroVisible && _current,
          isCurrentWithPopup: (popup) =>
              presentation == _presentation &&
              _heroVisible &&
              !_covered &&
              _ownsPresentation(ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(
                ModalRoute.of(context),
                ownedPopup: popup,
              ),
          onManage: _manage,
          onRecovery: _showRecovery,
          onMode: _mode,
          onImport: () => _open(() => openImport(context, widget.controller)),
        ),
      ),
    );
  }

  Future<void> _showRecovery() async {
    if (!_current || !widget.controller.state.recoveryRequired) return;
    final app = widget.controller;
    final source = _feedbackSource;
    final origin = ModalRoute.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    late DialogRoute<String> dialog;
    var retired = false;
    var closing = false;
    var dismissalScheduled = false;
    bool current(ModalRoute<dynamic> popup) =>
        !retired &&
        source == _feedbackSource &&
        app.state.recoveryRequired &&
        !_covered &&
        _ownsPresentation(ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(origin, ownedPopup: popup);
    void check() {
      if (closing) {
        if (source != _feedbackSource || !app.state.recoveryRequired) {
          retired = true;
        }
        return;
      }
      if (dialog.animation?.status == AnimationStatus.reverse) return;
      final popup = AppTaskNavigatorObserver.coveringPopup(dialog) ?? dialog;
      if (current(popup)) return;
      retired = true;
      if (dismissalScheduled) return;
      dismissalScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!navigator.mounted || !dialog.isActive) return;
        if (dialog.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(dialog);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    final changes = Listenable.merge([
      app,
      _owner,
      AppTaskNavigatorObserver.changesFor(origin),
    ]);
    dialog = DialogRoute<String>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (context) {
        ModalRoute.isCurrentOf(context);
        return ListenableBuilder(
          listenable: changes,
          builder: (context, _) {
            check();
            final active = current(dialog);
            final strings = AppLocalizations.of(context);
            void close([String? action]) {
              if (!current(dialog)) return;
              closing = true;
              navigator.pop(action);
            }

            return IgnorePointer(
              ignoring: !active,
              child: ExcludeFocus(
                excluding: !active,
                child: ExcludeSemantics(
                  excluding: !active,
                  child: AlertDialog(
                    key: const ValueKey('overview-core-recovery'),
                    scrollable: true,
                    title: Text(strings.coreInterruptedTitle),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(strings.coreInterruptedMessage),
                        for (final text in {
                          for (final error in [
                            app.errorMessage,
                            app.state.errorMessage,
                            app.state.modeErrorMessage,
                            if (!app.state.resultSuccess)
                              app.state.resultMessageDescription,
                          ].whereType<AppMessage>())
                            error.resolve(strings),
                        }) ...[
                          const SizedBox(height: 12),
                          SelectableText(text),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: active && app.canEdit && !app.busy
                                  ? () => close('restart')
                                  : null,
                              icon: const Icon(Icons.restart_alt),
                              label: Text(strings.coreRecoveryRestart),
                            ),
                            TextButton(
                              onPressed: active ? () => close('select') : null,
                              child: Text(strings.coreRecoverySelect),
                            ),
                          ],
                        ),
                        CoreCleanupAction(
                          app: app,
                          request: const {},
                          enabled: active,
                          isCurrent: () => current(dialog),
                          isCurrentWithPopup: current,
                          title: (strings) => strings.coreCleanupSelect,
                          description: (strings) =>
                              strings.coreCleanupSelectionNotice,
                          icon: Icons.delete_sweep_outlined,
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: active ? close : null,
                        child: Text(strings.close),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    changes.addListener(check);
    final String? action;
    try {
      action = await navigator.push(dialog);
      await dialog.completed;
    } finally {
      changes.removeListener(check);
    }
    if (retired ||
        !_current ||
        source != _feedbackSource ||
        !app.state.recoveryRequired) {
      return;
    }
    if (action == 'restart' && app.canEdit && !app.busy) {
      await app.submit({
        'action': 'start',
        'vpnIntent': app.state.vpnIntent || !app.state.lanIntent,
      });
    } else if (action == 'select') {
      await _manage();
    }
  }

  Widget _pageActivity(Widget child) {
    final active = _current;
    return IgnorePointer(
      ignoring: !active,
      child: ExcludeFocus(
        excluding: !active,
        child: ExcludeSemantics(excluding: !active, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
      final controller = widget.controller;
      final palette = HomePalette.of(context);
      return _pageActivity(
        LayoutBuilder(
          builder: (context, viewport) {
            final contentWidth = viewport.maxWidth;
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final controlMinimum = (320 * scale).clamp(320.0, 480.0);
            final networkMinimum = (360 * scale).clamp(360.0, 560.0);
            final wide =
                contentWidth >= math.max(840, controlMinimum + networkMinimum);
            final controlWidth = (contentWidth * .32).clamp(
              controlMinimum,
              480.0,
            );
            final motion = MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180);
            return TweenAnimationBuilder<double>(
              tween: Tween(end: wide ? 1.0 : 0.0),
              duration: motion,
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                final layoutProgress = motion == Duration.zero
                    ? (wide ? 1.0 : 0.0)
                    : value;
                final sectionWidth =
                    contentWidth - controlWidth * layoutProgress;
                final networkContentWidth = math.max(
                  0.0,
                  math.min(
                    sectionWidth -
                        _networkPadding.horizontal -
                        MediaQuery.paddingOf(context).horizontal,
                    _networkReadingWidth * scale,
                  ),
                );
                return TweenAnimationBuilder<double>(
                  tween: Tween(end: controller.state.running ? 1.0 : 0.0),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 320),
                  builder: (context, progress, network) {
                    final field = palette.controlBackground(progress);
                    final statusInset = MediaQuery.paddingOf(context).top;
                    final neutralStatusBar =
                        MediaQuery.sizeOf(context).width >= 600 &&
                        statusInset > 0;
                    final statusBackground = neutralStatusBar
                        ? palette.background
                        : field;
                    final lightIcons =
                        palette.dark ||
                        palette
                                .legibleInk(statusBackground)
                                .computeLuminance() >
                            statusBackground.computeLuminance();
                    return ColoredBox(
                      color: field,
                      child: AnnotatedRegion<SystemUiOverlayStyle>(
                        value: lightIcons
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark,
                        child: Scaffold(
                          backgroundColor: Colors.transparent,
                          body: Stack(
                            fit: StackFit.expand,
                            children: [
                              CustomScrollView(
                                key: _viewport,
                                controller: _scroll,
                                slivers: [
                                  SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        AnimatedAlign(
                                          duration: motion,
                                          curve: Curves.easeOutCubic,
                                          alignment: wide
                                              ? Alignment.center
                                              : Alignment.topCenter,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: contentWidth,
                                              minHeight: viewport.maxHeight,
                                            ),
                                            child: DecoratedBox(
                                              key: const ValueKey(
                                                'overview-brand-field',
                                              ),
                                              decoration: BoxDecoration(
                                                color: field,
                                              ),
                                              child: _OverviewLayout(
                                                key: const ValueKey(
                                                  'overview-workspace',
                                                ),
                                                progress: layoutProgress,
                                                controlWidth: controlWidth,
                                                minimumHeight:
                                                    viewport.maxHeight,
                                                children: [
                                                  _control(
                                                    progress,
                                                    compact:
                                                        !wide &&
                                                        viewport.maxHeight <
                                                            700,
                                                    width:
                                                        contentWidth +
                                                        (controlWidth -
                                                                contentWidth) *
                                                            layoutProgress,
                                                  ),
                                                  network!,
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              if (neutralStatusBar)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  height: statusInset,
                                  child: IgnorePointer(
                                    child: ColoredBox(
                                      color: palette.background,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  child: AnimatedContainer(
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    key: const ValueKey('network-surface'),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(24),
                        topRight: Radius.circular(wide ? 0 : 24),
                      ),
                    ),
                    padding: _networkPadding,
                    child: SafeArea(
                      top: wide,
                      child: AnimatedAlign(
                        duration: motion,
                        curve: Curves.easeOutCubic,
                        alignment: wide
                            ? Alignment.center
                            : Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: networkContentWidth,
                            maxHeight: wide
                                ? _networkReadingHeight * scale
                                : double.infinity,
                          ),
                          child: TrafficPanel(
                            key: _network,
                            traffic: _traffic,
                            width: networkContentWidth,
                            fillHeight: wide,
                            visible: _networkVisible && _current,
                            onOpen: _connections,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    },
  );

  @override
  void dispose() {
    widget.controller.removeListener(_syncOwner);
    _traffic.dispose();
    _scroll.dispose();
    _owner.dispose();
    super.dispose();
  }
}

// Only geometry changes: both business subtrees keep their element/State identity.
class _OverviewLayout extends MultiChildRenderObjectWidget {
  const _OverviewLayout({
    super.key,
    required this.progress,
    required this.controlWidth,
    required this.minimumHeight,
    required super.children,
  });

  final double progress;
  final double controlWidth;
  final double minimumHeight;

  @override
  _RenderOverviewLayout createRenderObject(BuildContext context) =>
      _RenderOverviewLayout(progress, controlWidth, minimumHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderOverviewLayout renderObject,
  ) => renderObject.update(progress, controlWidth, minimumHeight);
}

class _OverviewParentData extends ContainerBoxParentData<RenderBox> {}

typedef _OverviewGeometry = ({Size size, Rect control, Rect network});

class _RenderOverviewLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _OverviewParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _OverviewParentData> {
  _RenderOverviewLayout(
    this._progress,
    this._controlWidth,
    this._minimumHeight,
  );

  double _progress;
  double _controlWidth;
  double _minimumHeight;

  void update(double progress, double controlWidth, double minimumHeight) {
    if ((_progress, _controlWidth, _minimumHeight) ==
        (progress, controlWidth, minimumHeight)) {
      return;
    }
    _progress = progress;
    _controlWidth = controlWidth;
    _minimumHeight = minimumHeight;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _OverviewParentData) {
      child.parentData = _OverviewParentData();
    }
  }

  _OverviewGeometry _geometry(double width) {
    final control = firstChild!;
    final network = childAfter(control)!;
    final controlWidth = width + (_controlWidth - width) * _progress;
    final networkWidth = width - _controlWidth * _progress;
    final controlHeight = control.getMaxIntrinsicHeight(controlWidth);
    final networkHeight = network.getMaxIntrinsicHeight(networkWidth);
    final columnHeight = math.max(
      _minimumHeight,
      controlHeight + networkHeight,
    );
    final rowHeight = math.max(
      _minimumHeight,
      math.max(controlHeight, networkHeight),
    );
    final height = columnHeight + (rowHeight - columnHeight) * _progress;
    final columnControlHeight = columnHeight - networkHeight;
    final currentControlHeight =
        columnControlHeight + (height - columnControlHeight) * _progress;
    return (
      size: Size(width, height),
      control: Rect.fromLTWH(0, 0, controlWidth, currentControlHeight),
      network: Rect.fromLTWH(
        _controlWidth * _progress,
        columnControlHeight * (1 - _progress),
        networkWidth,
        height - columnControlHeight * (1 - _progress),
      ),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _geometry(width).size.height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _geometry(width).size.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_geometry(constraints.maxWidth).size);

  @override
  void performLayout() {
    final geometry = _geometry(constraints.maxWidth);
    size = constraints.constrain(geometry.size);
    final control = firstChild!;
    final network = childAfter(control)!;
    void place(RenderBox child, Rect rect) {
      child.layout(BoxConstraints.tight(rect.size), parentUsesSize: true);
      (child.parentData! as _OverviewParentData).offset = rect.topLeft;
    }

    place(control, geometry.control);
    place(network, geometry.network);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
