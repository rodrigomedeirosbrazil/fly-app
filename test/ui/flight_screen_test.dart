import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/xctod_frame.dart';
import 'package:fly_app/ui/flight_screen.dart';
import 'package:fly_app/ui/widgets/dial.dart';

XctodFrame frame({
  double? voltage = 50.4,
  int? motorTempC = 61,
  MotorTempSource source = MotorTempSource.can,
  int? escTempC = 54,
  int? currentA = 30,
  int? rpm = 4200,
  int socVoltage = 91,
  int? bmsMaxTempC = 38,
  int? cellMaxMv = 3745,
  double? powerKw = 1.5,
  ArmState armState = ArmState.armed,
  String? disarmCode,
  int powerPct = 100,
  int? cellMinMv = 3712,
}) =>
    XctodFrame(
      socCoulomb: 87,
      socVoltage: socVoltage,
      voltage: voltage,
      powerKw: powerKw,
      throttlePct: 42,
      throttleRaw: 1234,
      powerPct: powerPct,
      motorTempC: motorTempC,
      motorTempSource: source,
      rpm: rpm,
      currentA: currentA,
      escTempC: escTempC,
      armState: armState,
      disarmCode: disarmCode,
      bmsMaxTempC: bmsMaxTempC,
      cellMinMv: cellMinMv,
      cellMaxMv: cellMaxMv,
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

  group('power is a readout, not a gauge', () {
    testWidgets('only the two temperatures get dials', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      // Power has no maximum, so a circular gauge would have to invent a full
      // scale. It is a number.
      expect(find.byType(Dial), findsNWidgets(2));
      expect(find.text('1.5'), findsOneWidget);
      expect(find.text('kW'), findsOneWidget);
    });

    testWidgets('no power reading drops the readout entirely', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerKw: null),
        stale: false,
      )));

      expect(find.text('kW'), findsNothing);
      expect(find.byType(Dial), findsNWidgets(2));
    });
  });

  group('current in the hero band', () {
    testWidgets('current is a primary reading', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      expect(find.text('30'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('no current collapses the cell instead of printing zero',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(currentA: null),
        stale: false,
      )));

      expect(find.text('A'), findsNothing);
      expect(find.text('CORRENTE'), findsNothing);
    });
  });

  group('secondary data drawer', () {
    testWidgets('the readings the panel does not show are reachable',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      // Not on the panel.
      expect(find.text('4200'), findsNothing);

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();

      expect(find.text('4200'), findsOneWidget); // rpm
      expect(find.text('91 %'), findsOneWidget); // soc from voltage
      expect(find.text('1234'), findsOneWidget); // raw throttle
      expect(find.text('38 °C'), findsOneWidget); // bms max temp
      expect(find.text('3712 / 3745 mV'), findsOneWidget); // cell min / max
      expect(find.text('CAN'), findsWidgets); // motor temp source
    });

    testWidgets('unavailable secondary readings show a dash, not a zero',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(rpm: null, bmsMaxTempC: null, cellMinMv: null, cellMaxMv: null),
        stale: false,
      )));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();

      expect(find.text('0'), findsNothing);
      expect(find.text('0 °C'), findsNothing);
    });

    testWidgets('the handle is present with no frame at all', (tester) async {
      await tester.pumpWidget(wrap(const FlightScreen(frame: null, stale: true)));

      // The band stack never changes shape, so the handle exists even with no
      // data behind it.
      expect(find.byTooltip('Mais dados'), findsOneWidget);
    });
  });

  group('layout holds at real device sizes', () {
    // A widget test fails on RenderFlex overflow, so pumping at each size and
    // settling is the assertion. 393x852 is the iPhone 14 Pro this was first
    // run on; the others are the small-phone and landscape cases where a fixed
    // band height is most likely to run out of room.
    for (final size in const [
      Size(393, 852),
      Size(320, 480),
      Size(852, 393),
      Size(1280, 800),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
