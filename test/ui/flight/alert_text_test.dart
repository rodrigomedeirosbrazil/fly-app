import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/flight_alerts.dart';
import 'package:fly_app/ui/flight/alert_text.dart';

FlightAlert a(
  AlertComponent c,
  AlertProblem p, {
  DisarmReason? reason,
  String? code,
  int? powerPct,
  int? marginC,
  bool off = false,
}) =>
    FlightAlert(
      component: c,
      problem: p,
      severity: AlertSeverity.info,
      rank: 1,
      reason: reason,
      code: code,
      powerPct: powerPct,
      marginC: marginC,
      powerControlOff: off,
    );

void main() {
  test('labels name the component, then the problem', () {
    expect(alertLabel(a(AlertComponent.motor, AlertProblem.reducing)),
        (line1: 'MOTOR', line2: 'REDUZINDO'));
    expect(alertLabel(a(AlertComponent.esc, AlertProblem.noData)),
        (line1: 'ESC', line2: 'SEM DADOS'));
    expect(alertLabel(a(AlertComponent.battery, AlertProblem.critical)),
        (line1: 'BATERIA', line2: 'CRÍTICA'));
    expect(alertLabel(a(AlertComponent.throttle, AlertProblem.disarmed)),
        (line1: 'ACELERADOR', line2: 'DESARMOU'));
    expect(
        alertLabel(a(AlertComponent.controller, AlertProblem.unknownCode,
            code: 'NEW ERR')),
        (line1: 'CONTROLADOR', line2: 'NEW ERR'));
  });

  test('every latched fault has its own sentence', () {
    final sentences = {
      for (final r in [
        DisarmReason.throttleWiredInvalid,
        DisarmReason.throttleLinkLost,
        DisarmReason.motorTempLost,
        DisarmReason.motorTempSourceChanged,
        DisarmReason.escTempLost,
        DisarmReason.batteryVoltageLost,
      ])
        alertSentence(
            a(AlertComponent.motor, AlertProblem.disarmed, reason: r)),
    };
    expect(sentences, hasLength(6));
    expect(sentences.every((s) => s.startsWith('O motor foi desarmado')),
        isTrue);
  });

  test('sentences quote the numbers they depend on', () {
    expect(
      alertSentence(
          a(AlertComponent.motor, AlertProblem.reducing, powerPct: 70)),
      'O motor está quente e o controlador limitou a potência a 70 %. '
      'Ela volta quando a temperatura baixar.',
    );
    expect(
      alertSentence(
          a(AlertComponent.esc, AlertProblem.nearLimit, marginC: 5)),
      'O ESC está a 5 °C do ponto em que a potência começa a ser reduzida.',
    );
  });

  test('a held ramp that is back to 100 % does not claim a limit', () {
    expect(
      alertSentence(
          a(AlertComponent.motor, AlertProblem.reducing, powerPct: 100)),
      'O motor ainda está perto do ponto de redução, mas a potência já voltou '
      'a 100 %. Ela volta a ser reduzida se a temperatura subir.',
    );
    expect(
      alertSentence(
          a(AlertComponent.esc, AlertProblem.reducing, powerPct: 100)),
      'O ESC ainda está perto do ponto de redução, mas a potência já voltou '
      'a 100 %. Ela volta a ser reduzida se a temperatura subir.',
    );
  });

  test('power control off says the motor will not reduce', () {
    expect(
      alertSentence(a(AlertComponent.motor, AlertProblem.overheated, off: true)),
      contains('controle de potência está desligado'),
    );
    expect(alertLabel(a(AlertComponent.motor, AlertProblem.aboveLimit)).line2,
        'ACIMA DO LIMITE');
  });

  test('every component and problem pair produces text', () {
    for (final c in AlertComponent.values) {
      for (final p in AlertProblem.values) {
        final alert = a(c, p,
            reason: DisarmReason.motorTempLost,
            code: 'X',
            powerPct: 50,
            marginC: 3);
        expect(alertLabel(alert).line1, isNotEmpty);
        expect(alertSentence(alert), isNotEmpty);
      }
    }
  });
}
