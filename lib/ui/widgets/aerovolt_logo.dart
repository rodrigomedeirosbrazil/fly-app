import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Aerovolt stacked lockup, tinted by the theme rather than by the file.
///
/// The asset paints a single rect through a mask, so its colour is not baked
/// in: one file serves any tint, and there is no light/dark pair to keep in
/// sync. Its viewBox is normalised to the ink, so [width] is the width you see
/// — there is no invisible padding to compensate for.
class AerovoltLogo extends StatelessWidget {
  const AerovoltLogo({super.key, required this.width, this.color});

  /// Sized by the caller against its box, never against a point constant.
  final double width;

  /// Defaults to `colorScheme.onSurface`.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      'assets/logo/aerovolt.svg',
      width: width,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      semanticsLabel: 'Aerovolt',
    );
  }
}
