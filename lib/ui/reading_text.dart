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
