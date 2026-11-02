import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../navigation/task_activity.dart';

/// A content-sized selection menu constrained to the available workspace.
/// MenuAnchor supplies positioning, animation, dismissal, scrolling and focus.
class ChoiceMenuButton<T> extends StatefulWidget {
  const ChoiceMenuButton({
    super.key,
    required this.options,
    required this.onSelected,
    this.disabledOptions = const {},
    this.value,
    this.enabled = true,
    this.identity,
    this.tooltip,
    this.semanticsLabel,
    this.semanticsValue,
    this.iconColor,
    this.leadingIcon,
    this.optionBuilder,
    this.maxHeight,
    this.onOpened,
    this.onClosed,
    this.icon = Icons.arrow_drop_down,
    this.buttonBuilder,
    this.child,
  }) : assert(child == null || buttonBuilder == null);

  final Map<T, String> options;
  final Set<T> disabledOptions;
  final ValueChanged<T> onSelected;
  final T? value;
  final bool enabled;
  final Object? identity;
  final String? tooltip;
  final String? semanticsLabel;
  final String? semanticsValue;
  final Color? iconColor;
  final Widget? Function(T value)? leadingIcon;
  final Widget Function(T value, String label)? optionBuilder;
  final double? maxHeight;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;
  final IconData icon;
  final Widget Function(BuildContext, VoidCallback?, FocusNode)? buttonBuilder;
  final Widget? child;

  @override
  State<ChoiceMenuButton<T>> createState() => _ChoiceMenuButtonState<T>();
}

// The SDK panel follows the field's attachment direction. Keep its trigger and
// cached items in the interface direction without replacing animation children.
class _ChoiceMenuDirection extends InheritedWidget {
  const _ChoiceMenuDirection({required this.direction, required super.child});

  final TextDirection direction;

  static Widget preserve(Widget child) => Builder(
    builder: (context) => Directionality(
      textDirection: context
          .dependOnInheritedWidgetOfExactType<_ChoiceMenuDirection>()!
          .direction,
      child: child,
    ),
  );

  @override
  bool updateShouldNotify(_ChoiceMenuDirection oldWidget) =>
      direction != oldWidget.direction;
}

