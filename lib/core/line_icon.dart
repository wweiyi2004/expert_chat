import 'package:flutter/material.dart';

/// Compact outline glyphs share a 24-unit grid, round caps and 1.7-unit
/// strokes. They remain crisp at sidebar sizes without a font dependency.
class LineIcon extends StatelessWidget {
  const LineIcon(this.icon, {super.key, this.size = 18, this.color});
  final IconData icon;
  final double size;
  final Color? color;
  static const _supported = [
    Icons.search,
    Icons.folder_outlined,
    Icons.edit_square,
    Icons.more_vert,
    Icons.menu,
    Icons.add,
    Icons.article_outlined,
    Icons.autorenew,
    Icons.settings_outlined,
    Icons.view_sidebar_outlined,
  ];
  @override
  Widget build(BuildContext context) => !_supported.contains(icon)
      ? Icon(icon, size: size, color: color)
      : Center(
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: _LinePainter(
                icon,
                color ?? IconTheme.of(context).color ?? Colors.black,
              ),
            ),
          ),
        );
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.icon, this.color);
  final IconData icon;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(double x, double y, double x2, double y2) =>
        canvas.drawLine(Offset(x, y), Offset(x2, y2), paint);
    final path = Path();
    if (icon == Icons.search) {
      canvas.drawCircle(const Offset(10.5, 10.5), 6.5, paint);
      line(15.2, 15.2, 21, 21);
    } else if (icon == Icons.folder_outlined) {
      path.moveTo(3, 7);
      path.lineTo(3, 19);
      path.quadraticBezierTo(3, 20, 4, 20);
      path.lineTo(20, 20);
      path.quadraticBezierTo(21, 20, 21, 19);
      path.lineTo(21, 8);
      path.lineTo(12, 8);
      path.lineTo(10, 5);
      path.lineTo(4, 5);
      path.quadraticBezierTo(3, 5, 3, 7);
      canvas.drawPath(path, paint);
    } else if (icon == Icons.edit_square) {
      path.moveTo(20, 13);
      path.lineTo(20, 20);
      path.lineTo(4, 20);
      path.lineTo(4, 4);
      path.lineTo(11, 4);
      canvas.drawPath(path, paint);
      canvas.drawPath(
        Path()
          ..moveTo(10, 14)
          ..lineTo(11, 10)
          ..lineTo(19, 2)
          ..lineTo(22, 5)
          ..lineTo(14, 13)
          ..close(),
        paint,
      );
    } else if (icon == Icons.more_vert) {
      for (final y in [5.0, 12.0, 19.0]) {
        canvas.drawCircle(Offset(12, y), 1, Paint()..color = color);
      }
    } else if (icon == Icons.menu) {
      for (final y in [5.0, 12.0, 19.0]) {
        line(4, y, 20, y);
      }
    } else if (icon == Icons.add) {
      line(4, 12, 20, 12);
      line(12, 4, 12, 20);
    } else if (icon == Icons.article_outlined) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(5, 3, 14, 18),
          const Radius.circular(2),
        ),
        paint,
      );
      line(9, 8, 15, 8);
      line(9, 12, 15, 12);
      line(9, 16, 13, 16);
    } else if (icon == Icons.autorenew) {
      canvas.drawArc(const Rect.fromLTWH(4, 4, 16, 16), -.8, 2.5, false, paint);
      canvas.drawArc(
        const Rect.fromLTWH(4, 4, 16, 16),
        2.35,
        2.5,
        false,
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(16, 3)
          ..lineTo(19, 7)
          ..lineTo(22, 3),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(2, 21)
          ..lineTo(5, 17)
          ..lineTo(8, 21),
        paint,
      );
    } else if (icon == Icons.view_sidebar_outlined) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 4, 18, 16),
          const Radius.circular(2),
        ),
        paint,
      );
      line(9, 4, 9, 20);
    } else {
      // Settings: eight teeth around the same fine outline as other controls.
      canvas.drawCircle(const Offset(12, 12), 6.5, paint);
      canvas.drawCircle(const Offset(12, 12), 2.5, paint);
      for (var i = 0; i < 8; i++) {
        canvas.save();
        canvas.translate(12, 12);
        canvas.rotate(i * 0.78539816339);
        line(0, -6.5, 0, -9);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter oldDelegate) =>
      icon != oldDelegate.icon || color != oldDelegate.color;
}
