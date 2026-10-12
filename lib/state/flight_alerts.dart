import 'dart:math' as math;

import '../protocol/config_groups.dart';
import '../protocol/telemetry_frame.dart';
import 'gauge_levels.dart';

/// What has the problem. Declaration order is the tie order inside a rank, so
/// the card never alternates between two equal alerts.
enum AlertComponent { motor, esc, battery, throttle, power, controller }

enum AlertProblem {
  disarmed,
  unknownCode,
  overheated,
  aboveLimit,
  reducing,
  critical,
  low,
  limited,
  noSensor,
  noData,
  noBms,
  nearLimit,
}

/// Most severe first. Matches the gauge colours: [danger] is red, [caution]
/// amber, [info] neutral; [disarmed] is red with a filled card, because the
/// motor will not run.
enum AlertSeverity { disarmed, danger, caution, info }

class FlightAlert {
  const FlightAlert({
    required this.component,
    required this.problem,
    required this.severity,
    required this.rank,
    this.reason,
    this.code,
    this.powerPct,
    this.marginC,
    this.powerControlOff = false,
  });

  final AlertComponent component;
  final AlertProblem problem;
  final AlertSeverity severity;

  /// 1 is most important. The spec's priority table, verbatim.
  final int rank;

  /// The latched fault, for [AlertProblem.disarmed].
  final DisarmReason? reason;

  /// The firmware's own code, for [AlertProblem.unknownCode].
  final String? code;

  /// Available power, for the alerts whose sentence quotes it.
  final int? powerPct;

  /// Degrees left before reduction starts, for [AlertProblem.nearLimit].
  final int? marginC;

  /// The firmware is not derating: its power control is off.
  final bool powerControlOff;
}

const _faultComponent = {
  DisarmReason.throttleWiredInvalid: AlertComponent.throttle,
  DisarmReason.throttleLinkLost: AlertComponent.throttle,
  DisarmReason.motorTempLost: AlertComponent.motor,
  DisarmReason.motorTempSourceChanged: AlertComponent.motor,
  DisarmReason.escTempLost: AlertComponent.esc,
  DisarmReason.batteryVoltageLost: AlertComponent.battery,
};

