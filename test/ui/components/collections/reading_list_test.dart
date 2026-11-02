import 'dart:convert';

import 'package:clash_pseudo/src/ui/components/collections/reading_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _disableAnchor = bool.fromEnvironment('validationDisableReadingAnchor');

Future<void> _exerciseVisualCellAnchor(
  WidgetTester tester, {
  required bool removeFirstCell,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(480, 420);
  addTearDown(tester.view.reset);
  final ids = [for (var id = 0; id < 120; id++) id];
  final rows = ValueNotifier<({int columns, List<int> ids})>((
    columns: 2,
    ids: ids,
  ));
  final scroll = ScrollController();
  final motion = AnimationController(
    vsync: tester,
    value: 1,
    duration: const Duration(milliseconds: 180),
  );
  final keys = <int, GlobalKey>{};
  addTearDown(rows.dispose);
  addTearDown(scroll.dispose);
  try {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<({int columns, List<int> ids})>(
            valueListenable: rows,
            builder: (context, value, _) {
              final visualRects = <Object, Rect>{
                for (final entry in keys.entries)
                  if (entry.value.currentContext?.findRenderObject()
                      case final _VisualAnchorCellRender cell)
                    if (cell.attached && cell.hasSize)
                      entry.key: cell.visualGlobalRect,
              };
              motion.forward(from: 0);
              return ReadingList(
                controller: scroll,
                identity: 0,
                visualAnchorRect: (id) => visualRects[id],
                header: const SizedBox(height: 40),
                items: [
                  for (
                    var start = 0;
                    start < value.ids.length;
                    start += value.columns
                  )
                    ReadingListItem(
                      id: value.ids[start],
                      anchors: [
                        for (
                          var i = start + 1;
                          i < start + value.columns && i < value.ids.length;
                          i++
                        )
                          value.ids[i],
                      ],
                      builder: (context) => SizedBox(
                        key: ValueKey('visual-row-${value.ids[start]}'),
                        height: 80,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var column = 0;
                              column < value.columns;
                              column++
                            )
                              Expanded(
                                child: start + column >= value.ids.length
                                    ? const SizedBox.shrink()
                                    : _VisualAnchorCell(
                                        key: keys.putIfAbsent(
                                          value.ids[start + column],
                                          GlobalKey.new,
                                        ),
                                        animation: motion,
                                        origin:
                                            visualRects[value.ids[start +
                                                column]],
                                        scroll: scroll,
                                        child: SizedBox(
                                          key: ValueKey(
                                            'visual-cell-${value.ids[start + column]}',
                                          ),
                                          height: 80,
                                          child: Text(
                                            'cell-${value.ids[start + column]}',
                                          ),
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    scroll.jumpTo(1600);
    await tester.pumpAndSettle();
    final position = scroll.position;
    final targetId = removeFirstCell ? 44 : 40;
    final target = find.byKey(ValueKey('visual-cell-$targetId'));
    final element = tester.element(target);
    rows.value = (columns: 3, ids: ids);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(motion.isAnimating, isTrue);
    expect(motion.value, inExclusiveRange(0, 1));
    if (removeFirstCell) {
      scroll.jumpTo(140);
      await tester.pump();
      expect(find.byKey(const ValueKey('visual-cell-42')), findsOneWidget);
      expect(
        tester.getTopLeft(target).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('visual-row-42'))).dy,
        ),
      );
    } else {
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('visual-cell-39'))).dy,
        lessThan(0),
      );
      expect(tester.getTopLeft(target).dy, greaterThanOrEqualTo(0));
    }
    expect(tester.element(target), same(element));
    final top = tester.getTopLeft(target).dy;
    rows.value = (
      columns: 2,
      ids: removeFirstCell ? ids.where((id) => id != 42).toList() : ids,
    );
    for (final milliseconds in [0, 16, 80]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      expect(target, findsOneWidget);
      expect(tester.getTopLeft(target).dy, closeTo(top, .01));
      expect(tester.element(target), same(element));
      expect(scroll.position, same(position));
      expect(motion.isAnimating, isTrue);
      expect(tester.takeException(), isNull);
    }
    if (removeFirstCell) {
      expect(find.byKey(const ValueKey('visual-cell-42')), findsNothing);
    }
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      motion.dispose();
    }
  }
}

class _VisualAnchorCell extends SingleChildRenderObjectWidget {
  const _VisualAnchorCell({
    super.key,
    required this.animation,
    required this.origin,
    required this.scroll,
    required super.child,
  });

  final Animation<double> animation;
  final Rect? origin;
  final ScrollController scroll;

  @override
  _VisualAnchorCellRender createRenderObject(BuildContext context) =>
      _VisualAnchorCellRender(animation, origin, scroll);

  @override
  void updateRenderObject(
    BuildContext context,
    _VisualAnchorCellRender renderObject,
  ) => renderObject.update(origin);
}

class _VisualAnchorCellRender extends RenderProxyBox {
  _VisualAnchorCellRender(this.animation, this._origin, this.scroll)
    : _scrollAtOrigin = scroll.hasClients ? scroll.offset : 0;

  final Animation<double> animation;
  final ScrollController scroll;
  Rect? _origin;
  double _scrollAtOrigin;
  Matrix4 _matrix = Matrix4.identity();

  Rect get visualGlobalRect => MatrixUtils.transformRect(
    child!.getTransformTo(null),
    Offset.zero & child!.size,
  );

  void update(Rect? origin) {
    _origin = origin;
    _scrollAtOrigin = scroll.hasClients ? scroll.offset : 0;
    markNeedsPaint();
  }

  void _tick() => markNeedsPaint();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    animation.addListener(_tick);
  }

  @override
  void detach() {
    animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = localToGlobal(Offset.zero);
    final currentScroll = scroll.hasClients ? scroll.offset : 0.0;
    final origin = _origin?.topLeft.translate(
      0,
      _scrollAtOrigin - currentScroll,
    );
    final delta = origin == null
        ? Offset.zero
        : (origin - target) * (1 - animation.value);
    _matrix = Matrix4.translationValues(delta.dx, delta.dy, 0);
    context.pushTransform(
      needsCompositing,
      offset,
      _matrix,
      (context, offset) => super.paint(context, offset),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_matrix);
}

const _enabled = bool.fromEnvironment('validationLayoutMetrics');

void main() {
  group('reading_list', () {
    for (final visual in [false, true]) {
      testWidgets(
        'global reading anchor survives a same-size viewport origin change visual=$visual',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(480, 600);
          addTearDown(tester.view.reset);
          final origin = ValueNotifier(0.0);
          final scroll = ScrollController();
          final keys = <int, GlobalKey>{};
          addTearDown(origin.dispose);
          addTearDown(scroll.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<double>(
                  valueListenable: origin,
                  builder: (context, top, _) => Column(
                    children: [
                      SizedBox(height: top),
                      SizedBox(
                        height: 280,
                        child: ReadingList(
                          controller: scroll,
                          identity: 0,
                          viewportOrigin: top,
                          visualAnchorRect: visual
                              ? (id) {
                                  final box = keys[id]?.currentContext
                                      ?.findRenderObject();
                                  if (box is! RenderBox || !box.hasSize) {
                                    return null;
                                  }
                                  return box.localToGlobal(Offset.zero) &
                                      box.size;
                                }
                              : null,
                          header: const SizedBox(height: 40),
                          items: [
                            for (var id = 0; id < 100; id++)
                              ReadingListItem(
                                id: id,
                                builder: (_) => SizedBox(
                                  key: keys.putIfAbsent(id, GlobalKey.new),
                                  height: top >= 100 ? 80 : 40,
                                  child: Text('moving-row-$id'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          scroll.jumpTo(400);
          await tester.pumpAndSettle();
          final target = find.byKey(keys[12]!);
          final element = tester.element(target);
          final bounds = tester.getRect(target);
          final reading = tester.state(find.byType(ReadingList));
          final position = scroll.position;
          for (final top in [48.0, 16.0, 64.0, 0.0]) {
            origin.value = top;
            for (final milliseconds in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: milliseconds));
              expect(tester.getRect(target).top, closeTo(bounds.top, .01));
              expect(tester.getRect(target).size, bounds.size);
              expect(tester.element(target), same(element));
              expect(tester.state(find.byType(ReadingList)), same(reading));
              expect(scroll.position, same(position));
              expect(tester.takeException(), isNull);
            }
          }
          origin.value = 1;
          await tester.pumpAndSettle();
          final first = find.byKey(keys[10]!);
          final firstElement = tester.element(first);
          final firstTop = tester.getTopLeft(first).dy;
          origin.value = 112;
          for (final milliseconds in [0, 16, 80]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getTopLeft(first).dy, closeTo(firstTop, .01));
            expect(tester.getSize(first).height, 80);
            expect(tester.element(first), same(firstElement));
            expect(tester.state(find.byType(ReadingList)), same(reading));
            expect(scroll.position, same(position));
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    for (final width in [320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('reading list is lazy at 4096 rows $width/$scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final built = <int>{};
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: ReadingList(
                    controller: scroll,
                    identity: 0,
                    header: const SizedBox(height: 48),
                    items: [
                      for (var i = 0; i < 4096; i++)
                        ReadingListItem(
                          id: i,
                          builder: (context) {
                            built.add(i);
                            return SizedBox(
                              height: 72,
                              child: Text('第 $i 项 / row $i'),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(built.length, lessThan(40));
          scroll.jumpTo(4094 * 72.0);
          await tester.pumpAndSettle();
          expect(find.text('第 4095 项 / row 4095'), findsOneWidget);
          // Variable-height SDK SliverList may measure the prefix on a distant
          // pixel jump. Its retained tree must still be lazy at either endpoint.
          expect(
            find
                .textContaining(' / row ', skipOffstage: false)
                .evaluate()
                .length,
            lessThan(40),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    testWidgets(
      'reading object stays before paint through distant inserts and deletions',
      (tester) async {
        final rows = ValueNotifier([for (var i = 0; i < 100; i++) i]);
        final scroll = ScrollController();
        addTearDown(rows.dispose);
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<List<int>>(
                valueListenable: rows,
                builder: (context, value, _) {
                  Widget row(BuildContext context, int i) => Padding(
                    key: ValueKey(value[i]),
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'object-${value[i]} ${value[i].isEven ? '多行内容 long title ' * 7 : 'short'}',
                    ),
                  );
                  if (_disableAnchor) {
                    return CustomScrollView(
                      controller: scroll,
                      slivers: [
                        const SliverToBoxAdapter(child: SizedBox(height: 60)),
                        SliverList.builder(
                          itemCount: value.length,
                          itemBuilder: row,
                          findChildIndexCallback: (key) => key is ValueKey<int>
                              ? value.indexOf(key.value)
                              : null,
                        ),
                      ],
                    );
                  }
                  return ReadingList(
                    controller: scroll,
                    identity: 0,
                    header: const SizedBox(height: 60),
                    items: [
                      for (var i = 0; i < value.length; i++)
                        ReadingListItem(
                          id: value[i],
                          builder: (context) => row(context, i),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        final target = find.byKey(const ValueKey(40));
        await tester.scrollUntilVisible(
          target,
          400,
          scrollable: find.byType(Scrollable),
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        final rect = tester.getRect(target);
        final position = scroll.position;
        for (final next in [
          [for (var i = -512; i < 100; i++) i],
          [for (var i = 30; i < 100; i++) i],
          [for (var i = 35; i < 100; i++) i],
        ]) {
          rows.value = next;
          for (final milliseconds in [0, 16, 32, 80]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(target, findsOneWidget);
            expect(tester.getRect(target), rect);
            expect(scroll.position, same(position));
            expect(tester.takeException(), isNull);
          }
          final semantic = tester.widget<IndexedSemantics>(
            find
                .ancestor(of: target, matching: find.byType(IndexedSemantics))
                .first,
          );
          expect(semantic.index, next.indexOf(40));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'same-ID content changes preserve the reading row before paint',
      (tester) async {
        final expanded = ValueNotifier(false);
        final scroll = ScrollController();
        addTearDown(expanded.dispose);
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: expanded,
                builder: (context, value, _) => ReadingList(
                  controller: scroll,
                  identity: 0,
                  header: const SizedBox(height: 48),
                  items: [
                    for (var i = 0; i < 100; i++)
                      ReadingListItem(
                        id: i,
                        layoutValues:
                            const bool.fromEnvironment(
                              'validationDisableReadingContentAnchor',
                            )
                            ? const []
                            : [value],
                        builder: (context) => SizedBox(
                          key: ValueKey(i),
                          height: value && i < 40 ? 180 : 72,
                          child: Text('row-$i'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        scroll.jumpTo(40 * 72 + 48);
        await tester.pumpAndSettle();
        final target = find.byKey(const ValueKey(40));
        final before = tester.getRect(target);
        expect(before.top, greaterThanOrEqualTo(0));
        final position = scroll.position;
        expanded.value = true;
        for (final ms in [0, 16, 80]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(target, findsOneWidget);
          expect(tester.getRect(target), before);
          expect(scroll.position, same(position));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('grid aliases retain a surviving cell when rows regroup', (
      tester,
    ) async {
      final columns = ValueNotifier(3);
      final scroll = ScrollController();
      addTearDown(columns.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: columns,
              builder: (context, count, _) => ReadingList(
                controller: scroll,
                identity: 0,
                header: const SizedBox(height: 60),
                items: [
                  for (var start = 0; start < 240; start += count)
                    ReadingListItem(
                      id: start,
                      anchors: [
                        for (
                          var i = start + 1;
                          i < start + count && i < 240;
                          i++
                        )
                          i,
                      ],
                      builder: (context) => SizedBox(
                        key: ValueKey('grid-row-$start'),
                        height: 96,
                        child: Row(
                          children: [
                            for (
                              var i = start;
                              i < start + count && i < 240;
                              i++
                            )
                              Expanded(child: Text('cell-$i')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      final target = find.text('cell-63');
      await tester.scrollUntilVisible(
        target,
        400,
        scrollable: find.byType(Scrollable),
      );
      for (final count in [2, 4]) {
        columns.value = 3;
        await tester.pump();
        final firstReadingRow = find.byKey(const ValueKey('grid-row-63'));
        await tester.scrollUntilVisible(
          firstReadingRow,
          400,
          scrollable: find.byType(Scrollable),
        );
        await tester.ensureVisible(firstReadingRow);
        await tester.pumpAndSettle();
        final top = tester.getTopLeft(target).dy;
        columns.value = count;
        for (final milliseconds in [0, 16, 80]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(target, findsOneWidget);
          expect(tester.getTopLeft(target).dy, top);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'visual cell anchor survives regrouping during paint motion',
      (tester) => _exerciseVisualCellAnchor(tester, removeFirstCell: false),
    );

    testWidgets(
      'visual cell anchor survives removal of its old row first cell',
      (tester) => _exerciseVisualCellAnchor(tester, removeFirstCell: true),
    );
  });
  group('reading_layout_metrics', () {
    testWidgets(
      'layout observation is opt-in, bounded and reports actual Flutter metrics',
      (tester) async {
        tester.view.physicalSize = const Size(3408, 2272);
        tester.view.devicePixelRatio = 2;
        tester.view.padding = const FakeViewPadding(top: 72, bottom: 64);
        tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 64);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        final tick = ValueNotifier(0);
        addTearDown(tick.dispose);
        final records = <Map<String, dynamic>>[];
        final previous = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message?.startsWith('CATEGORY_LAYOUT ') == true) {
            expect(message, isNot(contains('private sample text')));
            records.add(
              jsonDecode(message!.substring('CATEGORY_LAYOUT '.length))
                  as Map<String, dynamic>,
            );
          } else {
            previous(message, wrapWidth: wrapWidth);
          }
        };
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 840),
                    child: ValueListenableBuilder<int>(
                      valueListenable: tick,
                      builder: (context, value, _) => ReadingList(
                        identity: 0,
                        header: Text('private sample text $value'),
                        items: const [],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          if (_enabled) {
            expect(records, isNotEmpty);
            final actual = records.last;
            expect(actual['window'], [1704.0, 1136.0]);
            expect(actual['inheritedSize'], [1704.0, 1136.0]);
            expect(actual['devicePixelRatio'], 2);
            expect(actual['viewPadding'], [0.0, 36.0, 0.0, 32.0]);
            expect((actual['parent'] as List)[1], 840);
            expect(actual['scaledText'], [14.0, 16.0, 28.0]);
          } else {
            expect(records, isEmpty);
          }
          tester.view.viewInsets = const FakeViewPadding(bottom: 600);
          await tester.pump();
          if (_enabled) {
            expect(records.last['viewInsets'], [0.0, 0.0, 0.0, 300.0]);
          }
          for (var i = 1; i <= 40; i++) {
            tick.value = i;
            await tester.pump();
          }
          expect(records.length, _enabled ? 16 : 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugPrint = previous;
        }
      },
    );
  });
}
