import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'palette.dart';

/// Dark rounded square with two pills, as in the wireframe header.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    Widget pill(Color color, double left, double top) => Positioned(
          left: size * left,
          top: size * top,
          child: Container(
            width: size * 0.46,
            height: size * 0.2,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(size),
            ),
          ),
        );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Palette.ink,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: Stack(children: [
        pill(Colors.white, 0.22, 0.24),
        pill(Palette.logoPill, 0.34, 0.56),
      ]),
    );
  }
}

/// Circular progress arc around an optional child, used for task progress and token budget.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 40,
    this.stroke = 3.5,
    this.fill,
    this.color = Palette.ring,
    this.child,
  });

  final double value;
  final double size;
  final double stroke;
  final Color? fill;
  final Color color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(value.clamp(0, 1), stroke, fill, color),
        child: Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.stroke, this.fill, this.color);

  final double value;
  final double stroke;
  final Color? fill;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    if (fill != null) {
      canvas.drawOval(rect, Paint()..color = fill!);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, line..color = Palette.ringTrack);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * value, false, line..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.fill != fill || old.color != color;
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Palette.chip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Palette.chipText),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                color: Palette.chipText, fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }
}

String formatMb(int kb) => '${(kb / 1024).toStringAsFixed(1)} MB';
