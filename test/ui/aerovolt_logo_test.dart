import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/widgets/aerovolt_logo.dart';

void main() {
  testWidgets('tints itself from the theme rather than from the file',
      (tester) async {
    const onSurface = Color(0xFFE6EDF3);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(onSurface: onSurface),
      ),
      home: const Scaffold(body: AerovoltLogo(width: 200)),
    ));

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      svg.colorFilter,
      const ColorFilter.mode(onSurface, BlendMode.srcIn),
      reason: 'the asset is white; the theme decides what colour it becomes',
    );
  });

  testWidgets('an explicit colour wins over the theme', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AerovoltLogo(width: 200, color: Color(0xFF3FB950)),
      ),
    ));

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Color(0xFF3FB950), BlendMode.srcIn),
    );
  });
}
