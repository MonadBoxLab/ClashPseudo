import 'package:flutter/material.dart';

class StrategyIcon extends StatelessWidget {
  const StrategyIcon({super.key, required this.type, this.size = 30});
  final String type;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _StrategyIconPainter(
        type,
        Theme.of(context).brightness == Brightness.dark,
      ),
    ),
  );
}

class _StrategyIconPainter extends CustomPainter {
  const _StrategyIconPainter(this.type, this.dark);
  final String type;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 32, size.height / 32);
    final (first, second) = switch (type) {
      'select' => (const Color(0xffea7841), const Color(0xffc54358)),
      'url-test' => (const Color(0xff20a581), const Color(0xff48bfd0)),
      'fallback' => (const Color(0xff477eda), const Color(0xff55bdcc)),
      'load-balance' => (const Color(0xff8b65cf), const Color(0xffd771a6)),
      _ => (const Color(0xff778994), const Color(0xffa5b5ba)),
    };
    Color tone(Color color) =>
        dark ? Color.lerp(color, Colors.white, .18)! : color;
    final a = Paint()
      ..color = tone(first)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final b = Paint()
      ..color = tone(second)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (type) {
      case 'select':
        a.style = PaintingStyle.stroke;
        canvas.drawPath(
          Path()
            ..moveTo(7, 25)
            ..lineTo(7, 18)
            ..quadraticBezierTo(7, 15, 11, 15)
            ..lineTo(21, 15)
            ..quadraticBezierTo(25, 15, 25, 11)
            ..lineTo(25, 7),
          a,
        );
        b.style = PaintingStyle.stroke;
        canvas.drawPath(
          Path()
            ..moveTo(7, 15)
            ..lineTo(7, 7),
          b,
        );
        a.style = PaintingStyle.fill;
        b.style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(7, 26), 4, a);
        canvas.drawCircle(const Offset(25, 6), 4, a);
        canvas.drawCircle(const Offset(7, 6), 4, b);
      case 'url-test':
        a.style = PaintingStyle.stroke;
        canvas.drawArc(const Rect.fromLTWH(3, 3, 26, 26), .65, 4.95, false, a);
        canvas.drawPath(
          Path()
            ..moveTo(25, 3)
            ..lineTo(28, 9)
            ..lineTo(21, 9),
          b,
        );
        canvas.drawPath(
          Path()
            ..moveTo(17, 7)
            ..lineTo(10, 18)
            ..lineTo(16, 18)
            ..lineTo(14, 26)
            ..lineTo(23, 14)
            ..lineTo(17, 14)
            ..close(),
          b,
        );
      case 'fallback':
        a.style = PaintingStyle.stroke;
        b.style = PaintingStyle.stroke;
        canvas.drawPath(
          Path()
            ..moveTo(4, 10)
            ..lineTo(25, 10)
            ..moveTo(20, 5)
            ..lineTo(25, 10)
            ..lineTo(20, 15),
          a,
        );
        canvas.drawPath(
          Path()
            ..moveTo(28, 23)
            ..lineTo(7, 23)
            ..moveTo(12, 18)
            ..lineTo(7, 23)
            ..lineTo(12, 28),
          b,
        );
      case 'load-balance':
        a.style = PaintingStyle.stroke;
        canvas.drawPath(
          Path()
            ..moveTo(4, 16)
            ..lineTo(13, 16)
            ..moveTo(13, 6)
            ..lineTo(13, 26)
            ..moveTo(13, 6)
            ..lineTo(22, 6)
            ..moveTo(13, 26)
            ..lineTo(22, 26),
          a,
        );
        for (final y in [6.0, 16.0, 26.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(25, y), width: 10, height: 6),
              const Radius.circular(2),
            ),
            b,
          );
        }
      default:
        canvas.drawCircle(const Offset(10, 12), 7, a);
        canvas.drawCircle(const Offset(22, 21), 7, b);
    }
  }

  @override
  bool shouldRepaint(_StrategyIconPainter oldDelegate) =>
      type != oldDelegate.type || dark != oldDelegate.dark;
}
