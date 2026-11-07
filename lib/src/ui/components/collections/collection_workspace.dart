import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class CollectionWorkspace extends StatefulWidget {
  const CollectionWorkspace({
    super.key,
    required this.master,
    required this.detail,
    required this.onClose,
    this.active = true,
    this.detailStatus = '',
    this.onMasterVisibilityChanged,
  });

  final Widget master;

  /// Keep the key stable while reading one selection; change it for a new one.
  final Widget? detail;
  final VoidCallback onClose;

  /// Interaction eligibility, independent of any retiring visual transition.
  final bool active;
  final String detailStatus;
  final ValueChanged<bool>? onMasterVisibilityChanged;

  /// Whether the containing pane may present UI or receive user actions now.
  /// Async completions can read this with [listen] false after checking mounted.
  static bool paneActiveOf(BuildContext context, {bool listen = true}) =>
      (listen
              ? context
                    .dependOnInheritedWidgetOfExactType<_CollectionPaneScope>()
              : context.getInheritedWidgetOfExactType<_CollectionPaneScope>())
          ?.active ??
      true;

  @override
  State<CollectionWorkspace> createState() => CollectionWorkspaceState();
}

typedef _PaneGeometry = ({
  double masterWidth,
  double detailLeft,
  double detailWidth,
  double masterOpacity,
  double detailOpacity,
  double dividerOpacity,
});

