import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_task.dart';
import '../../app/app_theme.dart';
import '../configs/configs_page.dart';
import '../configs/widgets/import_dialog.dart';
import '../connections/connections_page.dart';
import '../mode/mode_sheet.dart';
import 'traffic_controller.dart';
import 'widgets/status_hero.dart';
import 'widgets/traffic_panel.dart';

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

  @override
  void initState() {
    super.initState();
    _traffic = TrafficController(widget.controller);
    _scroll.addListener(_checkVisible);
  }

  @override
  void didUpdateWidget(OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _traffic.dispose();
      _traffic = TrafficController(widget.controller);
    }
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
    _traffic.setVisible(
      networkVisible &&
          widget.active &&
          !_covered &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
    if (visible != _heroVisible || networkVisible != _networkVisible) {
      setState(() {
        _heroVisible = visible;
        _networkVisible = networkVisible;
      });
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    if (_covered) return;
    setState(() => _covered = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _covered = false);
    }
  }

  Future<void> _manage() async {
    final controller = widget.controller;
    if (widget.onOpenTask case final open?) {
      open(AppTask.configurations);
      return;
    }
    await _open(
      () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => ConfigsPage(controller: controller)),
      ),
    );
  }

  Future<void> _connections() async {
    final controller = widget.controller;
    if (widget.onOpenTask case final open?) {
      open(AppTask.connections);
      return;
    }
    await _open(
      () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => ConnectionsPage(app: controller)),
      ),
    );
  }

  Future<void> _mode() {
    final controller = widget.controller;
    final epoch = controller.storageEpoch;
    return _open(
      () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: HomePalette.of(context).surface,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => ModeSheet(controller: controller, storageEpoch: epoch),
      ),
    );
  }

  Widget _control(double progress) => ConstrainedBox(
    key: _hero,
    constraints: const BoxConstraints(minHeight: 460, maxWidth: 1200),
    child: ListenableBuilder(
      listenable: _traffic,
      builder: (context, _) => StatusHero(
        traffic: _traffic,
        controller: widget.controller,
        runningProgress: progress,
        visible:
            widget.active &&
            _heroVisible &&
            !_covered &&
            (ModalRoute.of(context)?.isCurrent ?? true),
        onManage: _manage,
        onMode: _mode,
        onImport: () => _open(() => openImport(context, widget.controller)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
      final controller = widget.controller;
      final palette = HomePalette.of(context);
      return LayoutBuilder(
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
          final networkContentWidth = math.min(
            (wide ? contentWidth - controlWidth : contentWidth) -
                _networkPadding.horizontal -
                MediaQuery.paddingOf(context).horizontal,
            _networkReadingWidth * scale,
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
                  MediaQuery.sizeOf(context).width >= 600 && statusInset > 0;
              final statusBackground = neutralStatusBar
                  ? palette.background
                  : field;
              final lightIcons =
                  palette.dark ||
                  palette.legibleInk(statusBackground).computeLuminance() >
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
                                  Align(
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
                                        decoration: BoxDecoration(color: field),
                                        child: IntrinsicHeight(
                                          child: Flex(
                                            key: const ValueKey(
                                              'overview-workspace',
                                            ),
                                            direction: wide
                                                ? Axis.horizontal
                                                : Axis.vertical,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Flexible(
                                                flex: wide ? 0 : 1,
                                                fit: FlexFit.tight,
                                                child: SizedBox(
                                                  width: wide
                                                      ? controlWidth
                                                      : null,
                                                  child: _control(progress),
                                                ),
                                              ),
                                              Flexible(
                                                flex: wide ? 1 : 0,
                                                fit: FlexFit.tight,
                                                child: network!,
                                              ),
                                            ],
                                          ),
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
                              child: ColoredBox(color: palette.background),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
            child: Container(
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
                child: Align(
                  alignment: wide ? Alignment.center : Alignment.topCenter,
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
                      visible:
                          widget.active &&
                          _networkVisible &&
                          !_covered &&
                          (ModalRoute.of(context)?.isCurrent ?? true),
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
  );

  @override
  void dispose() {
    _traffic.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
