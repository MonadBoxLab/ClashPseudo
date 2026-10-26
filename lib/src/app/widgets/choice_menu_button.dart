import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

/// A selection menu whose surface shares the trigger's right edge.
/// MenuAnchor supplies dismissal, scrolling, keyboard traversal and focus.
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

class _ChoiceMenuButtonState<T> extends State<ChoiceMenuButton<T>>
    with WidgetsBindingObserver {
  final _controller = MenuController();
  final _focus = FocusNode();
  final _anchor = GlobalKey();
  LocalHistoryEntry? _history;
  Map<T, String> _options = {};
  Set<T> _disabledOptions = {};
  T? _value;
  Object? _identity;
  ValueChanged<T>? _select;
  double _anchorWidth = 200;
  double _rightSpace = double.infinity;
  bool _closing = false;
  int _opening = 0;
  int _selectionOpening = 0;
  Size? _openingSize;
  Rect? _openingBounds;
  AppLifecycleListener? _lifecycle;
  static const _horizontalMargin = 8.0;

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
    // Scaffold 可消费页面的键盘 inset，根 Overlay 仍按原始窗口重新预算。
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

  void _toggle() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    if (_controller.isOpen) {
      _controller.close();
      return;
    }
    if (!widget.enabled || widget.options.isEmpty) return;
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final workspace = _workspace();
    if (workspace.available.isEmpty) return;
    setState(() {
      _selectionOpening = ++_opening;
      _openingSize = MediaQuery.sizeOf(context);
      _openingBounds = workspace.bounds;
      _anchorWidth = box.size.width;
      _rightSpace = math.max(
        112.0,
        box.localToGlobal(Offset.zero).dx +
            box.size.width -
            workspace.available.left -
            _horizontalMargin,
      );
      _options = Map.unmodifiable(widget.options);
      _disabledOptions = Set.unmodifiable(widget.disabledOptions);
      _value = widget.value;
      _identity = widget.identity;
      _select = widget.onSelected;
    });
    widget.onOpened?.call();
    if (mounted) {
      late final LocalHistoryEntry history;
      history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (!identical(_history, history)) return;
          _history = null;
          if (mounted && _controller.isOpen) _controller.close();
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
      _controller.open();
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
        (ModalRoute.of(context)?.isCurrent == false ||
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
    final width = math.min(
      math.min(_rightSpace, _anchorWidth.clamp(200.0, 320.0)),
      math.max(0.0, workspace.available.width - _horizontalMargin * 2),
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final enabled = widget.enabled && widget.options.isNotEmpty;
    final colors = Theme.of(context).colorScheme;
    final selection = (_identity, _select, _selectionOpening);
    final interactive =
        enabled &&
        widget.identity == _identity &&
        _opening == _selectionOpening &&
        !_closing;
    // PopScope exposes root-menu Back interception; LocalHistory consumes direct
    // Navigator pops on this page.
    return PopScope(
      canPop: !_controller.isOpen || _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controller.isOpen && !_closing) _controller.close();
      },
      // 菜单使用所属 Overlay 的有效区域，按钮保持页面原有的 MediaQuery。
      child: MediaQuery(
        data: workspace.media,
        // 菜单与触发控件保持原有的语义和焦点遍历关系。
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: MenuAnchor(
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
            alignmentOffset: Offset(rtl ? 0 : -width, 0),
            style: MenuStyle(
              alignment: Alignment.bottomRight,
              minimumSize: WidgetStatePropertyAll(Size(width, 0)),
              maximumSize: WidgetStatePropertyAll(
                Size(
                  width,
                  math.min(
                    widget.maxHeight ?? double.infinity,
                    workspace.available.height,
                  ),
                ),
              ),
              visualDensity: VisualDensity.standard,
            ),
            onClose: () {
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
            menuChildren: [
              for (final entry in _options.entries)
                ExcludeFocus(
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
                          onPressed: _disabledOptions.contains(entry.key)
                              ? null
                              : () {
                                  if (mounted &&
                                      !widget.disabledOptions.contains(
                                        entry.key,
                                      ) &&
                                      widget.enabled &&
                                      widget.identity == selection.$1 &&
                                      _opening == selection.$3 &&
                                      MediaQuery.sizeOf(context) ==
                                          _openingSize &&
                                      _workspace().bounds == _openingBounds &&
                                      ModalRoute.of(context)?.isCurrent !=
                                          false) {
                                    // SDK selections are deferred until closing begins.
                                    _removeHistory();
                                    selection.$2?.call(entry.key);
                                  }
                                },
                          style: const ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(Size(0, 48)),
                            alignment: AlignmentDirectional.centerStart,
                          ),
                          leadingIcon: widget.leadingIcon?.call(entry.key),
                          trailingIcon: SizedBox.square(
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
                              widget.optionBuilder?.call(
                                entry.key,
                                entry.value,
                              ) ??
                              Text(entry.value),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
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
              return MediaQuery(
                data: media,
                child: SizedBox(key: _anchor, child: button),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle?.dispose();
    _removeHistory();
    _focus.dispose();
    super.dispose();
  }
}
