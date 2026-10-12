import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A threshold drawn as a thin radial line across the track, in the same unit
/// as the dial's value.
class DialStripe {
  const DialStripe(this.at, this.color);

  final double at;
  final Color color;
}

/// A 270° gauge.
///
/// [value] of null means the controller reported no valid reading: the arc
/// stays empty and the number becomes a dash. It is never drawn as zero.
///
/// Sized only as a proportion of the space it is given — no point sizes — which
/// is what survives an orientation change and a 320 pt phone alike.
///
/// Thresholds are [stripes], not filled bands, and the **whole** value arc
/// takes [color]: green below the first threshold, amber between, red past the
/// second. The caller decides the colour from `gauge_levels.dart`. The alert
/// card shares those thresholds and hysteresis, but it also reflects the
/// firmware's own `limitCauses`, so it may be amber while the dial is still
/// green; that is deliberate (the firmware is the truth about a reduction), so
/// nobody should "fix" it by ignoring `limitCauses`.
class Dial extends StatelessWidget {
  const Dial({
    super.key,
    required this.value,
    this.min = 0,
    required this.max,
    required this.unit,
    this.label,
    this.caption,
    this.badge,
    this.note,
    this.showScale = false,
    this.stripes = const [],
    this.color,
    this.format,
    this.showArc = true,
  });

  final double? value;

  /// The scale. Fixed for temperature, power, current and RPM; the pilot's
  /// own voltage window for voltage.
  final double min;
  final double max;
  final String unit;

  /// Small caption inside the ring, under the number (the battery's
  /// "BATERIA"). The unit is not repeated here -- it already sits beside the
  /// number, and a second copy made the ring read "68 % BATERIA %".
  final String? label;

  /// Caption under the whole dial ("TEMP MOTOR", "TENSÃO").
  final String? caption;

  /// Provenance tag inside the ring, e.g. the temperature source.
  final String? badge;

  /// Why there is no reading, shown under the dash. Ignored when [value] is
  /// present: a valid number needs no excuse.
  final String? note;

  /// Draw [min] and [max] at the ring's open ends.
  final bool showScale;

  final List<DialStripe> stripes;

  /// The value arc's colour. Null is the theme's primary (green).
  final Color? color;

  /// How the number is written. Null rounds to an integer.
  final String Function(double)? format;

  /// False draws the number with no ring at all: a scale the app cannot know
  /// is not invented.
  final bool showArc;

  bool get _hasScale => showArc && max > min;

  double _fractionOf(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final hasScale = _hasScale;
    final fraction = (v == null || !hasScale) ? 0.0 : _fractionOf(v);

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
                  valueColor: color ?? theme.colorScheme.primary,
                  stripeFractions: hasScale
                      ? [for (final s in stripes) _fractionOf(s.at)]
                      : const [],
                  stripeColors: hasScale
                      ? [for (final s in stripes) s.color]
                      : const [],
                  showArc: hasScale,
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Scales down rather than overflowing: a formatted
                          // number ("5.830", "-12") can be wider than "61".
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _Value(
                                text: v == null
                                    ? '–'
                                    : (format?.call(v) ??
                                        v.round().toString()),
                                unit: v == null || unit.isEmpty ? null : unit,
                                side: side),
                          ),
                          if (label != null)
                            Text(
                              label!,
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
                          if (v == null && note != null)
                            SizedBox(
                              width: side * 0.7,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  note!,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                    fontSize: side * 0.08,
                                    letterSpacing: 1.0,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
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
      Positioned(left: 0, bottom: 0, child: Text(_trim(min), style: style)),
      Positioned(right: 0, bottom: 0, child: Text(_trim(max), style: style)),
    ];
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
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
    required this.stripeFractions,
    required this.stripeColors,
    required this.showArc,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;
  final List<double> stripeFractions;
  final List<Color> stripeColors;
  final bool showArc;

  /// Bottom-left, sweeping clockwise through the top to bottom-right.
  static const double _start = 3 * math.pi / 4;
  static const double _sweep = 3 * math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (!showArc) return;

    final side = size.shortestSide;
    final stroke = side * 0.11;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (side - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    Paint arc(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = c;

    canvas.drawArc(rect, _start, _sweep, false, arc(trackColor));
    if (fraction > 0) {
      canvas.drawArc(rect, _start, _sweep * fraction, false, arc(valueColor));
    }

    // Over the value arc, so the threshold stays visible once it is passed.
    final line = Paint()..strokeWidth = math.max(1.5, side * 0.025);
    for (var i = 0; i < stripeFractions.length; i++) {
      final angle = _start + _sweep * stripeFractions[i];
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (radius - stroke * 0.85),
        center + dir * (radius + stroke * 0.5),
        line..color = stripeColors[i],
      );
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction ||
      old.valueColor != valueColor ||
      old.trackColor != trackColor ||
      old.showArc != showArc ||
      !_sameList(old.stripeFractions, stripeFractions) ||
      !_sameList(old.stripeColors, stripeColors);

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
