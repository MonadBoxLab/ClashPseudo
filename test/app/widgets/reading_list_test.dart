import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _disableAnchor = bool.fromEnvironment('validationDisableReadingAnchor');

void main() {
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
          find.textContaining(' / row ', skipOffstage: false).evaluate().length,
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

  testWidgets('same-ID content changes preserve the reading row before paint', (
    tester,
  ) async {
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
  });

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
                      for (var i = start + 1; i < start + count && i < 240; i++)
                        i,
                    ],
                    builder: (context) => SizedBox(
                      key: ValueKey('grid-row-$start'),
                      height: 96,
                      child: Row(
                        children: [
                          for (var i = start; i < start + count && i < 240; i++)
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
}
