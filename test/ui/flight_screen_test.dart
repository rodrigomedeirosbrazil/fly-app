import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/ui/flight/panel_prefs.dart';
import 'package:fly_app/ui/flight_screen.dart';
import 'package:fly_app/ui/widgets/dial.dart';
import 'package:fly_app/ui/widgets/status_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? rawDisarmCode,
  int powerPct = 100,
  int? cellMinMv = 3712,
  Set<LimitCause>? limitCauses,
  Duration? sessionSec,
  int? remainingMin,
  bool remainingByVoltage = false,
  Duration? hourMeterSec,
  Duration? uptimeSec,
  int? cellDeltaMv,
  SignalState? motorTempState,
  SignalState? escTempState,
  SignalState? batteryVoltageState,
  bool? hasTelemetry,
  bool? bmsConnected,
  bool? bmsConfigured,
  BmsLinkState? bmsLinkState,
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
      rawDisarmCode: rawDisarmCode,
      bmsMaxTempC: bmsMaxTempC,
      cellMinMv: cellMinMv,
      cellMaxMv: cellMaxMv,
      receivedAt: DateTime.utc(2026, 9, 9),
      limitCauses: limitCauses,
      sessionSec: sessionSec,
      remainingMin: remainingMin,
      remainingByVoltage: remainingByVoltage,
      hourMeterSec: hourMeterSec,
      uptimeSec: uptimeSec,
      cellDeltaMv: cellDeltaMv,
      motorTempState: motorTempState,
      escTempState: escTempState,
      batteryVoltageState: batteryVoltageState,
      hasTelemetry: hasTelemetry,
      bmsConnected: bmsConnected,
      bmsConfigured: bmsConfigured,
      bmsLinkState: bmsLinkState,
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

