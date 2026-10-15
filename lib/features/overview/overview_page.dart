import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../configs/configs_page.dart';
import '../configs/widgets/import_dialog.dart';
import '../mode/mode_sheet.dart';
import 'widgets/status_hero.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.controller, this.active = true});
  final AppController controller;
  final bool active;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  final _hero = GlobalKey();
  final _scroll = ScrollController();
  bool _heroVisible = true;
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkVisible);
  }

  void _checkVisible() {
    if (!mounted) return;
    final box = _hero.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final visible = bounds.overlaps(screen);
    if (visible != _heroVisible) setState(() => _heroVisible = visible);
  }

  Future<void> _open(Future<void> Function() action) async {
    setState(() => _covered = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _covered = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
      final controller = widget.controller;
      final palette = HomePalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      final running = controller.state.running;
      return AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 320),
        color: running ? palette.hero : palette.background,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: running || palette.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Column(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          key: _hero,
                          constraints: const BoxConstraints(minHeight: 460),
                          child: StatusHero(
                            controller: controller,
                            visible:
                                widget.active &&
                                _heroVisible &&
                                !_covered &&
                                (ModalRoute.of(context)?.isCurrent ?? true),
                            onManage: () => _open(
                              () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ConfigsPage(controller: controller),
                                ),
                              ),
                            ),
                            onMode: () => _open(
                              () => showModalBottomSheet<void>(
                                context: context,
                                backgroundColor: palette.surface,
                                isScrollControlled: true,
                                useSafeArea: true,
                                showDragHandle: true,
                                builder: (_) =>
                                    ModeSheet(controller: controller),
                              ),
                            ),
                            onImport: () =>
                                _open(() => openImport(context, controller)),
                          ),
                        ),
                      ),
                      Container(
                        key: const ValueKey('network-surface'),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: palette.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '网络活动',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 14),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.insights_outlined,
                                    size: 20,
                                    color: palette.muted,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      '网络观察尚未接入',
                                      style: TextStyle(
                                        color: palette.muted,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
