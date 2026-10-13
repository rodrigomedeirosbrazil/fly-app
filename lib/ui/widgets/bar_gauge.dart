import 'package:flutter/material.dart';

import 'dial.dart';

/// A reading as a large number over a horizontal bar.
///
/// The number is the point: it takes all the height the caption and the bar
/// leave, sized as a proportion of that height and shrunk to the width, so it
/// grows with the card instead of sitting in a ring's hole.
///
/// [value] of null means the controller reported no valid reading: the number
/// becomes a dash with [note] under it and the track stays empty. It is never
/// drawn as zero.
///
/// The bar follows the same rules as [Dial]'s arc: thresholds are [stripes],
/// and the whole fill takes [color], decided by the caller from
/// `gauge_levels.dart`. With no scale ([showBar] false, or `max <= min`) the
/// bar's slot stays empty rather than inventing one, and the number does not
/// move when a scale arrives.
class BarGauge extends StatelessWidget {
  const BarGauge({
    super.key,
    required this.value,
    this.min = 0,
    required this.max,
    required this.unit,
    this.caption,
    this.note,
    this.stripes = const [],
    this.color,
    this.format,
    this.showBar = true,
  });

  final double? value;
  final double min;
  final double max;
  final String unit;

  /// Name of the reading, above the number ("TENSÃO").
  final String? caption;

  /// Why there is no reading, shown under the dash. Ignored when [value] is
  /// present.
  final String? note;

  final List<DialStripe> stripes;

  /// The fill's colour. Null is the theme's primary (green).
  final Color? color;

  /// How the number is written. Null rounds to an integer.
  final String Function(double)? format;

  /// False leaves the bar's slot empty: a scale the app cannot know is not
  /// invented.
  final bool showBar;

  static const double _barHeight = 10;

  bool get _hasScale => showBar && max > min;

  double _fractionOf(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null)
          Text(
            caption!,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
              color: s.onSurfaceVariant,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _number(s, c.maxHeight),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: _barHeight,
          child: _hasScale ? _bar(s) : null,
        ),
      ],
    );
  }

  Widget _number(ColorScheme s, double h) {
    final v = value;
    if (v == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '–',
            maxLines: 1,
            style: TextStyle(
              fontSize: h * 0.55,
              height: 1.0,
              fontWeight: FontWeight.w600,
              color: s.outline,
            ),
          ),
          if (note != null)
            Text(
              note!,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: h * 0.18,
                letterSpacing: 1.0,
                fontWeight: FontWeight.w600,
                color: s.onSurfaceVariant,
              ),
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          format?.call(v) ?? v.round().toString(),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: h * 0.85,
            height: 1.0,
            fontWeight: FontWeight.w600,
            letterSpacing: -h * 0.02,
            color: s.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (unit.isNotEmpty) ...[
          SizedBox(width: h * 0.04),
          Text(
            unit,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(fontSize: h * 0.28, color: s.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _bar(ColorScheme s) {
    final v = value;
    return LayoutBuilder(
      builder: (context, c) => Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipRRect(
              key: const Key('bar-track'),
              borderRadius: BorderRadius.circular(_barHeight / 2),
              child: ColoredBox(
                color: s.surfaceContainerHighest,
                child: v == null
                    ? null
                    : FractionallySizedBox(
                        key: const Key('bar-fill'),
                        alignment: Alignment.centerLeft,
                        widthFactor: _fractionOf(v),
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: color ?? s.primary,
                            borderRadius:
                                BorderRadius.circular(_barHeight / 2),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          // Over the fill and outside the clip, so a threshold stays visible
          // once it is passed.
          for (final (i, stripe) in stripes.indexed)
            Positioned(
              key: Key('bar-stripe-$i'),
              left: (c.maxWidth * _fractionOf(stripe.at) - 1)
                  .clamp(0.0, c.maxWidth - 2),
              top: -3,
              bottom: -3,
              width: 2,
              child: ColoredBox(color: stripe.color),
            ),
        ],
      ),
    );
  }
}