/// Every active alert, most important first.
///
/// Uses only what the frame can say: on the `$XCTOD` path the binary-only
/// fields are null and their alerts simply do not arise — a missing field is
/// never read as a fault or as an all-clear. [motorLevel] and [escLevel] are
/// null when no thermal band is known.
List<FlightAlert> flightAlerts(
  TelemetryFrame f, {
  ThermalLevel? motorLevel,
  ThermalLevel? escLevel,
  ThermalConfig? thermal,
}) {
  final out = <FlightAlert>[];

  // 1. A latched fault: the controller disarmed itself.
  if (f.disarmCode != null) {
    final component = _faultComponent[f.disarmReason];
    out.add(component == null
        ? FlightAlert(
            component: AlertComponent.controller,
            problem: AlertProblem.unknownCode,
            severity: AlertSeverity.disarmed,
            rank: 1,
            code: f.disarmCode,
          )
        : FlightAlert(
            component: component,
            problem: AlertProblem.disarmed,
            severity: AlertSeverity.disarmed,
            rank: 1,
            reason: f.disarmReason,
          ));
  }

  // 2, 4, 10. Temperatures.
  final controlOff = f.powerControlEnabled == false;
  void thermalAlert(
    AlertComponent component,
    ThermalLevel? level,
    LimitCause cause,
    double? temp,
    double? start,
  ) {
    // The firmware saying it is derating is the truth about a reduction,
    // whatever this app computed — including when it has no config at all.
    final limiting = f.limitCauses?.contains(cause) ?? false;
    if (level == ThermalLevel.over) {
      out.add(FlightAlert(
        component: component,
        problem: AlertProblem.overheated,
        severity: AlertSeverity.danger,
        rank: 2,
        powerControlOff: controlOff,
      ));
    } else if (level == ThermalLevel.ramp || limiting) {
      final notReducing = controlOff && !limiting;
      out.add(FlightAlert(
        component: component,
        problem: notReducing ? AlertProblem.aboveLimit : AlertProblem.reducing,
        severity: AlertSeverity.caution,
        rank: 4,
        powerPct: f.powerPct,
        powerControlOff: notReducing,
      ));
    } else if (level == ThermalLevel.near && temp != null && start != null) {
      out.add(FlightAlert(
        component: component,
        problem: AlertProblem.nearLimit,
        severity: AlertSeverity.info,
        rank: 10,
        marginC: math.max(0, (start - temp).ceil()),
      ));
    }
  }

  thermalAlert(AlertComponent.motor, motorLevel, LimitCause.motorTemp,
      f.motorTempC, thermal?.motorBandStartC);
  thermalAlert(AlertComponent.esc, escLevel, LimitCause.escTemp, f.escTempC,
      thermal?.escBandStartC);

  // 3, 6. State of charge — the same zones the battery dial is drawn in.
  switch (batteryZone(f.socCoulomb.toDouble())) {
    case GaugeZone.danger:
      out.add(const FlightAlert(
        component: AlertComponent.battery,
        problem: AlertProblem.critical,
        severity: AlertSeverity.danger,
        rank: 3,
      ));
    case GaugeZone.caution:
      out.add(const FlightAlert(
        component: AlertComponent.battery,
        problem: AlertProblem.low,
        severity: AlertSeverity.caution,
        rank: 6,
      ));
    case GaugeZone.normal:
      break;
  }

  // 5. Limiters other than temperature.
  final causes = f.limitCauses;
  if (causes != null && causes.contains(LimitCause.battery)) {
    out.add(FlightAlert(
      component: AlertComponent.battery,
      problem: AlertProblem.reducing,
      severity: AlertSeverity.caution,
      rank: 5,
      powerPct: f.powerPct,
    ));
  } else if (f.isLimited && (causes == null || causes.isEmpty)) {
    // The sentence cannot name a cause, and a binary frame may carry a
    // limiter this build does not know. Either way: say power is limited.
    out.add(FlightAlert(
      component: AlertComponent.power,
      problem: AlertProblem.limited,
      severity: AlertSeverity.caution,
      rank: 5,
      powerPct: f.powerPct,
    ));
  }

  // 7. Before arming, a reading that is not valid. Armed, a loss is the
  // firmware's to judge, and it disarms with its own reason.
  if (!f.isArmed) {
    for (final (component, state) in [
      (AlertComponent.motor, f.motorTempState),
      (AlertComponent.esc, f.escTempState),
      (AlertComponent.battery, f.batteryVoltageState),
    ]) {
      if (state != null && state != SignalState.valid) {
        out.add(FlightAlert(
          component: component,
          problem: AlertProblem.noSensor,
          severity: AlertSeverity.caution,
          rank: 7,
        ));
      }
    }
  }

  // 8. The controller hears nothing from the ESC.
  if (f.hasTelemetry == false) {
    out.add(const FlightAlert(
      component: AlertComponent.esc,
      problem: AlertProblem.noData,
      severity: AlertSeverity.info,
      rank: 8,
    ));
  }

  // 9. A configured BMS that is not connected.
  if (f.bmsConfigured == true) {
    final link = f.bmsLinkState;
    final connected = link == null
        ? f.bmsConnected == true
        : link == BmsLinkState.connected;
    if (!connected) {
      out.add(const FlightAlert(
        component: AlertComponent.battery,
        problem: AlertProblem.noBms,
        severity: AlertSeverity.info,
        rank: 9,
      ));
    }
  }

  out.sort((a, b) => a.rank != b.rank
      ? a.rank.compareTo(b.rank)
      : a.component.index.compareTo(b.component.index));
  return out;
}
