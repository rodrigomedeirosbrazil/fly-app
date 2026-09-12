import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/ui/flight_screen.dart';
import 'package:fly_app/ui/widgets/dial.dart';

import 'navigator_utils.dart';

TelemetryFrame frame({
  double? voltage = 50.4,
  double? motorTempC = 61,
  MotorTempSource source = MotorTempSource.can,
  double? escTempC = 54,
  double? currentA = 30,
  int? rpm = 4200,
  int socVoltage = 91,
  int? bmsMaxTempC = 38,
  int? cellMaxMv = 3745,
  double? powerKw = 1.5,
  ArmState armState = ArmState.armed,
  DisarmReason disarmReason = DisarmReason.none,
  int powerPct = 100,
  int? cellMinMv = 3712,
  Set<LimitCause>? limitCauses,
  Duration? sessionSec,
  Duration? hourMeterSec,
  Duration? uptimeSec,
  int? cellDeltaMv,
  SignalState? motorTempState,
  SignalState? escTempState,
  SignalState? batteryVoltageState,
}) =>
    TelemetryFrame(
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
      disarmReason: disarmReason,
      bmsMaxTempC: bmsMaxTempC,
      cellMinMv: cellMinMv,
      cellMaxMv: cellMaxMv,
      receivedAt: DateTime.utc(2026, 9, 9),
      limitCauses: limitCauses,
      sessionSec: sessionSec,
      hourMeterSec: hourMeterSec,
      uptimeSec: uptimeSec,
      cellDeltaMv: cellDeltaMv,
      motorTempState: motorTempState,
      escTempState: escTempState,
      batteryVoltageState: batteryVoltageState,
    );

