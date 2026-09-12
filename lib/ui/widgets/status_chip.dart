import 'package:flutter/material.dart';

/// A state, named in its own colour on a wash of it.
///
/// Lifted out of `flight_screen.dart` so the settings screens can say things
/// like "BMS conectado" in the vocabulary the panel already uses. A second
/// implementation would have drifted in radius, weight and alpha, and the
/// point of reusing it is that a pilot reads the two surfaces as one app.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
