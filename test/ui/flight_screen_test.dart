import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/xctod_frame.dart';
import 'package:fly_app/ui/flight_screen.dart';

XctodFrame frame({
  double? voltage = 50.4,
  int? motorTempC = 61,
  MotorTempSource source = MotorTempSource.can,
  int? escTempC = 54,
  int? currentA = 30,
  double? powerKw = 1.5,
  ArmState armState = ArmState.armed,
  String? disarmCode,
  int powerPct = 100,
  int? cellMinMv = 3712,
}) =>
    XctodFrame(
      socCoulomb: 87,
      socVoltage: 91,
      voltage: voltage,
      powerKw: powerKw,
      throttlePct: 42,
      throttleRaw: 1234,
      powerPct: powerPct,
      motorTempC: motorTempC,
      motorTempSource: source,
      rpm: 4200,
      currentA: currentA,
      escTempC: escTempC,
      armState: armState,
      disarmCode: disarmCode,
      bmsMaxTempC: 38,
      cellMinMv: cellMinMv,
      cellMaxMv: 3745,
      receivedAt: DateTime.utc(2026, 9, 9),
    );

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('renders the headline readings when everything is present',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

    expect(find.text('87'), findsOneWidget); // SoC
    expect(find.text('ARMED'), findsOneWidget);
    expect(find.text('CAN'), findsOneWidget); // motor temp source badge
  });

  testWidgets('a missing motor temperature shows a dash, never a zero',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(motorTempC: null, source: MotorTempSource.none),
      stale: false,
    )));

    expect(find.text('0'), findsNothing);
    expect(find.text('–'), findsWidgets);
    expect(find.text('CAN'), findsNothing);
  });

  testWidgets('a disarm code is shown in the space the status bar reserves',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(armState: ArmState.disarmed, disarmCode: 'MOT SRC'),
      stale: false,
    )));

    expect(find.text('MOT SRC'), findsOneWidget);
  });

  testWidgets('a limited frame shows the available-power chip', (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(powerPct: 73),
      stale: false,
    )));

    expect(find.text('DISPONÍVEL 73 %'), findsOneWidget);
  });

  testWidgets('an unlimited frame shows no chip', (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

    expect(find.textContaining('DISPONÍVEL'), findsNothing);
  });

  testWidgets('stale link replaces every reading with SEM SINAL',
      (tester) async {
    await tester.pumpWidget(wrap(const FlightScreen(frame: null, stale: true)));

    expect(find.text('SEM SINAL'), findsOneWidget);
    expect(find.text('87'), findsNothing);
  });

  testWidgets('the voltage cell toggles to per-cell on tap', (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

    expect(find.text('50.4'), findsOneWidget);
    expect(find.text('V'), findsOneWidget);

    await tester.tap(find.text('50.4'));
    await tester.pumpAndSettle();

    // cellMinMv is 3712, so the BMS minimum cell wins over an estimate.
    expect(find.text('3.71'), findsOneWidget);
    expect(find.text('V/cél'), findsOneWidget);
    expect(find.text('50.4'), findsNothing);
  });

  testWidgets('per-cell falls back to an estimate marked with a tilde',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(cellMinMv: null),
      stale: false,
    )));

    await tester.tap(find.text('50.4'));
    await tester.pumpAndSettle();

    // 50.4 V over a hardcoded 14 cells.
    expect(find.text('~3.60'), findsOneWidget);
  });

  testWidgets('the toggle survives a missing voltage without crashing',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(voltage: null),
      stale: false,
    )));

    expect(find.text('–'), findsWidgets);
  });
}