class CollectionWorkspaceState extends State<CollectionWorkspace>
    with TickerProviderStateMixin {
  final _masterFocus = FocusScopeNode(debugLabel: 'collection-master');
  late final _layout = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  late final _content = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  _PaneGeometry? _from;
  _PaneGeometry? _to;
  LocalHistoryEntry? _history;
  late bool _showDetail;
  bool _historyWanted = false;
  bool? _masterVisible;
  bool _detailVisible = false;
  bool _detailsAvailable = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _showDetail = widget.detail != null;
    _masterFocus.addListener(_focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _layout.value = 1;
      _content.value = 1;
    }
  }

  void _focusChanged() {
    if (mounted && widget.active && _masterFocus.hasFocus && _showDetail) {
      setState(() => _showDetail = false);
    }
  }

  @override
  void didUpdateWidget(CollectionWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.detail?.runtimeType != widget.detail?.runtimeType ||
        oldWidget.detail?.key != widget.detail?.key;
    if (widget.detail == null) {
      _showDetail = false;
    } else if (oldWidget.detail == null || changed) {
      _showDetail = true;
    }
    if (!widget.active || widget.detail == null) _removeHistory();
    if (!widget.active || _reduceMotion) {
      _layout.value = 1;
      _content.value = 1;
    } else if (changed) {
      // A replacement owns the only live detail subtree. Retarget an unfinished
      // reveal rather than flashing back to zero during rapid replacements.
      _content.forward(from: _content.isAnimating ? _content.value : 0);
    }
  }

  bool get showingDetail => _showDetail && widget.detail != null;

  /// Whether the layout shows details; check page interaction eligibility separately.
  /// Detail popups must also verify their route, selected object, and source page still
  /// match those at opening.
  bool get detailPresented => widget.detail != null && _historyWanted;

  /// Whether the layout shows the main list; check page interaction eligibility
  /// separately.
  bool get masterPresented => _to?.masterOpacity == 1;

  bool get masterVisible => widget.active && _masterVisible == true;
  bool get detailVisible => widget.active && _detailVisible;

  void showMaster() {
    if (mounted && widget.active) setState(() => _showDetail = false);
  }

  void _showDetails() {
    if (!mounted || !widget.active || widget.detail == null) return;
    _masterFocus.unfocus();
    setState(() => _showDetail = true);
  }

  void _syncHistory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.active || !_historyWanted || widget.detail == null) {
        _removeHistory();
        return;
      }
      if (_history != null) return;
      final route = ModalRoute.of(context);
      if (route == null) return;
      late final LocalHistoryEntry entry;
      entry = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (!identical(_history, entry)) return;
          _history = null;
          if (mounted &&
              widget.active &&
              _historyWanted &&
              widget.detail != null) {
            widget.onClose();
          }
        },
      );
      _history = entry;
      route.addLocalHistoryEntry(entry);
    });
  }

  void _removeHistory() {
    final entry = _history;
    _history = null;
    entry?.remove();
  }

  _PaneGeometry get _visual {
    final from = _from!;
    final to = _to!;
    final t = Curves.easeOutCubic.transform(_layout.value);
    double mix(double a, double b) => lerpDouble(a, b, t)!;
    return (
      masterWidth: mix(from.masterWidth, to.masterWidth),
      detailLeft: mix(from.detailLeft, to.detailLeft),
      detailWidth: mix(from.detailWidth, to.detailWidth),
      masterOpacity: mix(from.masterOpacity, to.masterOpacity),
      detailOpacity: mix(from.detailOpacity, to.detailOpacity),
      dividerOpacity: mix(from.dividerOpacity, to.dividerOpacity),
    );
  }

  void _retarget(_PaneGeometry target) {
    if (_to == target) return;
    _from = _to == null ? target : _visual;
    _to = target;
    if (_reduceMotion || !widget.active || _from == target) {
      _layout.value = 1;
    } else {
      _layout.forward(from: 0);
    }
  }

  Widget _pane({
    required bool eligible,
    required double opacity,
    required Widget child,
  }) => IgnorePointer(
    ignoring: !eligible,
    child: ExcludeFocus(
      excluding: !eligible,
      child: ExcludeSemantics(
        excluding: !eligible,
        child: _CollectionPaneScope(
          active: eligible,
          child: TickerMode(
            enabled: opacity > 0,
            child: Opacity(opacity: opacity, child: child),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final masterMinimum = (320 * scale).clamp(320.0, 480.0);
      final detailMinimum = (480 * scale).clamp(480.0, 840.0);
      final wide =
          constraints.maxWidth >= masterMinimum + detailMinimum + 1 &&
          constraints.maxHeight >= 280;
      final showDetail = widget.detail != null && _showDetail;
      final masterVisible = widget.active && (wide || !showDetail);
      final detailVisible = widget.active && (wide || showDetail);
      _detailVisible = detailVisible;
      _detailsAvailable =
          widget.active && !wide && !showDetail && widget.detail != null;
      final detailIdentity = (widget.detail?.runtimeType, widget.detail?.key);
      if (_masterVisible != masterVisible) {
        _masterVisible = masterVisible;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _masterVisible == masterVisible) {
            widget.onMasterVisibilityChanged?.call(masterVisible);
          }
        });
      }
      _historyWanted = wide || showDetail;
      _syncHistory();
      final masterWidth = wide
          ? (constraints.maxWidth * .38).clamp(masterMinimum, 560.0)
          : constraints.maxWidth;
      _retarget((
        masterWidth: masterWidth,
        detailLeft: wide ? masterWidth + 1 : 0,
        detailWidth: wide
            ? constraints.maxWidth - masterWidth - 1
            : constraints.maxWidth,
        masterOpacity: wide || !showDetail ? 1 : 0,
        detailOpacity: wide || showDetail ? 1 : 0,
        dividerOpacity: wide ? 1 : 0,
      ));
      final master = FocusScope(node: _masterFocus, child: widget.master);
      final detail = FadeTransition(
        opacity: _content,
        // Do not retain an outgoing business page just to animate its pixels.
        // Its actions, subscriptions and async UI eligibility retire with it.
        child: widget.detail == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(AppLocalizations.of(context).selectDetails),
                ),
              )
            : Column(
                children: [
                  Expanded(child: widget.detail!),
                  SafeArea(
                    top: false,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          widget.detailStatus,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );
      return _CollectionScope(
        detailAvailable: _detailsAvailable,
        showDetails: () {
          if (_detailsAvailable &&
              detailIdentity ==
                  (widget.detail?.runtimeType, widget.detail?.key)) {
            _showDetails();
          }
        },
        // Both panes keep the same element path through every constraint and
        // visibility change. Only real capacity changes move their geometry.
        child: AnimatedBuilder(
          animation: _layout,
          builder: (context, _) {
            final visual = _visual;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: visual.masterWidth,
                  child: _pane(
                    eligible: masterVisible,
                    opacity: visual.masterOpacity,
                    child: master,
                  ),
                ),
                Positioned(
                  left: visual.detailLeft,
                  top: 0,
                  bottom: 0,
                  width: visual.detailWidth,
                  child: _pane(
                    eligible: detailVisible,
                    opacity: visual.detailOpacity,
                    child: detail,
                  ),
                ),
                Positioned(
                  left: visual.detailLeft - 1,
                  top: 0,
                  bottom: 0,
                  width: 1,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Opacity(
                        opacity: visual.dividerOpacity,
                        child: const VerticalDivider(width: 1),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  @override
  void dispose() {
    _removeHistory();
    _masterFocus.removeListener(_focusChanged);
    _masterFocus.dispose();
    _layout.dispose();
    _content.dispose();
    super.dispose();
  }
}

class _CollectionPaneScope extends InheritedWidget {
  const _CollectionPaneScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_CollectionPaneScope oldWidget) =>
      active != oldWidget.active;
}

class _CollectionScope extends InheritedWidget {
  const _CollectionScope({
    required this.detailAvailable,
    required this.showDetails,
    required super.child,
  });

  final bool detailAvailable;
  final VoidCallback showDetails;

  @override
  bool updateShouldNotify(_CollectionScope oldWidget) =>
      detailAvailable != oldWidget.detailAvailable;
}

class CollectionDetailsAction extends StatelessWidget {
  const CollectionDetailsAction({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_CollectionScope>();
    if (scope?.detailAvailable != true) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('collection-show-details'),
      onPressed: scope!.showDetails,
      tooltip: AppLocalizations.of(context).details,
      icon: const Icon(Icons.article_outlined),
    );
  }
}
