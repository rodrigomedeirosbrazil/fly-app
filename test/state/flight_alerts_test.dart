import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/flight_alerts.dart';
import 'package:fly_app/state/gauge_levels.dart';

/// A healthy binary frame: armed, nothing limiting, every sensor valid.
TelemetryFrame f({
  int soc = 80,
  ArmState arm = ArmState.armed,
  DisarmReason reason = DisarmReason.none,
  String? rawDisarmCode,
  int powerPct = 100,
  Set<LimitCause>? limitCauses = const {},
  double? motorTempC = 50,
  double? escTempC = 40,
  SignalState? motorState = SignalState.valid,
  SignalState? escState = SignalState.valid,
  SignalState? battState = SignalState.valid,
  bool? hasTelemetry = true,
  bool? powerControl = true,
  bool? bmsConfigured = false,
  bool? bmsConnected,
  BmsLinkState? bmsLink,
}) =>
    TelemetryFrame(
      socCoulomb: soc,
      socVoltage: soc,
      voltage: 50,
      powerKw: 5,
      throttlePct: 40,
      throttleRaw: 0,
      powerPct: powerPct,
      motorTempC: motorTempC,
      motorTempSource: MotorTempSource.can,
      rpm: 4000,
      currentA: 100,
      escTempC: escTempC,
      armState: arm,
      disarmReason: reason,
      rawDisarmCode: rawDisarmCode,
      bmsMaxTempC: null,
      cellMinMv: null,
      cellMaxMv: null,
      receivedAt: DateTime.utc(2026, 10, 12),
      limitCauses: limitCauses,
      motorTempState: motorState,
      escTempState: escState,
      batteryVoltageState: battState,
      hasTelemetry: hasTelemetry,
      powerControlEnabled: powerControl,
      bmsConfigured: bmsConfigured,
      bmsConnected: bmsConnected,
      bmsLinkState: bmsLink,
    );

/// The `$XCTOD` shape: every binary-only field null.
TelemetryFrame sentence({int soc = 80, int powerPct = 100}) => f(
      soc: soc,
      powerPct: powerPct,
      limitCauses: null,
      motorState: null,
      escState: null,
      battState: null,
      hasTelemetry: null,
      powerControl: null,
      bmsConfigured: null,
    );

const thermal = ThermalConfig(
  motorReductionStartC: 80,
  motorMaxC: 110,
  escReductionStartC: 70,
  escMaxC: 100,
  motorTempSource: 0,
);

(AlertComponent, AlertProblem) top(List<FlightAlert> a) =>
    (a.first.component, a.first.problem);

