import 'dart:ui' show SemanticsInputType;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

// SDK TextField provides dense alignment inside the 48dp target, with normal hit
// testing, semantics and focus handling.
class ToolbarSearchField extends StatefulWidget {
  const ToolbarSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.trailing,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final Widget trailing;

  @override
  State<ToolbarSearchField> createState() => _ToolbarSearchFieldState();
}

class _ToolbarSearchFieldState extends State<ToolbarSearchField> {
  double _keyboardInset = 0;
  Size? _windowSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    // A native IME may consume Back before the route sees it.
    if (_keyboardInset > 0 &&
        media.viewInsets.bottom == 0 &&
        _windowSize == media.size &&
        widget.focusNode.hasFocus) {
      widget.focusNode.unfocus();
    }
    _keyboardInset = media.viewInsets.bottom;
    _windowSize = media.size;
  }

  @override
  void didUpdateWidget(ToolbarSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) _keyboardInset = 0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    );
    return Semantics(
      inputType: SemanticsInputType.search,
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(fontSize: 16, color: colors.onSurface),
        decoration: InputDecoration(
          constraints: const BoxConstraints.tightFor(height: 48),
          isDense: true,
          filled: true,
          fillColor: colors.surfaceContainer,
          contentPadding: EdgeInsets.zero,
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.primary),
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: HomePalette.of(context).moreAction,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 44,
            minHeight: 48,
          ),
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: widget.trailing,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 60,
            minHeight: 48,
          ),
          hintText: widget.hintText,
          hintStyle: TextStyle(fontSize: 16, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}
