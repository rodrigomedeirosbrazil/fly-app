import '../protocol/control_info.dart';

/// Which cards the bottom row carries.
///
/// From fly-controller's `TelemetryAvailability.cpp`: current exists with a
/// current sensor and ESC data (Tmotor and Hobbywing — `BoardConfig.cpp`,
/// `hasCurrentSensor`), **or** BMS data; power exists exactly when current
/// does; RPM exists with a current sensor and ESC data, so on Tmotor and
/// Hobbywing.
/// **A hand-copied fly-controller fact**, like the wire layouts.
enum BottomRowLayout {
  /// Voltage, power/current, RPM.
  full,

  /// Voltage, power/current — current comes from the BMS.
  noRpm,

  /// One wide voltage card: pack and per cell side by side.
  voltageOnly,
}

/// Decided by facts that cannot change in flight: the board type from `INFO`
/// and whether a BMS is configured (settings are refused while armed). So the
/// row never reflows under a pilot reading it. A reading that disappears in
/// use keeps its card and shows its reason instead.
BottomRowLayout bottomRowFor({
  required ControllerType type,
  required bool bmsConfigured,
}) =>
    switch (type) {
      ControllerType.xag =>
        bmsConfigured ? BottomRowLayout.noRpm : BottomRowLayout.voltageOnly,
      ControllerType.tmotor ||
      ControllerType.hobbywing ||
      ControllerType.unknown =>
        BottomRowLayout.full,
    };

/// Where the ESC temperature comes from. The telemetry does not say; the
/// board does — Tmotor and Hobbywing over CAN, XAG from the NTC on
/// `ADS1115_ESC_TEMP_CHANNEL` (fly-controller `config.h`, XAG only). Another
/// hand-copied fact.
String? escTempSourceFor(ControllerType type) => switch (type) {
      ControllerType.tmotor || ControllerType.hobbywing => 'CAN',
      ControllerType.xag => 'NTC',
      ControllerType.unknown => null,
    };
