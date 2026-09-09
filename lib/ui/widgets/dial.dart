import 'dart:math' show pi;

import 'package:flutter/material.dart';

/// A 270° gauge. [value] of null means the controller reported no valid
/// reading: the arc stays empty and the number becomes a dash. It is never
/// drawn as zero.
class Dial extends StatelessWidget {
  const Dial({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    required this.unit,
    this.badge,
  });

  final String label;
  final double? value;
  final double max;
  final String unit;

  /// Small caption inside the dial, e.g. the motor temperature source.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final fraction = (v == null || max <= 0) ? 0.0 : (v / max).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        return CustomPaint(
          painter: _DialPainter(
            fraction: fraction,
            trackColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: theme.colorScheme.primary,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: side * 0.10,
                    letterSpacing: 1.2,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  v == null ? '–' : v.round().toString(),
                  style: TextStyle(
                    fontSize: side * 0.30,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (v != null)
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: side * 0.10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (badge != null)
                  Padding(
                    padding: EdgeInsets.only(top: side * 0.03),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontSize: side * 0.08,
                        letterSpacing: 1.0,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.fraction,
    required this.trackColor,
    required this.valueColor,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;

  /// Bottom-left, sweeping clockwise through the top to bottom-right.
  static const double _start = 3 * pi / 4;
  static const double _sweep = 3 * pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final stroke = side * 0.09;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side - stroke,
      height: side - stroke,
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, _start, _sweep, false, track);

    if (fraction <= 0) return;

    final value = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = valueColor;
    canvas.drawArc(rect, _start, _sweep * fraction, false, value);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction ||
      old.valueColor != valueColor ||
      old.trackColor != trackColor;
}