/// A wire-shaped Thermal group: motor 80–100 °C, ESC 70–95 °C.
Uint8List thermalGroupBytes() {
  final d = ByteData(17);
  d.setInt32(0, 80000, Endian.little);
  d.setInt32(4, 100000, Endian.little);
  d.setInt32(8, 70000, Endian.little);
  d.setInt32(12, 95000, Endian.little);
  return d.buffer.asUint8List();
}

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('renders the headline readings when everything is present',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

    expect(find.text('87'), findsOneWidget); // SoC
    expect(find.text('ARMADO'), findsOneWidget);
    expect(find.text('CAN'), findsOneWidget); // motor temp source badge
  });

  testWidgets('a missing motor temperature shows a dash, never a zero',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(motorTempC: null, source: MotorTempSource.none),
      stale: false,
    )));

    // Scoped to the motor dial: '0' is legitimately on screen as the battery
    // dial's scale end, so a bare find.text('0') would prove nothing.
    final motorDial = find.ancestor(
      of: find.text('MOTOR'),
      matching: find.byType(Dial),
    );
    expect(find.descendant(of: motorDial, matching: find.text('–')),
        findsOneWidget);
    expect(find.descendant(of: motorDial, matching: find.text('0')),
        findsNothing);
    expect(find.text('CAN'), findsNothing);
  });

  testWidgets('a disarm code is shown in the space the status bar reserves',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(armState: ArmState.disarmed, disarmReason: DisarmReason.motorTempSourceChanged),
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

    expect(find.text('50.40'), findsOneWidget);
    expect(find.text('V'), findsOneWidget);

    await tester.tap(find.text('50.40'));
    await tester.pumpAndSettle();

    // cellMinMv is 3712, so the BMS minimum cell wins over an estimate.
    expect(find.text('3.71'), findsOneWidget);
    expect(find.text('V/cél'), findsOneWidget);
    expect(find.text('50.40'), findsNothing);
  });

  testWidgets('per-cell falls back to an estimate marked with a tilde',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(cellMinMv: null),
      stale: false,
    )));

    await tester.tap(find.text('50.40'));
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

      // Battery, motor and ESC. Power has no maximum, so a circular gauge
      // would have to invent a full scale -- it is a number, and the dial
      // count is the same whether power is present or not.
      expect(find.byType(Dial), findsNWidgets(3));
      expect(find.text('1.5'), findsOneWidget);
      expect(find.text('kW'), findsOneWidget);
    });

    testWidgets('no power reading drops the readout entirely', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerKw: null),
        stale: false,
      )));

      expect(find.text('kW'), findsNothing);
      expect(find.byType(Dial), findsNWidgets(3));
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

      // Each unavailable row reads as a dash. Checked row by row: a bare
      // find.text('0') would collide with the battery dial's scale end.
      for (final label in const ['RPM', 'Temp. máx. BMS', 'Células mín / máx']) {
        final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
        expect(find.descendant(of: row.first, matching: find.text('–')),
            findsOneWidget,
            reason: '$label should read as a dash');
      }
      expect(find.text('0 °C'), findsNothing);
    });

    testWidgets('the drawer keeps updating while it is open', (tester) async {
      // A modal route builds once from the frame captured when it was pushed
      // and never sees another. The drawer has to live in the tree that the
      // 1 Hz frames rebuild, or it silently freezes.
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(rpm: 4200), stale: false)));
      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();
      expect(find.text('4200'), findsOneWidget);

      await tester.pumpWidget(wrap(FlightScreen(frame: frame(rpm: 5100), stale: false)));
      await tester.pumpAndSettle();

      expect(find.text('5100'), findsOneWidget);
      expect(find.text('4200'), findsNothing);
    });

    testWidgets('the handle is present with no frame at all', (tester) async {
      await tester.pumpWidget(wrap(const FlightScreen(frame: null, stale: true)));

      // The band stack never changes shape, so the handle exists even with no
      // data behind it.
      expect(find.byTooltip('Mais dados'), findsOneWidget);
    });

    testWidgets('the binary-only readings reach the drawer', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(
          hourMeterSec: const Duration(seconds: 123456),
          cellDeltaMv: 33,
          uptimeSec: const Duration(seconds: 900),
          motorTempState: SignalState.valid,
          escTempState: SignalState.stale,
          batteryVoltageState: SignalState.valid,
        ),
        stale: false,
      )));
      await tester.tap(find.text('MAIS DADOS'));
      await tester.pumpAndSettle();

      expect(find.text('34:17:36'), findsOneWidget); // hour meter
      expect(find.text('33 mV'), findsOneWidget);
      expect(find.text('OK · PARADO · OK'), findsOneWidget);
    });

    testWidgets('a sentence-fed frame dashes them instead of showing zeros',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.tap(find.text('MAIS DADOS'));
      await tester.pumpAndSettle();

      expect(find.text('Horímetro'), findsOneWidget);
      // Exactly the five rows only the binary service can fill: hour meter,
      // cell delta, sensor states, uptime, firmware. An exact count is the
      // point -- findsAtLeast would still pass if a row the sentence DOES
      // carry silently started dashing.
      expect(find.text('–'), findsNWidgets(5));
    });

    testWidgets('the settings entry is present and live when disarmed',
        (tester) async {
      var opened = false;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(armState: ArmState.disarmed),
        stale: false,
        onOpenSettings: () => opened = true,
      )));
      await tester.tap(find.text('MAIS DADOS'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('CONFIGURAÇÕES'));
      await tester.tap(find.text('CONFIGURAÇÕES'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });

    testWidgets('armed leaves the entry in place but inert', (tester) async {
      var opened = false;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(armState: ArmState.armed),
        stale: false,
        onOpenSettings: () => opened = true,
      )));
      await tester.tap(find.text('MAIS DADOS'));
      await tester.pumpAndSettle();

      expect(find.text('CONFIGURAÇÕES'), findsOneWidget,
          reason: 'fixed presence, varying state');
      await tester.tap(find.text('CONFIGURAÇÕES'));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
    });

    testWidgets('a connection with no request channel leaves it inert too',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(armState: ArmState.disarmed),
        stale: false,
        onOpenSettings: null,
      )));
      await tester.tap(find.text('MAIS DADOS'));
      await tester.pumpAndSettle();

      expect(find.text('CONFIGURAÇÕES'), findsOneWidget);
    });
  });

  group('the Android back button', () {
    // There is no iOS counterpart, and the overlay is a Stack child rather
    // than a route — deliberately, so its readings keep updating — so there
    // is nothing for back to pop and it popped the app instead.
    testWidgets('closes the overlay instead of leaving', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();
      // 4200 is the rpm, which only the overlay shows.
      expect(find.text('4200'), findsOneWidget);

      await simulateSystemBack();
      await tester.pumpAndSettle();

      expect(find.text('4200'), findsNothing);
      // Still mounted: back closed the overlay, it did not pop the screen.
      expect(find.byType(FlightScreen), findsOneWidget);
    });

    testWidgets('does nothing with the overlay closed', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await simulateSystemBack();
      await tester.pumpAndSettle();

      // Leaving mid-flight is home or the app switcher, deliberately.
      expect(find.byType(FlightScreen), findsOneWidget);
      expect(find.byTooltip('Mais dados'), findsOneWidget);
    });

    testWidgets('a second back with the overlay already closed still holds',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();
      await simulateSystemBack();
      await tester.pumpAndSettle();
      await simulateSystemBack();
      await tester.pumpAndSettle();

      expect(find.byType(FlightScreen), findsOneWidget);
    });
  });

  group('the limiter chip names its cause', () {
    testWidgets('one cause leads the chip', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 80, limitCauses: {LimitCause.motorTemp}),
        stale: false,
      )));

      expect(find.text('MOT 80 %'), findsOneWidget);
      expect(find.textContaining('DISPONÍVEL'), findsNothing);
    });

    testWidgets('causes combine in a fixed order', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 70, limitCauses: {
          LimitCause.escTemp,
          LimitCause.battery,
        }),
        stale: false,
      )));

      expect(find.text('BAT ESC 70 %'), findsOneWidget);
    });

    testWidgets('a source that cannot say keeps the original wording',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 80, limitCauses: null),
        stale: false,
      )));

      expect(find.text('DISPONÍVEL 80 %'), findsOneWidget);
    });

    testWidgets('an empty cause set with full power shows no chip at all',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 100, limitCauses: const <LimitCause>{}),
        stale: false,
      )));

      // Asserted against the chip's own wording, not against '%' — the
      // throttle and battery cards carry percentages of their own.
      expect(find.textContaining('DISPONÍVEL'), findsNothing);
      expect(find.textContaining('100 %'), findsNothing);
    });
  });

  group('the flight clock', () {
    testWidgets('renders as mm:ss in the space the status row reserves',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(sessionSec: const Duration(seconds: 754)),
        stale: false,
      )));

      expect(find.text('12:34'), findsOneWidget);
    });

    testWidgets('passes an hour without wrapping to zero', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(sessionSec: const Duration(seconds: 3725)),
        stale: false,
      )));

      expect(find.text('62:05'), findsOneWidget);
    });

    testWidgets('is simply absent on the sentence path', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(sessionSec: null),
        stale: false,
      )));

      // A bare ':' would also match readings elsewhere on the panel, so this
      // asserts the clock's own shape: two digits, a colon, two digits.
      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            w.data != null &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data!)),
        findsNothing,
      );
    });
  });

  group('the thermal band reaches the dials', () {
    Dial dialWithCaption(WidgetTester tester, String caption) =>
        tester.widgetList<Dial>(find.byType(Dial)).firstWhere(
              (d) => d.caption == caption,
            );

    testWidgets('motor and ESC each get their own thresholds',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        thermalConfig: ThermalConfig.decode(thermalGroupBytes())!,
      )));

      expect(dialWithCaption(tester, 'MOTOR').bandStart, closeTo(80.0, 1e-9));
      expect(dialWithCaption(tester, 'MOTOR').bandEnd, closeTo(100.0, 1e-9));
      expect(dialWithCaption(tester, 'ESC').bandStart, closeTo(70.0, 1e-9));
      expect(dialWithCaption(tester, 'ESC').bandEnd, closeTo(95.0, 1e-9));
    });

    testWidgets('no config means no band, and nothing else changes',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        thermalConfig: null,
      )));

      expect(dialWithCaption(tester, 'MOTOR').bandStart, isNull);
      expect(dialWithCaption(tester, 'ESC').bandStart, isNull);
      expect(find.text('61'), findsOneWidget, reason: 'the reading is intact');
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

        await tester.pumpWidget(wrap(FlightScreen(
          frame: frame(
            powerPct: 70,
            limitCauses: {
              LimitCause.battery,
              LimitCause.motorTemp,
              LimitCause.escTemp,
            },
            sessionSec: const Duration(seconds: 754),
          ),
          stale: false,
          thermalConfig: ThermalConfig.decode(thermalGroupBytes()),
        )));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Also test the overlay open at this size, especially the 852x393
        // landscape where rows would overflow without scrolling.
        await tester.tap(find.text('MAIS DADOS'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('mute control', () {
    testWidgets('the drawer carries a mute control', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        muted: false,
      )));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mute-buzzer')), findsOneWidget);
      expect(find.text('SOM DO CONTROLADOR'), findsOneWidget);
      expect(find.text('LIGADO'), findsOneWidget);
    });

    testWidgets('the mute control toggles the state', (tester) async {
      bool muted = false;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        muted: muted,
        onSetMuted: (value) async {
          muted = value;
        },
      )));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();

      expect(find.text('LIGADO'), findsOneWidget);

      // Tap the switch to mute
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(muted, isTrue);
    });

    testWidgets('the label changes when muted', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        muted: true,
      )));

      await tester.tap(find.byTooltip('Mais dados'));
      await tester.pumpAndSettle();

      expect(find.text('DESLIGADO'), findsOneWidget);
      expect(find.text('LIGADO'), findsNothing);
    });
  });
}
