/// Range validation for the settings this app can write.
///
/// This is the **fourth** hand-copied fly-controller contract in this repo,
/// after the `$XCTOD` sentence, the telemetry struct and the config groups.
/// The definition of record is `src/Settings/SettingsValidation.h`, which the
/// firmware shares between its web portal and `CFG_SET`.
///
/// Nothing checks that the two agree. `ErrBadArg` coming back from a write the
/// app accepted is the only detector, which is why the editor reports it as a
/// divergence rather than as a pilot error.
///
/// The file is split deliberately: mirrored rules first, then the ordering
/// rules the firmware does **not** have. Anyone diffing the two files needs to
/// see at a glance what is a copy and what is an addition.
library;

import 'mac_address.dart';

enum SettingsError {
  none,

  // --- Mirrored from SettingsValidation.h ---
  capacityRange,
  minVoltageRange,
  maxVoltageRange,
  dividerRatioRange,
  motorTempRange,
  escTempRange,
  motorTempSourceInvalid,
  bmsTypeInvalid,
  bmsMacMissing,
  buzzerVolumeRange,
  throttleSourceInvalid,

  // --- This app's own. See the ordering section below. ---
  invalidNumber,
  voltageOrder,
  motorTempOrder,
  escTempOrder,
  calibrationReferenceRange,
}

/// Reads a number the way a Brazilian pilot types it, and returns **null**
/// rather than a plausible zero when it cannot.
///
/// The comma is the decimal separator here, and every label on these screens
/// is written with one (`3,15 V`), so `double.parse` alone rejects exactly
/// what the pilot is most likely to enter. The old `?? 0` then turned that
/// rejection into a valid-looking reading: `0 °C` passes the 0..150 range and
/// the ordering rule, so a mistyped reduction start would have been written
/// as a band that cuts power from zero upward -- the same unusable
/// configuration the ordering rules exist to refuse.
///
/// Empty is null too. A blank field is a field the pilot has not answered,
/// not a zero they chose.
double? parseSetting(String text) {
  final trimmed = text.trim().replaceAll(',', '.');
  if (trimmed.isEmpty) return null;
  return double.tryParse(trimmed);
}

// ---------------------------------------------------------------------------
// Mirrored from the firmware. Changing a bound here without changing it there
// is divergence.
// ---------------------------------------------------------------------------

SettingsError validatePowerRanges({
  required int capacityMah,
  required int minVoltageMv,
  required int maxVoltageMv,
}) {
  if (capacityMah < 1000 || capacityMah > 65000) {
    return SettingsError.capacityRange;
  }
  if (minVoltageMv < 2500 || minVoltageMv > 63000) {
    return SettingsError.minVoltageRange;
  }
  if (maxVoltageMv < 2500 || maxVoltageMv > 63000) {
    return SettingsError.maxVoltageRange;
  }
  return SettingsError.none;
}

/// Separate in the firmware too: its web handler applies this only when the
/// field is present in the JSON body.
SettingsError validateDividerRatio(double ratio) =>
    (ratio < 1.0 || ratio > 100.0)
        ? SettingsError.dividerRatioRange
        : SettingsError.none;

/// The firmware works in millicelsius and bounds each of the four at
/// 0..150000. Expressed here in °C, which is what the form collects.
SettingsError validateThermalRanges({
  required double motorReductionStartC,
  required double motorMaxC,
  required double escReductionStartC,
  required double escMaxC,
}) {
  bool outOfRange(double c) => c < 0 || c > 150;

  if (outOfRange(motorMaxC) || outOfRange(motorReductionStartC)) {
    return SettingsError.motorTempRange;
  }
  if (outOfRange(escMaxC) || outOfRange(escReductionStartC)) {
    return SettingsError.escTempRange;
  }
  return SettingsError.none;
}

/// 0 = CAN, 1 = NTC. The firmware's highest valid value is 1.
SettingsError validateMotorTempSource(int source) =>
    source > 1 || source < 0
        ? SettingsError.motorTempSourceInvalid
        : SettingsError.none;

/// 0 none, 1 JBD, 2 Daly, 3 JK — and **a non-zero type requires an address**.
///
/// Both rules are the firmware's, from `BleControl`'s own handler. The second
/// is what makes a half-configured BMS impossible: a type with no MAC would
/// have the controller trying to reach a device it has no way to name.
///
/// The reverse is allowed. An address with type 0 reaches nothing, so it is
/// dead data rather than a broken configuration, and the portal keeps it too
/// — which lets a pilot turn a BMS off without losing the address.
SettingsError validateBms({
  required int bmsType,
  required List<int> bmsMac,
}) {
  if (bmsType < 0 || bmsType > 3) return SettingsError.bmsTypeInvalid;
  if (bmsType != 0 && isUnsetMac(bmsMac)) return SettingsError.bmsMacMissing;
  return SettingsError.none;
}

/// Buzzer volume 0..100 and throttle source 0 wired / 1 wireless.
SettingsError validateSystem({
  required int buzzerVolume,
  required int throttleSource,
}) {
  if (buzzerVolume < 0 || buzzerVolume > 100) {
    return SettingsError.buzzerVolumeRange;
  }
  if (throttleSource < 0 || throttleSource > 1) {
    return SettingsError.throttleSourceInvalid;
  }
  return SettingsError.none;
}