void main() {
  test('a healthy frame has no alerts', () {
    expect(flightAlerts(f()), isEmpty);
  });

  group('latched faults', () {
    for (final (reason, component) in const [
      (DisarmReason.throttleWiredInvalid, AlertComponent.throttle),
      (DisarmReason.throttleLinkLost, AlertComponent.throttle),
      (DisarmReason.motorTempLost, AlertComponent.motor),
      (DisarmReason.motorTempSourceChanged, AlertComponent.motor),
      (DisarmReason.escTempLost, AlertComponent.esc),
      (DisarmReason.batteryVoltageLost, AlertComponent.battery),
    ]) {
      test('$reason names $component', () {
        final a = flightAlerts(f(arm: ArmState.disarmed, reason: reason));
        expect(top(a), (component, AlertProblem.disarmed));
        expect(a.first.severity, AlertSeverity.disarmed);
        expect(a.first.reason, reason);
      });
    }

    test('a manual disarm is not an alert', () {
      expect(
        flightAlerts(f(arm: ArmState.disarmed, reason: DisarmReason.manual)),
        isEmpty,
      );
    });

    test('a code this build does not know keeps the code', () {
      final a = flightAlerts(f(
        arm: ArmState.disarmed,
        reason: DisarmReason.unknown,
        rawDisarmCode: 'NEW ERR',
      ));
      expect(top(a), (AlertComponent.controller, AlertProblem.unknownCode));
      expect(a.first.code, 'NEW ERR');
    });
  });

  group('thermal', () {
    test('over the maximum is SUPERAQUECIDO, red', () {
      final a = flightAlerts(f(motorTempC: 112),
          motorLevel: ThermalLevel.over, thermal: thermal);
      expect(top(a), (AlertComponent.motor, AlertProblem.overheated));
      expect(a.first.severity, AlertSeverity.danger);
    });

    test('in the ramp is REDUZINDO, amber, carrying the available power', () {
      final a = flightAlerts(
        f(escTempC: 85, powerPct: 70, limitCauses: {LimitCause.escTemp}),
        escLevel: ThermalLevel.ramp,
        thermal: thermal,
      );
      expect(top(a), (AlertComponent.esc, AlertProblem.reducing));
      expect(a.first.severity, AlertSeverity.caution);
      expect(a.first.powerPct, 70);
    });

    test('a held ramp is still REDUZINDO when the firmware is at 100 %', () {
      // Hysteresis keeps the level at ramp after the controller stopped
      // limiting. The label stays (demoting to near would flicker); the
      // sentence is what has to be honest about the 100 %.
      final a = flightAlerts(
        f(motorTempC: 79, powerPct: 100, limitCauses: const {}),
        motorLevel: ThermalLevel.ramp,
        thermal: thermal,
      );
      expect(top(a), (AlertComponent.motor, AlertProblem.reducing));
      expect(a.first.powerPct, 100);
    });

    test('near is information, with the margin to the start', () {
      final a = flightAlerts(f(motorTempC: 74.2),
          motorLevel: ThermalLevel.near, thermal: thermal);
      expect(top(a), (AlertComponent.motor, AlertProblem.nearLimit));
      expect(a.first.severity, AlertSeverity.info);
      expect(a.first.marginC, 6);
    });

    test('the firmware limiting wins even with no thermal config', () {
      // CFG_GET failed or older firmware: no levels, but limitCauses is the
      // controller itself saying it is derating.
      final a = flightAlerts(
          f(powerPct: 60, limitCauses: {LimitCause.motorTemp}));
      expect(top(a), (AlertComponent.motor, AlertProblem.reducing));
    });

    test('power control off never claims a reduction', () {
      final ramp = flightAlerts(f(motorTempC: 90, powerControl: false),
          motorLevel: ThermalLevel.ramp, thermal: thermal);
      expect(top(ramp), (AlertComponent.motor, AlertProblem.aboveLimit));
      expect(ramp.first.powerControlOff, isTrue);

      final over = flightAlerts(f(motorTempC: 115, powerControl: false),
          motorLevel: ThermalLevel.over, thermal: thermal);
      expect(top(over), (AlertComponent.motor, AlertProblem.overheated));
      expect(over.first.powerControlOff, isTrue);
    });
  });

  group('battery', () {
    for (final (soc, problem) in const [
      (11, null),
      (10, AlertProblem.low),
      (6, AlertProblem.low),
      (5, AlertProblem.critical),
      (0, AlertProblem.critical),
    ]) {
      test('$soc % is $problem', () {
        final a = flightAlerts(f(soc: soc));
        if (problem == null) {
          expect(a, isEmpty);
        } else {
          expect(top(a), (AlertComponent.battery, problem));
        }
      });
    }

    test('the battery limiter is BATERIA / REDUZINDO', () {
      final a = flightAlerts(
          f(powerPct: 50, limitCauses: {LimitCause.battery}));
      expect(top(a), (AlertComponent.battery, AlertProblem.reducing));
      expect(a.first.powerPct, 50);
    });
  });

  test('a limiter this app cannot name still surfaces', () {
    final a = flightAlerts(f(powerPct: 80, limitCauses: const {}));
    expect(top(a), (AlertComponent.power, AlertProblem.limited));
  });

  group('before arming', () {
    test('a sensor that is not valid warns while disarmed', () {
      final a = flightAlerts(
          f(arm: ArmState.disarmed, motorState: SignalState.absent));
      expect(top(a), (AlertComponent.motor, AlertProblem.noSensor));
      expect(a.first.severity, AlertSeverity.caution);
    });

    test('but not while armed, where a loss is the firmware\'s to judge', () {
      expect(flightAlerts(f(motorState: SignalState.stale)), isEmpty);
    });
  });

  test('no ESC data is information', () {
    final a = flightAlerts(f(hasTelemetry: false));
    expect(top(a), (AlertComponent.esc, AlertProblem.noData));
    expect(a.first.severity, AlertSeverity.info);
  });

  group('BMS', () {
    test('configured and not connected', () {
      final a = flightAlerts(
          f(bmsConfigured: true, bmsLink: BmsLinkState.connecting));
      expect(top(a), (AlertComponent.battery, AlertProblem.noBms));
    });

    test('configured and connected is fine', () {
      expect(
        flightAlerts(f(bmsConfigured: true, bmsLink: BmsLinkState.connected)),
        isEmpty,
      );
    });

    test('older firmware without the link state falls back to the flag', () {
      final a = flightAlerts(f(bmsConfigured: true, bmsConnected: false));
      expect(top(a), (AlertComponent.battery, AlertProblem.noBms));
    });
  });

  group('priority', () {
    test('follows the table, and ties go motor, ESC, battery, throttle', () {
      final a = flightAlerts(
        f(
          soc: 4,
          motorTempC: 115,
          escTempC: 104,
          powerPct: 40,
          limitCauses: {LimitCause.battery},
          hasTelemetry: false,
        ),
        motorLevel: ThermalLevel.over,
        escLevel: ThermalLevel.over,
        thermal: thermal,
      );
      expect(a.map((x) => (x.component, x.problem)).toList(), [
        (AlertComponent.motor, AlertProblem.overheated),
        (AlertComponent.esc, AlertProblem.overheated),
        (AlertComponent.battery, AlertProblem.critical),
        (AlertComponent.battery, AlertProblem.reducing),
        (AlertComponent.esc, AlertProblem.noData),
      ]);
    });

    test('a latched fault outranks everything', () {
      final a = flightAlerts(
        f(
          arm: ArmState.disarmed,
          reason: DisarmReason.throttleLinkLost,
          soc: 3,
        ),
      );
      expect(top(a), (AlertComponent.throttle, AlertProblem.disarmed));
    });
  });

  group('the sentence path', () {
    test('says nothing it cannot know', () {
      expect(flightAlerts(sentence()), isEmpty);
    });

    test('a limit with no cause is POTÊNCIA / LIMITADA', () {
      final a = flightAlerts(sentence(powerPct: 70));
      expect(top(a), (AlertComponent.power, AlertProblem.limited));
    });

    test('battery levels still work', () {
      expect(top(flightAlerts(sentence(soc: 9))),
          (AlertComponent.battery, AlertProblem.low));
    });
  });
}
