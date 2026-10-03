import '../protocol/telemetry_frame.dart';

/// Why a reading shows a dash, from the binary source's signal state.
///
/// Null when there is nothing to explain — the reading is valid, or the
/// `$XCTOD` source carries no states at all. The portal names all three; a
/// bare dash leaves the pilot unable to tell an unplugged sensor from a
/// stale CAN frame.
String? signalNote(SignalState? s) => switch (s) {
      SignalState.stale => 'DESATUALIZADO',
      SignalState.invalid => 'INVÁLIDO',
      SignalState.absent => 'SEM SENSOR',
      _ => null,
    };

/// The portal's `FAULT_DISARM_INFO` (`TelemetryPage.h`), word for word, so a
/// pilot who learned a fault on one surface reads the same sentence on the
/// other. Manual disarm is absent on purpose: it is not a fault.
const Map<DisarmReason, ({String title, String detail})> kFaultExplanations = {
  DisarmReason.throttleWiredInvalid: (
    title: 'Desarmado: falha no acelerador (com fio)',
    detail: 'Leitura fora da faixa calibrada ou falha de leitura do ADS1115.',
  ),
  DisarmReason.throttleLinkLost: (
    title: 'Desarmado: falha no acelerador (sem fio)',
    detail: 'Link com o remote perdido por mais de 3 segundos.',
  ),
  DisarmReason.motorTempLost: (
    title: 'Desarmado: falha no sensor de temperatura do motor',
    detail: 'Estava válido ao armar e tornou-se inválido depois do armamento.',
  ),
  DisarmReason.motorTempSourceChanged: (
    title:
        'Desarmado: o sensor da temperatura do motor mudou (CAN ⇄ NTC) durante o voo',
    detail:
        'Os limites de temperatura são calibrados por sensor. Verifique o conector do NTC e o Status 5 do ESC antes de armar.',
  ),
  DisarmReason.escTempLost: (
    title: 'Desarmado: falha no sensor de temperatura do ESC',
    detail: 'Estava válido ao armar e tornou-se inválido depois do armamento.',
  ),
  DisarmReason.batteryVoltageLost: (
    title: 'Desarmado: falha no sensor de tensão da bateria',
    detail: 'Estava válido ao armar e tornou-se inválido depois do armamento.',
  ),
};