class _ChoiceMenuButtonState<T> extends State<ChoiceMenuButton<T>>
    with WidgetsBindingObserver {
  final _controller = MenuController();
  final _focus = FocusNode();
  final _anchor = GlobalKey();
  late final _dismiss = CallbackAction<DismissIntent>(
    onInvoke: (_) {
      _cancel();
      return null;
    },
  );
  LocalHistoryEntry? _history;
  Map<T, String> _options = {};
  Set<T> _disabledOptions = {};
  T? _value;
  Object? _identity;
  ValueChanged<T>? _select;
  bool _closing = false;
  bool _reopening = false;
  AlignmentGeometry _alignment = AlignmentDirectional.bottomStart;
  Object? _presentation;
  List<Widget> _menuChildren = const [];
  int _opening = 0;
  int _selectionOpening = 0;
  Size? _openingSize;
  Rect? _openingBounds;
  AppLifecycleListener? _lifecycle;

  ({Rect bounds, Rect available, MediaQueryData media}) _workspace() {
    final window = MediaQueryData.fromView(View.of(context));
    final windowBounds = Offset.zero & window.size;
    final overlay = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    final bounds = overlay is RenderBox && overlay.hasSize
        ? overlay.localToGlobal(Offset.zero) & overlay.size
        : windowBounds;
    EdgeInsets relativeInsets(EdgeInsets insets) {
      final visible = insets.deflateRect(windowBounds);
      return EdgeInsets.fromLTRB(
        (visible.left - bounds.left).clamp(0.0, bounds.width),
        (visible.top - bounds.top).clamp(0.0, bounds.height),
        (bounds.right - visible.right).clamp(0.0, bounds.width),
        (bounds.bottom - visible.bottom).clamp(0.0, bounds.height),
      );
    }

    final media = MediaQuery.of(context).copyWith(
      size: bounds.size,
      padding: relativeInsets(window.padding),
      viewPadding: relativeInsets(window.viewPadding),
      viewInsets: relativeInsets(window.viewInsets),
    );
    return (
      bounds: bounds,
      available: (media.padding + media.viewInsets).deflateRect(bounds),
      media: media,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    // Scaffold 可能已调整页面的键盘避让区域；根 Overlay 仍按原始窗口计算可用区域。
    if (_controller.isOpen) setState(() {});
  }

  @override
  void didUpdateWidget(ChoiceMenuButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.isOpen &&
        (!widget.enabled ||
            widget.identity != _identity ||
            !setEquals(widget.disabledOptions, _disabledOptions))) {
      _closeInvalidOpening();
    }
  }

  void _closeInvalidOpening() {
    // Retire the invalid identity immediately, before the closing animation.
    final opening = ++_opening;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.isOpen && _opening == opening) {
        _controller.close();
      }
    });
  }

  void _retireOpening() {
    if (!mounted) return;
    setState(() => _opening++);
    _lifecycle?.dispose();
    _lifecycle = null;
    _removeHistory();
    if (_controller.isOpen) _controller.close();
  }

  bool get _current =>
      mounted &&
      AppTaskActivity.isActive(context) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context));

  void _cancel({bool afterPopTransaction = false}) {
    if (!mounted || !_controller.isOpen || _closing) return;
    // Route teardown during build only closes; it cannot reclaim user focus.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _controller.close();
      return;
    }
    final opening = _opening;
    bool eligible() =>
        mounted &&
        _opening == opening &&
        _opening == _selectionOpening &&
        widget.identity == _identity &&
        widget.enabled &&
        widget.options.isNotEmpty &&
        _current &&
        _focus.canRequestFocus &&
        MediaQuery.sizeOf(context) == _openingSize &&
        _workspace().bounds == _openingBounds;
    final manager = FocusManager.instance;
    // Apply an external request made before cancellation before deciding who
    // owns focus. No delayed callback may reclaim it after the user moves on.
    manager.applyFocusChangesIfNeeded();
    final focused = manager.primaryFocus;
    final focusContext = focused?.context;
    final ownedFocus =
        identical(focused, _focus) ||
        (focusContext != null &&
            focusContext.mounted &&
            identical(MenuController.maybeOf(focusContext), _controller));
    final restore = ownedFocus && (afterPopTransaction || eligible());
    _controller.close();
    void restoreFocus() {
      if (!restore) return;
      manager.applyFocusChangesIfNeeded();
      if (eligible() && identical(manager.primaryFocus, focused)) {
        _focus.requestFocus();
        manager.applyFocusChangesIfNeeded();
      }
    }

    if (afterPopTransaction) {
      // LocalHistory.onRemove runs inside Route.didPop while the route entry
      // is temporarily popping. Recheck after that synchronous transaction,
      // not after the SDK exit animation, without relaxing route qualification.
      scheduleMicrotask(restoreFocus);
    } else {
      restoreFocus();
    }
  }

  void _toggle() {
    if (!_current) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    if (_controller.isOpen && !_closing) {
      _controller.close();
      return;
    }
    if (!widget.enabled || widget.options.isEmpty) return;
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final workspace = _workspace();
    if (workspace.available.isEmpty) return;
    // Measure only from the settled trigger, not during a lazy sliver rebuild.
    // The upper attachment keeps the SDK's first entrance frame above the IME.
    final roomBelow =
        workspace.available.bottom -
        box.localToGlobal(Offset(0, box.size.height)).dy;
    _alignment = roomBelow < 48
        ? AlignmentDirectional.topStart
        : AlignmentDirectional.bottomStart;
    if (_controller.isOpen) {
      if (_opening != _selectionOpening || widget.identity != _identity) return;
    } else {
      setState(() {
        _selectionOpening = ++_opening;
        _openingSize = MediaQuery.sizeOf(context);
        _openingBounds = workspace.bounds;
        _options = Map.unmodifiable(widget.options);
        _disabledOptions = Set.unmodifiable(widget.disabledOptions);
        _value = widget.value;
        _identity = widget.identity;
        _select = widget.onSelected;
      });
      widget.onOpened?.call();
    }
    if (mounted) {
      late final LocalHistoryEntry history;
      history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (!identical(_history, history)) return;
          _history = null;
          if (mounted && _controller.isOpen) {
            _cancel(afterPopTransaction: true);
          }
        },
      );
      _history = history;
      ModalRoute.of(context)?.addLocalHistoryEntry(history);
      _focus.requestFocus();
      _lifecycle?.dispose();
      _lifecycle = AppLifecycleListener(
        onHide: _retireOpening,
        onDetach: _retireOpening,
      );
      _reopening = _controller.isOpen;
      try {
        _controller.open();
      } finally {
        _reopening = false;
      }
    }
  }

  void _removeHistory() {
    final history = _history;
    _history = null;
    history?.remove();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isOpen &&
        (!_current ||
            MediaQuery.sizeOf(context) != _openingSize ||
            _workspace().bounds != _openingBounds)) {
      _closeInvalidOpening();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final workspace = _workspace();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _workspace().bounds != workspace.bounds) setState(() {});
    });
    final width = math.max(0.0, workspace.available.width);
    final height = math.max(0.0, workspace.available.height);
    final enabled = widget.enabled && widget.options.isNotEmpty && _current;
    final colors = Theme.of(context).colorScheme;
    final direction = Directionality.of(context);
    final attachmentDirection = widget.child == null
        ? direction
        : switch (direction) {
            TextDirection.ltr => TextDirection.rtl,
            TextDirection.rtl => TextDirection.ltr,
          };
    final selection = (_identity, _select, _selectionOpening);
    final interactive =
        enabled &&
        widget.identity == _identity &&
        _opening == _selectionOpening;
    // Keep SDK animation children stable when only the direction changes.
    // Recreating them would replace its in-progress forward/reverse curves.
    final presentation = (
      selection,
      interactive,
      colors,
      widget.leadingIcon,
      widget.optionBuilder,
    );
    if (_presentation != presentation) {
      _presentation = presentation;
      _menuChildren = _items(interactive, selection, colors);
    }
    // PopScope exposes root-menu Back interception; LocalHistory consumes direct
    // Navigator pops on this page.
    return PopScope(
      canPop: !_controller.isOpen || _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controller.isOpen && !_closing) _cancel();
      },
      // 菜单使用所属 Overlay 的有效区域，按钮保持页面原有的 MediaQuery。
      child: MediaQuery(
        data: workspace.media,
        // 菜单与触发控件保持原有的语义和焦点遍历关系。
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: _ChoiceMenuDirection(
            direction: direction,
            // Custom fields attach at their trailing edge. The SDK panel,
            // including scrolling and directional padding, follows this side.
            child: Directionality(
              textDirection: attachmentDirection,
              child: MenuAnchor(
                animated: !MediaQuery.disableAnimationsOf(context),
                useRootOverlay: true,
                controller: _controller,
                childFocusNode: _focus,
                crossAxisUnconstrained: false,
                consumeOutsideTap: !_closing,
                reservedPadding:
                    workspace.media.padding + workspace.media.viewInsets,
                onAnimationStatusChanged: (status) {
                  final closing =
                      status == AnimationStatus.reverse ||
                      status == AnimationStatus.dismissed;
                  if (closing) _removeHistory();
                  if (_closing != closing) setState(() => _closing = closing);
                },
                style: MenuStyle(
                  alignment: _alignment,
                  maximumSize: WidgetStatePropertyAll(
                    Size(
                      width,
                      math.min(widget.maxHeight ?? double.infinity, height),
                    ),
                  ),
                  visualDensity: VisualDensity.standard,
                ),
                onClose: () {
                  // RawMenuAnchor briefly hides its overlay when reversing open.
                  // That is still the same opening, not a retired selection scope.
                  if (_reopening) return;
                  final opening = _opening;
                  _lifecycle?.dispose();
                  _lifecycle = null;
                  _removeHistory();
                  widget.onClosed?.call();
                  // SDK selections are deferred until the closing frame. Retire after
                  // those callbacks, including when animations are disabled.
                  WidgetsBinding.instance.endOfFrame.then((_) {
                    if (mounted && _opening == opening) _opening++;
                  });
                },
                menuChildren: _menuChildren,
                builder: (context, controller, child) {
                  final trigger = widget.child;
                  Widget button;
                  if (widget.buttonBuilder case final builder?) {
                    button = builder(context, enabled ? _toggle : null, _focus);
                  } else if (trigger == null) {
                    button = IconButton(
                      focusNode: _focus,
                      tooltip: widget.tooltip,
                      color: widget.iconColor,
                      onPressed: enabled ? _toggle : null,
                      icon: Icon(widget.icon),
                    );
                  } else {
                    button = Semantics(
                      button: true,
                      enabled: enabled,
                      label: widget.semanticsLabel,
                      value: widget.semanticsValue,
                      child: InkWell(
                        focusNode: _focus,
                        onTap: enabled ? _toggle : null,
                        child: widget.semanticsLabel == null
                            ? trigger
                            : ExcludeSemantics(child: trigger),
                      ),
                    );
                    if (widget.tooltip case final tooltip?) {
                      button = Tooltip(message: tooltip, child: button);
                    }
                  }
                  return _ChoiceMenuDirection.preserve(
                    MediaQuery(
                      data: media,
                      child: SizedBox(
                        key: _anchor,
                        child: Actions(
                          actions: {
                            if (_controller.isOpen && !_closing)
                              DismissIntent: _dismiss,
                          },
                          child: button,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _items(
    bool interactive,
    (Object?, ValueChanged<T>?, int) selection,
    ColorScheme colors,
  ) => [
    for (final entry in _options.entries)
      _ChoiceMenuDirection.preserve(
        Actions(
          actions: {DismissIntent: _dismiss},
          child: ExcludeFocus(
            excluding: !interactive,
            child: IgnorePointer(
              ignoring: !interactive,
              child: ExcludeSemantics(
                excluding: !interactive,
                child: Semantics(
                  enabled: !_disabledOptions.contains(entry.key),
                  selected: _value == null ? null : entry.key == _value,
                  child: MenuItemButton(
                    key: ValueKey(entry.key),
                    // Let the SDK defer activation until focus changes are applied,
                    // then close here so cancellation cannot authorize an old action.
                    closeOnActivate: false,
                    onPressed: _disabledOptions.contains(entry.key)
                        ? null
                        : () {
                            if (_current &&
                                !_closing &&
                                _controller.isOpen &&
                                !widget.disabledOptions.contains(entry.key) &&
                                widget.enabled &&
                                widget.identity == selection.$1 &&
                                _opening == selection.$3 &&
                                MediaQuery.sizeOf(context) == _openingSize &&
                                _workspace().bounds == _openingBounds) {
                              _removeHistory();
                              _controller.close();
                              _focus.requestFocus();
                              FocusManager.instance.applyFocusChangesIfNeeded();
                              selection.$2?.call(entry.key);
                            }
                          },
                    style: const ButtonStyle(
                      minimumSize: WidgetStatePropertyAll(Size(0, 48)),
                      alignment: AlignmentDirectional.centerStart,
                    ),
                    leadingIcon: widget.leadingIcon?.call(entry.key),
                    trailingIcon: _value == null
                        ? null
                        : SizedBox.square(
                            dimension: 20,
                            child: entry.key == _value
                                ? Icon(
                                    Icons.check,
                                    size: 20,
                                    color: colors.primary,
                                  )
                                : null,
                          ),
                    child:
                        widget.optionBuilder?.call(entry.key, entry.value) ??
                        Text(entry.value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
  ];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle?.dispose();
    _removeHistory();
    _focus.dispose();
    super.dispose();
  }
}
