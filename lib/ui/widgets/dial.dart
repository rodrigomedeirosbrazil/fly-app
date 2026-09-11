import 'dart:math' show pi;

import 'package:flutter/material.dart';

/// A 270° gauge.
///
/// [value] of null means the controller reported no valid reading: the arc
/// stays empty and the number becomes a dash. It is never drawn as zero.
///
/// Sized only as a proportion of the space it is given — no point sizes — which
/// is what survives an orientation change and a 320 pt phone alike.
///
/// The reduction band is the arc between where the controller begins cutting
/// power and where it cuts it entirely. Both come from the controller's NVS
/// over `CFG_GET`, so they are this pilot's numbers rather than the factory
/// defaults — which is why the band could not be drawn before phase 2.
///
/// It has two zones, because the firmware's derating has two. From
/// [bandStart] to [bandEnd] power ramps down proportionally; **above**
/// [bandEnd] `Power::calcMotorTempLimit` constrains it to zero and leaves it
/// there. So the arc past [bandEnd] is not a return to normal — it is the one
/// region where the motor is certainly not pushing, and it is drawn solid.
///
/// [bandStart] and [bandEnd] null means no band: the sentence path, firmware
/// that cannot answer, or thresholds that do not describe a range. The scale
/// stays [max] regardless, so the needle angle means the same temperature on
/// every aircraft.
class Dial extends StatelessWidget {
  const Dial({
    super.key,
    required this.value,
    required this.max,
    required this.unit,
    this.label,
    this.caption,
    this.badge,
    this.showScale = false,
    this.bandStart,
    this.bandEnd,
  });

  final double? value;
  final double max;
  final String unit;

  /// Small caption inside the ring, under the number (the battery's "BATERIA").
  final String? label;

  /// Caption under the whole dial (the thermals' "MOTOR" / "ESC").
  final String? caption;

  /// Provenance tag inside the ring, e.g. the motor temperature source.
  final String? badge;

  /// Draw 0 and [max] at the ring's open ends.
  final bool showScale;

  /// Where power reduction begins, in the same unit as [value].
  final double? bandStart;

  /// Where power reaches zero. Everything hotter is also zero.
  final double? bandEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final fraction = (v == null || max <= 0) ? 0.0 : (v / max).clamp(0.0, 1.0);
    final band = _bandFractions();

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = constraints.biggest.shortestSide;
              return CustomPaint(
                painter: _DialPainter(
                  fraction: fraction,
                  trackColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: theme.colorScheme.primary,
                  rampColor: theme.colorScheme.tertiary,
                  cutColor: theme.colorScheme.error,
                  bandStartFraction: band.$1,
                  cutFraction: band.$2,
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Value(text: v == null ? '–' : v.round().toString(),
                              unit: v == null ? null : unit, side: side),
                          if (label != null)
                            Text(
                              '$label $unit',
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: side * 0.10,
                                letterSpacing: 2.0,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (badge != null)
                            Text(
                              badge!,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: side * 0.09,
                                letterSpacing: 1.5,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showScale) ..._scaleLabels(theme, side),
                  ],
                ),
              );
            },
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              caption!,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _scaleLabels(ThemeData theme, double side) {
    final style = TextStyle(
      fontSize: side * 0.09,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return [
      Positioned(left: 0, bottom: 0, child: Text('0', style: style)),
      Positioned(
          right: 0, bottom: 0, child: Text(max.round().toString(), style: style)),
    ];
  }

  /// The band as fractions of the arc, or (null, null) when there is none.
  ///
  /// Guards the same rule `ThermalConfig` does, because a Dial can be built
  /// from anywhere: numbers that do not describe a range do not become one.
  (double?, double?) _bandFractions() {
    final start = bandStart;
    final end = bandEnd;
    if (start == null || end == null) return (null, null);
    if (max <= 0 || start <= 0 || start >= end) return (null, null);
    return ((start / max).clamp(0.0, 1.0), (end / max).clamp(0.0, 1.0));
  }
}

/// The number and its unit on one baseline. The unit is small and adjacent, not
/// a line of its own: "58.40 V" reads as one quantity, a unit stranded at the
/// bottom of a tall cell does not.
class _Value extends StatelessWidget {
  const _Value({required this.text, required this.unit, required this.side});

  final String text;
  final String? unit;
  final double side;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          text,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: side * 0.30,
            fontWeight: FontWeight.w600,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (unit != null) ...[
          SizedBox(width: side * 0.02),
          Text(
            unit!,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: side * 0.11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.fraction,
    required this.trackColor,
    required this.valueColor,
    required this.rampColor,
    required this.cutColor,
    required this.bandStartFraction,
    required this.cutFraction,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;
  /// Amber for the ramp, red for the cut. Two colours rather than two
  /// opacities of one: caution and danger are different states, and the
  /// instrument convention for them is older than this app.
  final Color rampColor;
  final Color cutColor;
  /// Where reduction begins, as a fraction of the arc.
  final double? bandStartFraction;

  /// Where power reaches zero. From here to the end of the arc is full cut.
  final double? cutFraction;

  /// Bottom-left, sweeping clockwise through the top to bottom-right.
  static const double _start = 3 * pi / 4;
  static const double _sweep = 3 * pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final stroke = side * 0.11;
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

    final bandStart = bandStartFraction;
    final cut = cutFraction;
    if (bandStart != null && cut != null) {
      // Both under the value arc, so a warning never obscures the number it
      // warns about. Butt caps: a round cap overhangs its own threshold and
      // would put red where the controller is not yet reducing.
      Paint zone(Color color) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = color;

      // The ramp: power falls proportionally across this span.
      if (cut > bandStart) {
        canvas.drawArc(rect, _start + _sweep * bandStart,
            _sweep * (cut - bandStart), false, zone(rampColor));
      }
      // The cut: power is zero from here to the end of the scale, so the
      // band does not stop at the threshold -- stopping would suggest the
      // arc beyond it is safe again, which is the opposite of true.
      if (cut < 1.0) {
        canvas.drawArc(rect, _start + _sweep * cut, _sweep * (1.0 - cut),
            false, zone(cutColor));
      }
    }

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
      old.trackColor != trackColor ||
      old.rampColor != rampColor ||
      old.cutColor != cutColor ||
      old.bandStartFraction != bandStartFraction ||
      old.cutFraction != cutFraction;
}
