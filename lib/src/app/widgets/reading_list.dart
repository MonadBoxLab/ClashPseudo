import 'dart:convert';

import 'package:flutter/material.dart';

/// Transient presentation row. Grid rows may anchor on a surviving cell after
/// regrouping.
class ReadingListItem {
  const ReadingListItem({
    required this.id,
    required this.builder,
    this.anchors = const [],
    this.layoutValues = const [],
    this.semanticChildCount,
  });
  final Object id;
  final WidgetBuilder builder;
  final List<Object> anchors;

  /// Content affecting a row's size while its identity remains stable.
  final List<Object?> layoutValues;

  /// Grouped rows supply their own IndexedSemantics for each actual cell.
  /// Ordinary rows leave this null and receive one SDK index automatically.
  final int? semanticChildCount;
}

/// SDK center slivers preserve the reading object before layout when preceding rows
/// change.
class ReadingList extends StatefulWidget {
  const ReadingList({
    super.key,
    required this.header,
    required this.items,
    required this.identity,
    this.controller,
  });
  final Widget header;
  final List<ReadingListItem> items;
  final Object identity;
  final ScrollController? controller;

  @override
  State<ReadingList> createState() => _ReadingListState();
}

class _ReadingListState extends State<ReadingList> {
  final _ownScroll = ScrollController();
  ScrollController get _scroll => widget.controller ?? _ownScroll;
  final _viewport = GlobalKey();
  final _header = GlobalKey();
  static const _top = ValueKey('reading-top');
  static const _center = ValueKey('reading-center');
  final _keys = <Object, GlobalKey>{};
  final _keyIds = <Key, Object>{};
  List<ReadingListItem> _items = const [];
  Map<Object, int> _indices = {};
  List<int> _semanticStarts = const [];
  int _semanticCount = 0;
  Object? _identity;
  Object? _layout;
  int _centerIndex = 0;
  bool _anchored = false;
  double _anchorPixels = 0;
  int _layoutSamples = 0;

  void _prepare(Object layout, double viewportHeight) {
    final items = widget.items;
    final sameIdentity = _identity == widget.identity;
    if (sameIdentity &&
        _layout == layout &&
        _items.length == items.length &&
        items.indexed.every((item) {
          final old = _items[item.$1];
          final next = item.$2;
          return next.id == old.id &&
              next.semanticChildCount == old.semanticChildCount &&
              next.layoutValues.length == old.layoutValues.length &&
              next.layoutValues.indexed.every(
                (value) => value.$2 == old.layoutValues[value.$1],
              ) &&
              next.anchors.length == old.anchors.length &&
              next.anchors.indexed.every(
                (anchor) => anchor.$2 == old.anchors[anchor.$1],
              );
        })) {
      _items = items;
      return;
    }
    final indices = <Object, int>{
      for (var i = 0; i < items.length; i++) ...{
        items[i].id: i,
        for (final anchor in items[i].anchors) anchor: i,
      },
    };
    int? anchorIndex;
    var offset = 0.0;
    final viewport = _viewport.currentContext?.findRenderObject();
    final header = _header.currentContext?.findRenderObject();
    if (sameIdentity &&
        _scroll.hasClients &&
        viewport is RenderBox &&
        viewport.hasSize) {
      final top = viewport.localToGlobal(Offset.zero).dy;
      final bottom = top + viewport.size.height;
      final headerVisible =
          header is RenderBox &&
          header.hasSize &&
          header.size.height > 0 &&
          header.localToGlobal(Offset(0, header.size.height)).dy > top;
      if (!headerVisible) {
        // Prefer a complete row; if only a partial survivor remains, retain it.
        for (final complete in [true, false]) {
          for (final item in _items) {
            final next = [
              item.id,
              ...item.anchors,
            ].map((id) => indices[id]).whereType<int>().firstOrNull;
            if (next == null) continue;
            final box = _keys[item.id]?.currentContext?.findRenderObject();
            if (box is! RenderBox || !box.hasSize) continue;
            final y = box.localToGlobal(Offset.zero).dy;
            if (y < bottom &&
                (complete ? y >= top : y + box.size.height > top)) {
              anchorIndex = next;
              offset = y - top;
              break;
            }
          }
          if (anchorIndex != null) break;
        }
      }
    }
    if (anchorIndex != null) {
      _centerIndex = anchorIndex;
      _anchored = true;
      final maximum = (viewportHeight - 48).clamp(0.0, double.infinity);
      final target = offset > maximum ? maximum : offset;
      _anchorPixels = target > 0 ? target : 0;
      _scroll.position.correctBy(_anchorPixels - target - _scroll.offset);
    } else if (!sameIdentity || _anchored) {
      final y =
          sameIdentity &&
              viewport is RenderBox &&
              header is RenderBox &&
              header.hasSize
          ? header.localToGlobal(Offset.zero).dy -
                viewport.localToGlobal(Offset.zero).dy
          : 0.0;
      _centerIndex = 0;
      _anchored = false;
      _anchorPixels = 0;
      if (_scroll.hasClients) _scroll.position.correctBy(-y - _scroll.offset);
    }
    _items = items;
    _indices = indices;
    _semanticCount = 0;
    _semanticStarts = [];
    for (final item in items) {
      _semanticStarts.add(_semanticCount);
      _semanticCount += item.semanticChildCount ?? 1;
    }
    _identity = widget.identity;
    _layout = layout;
    final ids = items.map((item) => item.id).toSet();
    _keys.removeWhere((id, _) => !ids.contains(id));
    _keyIds.removeWhere((_, id) => !ids.contains(id));
  }

