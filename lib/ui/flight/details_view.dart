import 'package:flutter/material.dart';

import '../../protocol/config_groups.dart';
import '../../protocol/control_info.dart';
import '../../protocol/telemetry_frame.dart';
import '../../state/flight_alerts.dart';
import '../../state/gauge_levels.dart';
import '../../state/panel_layout_policy.dart';
import '../../state/telemetry_source_policy.dart';
import '../widgets/status_chip.dart';
import 'alert_card.dart';
import 'alert_text.dart';
import 'number_format.dart';
import 'panel_cards.dart';

/// Pulled past this fraction of the screen height, details open; released
/// earlier, they spring back. A grazed touch with a glove must not replace
/// the panel.
const double kDetailsOpenFraction = 0.4;

/// Everything the pilot does not need every second, by component.
///
/// A `Stack` child of the flight screen, like the drawer, so it is rebuilt by
/// every frame and its numbers stay live. The strip on top stays put while
/// the list scrolls: open in flight, the state, the battery and the worst
/// alert are never out of sight.
class DetailsView extends StatelessWidget {
  const DetailsView({
    super.key,
    required this.frame,
    required this.stale,
    this.reconnecting = false,
    required this.alerts,
    this.thermalConfig,
    this.controllerType = ControllerType.unknown,
    this.telemetrySource,
    this.rejectedFrames = 0,
    this.firmwareVersion,
    this.firmwareBuild,
    required this.onClose,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.onHandleDragCancel,
    this.columns = 1,
  });

  final TelemetryFrame? frame;
  final bool stale;

  /// The link is retrying; the strip says the same as the status row.
  final bool reconnecting;
  final List<FlightAlert> alerts;
  final ThermalConfig? thermalConfig;
  final ControllerType controllerType;
  final TelemetrySource? telemetrySource;
  final int rejectedFrames;
  final String? firmwareVersion;
  final String? firmwareBuild;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onHandleDragUpdate;
  final GestureDragEndCallback? onHandleDragEnd;
  final GestureDragCancelCallback? onHandleDragCancel;
  final int columns;

  static String _or(Object? v, String suffix) => v == null ? '–' : '$v$suffix';

  static String _state(SignalState? s) => switch (s) {
    SignalState.valid => 'válido',
    SignalState.stale => 'desatualizado',
    SignalState.invalid => 'inválido',
    SignalState.absent => 'sem sensor',
    null => '–',
  };

  static String _band(double? start, double? end) =>
      start == null || end == null
      ? '–'
      : '${start.round()} °C · ${end.round()} °C';

  String get _bms {
    final f = frame;
    switch (f?.bmsLinkState) {
      case BmsLinkState.connected:
        return 'Conectado';
      case BmsLinkState.connecting:
        return 'Conectando';
      case BmsLinkState.idle:
        return 'Ocioso';
      case BmsLinkState.notConfigured:
        return 'Não configurado';
      case BmsLinkState.unknown:
      case null:
        break;
    }
    if (f?.bmsConnected == true) return 'Conectado';
    if (f?.bmsConfigured == true) return 'Sem conexão';
    if (f?.bmsConfigured == false) return 'Não configurado';
    return '–';
  }

