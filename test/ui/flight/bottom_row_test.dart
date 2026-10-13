import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/panel_layout_policy.dart';
import 'package:fly_app/ui/flight/panel_cards.dart';
import 'package:fly_app/ui/widgets/bar_gauge.dart';

TelemetryFrame frame({
  double? voltage = 50.8,
  double? powerKw = 7.5,
  double? currentA = 148,
  int? rpm = 5830,
  bool? hasTelemetry = true,
}) => TelemetryFrame(
  socCoulomb: 62,
  socVoltage: 58,
  voltage: voltage,
  powerKw: powerKw,
  throttlePct: 55,
  throttleRaw: 0,
  powerPct: 100,
  motorTempC: 60,
  motorTempSource: MotorTempSource.can,
  rpm: rpm,
  currentA: currentA,
  escTempC: 50,
  armState: ArmState.armed,
  disarmReason: DisarmReason.none,
  bmsMaxTempC: null,
  cellMinMv: null,
  cellMaxMv: null,
  receivedAt: DateTime.utc(2026, 10, 12),
  hasTelemetry: hasTelemetry,
);

const power = PowerConfig(
  capacityMah: 20000,
  minVoltageMv: 42000,
  maxVoltageMv: 58800,
  powerControlEnabled: true,
  voltageDividerRatio: 11,
);

Widget row(
  BottomRowLayout layout, {
  TelemetryFrame? f,
  PowerConfig? config = power,
  bool perCell = false,
  bool showCurrent = false,
  VoidCallback? onPerCell,
  VoidCallback? onCurrent,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 380,
      height: 130,
      child: BottomRowCards(
        layout: layout,
        frame: f ?? frame(),
        powerConfig: config,
        perCell: perCell,
        showCurrent: showCurrent,
        onTogglePerCell: onPerCell ?? () {},
        onToggleCurrent: onCurrent ?? () {},
      ),
    ),
  ),
);

BarGauge dial(WidgetTester t, String key) =>
    t.widget<BarGauge>(find.byKey(Key(key)));

void main() {
  testWidgets('full: voltage, power, rpm, formatted the Brazilian way', (
    tester,
  ) async {
    await tester.pumpWidget(row(BottomRowLayout.full));
    expect(find.text('50,8'), findsOneWidget);
    expect(find.text('7,5'), findsOneWidget);
    expect(find.text('5.830'), findsOneWidget);
    expect(dial(tester, 'gauge-power').max, 18);
    expect(dial(tester, 'gauge-rpm').max, 6000);
  });

  testWidgets(
    'the voltage scale is the pilot\'s window, striped at 10 and 5 %',
    (tester) async {
      await tester.pumpWidget(row(BottomRowLayout.full));
      final d = dial(tester, 'gauge-voltage');
      expect(d.min, 42.0);
      expect(d.max, 58.8);
      expect(d.stripes.map((s) => s.at), [
        closeTo(43.68, 1e-9),
        closeTo(42.84, 1e-9),
      ]);
    },
  );

  testWidgets('no Power group: the voltage keeps its number, loses its bar', (
    tester,
  ) async {
    await tester.pumpWidget(row(BottomRowLayout.full, config: null));
    expect(dial(tester, 'gauge-voltage').showBar, isFalse);
    expect(find.text('50,8'), findsOneWidget);
  });

  testWidgets('per cell shows the estimate with a tilde', (tester) async {
    await tester.pumpWidget(row(BottomRowLayout.full, perCell: true));
    expect(find.text('~3,63'), findsOneWidget);
    expect(dial(tester, 'gauge-voltage').max, closeTo(4.2, 1e-9));
  });

  testWidgets('current replaces power, 0 to 300 A', (tester) async {
    await tester.pumpWidget(row(BottomRowLayout.full, showCurrent: true));
    expect(find.byKey(const Key('gauge-power')), findsNothing);
    expect(dial(tester, 'gauge-current').max, 300);
    expect(find.text('148'), findsOneWidget);
  });

  testWidgets('taps reach the toggles', (tester) async {
    var cell = 0, current = 0;
    await tester.pumpWidget(
      row(
        BottomRowLayout.full,
        onPerCell: () => cell++,
        onCurrent: () => current++,
      ),
    );
    await tester.tap(find.byKey(const Key('gauge-voltage')));
    await tester.tap(find.byKey(const Key('gauge-power')));
    expect((cell, current), (1, 1));
  });

  testWidgets('XAG with BMS has no RPM card', (tester) async {
    await tester.pumpWidget(row(BottomRowLayout.noRpm));
    expect(find.byKey(const Key('gauge-rpm')), findsNothing);
    expect(find.byKey(const Key('gauge-power')), findsOneWidget);
  });

  testWidgets('XAG without BMS: one wide voltage card, no toggle', (
    tester,
  ) async {
    var cell = 0;
    await tester.pumpWidget(
      row(BottomRowLayout.voltageOnly, onPerCell: () => cell++),
    );
    expect(find.byKey(const Key('voltage-wide')), findsOneWidget);
    expect(find.byKey(const Key('gauge-power')), findsNothing);
    expect(find.text('~3,63'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voltage-wide')));
    expect(cell, 0);
  });

  testWidgets('a reading lost in use keeps its card and says why', (
    tester,
  ) async {
    await tester.pumpWidget(
      row(
        BottomRowLayout.full,
        f: frame(powerKw: null, rpm: null, hasTelemetry: false),
      ),
    );
    expect(find.byKey(const Key('gauge-power')), findsOneWidget);
    expect(find.byKey(const Key('gauge-rpm')), findsOneWidget);
    expect(find.text('SEM DADOS'), findsNWidgets(2));
  });
}
