import 'package:flutter/material.dart';

import '../../state/flight_alerts.dart';
import 'alert_text.dart';
import 'panel_cards.dart';

/// Severity to look. The same three colours the gauges use, over the same
/// thresholds and hysteresis. The card also reflects the firmware's own
/// `limitCauses`, so it may be amber while a dial is still green; that is
/// deliberate (the firmware is the truth about a reduction), so nobody should
/// "fix" it by ignoring `limitCauses`. Null is the all-clear.
({Color accent, Color iconColor, Color? border, Color? fill, IconData icon})
    alertStyle(ColorScheme s, AlertSeverity? severity) => switch (severity) {
          null => (
              accent: s.primary,
              iconColor: s.primary,
              border: null,
              fill: null,
              icon: Icons.check_circle_outline,
            ),
          AlertSeverity.info => (
              accent: s.onSurface,
              iconColor: s.outline,
              border: s.outline,
              fill: null,
              icon: Icons.info_outline,
            ),
          AlertSeverity.caution => (
              accent: s.tertiary,
              iconColor: s.tertiary,
              border: s.tertiary,
              fill: null,
              icon: Icons.warning_amber_rounded,
            ),
          AlertSeverity.danger => (
              accent: s.error,
              iconColor: s.error,
              border: s.error,
              fill: null,
              icon: Icons.report_outlined,
            ),
          // Filled: the controller disarmed itself and the motor will not run.
          AlertSeverity.disarmed => (
              accent: s.error,
              iconColor: s.error,
              border: s.error,
              fill: s.error.withValues(alpha: 0.18),
              icon: Icons.power_settings_new,
            ),
        };

/// The single most important alert: what has the problem, then what kind.
///
/// Without a frame it shows a dash. "Tudo certo" from no data would be the
/// one reading on the panel that is confidently wrong.
class AlertCard extends StatelessWidget {
  const AlertCard({
    super.key,
    required this.alerts,
    required this.hasFrame,
    this.onTap,
  });

  final List<FlightAlert> alerts;
  final bool hasFrame;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final top = alerts.isEmpty ? null : alerts.first;
    final style = alertStyle(s, top?.severity);
    final label =
        top == null ? (line1: 'TUDO', line2: 'CERTO') : alertLabel(top);

    return PanelCard(
      key: const Key('alert-card'),
      onTap: onTap,
      padding: const EdgeInsets.all(6),
      borderColor: hasFrame ? style.border : null,
      fillColor: hasFrame ? style.fill : null,
      child: LayoutBuilder(builder: (context, c) {
        final side = c.biggest.shortestSide;
        final muted = TextStyle(
          fontSize: 11,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w600,
          color: s.onSurfaceVariant,
        );
        return Stack(
          children: [
            // Scales down rather than overflowing: on a 320x480 phone this
            // cell is about 50 px tall.
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!hasFrame)
                      Text('–',
                          style: TextStyle(
                              fontSize: side * 0.3,
                              fontWeight: FontWeight.w600))
                    else ...[
                      Icon(style.icon,
                          size: side * 0.28, color: style.iconColor),
                      _fit(
                          label.line1,
                          TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: style.accent,
                          ),
                          c.maxWidth),
                      _fit(
                          label.line2,
                          TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.5,
                            color: s.onSurface,
                          ),
                          c.maxWidth),
                    ],
                    const SizedBox(height: 2),
                    Text('ALERTAS', maxLines: 1, style: muted),
                  ],
                ),
              ),
            ),
            if (hasFrame && alerts.length > 1)
              Positioned(
                key: const Key('alert-more'),
                top: 0,
                right: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: s.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('+${alerts.length - 1}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
          ],
        );
      }),
    );
  }

  /// One line that shrinks rather than wraps: these cards are a third of a
  /// phone's width and "SUPERAQUECIDO" is long.
  static Widget _fit(String text, TextStyle style, double width) => SizedBox(
        width: width,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text, maxLines: 1, softWrap: false, style: style),
        ),
      );
}