  Widget _list({required bool before}) {
    final count = before ? _centerIndex : _items.length - _centerIndex;
    return SliverList(
      key: before ? null : _center,
      delegate: SliverChildBuilderDelegate(
        (context, local) {
          final index = before
              ? _centerIndex - local - 1
              : _centerIndex + local;
          final item = _items[index];
          final key = _keys.putIfAbsent(item.id, GlobalKey.new);
          _keyIds[key] = item.id;
          return KeyedSubtree(key: key, child: item.builder(context));
        },
        childCount: count,
        semanticIndexCallback: (_, local) {
          final index = before
              ? _centerIndex - local - 1
              : _centerIndex + local;
          return _items[index].semanticChildCount == null
              ? _semanticStarts[index]
              : null;
        },
        findChildIndexCallback: (key) {
          final index = _indices[_keyIds[key]];
          if (index == null) return null;
          final local = before
              ? _centerIndex - index - 1
              : index - _centerIndex;
          return local < 0 || local >= count ? null : local;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      assert(() {
        if (const bool.fromEnvironment('validationLayoutMetrics') &&
            _layoutSamples < 16) {
          final view = View.of(context);
          final window = MediaQueryData.fromView(view);
          final inherited = MediaQuery.of(context);
          List<double> insets(EdgeInsets value) => [
            value.left,
            value.top,
            value.right,
            value.bottom,
          ];
          debugPrint(
            'CATEGORY_LAYOUT ${jsonEncode({
              'sample': ++_layoutSamples,
              'viewId': view.viewId,
              'window': [window.size.width, window.size.height],
              'devicePixelRatio': window.devicePixelRatio,
              'inheritedSize': [inherited.size.width, inherited.size.height],
              'viewPadding': insets(window.viewPadding),
              'viewInsets': insets(window.viewInsets),
              'inheritedPadding': insets(inherited.padding),
              'parent': [constraints.minWidth, constraints.maxWidth, constraints.minHeight, constraints.maxHeight],
              'scaledText': [
                for (final size in [14.0, 16.0, 28.0]) inherited.textScaler.scale(size),
              ],
            })}',
          );
        }
        return true;
      }());
      _prepare((
        constraints,
        MediaQuery.textScalerOf(context),
        Localizations.localeOf(context),
      ), constraints.maxHeight);
      return KeyedSubtree(
        key: _viewport,
        child: CustomScrollView(
          controller: _scroll,
          center: _anchored ? _center : _top,
          anchor: constraints.maxHeight > 0
              ? (_anchorPixels / constraints.maxHeight).clamp(0.0, 1.0)
              : 0,
          semanticChildCount: _semanticCount,
          slivers: [
            SliverToBoxAdapter(
              key: _top,
              child: KeyedSubtree(key: _header, child: widget.header),
            ),
            if (_centerIndex > 0) _list(before: true),
            _list(before: false),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    _ownScroll.dispose();
    super.dispose();
  }
}