Widget wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3FB950),
          secondary: Color(0xFF3B82F6),
          error: Color(0xFFF85149),
          tertiary: Color(0xFFD29922),
          surfaceContainerHighest: Color(0xFF272D38),
        ),
      ),
      home: child,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    final motorDial = find.byKey(const Key('gauge-motor'));
    expect(find.descendant(of: motorDial, matching: find.text('–')),
        findsOneWidget);
    expect(find.descendant(of: motorDial, matching: find.text('0')),
        findsNothing);
    expect(find.text('CAN'), findsNothing);
  });

  testWidgets('a stale motor sensor says so under the dash', (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(
        motorTempC: null,
        source: MotorTempSource.none,
        motorTempState: SignalState.stale,
      ),
      stale: false,
    )));

    final motorDial = find.byKey(const Key('gauge-motor'));
    expect(find.descendant(of: motorDial, matching: find.text('DESATUALIZADO')),
        findsOneWidget);
  });

  testWidgets('an invalid voltage sensor says so beside the dash',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(voltage: null, batteryVoltageState: SignalState.invalid),
      stale: false,
    )));

    expect(find.text('INVÁLIDO'), findsOneWidget);
  });

  testWidgets('a valid reading carries no note', (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(motorTempState: SignalState.valid),
      stale: false,
    )));

    expect(find.text('DESATUALIZADO'), findsNothing);
    expect(find.text('INVÁLIDO'), findsNothing);
    expect(find.text('SEM SENSOR'), findsNothing);
  });

  testWidgets('a disarm code is shown in the space the status bar reserves',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(armState: ArmState.disarmed, disarmReason: DisarmReason.motorTempSourceChanged),
      stale: false,
    )));

    expect(find.text('MOT SRC'), findsOneWidget);
  });

  testWidgets('stale link replaces every reading with SEM SINAL',
      (tester) async {
    await tester.pumpWidget(wrap(const FlightScreen(frame: null, stale: true)));

    expect(find.text('SEM SINAL'), findsOneWidget);
    expect(find.text('87'), findsNothing);
  });

  group('status chip', () {
    final silentSince = DateTime.utc(2026, 9, 9, 12);
    DateTime fortySecondsLater() => silentSince.add(const Duration(seconds: 40));

    testWidgets('a stale link that is retrying says RECONECTANDO',
        (tester) async {
      await tester.pumpWidget(wrap(const FlightScreen(
        frame: null,
        stale: true,
        linkStatus: LinkStatus.connecting,
      )));

      expect(find.text('RECONECTANDO'), findsOneWidget);
      expect(find.text('SEM SINAL'), findsNothing);
    });

    testWidgets('tapping it while stale offers reconnect and disconnect',
        (tester) async {
      var reconnects = 0;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: null,
        stale: true,
        lastFrameAt: silentSince,
        now: fortySecondsLater,
        onReconnect: () => reconnects++,
        onDisconnect: () {},
      )));

      await tester.tap(find.text('SEM SINAL'));
      await tester.pumpAndSettle();

      expect(find.text('Último dado há 40 s.'), findsOneWidget);
      await tester.tap(find.text('Reconectar'));
      await tester.pumpAndSettle();
      expect(reconnects, 1);
    });

    testWidgets('disconnecting needs the confirmation, not just the tap',
        (tester) async {
      var disconnects = 0;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(armState: ArmState.disarmed),
        stale: false,
        onDisconnect: () => disconnects++,
      )));

      await tester.tap(find.text('DESARMADO'));
      await tester.pumpAndSettle();
      expect(disconnects, 0);
      expect(find.text('Reconectar'), findsNothing); // live link: nothing to retry

      await tester.tap(find.text('Desconectar'));
      await tester.pumpAndSettle();
      expect(disconnects, 1);
    });

    testWidgets('cancel leaves the link alone', (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: null,
        stale: true,
        onReconnect: () => calls++,
        onDisconnect: () => calls++,
      )));

      await tester.tap(find.text('SEM SINAL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(calls, 0);
    });

    testWidgets('an armed last frame is called out before disconnecting',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: null,
        stale: true,
        lastFrameAt: silentSince,
        lastFrameArmed: true,
        now: fortySecondsLater,
        onDisconnect: () {},
      )));

      await tester.tap(find.text('SEM SINAL'));
      await tester.pumpAndSettle();
      expect(find.textContaining('dizia ARMADO'), findsOneWidget);
    });

    testWidgets('without a disconnect handler the chip is inert',
        (tester) async {
      await tester.pumpWidget(wrap(const FlightScreen(frame: null, stale: true)));

      await tester.tap(find.text('SEM SINAL'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets('the toggle survives a missing voltage without crashing',
      (tester) async {
    await tester.pumpWidget(wrap(FlightScreen(
      frame: frame(voltage: null),
      stale: false,
    )));

    expect(find.text('–'), findsWidgets);
  });

  group('the drawer', () {
    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists every alert with its sentence', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(
          powerPct: 50,
          limitCauses: {LimitCause.battery},
          hasTelemetry: false,
        ),
        stale: false,
      )));
      await open(tester);

      final list = find.byKey(const Key('drawer-alerts'));
      expect(find.descendant(of: list, matching: find.text('BATERIA · REDUZINDO')),
          findsOneWidget);
      expect(
          find.descendant(
              of: list,
              matching: find.text(
                  'A bateria está baixa e o controlador limitou a potência a 50 %.')),
          findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('ESC · SEM DADOS')),
          findsOneWidget);
    });

    testWidgets('says all is well when it is', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
          frame: frame(hasTelemetry: true), stale: false)));
      await open(tester);
      expect(find.text('Nenhum alerta'), findsOneWidget);
    });

    testWidgets('the latched fault is explained in the new words',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(
          armState: ArmState.disarmed,
          disarmReason: DisarmReason.throttleLinkLost,
        ),
        stale: false,
      )));
      await open(tester);
      expect(find.textContaining('controle sem fio ficou mais de 3 segundos'),
          findsOneWidget);
    });

    testWidgets('keeps updating while open', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 70, limitCauses: {LimitCause.battery}),
        stale: false,
      )));
      await open(tester);
      expect(find.textContaining('a 70 %'), findsOneWidget);

      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 40, limitCauses: {LimitCause.battery}),
        stale: false,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('a 40 %'), findsOneWidget);
      expect(find.textContaining('a 70 %'), findsNothing);
    });

    testWidgets('carries no telemetry readings any more', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await open(tester);
      expect(find.text('Horímetro'), findsNothing);
      expect(find.text('Detalhes da telemetria'), findsNothing);
    });

    testWidgets('the bar is present with no frame at all', (tester) async {
      await tester.pumpWidget(
          wrap(const FlightScreen(frame: null, stale: true)));
      expect(find.byKey(const Key('drawer-bar')), findsOneWidget);
    });


    testWidgets('the settings entry is present and live when disarmed',
        (tester) async {
      var opened = false;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(armState: ArmState.disarmed),
        stale: false,
        onOpenSettings: () => opened = true,
      )));
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('settings-entry')));
      await tester.tap(find.byKey(const Key('settings-entry')));
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
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-entry')), findsOneWidget,
          reason: 'fixed presence, varying state');
      await tester.tap(find.byKey(const Key('settings-entry')));
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
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-entry')), findsOneWidget);
    });
  });

  group('the Android back button', () {
    // There is no iOS counterpart, and the overlay is a Stack child rather
    // than a route — deliberately, so its readings keep updating — so there
    // is nothing for back to pop and it popped the app instead.
    testWidgets('closes the overlay instead of leaving', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drawer')), findsOneWidget);

      await simulateSystemBack();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('drawer')), findsNothing);
      // Still mounted: back closed the overlay, it did not pop the screen.
      expect(find.byType(FlightScreen), findsOneWidget);
    });

    testWidgets('does nothing with the overlay closed', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await simulateSystemBack();
      await tester.pumpAndSettle();

      // Leaving mid-flight is home or the app switcher, deliberately.
      expect(find.byType(FlightScreen), findsOneWidget);
      expect(find.byKey(const Key('drawer-bar')), findsOneWidget);
    });

    testWidgets('a second back with the overlay already closed still holds',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();
      await simulateSystemBack();
      await tester.pumpAndSettle();
      await simulateSystemBack();
      await tester.pumpAndSettle();

      expect(find.byType(FlightScreen), findsOneWidget);
    });
  });

  group('portal parity on the flight screen', () {
    testWidgets('a limited frame marks the ceiling on the throttle bar',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 60, limitCauses: {LimitCause.motorTemp}),
        stale: false,
      )));
      expect(find.byKey(const Key('throttle-ceiling')), findsOneWidget);
    });

    testWidgets('an unlimited frame has no ceiling marker', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      expect(find.byKey(const Key('throttle-ceiling')), findsNothing);
    });

  });

  group('the portrait panel', () {
    testWidgets('remaining time shows the estimate and its source',
        (tester) async {
      Finder inCard(String t) => find.descendant(
          of: find.byKey(const Key('time-remaining')), matching: find.text(t));
      await tester.pumpWidget(
          wrap(FlightScreen(frame: frame(remainingMin: 23), stale: false)));
      expect(inCard('23'), findsOneWidget);
      expect(inCard('min'), findsOneWidget);
      await tester.pumpWidget(wrap(FlightScreen(
          frame: frame(remainingMin: 9, remainingByVoltage: true),
          stale: false)));
      expect(inCard('min · tensão'), findsOneWidget);
    });

    testWidgets('times sit under the battery, remaining waits for firmware',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(sessionSec: const Duration(seconds: 330)),
        stale: false,
      )));
      expect(find.text('05:30'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('time-remaining')),
              matching: find.text('indisponível')),
          findsOneWidget);
    });

    testWidgets('the throttle is now ACELERAÇÃO', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      expect(find.text('ACELERAÇÃO'), findsOneWidget);
      expect(find.text('ACELERADOR'), findsNothing);
    });

    testWidgets('the ESC badge follows the board', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(source: MotorTempSource.ntc),
        stale: false,
        controllerType: ControllerType.tmotor,
      )));
      final esc = find.byKey(const Key('gauge-esc'));
      expect(find.descendant(of: esc, matching: find.text('CAN')),
          findsOneWidget);
    });

    testWidgets('a motor in the ramp turns its whole arc amber',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(motorTempC: 85),
        stale: false,
        thermalConfig: ThermalConfig.decode(thermalGroupBytes())!,
      )));
      final dial = tester.widget<Dial>(find.byKey(const Key('gauge-motor')));
      expect(dial.color, const Color(0xFFD29922));
      expect(dial.stripes.map((s) => s.at), [80.0, 100.0]);
    });

    testWidgets('the power/current choice survives a restart', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gauge-power')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gauge-current')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gauge-current')), findsOneWidget);
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
      Size(640, 360),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
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
        await tester.tap(find.byKey(const Key('drawer-bar')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('landscape', () {
    void landscape(WidgetTester tester) {
      tester.view.physicalSize = const Size(852, 393);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('battery on the left, the rest on the right', (tester) async {
      landscape(tester);
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      final battery = tester.getCenter(find.byKey(const Key('gauge-battery')));
      final motor = tester.getCenter(find.byKey(const Key('gauge-motor')));
      expect(battery.dx, lessThan(852 * 0.45));
      expect(motor.dx, greaterThan(852 * 0.45));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the drawer leaves the battery uncovered', (tester) async {
      landscape(tester);
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('drawer'))).dx,
          greaterThan(852 * 0.35));
    });
  });

  group('orientation lock', () {
    late List<MethodCall> calls;

    setUp(() => calls = []);

    void capture(WidgetTester tester) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    List<Object?> lastOrientations() => calls
        .lastWhere((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .arguments as List<Object?>;

    testWidgets('defaults to portrait', (tester) async {
      capture(tester);
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.pumpAndSettle();
      expect(lastOrientations(), ['DeviceOrientation.portraitUp']);
    });

    testWidgets('the drawer choice is applied and remembered', (tester) async {
      capture(tester);
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Horizontal'));
      await tester.pumpAndSettle();
      expect(lastOrientations(), [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      expect((await PanelPrefs.load()).orientation,
          OrientationChoice.landscape);
    });

    testWidgets('automatic hands rotation back to the system', (tester) async {
      capture(tester);
      SharedPreferences.setMockInitialValues({'orientation': 'auto'});
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await tester.pumpAndSettle();
      expect(lastOrientations(), isEmpty);
    });
  });

  group('the bottom row follows the aircraft', () {
    testWidgets('XAG without a BMS shows the wide voltage, no RPM',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(bmsConfigured: false),
        stale: false,
        controllerType: ControllerType.xag,
      )));
      expect(find.byKey(const Key('voltage-wide')), findsOneWidget);
      expect(find.byKey(const Key('gauge-rpm')), findsNothing);
    });

    testWidgets('XAG with a BMS shows power, no RPM', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(bmsConfigured: true),
        stale: false,
        controllerType: ControllerType.xag,
      )));
      expect(find.byKey(const Key('gauge-power')), findsOneWidget);
      expect(find.byKey(const Key('gauge-rpm')), findsNothing);
    });

    testWidgets('XAG with a BMS keeps its row when the link goes stale',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(bmsConfigured: true),
        stale: false,
        controllerType: ControllerType.xag,
      )));
      expect(find.byKey(const Key('gauge-power')), findsOneWidget);

      // FlyApp hands over a null frame once the last one is older than 3 s.
      await tester.pumpWidget(wrap(FlightScreen(
        frame: null,
        stale: true,
        controllerType: ControllerType.xag,
      )));
      expect(find.byKey(const Key('gauge-power')), findsOneWidget);
      expect(find.byKey(const Key('voltage-wide')), findsNothing);
    });

    testWidgets('Tmotor shows RPM', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        controllerType: ControllerType.tmotor,
      )));
      expect(find.byKey(const Key('gauge-rpm')), findsOneWidget);
    });

    testWidgets('a reading lost mid-use does not reflow the row',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        controllerType: ControllerType.tmotor,
      )));
      expect(find.byKey(const Key('gauge-power')), findsOneWidget);
      expect(find.byKey(const Key('gauge-rpm')), findsOneWidget);

      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerKw: null, rpm: null, hasTelemetry: false),
        stale: false,
        controllerType: ControllerType.tmotor,
      )));
      expect(find.byKey(const Key('gauge-power')), findsOneWidget);
      expect(find.byKey(const Key('gauge-rpm')), findsOneWidget);
      expect(find.text('SEM DADOS'), findsWidgets);
    });
  });

  group('mute control', () {
    testWidgets('the drawer carries a mute control', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        muted: false,
      )));

      await tester.tap(find.byKey(const Key('drawer-bar')));
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

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.text('LIGADO'), findsOneWidget);

      // The extra drawer rows push the control below the scroll fold.
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();

      // Tap the switch to mute
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(muted, isTrue);
    });

    testWidgets('a speaker failure is named, not swallowed', (tester) async {
      // This subsystem reached hardware inaudible twice, and both times the
      // app said nothing -- so a silent phone and a quiet aircraft looked
      // identical. The pilot is the only one who can tell them apart.
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        audioError: 'PlatformException(DarwinAudioError, ...)',
      )));

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audio-error')), findsOneWidget);
      expect(find.textContaining('Falha no som'), findsOneWidget);
    });

    testWidgets('no failure, no line', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audio-error')), findsNothing);
    });

    testWidgets('the label changes when muted', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        muted: true,
      )));

      await tester.tap(find.byKey(const Key('drawer-bar')));
      await tester.pumpAndSettle();

      expect(find.text('DESLIGADO'), findsOneWidget);
      expect(find.text('LIGADO'), findsNothing);
    });
  });

  group('the alert card', () {
    testWidgets('a healthy frame says NENHUM ALERTA', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(hasTelemetry: true),
        stale: false,
      )));
      expect(find.text('NENHUM'), findsOneWidget);
    });

    testWidgets('a limited frame names the cause', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 70, limitCauses: {LimitCause.battery}),
        stale: false,
      )));
      expect(find.text('REDUZINDO'), findsOneWidget);
      // find.text matches a Text.rich by its plain text.
      expect(find.text('CONFIGURAÇÕES · 1 ALERTA'), findsOneWidget);
    });

    testWidgets('no ESC data is an alert, not a chip', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(hasTelemetry: false),
        stale: false,
      )));
      expect(find.text('SEM DADOS'), findsOneWidget);
      expect(find.byType(StatusChip), findsOneWidget,
          reason: 'only the state chip is left in the status row');
    });

    testWidgets('a stale link shows no all-clear', (tester) async {
      await tester.pumpWidget(
          wrap(const FlightScreen(frame: null, stale: true)));
      expect(find.text('NENHUM'), findsNothing);
    });

    testWidgets('tapping the card opens the drawer', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(powerPct: 70, limitCauses: {LimitCause.battery}),
        stale: false,
      )));
      await tester.tap(find.byKey(const Key('alert-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mute-buzzer')), findsOneWidget);
    });

    testWidgets('hysteresis holds across frames, not across rebuilds',
        (tester) async {
      final config = ThermalConfig.decode(thermalGroupBytes())!; // motor 80–100
      Future<void> show(double motor) => tester.pumpWidget(wrap(FlightScreen(
            frame: frame(motorTempC: motor, motorTempState: SignalState.valid),
            stale: false,
            thermalConfig: config,
          )));

      await show(81);
      expect(find.text('REDUZINDO'), findsOneWidget);
      await show(79); // within 2 °C below the start
      expect(find.text('REDUZINDO'), findsOneWidget);
      await show(77);
      expect(find.text('PERTO DO LIMITE'), findsOneWidget);
    });

    testWidgets('a config that arrives after the frame is applied to it',
        (tester) async {
      // The same frame instance both times: the thermal config comes a moment
      // after the first frame, and the alerts must not wait for the next one.
      final f = frame(motorTempC: 85, motorTempState: SignalState.valid);
      await tester.pumpWidget(wrap(FlightScreen(frame: f, stale: false)));
      expect(find.text('REDUZINDO'), findsNothing);

      await tester.pumpWidget(wrap(FlightScreen(
        frame: f,
        stale: false,
        thermalConfig: ThermalConfig.decode(thermalGroupBytes())!,
      )));
      expect(find.text('REDUZINDO'), findsOneWidget);
    });
  });

  group('details', () {
    // The default test surface is 800x600, so 40 % is 240 px.
    Future<void> pull(WidgetTester tester, double dy) async {
      await tester.drag(find.byKey(const Key('details-handle')), Offset(0, dy));
      await tester.pumpAndSettle();
    }

    testWidgets('a short pull springs back', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 150);
      expect(find.byKey(const Key('details-view')), findsNothing);
    });

    testWidgets('past 40 % it opens', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      expect(find.byKey(const Key('details-view')), findsOneWidget);
    });

    testWidgets('stays live while open', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      expect(find.text('50,4 V'), findsOneWidget);

      await tester.pumpWidget(
          wrap(FlightScreen(frame: frame(voltage: 49.1), stale: false)));
      await tester.pumpAndSettle();
      expect(find.text('49,1 V'), findsOneWidget);
      expect(find.text('50,4 V'), findsNothing);
    });

    testWidgets('closes with the button', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      await tester.tap(find.byKey(const Key('details-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-view')), findsNothing);
    });

    testWidgets('closes by pulling the bottom handle up', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      await tester.drag(find.byKey(const Key('details-bottom-handle')),
          const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-view')), findsNothing);
    });

    testWidgets('back closes details first, then nothing leaves',
        (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      await simulateSystemBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-view')), findsNothing);
      expect(find.byType(FlightScreen), findsOneWidget);
    });

    testWidgets(
      'a pull just under the threshold springs back, just over opens',
      (tester) async {
        await tester.pumpWidget(
          wrap(FlightScreen(frame: frame(), stale: false)),
        );
        await pull(tester, 220);
        expect(find.byKey(const Key('details-view')), findsNothing);
        await pull(tester, 280);
        expect(find.byKey(const Key('details-view')), findsOneWidget);
      },
    );

    testWidgets('a short pull up on the bottom handle springs back open', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      await tester.drag(
        find.byKey(const Key('details-bottom-handle')),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-view')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('details-view'))).dy, 0);
    });

    testWidgets('a cancelled pull from closed settles closed', (tester) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('details-handle'))),
      );
      await g.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(find.byKey(const Key('details-view')), findsOneWidget);
      await g.cancel();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('details-view')), findsNothing);
    });

    testWidgets('a cancelled pull on the status row past 40 % settles open', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('details-handle'))),
      );
      await g.moveBy(const Offset(0, 400));
      await tester.pump();
      await g.cancel();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('details-view'))).dy, 0);
    });

    testWidgets('a cancelled pull on the bottom handle settles open', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(FlightScreen(frame: frame(), stale: false)));
      await pull(tester, 400);
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('details-bottom-handle'))),
      );
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await g.cancel();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('details-view'))).dy, 0);
    });

    testWidgets('the handle bar does not take taps from a long chip', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(
          FlightScreen(
            frame: null,
            stale: true,
            linkStatus: LinkStatus.connecting,
            onDisconnect: () {},
          ),
        ),
      );
      final chip = tester.getRect(find.byType(StatusChip));
      final bar = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('details-handle')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.constraints?.maxWidth == 40 &&
                w.constraints?.maxHeight == 5,
          ),
        ),
      );
      // The geometry this test exists for: the bar lies over the chip.
      expect(chip.contains(bar.topLeft), isTrue);
      expect(chip.contains(bar.bottomRight), isTrue);
      await tester.tapAt(bar.center);
      await tester.pumpAndSettle();
      expect(find.text('Sem dados do controlador'), findsOneWidget);
    });

    testWidgets('a tap on the state chip still offers the link dialog',
        (tester) async {
      var disconnects = 0;
      await tester.pumpWidget(wrap(FlightScreen(
        frame: frame(),
        stale: false,
        onDisconnect: () => disconnects++,
      )));
      await tester.tap(find.text('ARMADO'));
      await tester.pumpAndSettle();
      expect(find.text('Desconectar do controlador?'), findsOneWidget);
    });
  });
}
