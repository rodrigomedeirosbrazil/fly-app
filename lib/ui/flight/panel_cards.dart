import 'package:flutter/material.dart';

import '../../protocol/telemetry_frame.dart';

/// Rounded surface every panel element sits on.
///
/// The border is always drawn — transparent when there is nothing to say —
/// so a card that starts signalling never changes size.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(8),
    this.borderColor,
    this.fillColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final Color? fillColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fillColor ?? s.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            width: 2,
            color: borderColor ?? Colors.transparent,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The state chip's words and colour. Shared by the status row and the
/// details screen's fixed strip, which must say the same thing.
({String text, Color color}) statusChipFor(
  ColorScheme s,
  TelemetryFrame? f, {
  required bool stale,
  bool reconnecting = false,
}) {
  if (f == null) {
    return (
      text: !stale
          ? 'AGUARDANDO'
          : reconnecting
              ? 'RECONECTANDO'
              : 'SEM SINAL',
      color: stale ? s.error : s.outline,
    );
  }
  if (f.disarmCode != null) return (text: f.disarmCode!, color: s.error);
  if (f.isArmed) return (text: 'ARMADO', color: s.error);
  return (text: 'DESARMADO', color: s.outline);
}