// ---------------------------------------------------------------------------
// This app's own rules. The firmware has none of these, and says why:
//
//   "there is deliberately NO ordering check (min < max, reductionStart <
//    maxTemp): the portal has never had one, and adding it here would
//    silently change what it accepts."
//
// That is a sound reason not to change the firmware and a bad outcome for a
// pilot. `Power::calcMotorTempLimit` returns 0 outright when start == max, and
// runs map() with a negative denominator when start > max, whose result
// constrain(..., 0, 100) pins to 0. Either way power is cut from the reduction
// start upward: `start 20 °C, max 10 °C` makes the motor unusable above 20 °C,
// and that is discovered on takeoff.
//
// So the form refuses to produce it. The protocol and the firmware are
// untouched, and the divergence covers only values nobody wants.
// ---------------------------------------------------------------------------

SettingsError validateVoltageOrder({
  required int minVoltageMv,
  required int maxVoltageMv,
}) =>
    minVoltageMv >= maxVoltageMv
        ? SettingsError.voltageOrder
        : SettingsError.none;

SettingsError validateThermalOrder({
  required double motorReductionStartC,
  required double motorMaxC,
  required double escReductionStartC,
  required double escMaxC,
}) {
  if (motorReductionStartC >= motorMaxC) return SettingsError.motorTempOrder;
  if (escReductionStartC >= escMaxC) return SettingsError.escTempOrder;
  return SettingsError.none;
}

/// The pack voltage the pilot reads off the BMS, before a ratio is derived
/// from it. The firmware never sees this number — it receives only the
/// resulting ratio — so a typo here would be written as a plausible-looking
/// calibration and caught by nothing. Bounds are the portal's.
SettingsError validateCalibrationReference(double volts) =>
    (volts < 10 || volts > 65)
        ? SettingsError.calibrationReferenceRange
        : SettingsError.none;

// ---------------------------------------------------------------------------
// What the form calls. Ranges first: an out-of-range value is the more
// specific complaint, and reporting the ordering instead would send the pilot
// to fix the wrong field.
// ---------------------------------------------------------------------------

SettingsError validatePower({
  required int capacityMah,
  required int minVoltageMv,
  required int maxVoltageMv,
  required double dividerRatio,
}) {
  final ranges = validatePowerRanges(
    capacityMah: capacityMah,
    minVoltageMv: minVoltageMv,
    maxVoltageMv: maxVoltageMv,
  );
  if (ranges != SettingsError.none) return ranges;

  final ratio = validateDividerRatio(dividerRatio);
  if (ratio != SettingsError.none) return ratio;

  return validateVoltageOrder(
    minVoltageMv: minVoltageMv,
    maxVoltageMv: maxVoltageMv,
  );
}

SettingsError validateThermal({
  required double motorReductionStartC,
  required double motorMaxC,
  required double escReductionStartC,
  required double escMaxC,
  required int motorTempSource,
}) {
  final ranges = validateThermalRanges(
    motorReductionStartC: motorReductionStartC,
    motorMaxC: motorMaxC,
    escReductionStartC: escReductionStartC,
    escMaxC: escMaxC,
  );
  if (ranges != SettingsError.none) return ranges;

  final source = validateMotorTempSource(motorTempSource);
  if (source != SettingsError.none) return source;

  return validateThermalOrder(
    motorReductionStartC: motorReductionStartC,
    motorMaxC: motorMaxC,
    escReductionStartC: escReductionStartC,
    escMaxC: escMaxC,
  );
}

/// What to show the pilot, or null when there is nothing wrong.
String? messageFor(SettingsError error) => switch (error) {
      SettingsError.none => null,
      SettingsError.capacityRange => 'Capacidade: 1000 a 65000 mAh',
      SettingsError.minVoltageRange => 'Tensão mínima: 2,5 a 63,0 V',
      SettingsError.maxVoltageRange => 'Tensão máxima: 2,5 a 63,0 V',
      SettingsError.dividerRatioRange => 'Divisor: 1,0 a 100,0',
      SettingsError.motorTempRange => 'Temperatura do motor: 0 a 150 °C',
      SettingsError.escTempRange => 'Temperatura do ESC: 0 a 150 °C',
      SettingsError.motorTempSourceInvalid => 'Origem de temperatura inválida',
      SettingsError.bmsTypeInvalid => 'Tipo de BMS inválido',
      SettingsError.bmsMacMissing =>
        'Escolha o endereço do BMS — um tipo sem endereço não conecta',
      SettingsError.buzzerVolumeRange => 'Volume do buzzer: 0 a 100',
      SettingsError.throttleSourceInvalid => 'Origem do acelerador inválida',
      SettingsError.voltageOrder =>
        'A tensão mínima precisa ser menor que a máxima',
      SettingsError.motorTempOrder =>
        'O início da redução do motor precisa ser menor que o máximo — '
            'iguais ou invertidos cortam a potência',
      SettingsError.escTempOrder =>
        'O início da redução do ESC precisa ser menor que o máximo — '
            'iguais ou invertidos cortam a potência',
      SettingsError.calibrationReferenceRange =>
        'Tensão de referência: 10 a 65 V',
      SettingsError.invalidNumber =>
        'Preencha todos os campos com números válidos',
    };