  List<(String, List<(String, String)>)> _sections() {
    final f = frame;
    final cell = f == null ? null : perCellVolts(f);
    final t = thermalConfig;
    return [
      (
        'BATERIA',
        [
          ('Carga (contagem)', _or(f?.socCoulomb, ' %')),
          ('Carga (por tensão)', _or(f?.socVoltage, ' %')),
          ('Tensão', f?.voltage == null ? '–' : '${decimal(f!.voltage!, 1)} V'),
          ('Corrente', f?.currentA == null ? '–' : '${f!.currentA!.round()} A'),
          (
            'Por célula',
            cell == null
                ? '–'
                : '${cell.estimated ? '~' : ''}${decimal(cell.volts, 2)} V',
          ),
          (
            'Origem por célula',
            cell == null
                ? '–'
                : cell.estimated
                ? 'Calculado ÷${kSeriesCells}S'
                : 'BMS · menor célula',
          ),
          (
            'Células mín / máx',
            f?.cellMinMv == null || f?.cellMaxMv == null
                ? '–'
                : '${decimal(f!.cellMinMv! / 1000, 2)} / '
                      '${decimal(f.cellMaxMv! / 1000, 2)} V',
          ),
          ('Delta de células', _or(f?.cellDeltaMv, ' mV')),
          ('BMS', _bms),
          (
            'BMS: tensão',
            f?.bmsPackVoltage == null
                ? '–'
                : '${decimal(f!.bmsPackVoltage!, 1)} V',
          ),
          (
            'BMS: corrente',
            f?.bmsCurrentA == null ? '–' : '${f!.bmsCurrentA!.round()} A',
          ),
          ('BMS: carga', _or(f?.bmsSoc, ' %')),
          ('BMS: células', _or(f?.bmsCellCount, '')),
          ('BMS: temp. máx.', _or(f?.bmsMaxTempC, ' °C')),
        ],
      ),
      (
        'MOTOR',
        [
          (
            'Temperatura',
            f?.motorTempC == null ? '–' : '${f!.motorTempC!.round()} °C',
          ),
          (
            'Sensor',
            '${switch (f?.motorTempSource) {
              MotorTempSource.can => 'CAN',
              MotorTempSource.ntc => 'NTC',
              _ => '–',
            }} · ${_state(f?.motorTempState)}',
          ),
          ('RPM', f?.rpm == null ? '–' : grouped(f!.rpm!)),
          ('Redução · máximo', _band(t?.motorBandStartC, t?.motorBandEndC)),
        ],
      ),
      (
        'ESC',
        [
          (
            'Temperatura',
            f?.escTempC == null ? '–' : '${f!.escTempC!.round()} °C',
          ),
          (
            'Sensor',
            '${escTempSourceFor(controllerType) ?? '–'} · '
                '${_state(f?.escTempState)}',
          ),
          ('Redução · máximo', _band(t?.escBandStartC, t?.escBandEndC)),
          (
            'Dados do ESC',
            switch (f?.hasTelemetry) {
              true => 'recebendo',
              false => 'sem dados',
              null => '–',
            },
          ),
        ],
      ),
      (
        'ACELERADOR',
        [
          ('Aceleração', _or(f?.throttlePct, ' %')),
          ('Leitura bruta', f == null ? '–' : grouped(f.throttleRaw)),
          ('Potência disponível', _or(f?.powerPct, ' %')),
        ],
      ),
      (
        'SISTEMA',
        [
          (
            'Horímetro',
            f?.hourMeterSec == null ? '–' : hours(f!.hourMeterSec!),
          ),
          ('Tempo ligado', f?.uptimeSec == null ? '–' : hours(f!.uptimeSec!)),
          ('Firmware', firmwareVersion ?? '–'),
          // Hidden rather than dashed: on firmware that predates the field it
          // is a reading that does not exist.
          if (firmwareBuild != null) ('Build', firmwareBuild!),
          (
            'Origem dos dados',
            switch (telemetrySource) {
              TelemetrySource.control => 'binária (Fly Control)',
              TelemetrySource.xctod => r'$XCTOD',
              null => '–',
            },
          ),
          ('Quadros rejeitados', '$rejectedFrames'),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final sections = [for (final (t, rows) in _sections()) _Section(t, rows)];
    final perColumn = (sections.length / columns).ceil();

    return Material(
      key: const Key('details-view'),
      color: s.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Column(
            children: [
              _Strip(
                frame: frame,
                stale: stale,
                reconnecting: reconnecting,
                alerts: alerts,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var c = 0; c < columns; c++) ...[
                        if (c > 0) const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            children: [
                              for (final sec
                                  in sections
                                      .skip(c * perColumn)
                                      .take(perColumn))
                                sec,
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              GestureDetector(
                key: const Key('details-bottom-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: onHandleDragUpdate,
                onVerticalDragEnd: onHandleDragEnd,
                onVerticalDragCancel: onHandleDragCancel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: s.outline,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('details-close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_up),
                  label: const Text('VOLTAR AO PAINEL'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.frame,
    required this.stale,
    required this.reconnecting,
    required this.alerts,
  });

  final TelemetryFrame? frame;
  final bool stale;
  final bool reconnecting;
  final List<FlightAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final f = frame;
    final chip = statusChipFor(s, f, stale: stale, reconnecting: reconnecting);
    final top = alerts.isEmpty ? null : alerts.first;
    final style = alertStyle(s, top?.severity);
    final label = top == null ? null : alertLabel(top);
    return PanelCard(
      key: const Key('details-strip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // The same live dot the status row draws.
              Container(
                key: const Key('details-dot'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (f != null && !stale) ? s.primary : s.outline,
                ),
              ),
              const SizedBox(width: 10),
              StatusChip(text: chip.text, color: chip.color),
              const Spacer(),
              Text(
                'BATERIA ',
                style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
              ),
              Text(
                f == null ? '–' : '${f.socCoulomb} %',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (label != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(style.icon, size: 16, color: style.iconColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${label.line1} · ${label.line2}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: style.accent,
                    ),
                  ),
                ),
                if (alerts.length > 1) Text('+${alerts.length - 1}'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: s.onSurfaceVariant,
              ),
            ),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: s.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      value,
                      maxLines: 1,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
