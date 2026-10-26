import 'package:clash_pseudo/src/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/features/overview/widgets/status_text.dart';
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
}
