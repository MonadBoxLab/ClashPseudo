import 'package:clash_pseudo/src/ui/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'waves keep expanding while fading within 1.5 seconds without reviving on restart',
    (tester) async {
      var emitting = true;
      var visible = true;
      var reduced = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: Center(
                  child: PowerRipples(
                    emitting: emitting,
                    visible: visible,
                    color: Colors.red,
                    child: const SizedBox.square(dimension: 88),
                  ),
                ),
              );
            },
          ),
        ),
      );
      RipplePainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<RipplePainter>()
          .single;
      expect(painter().waves.map((wave) => wave.birth), [0]);
      expect(painter().time.value, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(painter().waves.length, 2);
      await tester.pump(const Duration(seconds: 2));
      expect(painter().waves.length, 3);
      final waves = List<RippleWave>.of(painter().waves);
      final ages = waves.map((wave) => wave.age(4)).toList();
      update(() => emitting = false);
      await tester.pump();
      expect(painter().waves, waves);
      expect(waves.map((wave) => wave.stoppedAt), [4, 4, 4]);
      expect(waves.map((wave) => wave.opacity(4)), [1, 1, 1]);
      await tester.pump(const Duration(milliseconds: 750));
      for (var i = 0; i < waves.length; i++) {
        expect(waves[i].age(4.75), closeTo(ages[i] + .75 / 6, .000001));
      }
      expect(waves.first.opacity(4.75), greaterThan(0));
      expect(waves.first.opacity(4.75), lessThan(1));
      update(() => emitting = true);
      await tester.pump();
      expect(painter().waves.length, 4);
      final fresh = painter().waves.last;
      expect(fresh.birth, 4.75);
      expect(fresh.stoppedAt, isNull);
      await tester.pump(const Duration(milliseconds: 750));
      expect(painter().waves, [fresh]);
      expect(waves.first.opacity(5.5), 0);
      update(() => emitting = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1499));
      expect(painter().waves, [fresh]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(painter().waves, isEmpty);
      expect(tester.binding.transientCallbackCount, 0);
      update(() => emitting = true);
      await tester.pump();
      expect(painter().waves.map((wave) => wave.birth), [0]);
      update(() => visible = false);
      await tester.pump();
      expect(painter().waves, isEmpty);
      expect(tester.binding.transientCallbackCount, 0);
      update(() {
        visible = true;
        reduced = true;
      });
      await tester.pump();
      expect(painter().waves, isEmpty);
      update(() => reduced = false);
      await tester.pump();
      expect(painter().waves.map((wave) => wave.birth), [0]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(painter().waves, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(painter().waves.map((wave) => wave.birth), [0]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('empty status uses related text without exposing it', (
    tester,
  ) async {
    const reference = '配置身份尚未确认 / Configuration identity pending';
    var text = '';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: SizedBox(
                width: 280,
                child: StatusText(
                  text,
                  emptyText: reference,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            );
          },
        ),
      ),
    );
    final status = find.byType(StatusText);
    final bounds = tester.getRect(status);
    expect(bounds.height, greaterThan(0));
    expect(find.text(reference), findsNothing);
    expect(find.semantics.byLabel(reference), findsNothing);
    for (final next in ['接管已关闭', 'Tunnel running', '']) {
      update(() => text = next);
      for (final ms in [0, 16, 80, 200, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(tester.getRect(status), bounds);
        expect(find.text(reference), findsNothing);
        expect(find.semantics.byLabel(reference), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  }, semanticsEnabled: true);

  testWidgets(
    'text fades through without overlap, skips same values and cancels old changes',
    (tester) async {
      var text = '已关闭';
      var reduced = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: Center(child: StatusText(text)),
              );
            },
          ),
        ),
      );
      update(() => text = '正在启动');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final opacities = tester
          .widgetList<Opacity>(
            find.descendant(
              of: find.byType(StatusText),
              matching: find.byType(Opacity),
            ),
          )
          .map((w) => w.opacity)
          .toList();
      expect(opacities.where((o) => o > 0 && o < 1), hasLength(1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('已关闭'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.binding.transientCallbackCount, 0);
      update(() {});
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      update(() => text = '正在停止');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      update(() => text = '接管运行中');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在停止'), findsNothing);
      expect(find.text('接管运行中'), findsWidgets);
      update(() {
        reduced = true;
        text = '状态未确认';
      });
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.text('接管运行中'), findsNothing);
    },
  );

  group('StatusText continuity', () {
    for (final interruption in [40, 99, 100, 101, 180, 260]) {
      testWidgets(
        'A to B to C retains the visible frame at ${interruption}ms',
        (tester) async {
          var text = 'A';
          late StateSetter update;
          await tester.pumpWidget(
            MaterialApp(
              home: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return Center(child: StatusText(text));
                },
              ),
            ),
          );
          final status = find.byType(StatusText);
          final state = tester.state(status);
          ({String text, double opacity, double offset}) frame() {
            final text = tester.widget<Text>(
              find.descendant(of: status, matching: find.byType(Text)),
            );
            final opacity = tester.widget<Opacity>(
              find.descendant(of: status, matching: find.byType(Opacity)),
            );
            final transform = opacity.child! as Transform;
            return (
              text: text.data!,
              opacity: opacity.opacity,
              offset: transform.transform.storage[13],
            );
          }

          update(() => text = 'B');
          await tester.pump();
          await tester.pump(Duration(milliseconds: interruption));
          final before = frame();
          update(() => text = 'C');
          await tester.pump();
          final after = frame();
          expect(after.text, before.text);
          expect(after.opacity, closeTo(before.opacity, .000001));
          expect(after.offset, closeTo(before.offset, .000001));
          expect(tester.state(status), same(state));
          expect(find.semantics.byLabel('C'), findsOneWidget);
          expect(find.semantics.byLabel('A'), findsNothing);
          expect(find.semantics.byLabel('B'), findsNothing);
          await tester.pump(const Duration(milliseconds: 300));
          expect(frame(), (text: 'C', opacity: 1.0, offset: 0.0));
          expect(tester.binding.transientCallbackCount, 0);
          expect(tester.takeException(), isNull);
        },
        semanticsEnabled: true,
      );
    }

    testWidgets(
      'return to the visible source continues entering from its current frame',
      (tester) async {
        var text = 'A';
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Center(child: StatusText(text));
              },
            ),
          ),
        );
        final status = find.byType(StatusText);
        double opacity() => tester
            .widget<Opacity>(
              find.descendant(of: status, matching: find.byType(Opacity)),
            )
            .opacity;
        double offset() =>
            (tester
                        .widget<Opacity>(
                          find.descendant(
                            of: status,
                            matching: find.byType(Opacity),
                          ),
                        )
                        .child!
                    as Transform)
                .transform
                .storage[13];
        update(() => text = 'B');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final beforeOpacity = opacity();
        final beforeOffset = offset();
        update(() => text = 'A');
        await tester.pump();
        expect(opacity(), closeTo(beforeOpacity, .000001));
        expect(offset(), closeTo(beforeOffset, .000001));
        await tester.pump(const Duration(milliseconds: 40));
        expect(opacity(), greaterThan(beforeOpacity));
        expect(offset(), greaterThan(beforeOffset));
        expect(find.text('B'), findsNothing);
        await tester.pumpAndSettle();
        expect(opacity(), 1);
        expect(offset(), 0);
      },
    );

    for (final policy in ['reduced', 'static', 'ticker']) {
      testWidgets('$policy reaches the target with no remaining ticker', (
        tester,
      ) async {
        var text = 'A';
        var immediate = false;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: policy == 'reduced' && immediate,
                  ),
                  child: TickerMode(
                    enabled: policy != 'ticker' || !immediate,
                    child: Center(
                      child: StatusText(
                        text,
                        animate: policy != 'static' || !immediate,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        update(() => text = 'B');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final state = tester.state(find.byType(StatusText));
        update(() => immediate = true);
        await tester.pump();
        expect(find.text('B'), findsOneWidget);
        expect(
          tester
              .widget<Opacity>(
                find.descendant(
                  of: find.byType(StatusText),
                  matching: find.byType(Opacity),
                ),
              )
              .opacity,
          1,
        );
        expect(tester.binding.transientCallbackCount, 0);
        update(() => text = 'C');
        await tester.pump();
        expect(find.text('C'), findsOneWidget);
        expect(find.text('B'), findsNothing);
        expect(tester.state(find.byType(StatusText)), same(state));
        expect(tester.binding.transientCallbackCount, 0);
      });
    }

    testWidgets(
      'multiline status keeps the complete large-text reading and its role',
      (tester) async {
        const text =
            'Waiting for the current configuration to finish / 等待当前配置操作完成';
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: const Center(
                child: SizedBox(
                  width: 180,
                  child: StatusText(
                    text,
                    maxLines: null,
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),
          ),
        );
        final visible = find.descendant(
          of: find.byType(StatusText),
          matching: find.byType(Text),
        );
        final widget = tester.widget<Text>(visible);
        expect(widget.data, text);
        expect(widget.style!.fontSize, 16);
        expect(widget.maxLines, isNull);
        expect(widget.softWrap, isTrue);
        expect(widget.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.getSize(visible).height, greaterThan(64));
        expect(tester.getSize(visible).width, lessThanOrEqualTo(180));
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(find.semantics.byLabel(text), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      semanticsEnabled: true,
    );
  });
}
