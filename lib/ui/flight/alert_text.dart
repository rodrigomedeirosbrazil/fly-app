import '../../protocol/telemetry_frame.dart';
import '../../state/flight_alerts.dart';

// What the alert card says, and the sentence the drawer adds.
//
// Replaces `kFaultExplanations`, which copied the web portal word for word.
// The portal is being removed, so the sentences now say what happened and
// what to do, in that order.

String _name(AlertComponent c) => switch (c) {
      AlertComponent.motor => 'MOTOR',
      AlertComponent.esc => 'ESC',
      AlertComponent.battery => 'BATERIA',
      AlertComponent.throttle => 'ACELERADOR',
      AlertComponent.power => 'POTÊNCIA',
      AlertComponent.controller => 'CONTROLADOR',
    };

/// "o motor" / "o ESC", for the middle of a sentence.
String _noun(AlertComponent c) => switch (c) {
      AlertComponent.esc => 'ESC',
      AlertComponent.battery => 'bateria',
      AlertComponent.throttle => 'acelerador',
      AlertComponent.power => 'controlador',
      AlertComponent.controller => 'controlador',
      AlertComponent.motor => 'motor',
    };

({String line1, String line2}) alertLabel(FlightAlert a) => (
      line1: _name(a.component),
      line2: switch (a.problem) {
        // The red card already says the motor stopped; the second line says
        // why, which "DESARMOU" did not -- and "BATERIA DESARMOU" was wrong.
        AlertProblem.disarmed => switch (a.reason) {
            DisarmReason.throttleWiredInvalid => 'SINAL INVÁLIDO',
            DisarmReason.throttleLinkLost => 'SEM SINAL',
            DisarmReason.motorTempSourceChanged => 'SENSOR TROCOU',
            DisarmReason.batteryVoltageLost => 'SEM TENSÃO',
            _ => 'SEM TEMPERATURA',
          },
        AlertProblem.unknownCode => 'CÓDIGO ${a.code ?? '?'}',
        AlertProblem.overheated => 'SUPERAQUECIDO',
        AlertProblem.aboveLimit => 'ACIMA DO LIMITE',
        AlertProblem.reducing => 'POTÊNCIA REDUZIDA',
        AlertProblem.critical => 'CRÍTICA',
        AlertProblem.low => 'BAIXA',
        AlertProblem.limited => 'LIMITADA',
        AlertProblem.noSensor =>
          a.component == AlertComponent.battery ? 'SEM TENSÃO' : 'SEM SENSOR',
        AlertProblem.noData => 'SEM DADOS',
        AlertProblem.noBms => 'SEM BMS',
        AlertProblem.nearLimit => 'PERTO DO LIMITE',
      },
    );

String alertSentence(FlightAlert a) {
  final noun = _noun(a.component);
  final p = a.powerPct ?? 0;
  return switch (a.problem) {
    AlertProblem.disarmed => _fault(a.reason),
    AlertProblem.unknownCode =>
      'O controlador desarmou o motor com o código ${a.code}, que este app '
          'não conhece. Atualize o app para ver a explicação.',
    AlertProblem.overheated => a.powerControlOff
        ? 'O $noun passou da temperatura máxima. O controle de potência está '
            'desligado, então o controlador não vai reduzir a potência. '
            'Alivie o acelerador.'
        : 'O $noun passou da temperatura máxima e a potência foi cortada. '
            'Alivie o acelerador e deixe esfriar.',
    AlertProblem.aboveLimit =>
      'O $noun passou do ponto de redução de potência. O controle de '
          'potência está desligado, então o controlador não vai reduzir a '
          'potência sozinho.',
    AlertProblem.reducing => a.component == AlertComponent.battery
        ? 'A bateria está baixa e o controlador limitou a potência a $p %.'
        // The app holds the ramp level through hysteresis, so it can outlast
        // the firmware's own limiting. The label stays; the sentence must not
        // claim a limit the controller has already lifted.
        : a.powerPct != null && a.powerPct! >= 100
            ? 'O $noun ainda está perto do ponto de redução, mas a potência '
                'já voltou a 100 %. Ela volta a ser reduzida se a '
                'temperatura subir.'
            : 'O $noun está quente e o controlador limitou a potência a $p %. '
                'Ela volta quando a temperatura baixar.',
    AlertProblem.critical => 'Bateria em 5 % ou menos. Pouse agora.',
    AlertProblem.low => 'Bateria em 10 % ou menos. Planeje o pouso.',
    AlertProblem.limited => 'O controlador limitou a potência a $p %.',
    AlertProblem.noSensor => switch (a.component) {
        AlertComponent.battery =>
          'A tensão da bateria não está chegando. Confira o cabo de medição '
              'de tensão antes de armar.',
        _ => 'A temperatura do $noun não está chegando. Confira o cabo do '
            'sensor antes de armar.',
      },
    AlertProblem.noData =>
      'O controlador não recebe dados do ESC. Confira o cabo de dados do ESC.',
    AlertProblem.noBms =>
      'Há um BMS configurado, mas a conexão com ele caiu.',
    AlertProblem.nearLimit =>
      'O $noun está a ${a.marginC ?? 0} °C do ponto em que a potência começa '
          'a ser reduzida.',
  };
}

String _fault(DisarmReason? r) => switch (r) {
      DisarmReason.throttleWiredInvalid =>
        'O motor foi desarmado porque o acelerador mandou uma leitura '
            'impossível. Confira o cabo e o conector do acelerador antes de '
            'armar de novo.',
      DisarmReason.throttleLinkLost =>
        'O motor foi desarmado porque o controle sem fio ficou mais de 3 '
            'segundos sem falar com o controlador. Veja se o controle está '
            'ligado e com bateria.',
      DisarmReason.motorTempLost =>
        'O motor foi desarmado porque o sensor de temperatura do motor parou '
            'de responder durante o voo. Confira o cabo do sensor antes de '
            'armar.',
      DisarmReason.motorTempSourceChanged =>
        'O motor foi desarmado porque a temperatura do motor passou a vir de '
            'outro sensor (CAN ⇄ NTC) no meio do voo. Os limites mudam com o '
            'sensor. Confira o conector do NTC antes de armar.',
      DisarmReason.escTempLost =>
        'O motor foi desarmado porque o sensor de temperatura do ESC parou de '
            'responder durante o voo. Confira o cabo de dados do ESC.',
      DisarmReason.batteryVoltageLost =>
        'O motor foi desarmado porque o controlador perdeu a leitura de '
            'tensão da bateria. Confira o cabo de medição de tensão.',
      _ => 'O motor foi desarmado por uma falha.',
    };
