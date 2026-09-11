import 'package:flutter/material.dart';

import '../../state/config_editor.dart';
import '../../state/control_session.dart';
import '../../state/telemetry_repository.dart';
import 'power_settings_screen.dart';
import 'settings_index_screen.dart';
import 'thermal_settings_screen.dart';

/// Opens the settings index, and from it the two editable groups.
///
/// A function rather than code inside `app.dart` because `FlyApp` builds its
/// own repository and enables the wakelock, so it cannot be pumped in a
/// widget test. The wiring here is exactly what shipped broken once, so it is
/// the part that has to be testable.
///
/// **Every screen's content sits in a `ListenableBuilder`.** A
/// `MaterialPageRoute`'s builder runs once, so anything read from [repo]
/// inside it would be a snapshot — which is how arming the aircraft with the
/// settings screen open failed to disable saving. It is the same trap
/// `CLAUDE.md` documents for the secondary-data drawer.
void openSettings(BuildContext context, TelemetryRepository repo) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (indexContext) => SettingsIndexScreen(
        onOpenPower: () => _push(
          indexContext,
          repo,
          (session) => PowerSettingsScreen(
            editor: ConfigEditor(session),
            config: repo.powerConfig,
            armed: repo.frame?.isArmed ?? false,
            // Null unless the battery-voltage signal state is Valid: the
            // codec already applies that rule, so calibration inherits it
            // rather than inventing a second one.
            sensorVolts: repo.frame?.voltage,
          ),
        ),
        onOpenThermal: () => _push(
          indexContext,
          repo,
          (session) => ThermalSettingsScreen(
            editor: ConfigEditor(session),
            config: repo.thermalConfig,
            armed: repo.frame?.isArmed ?? false,
            selectableMotorTempSource: repo.selectableMotorTempSource,
          ),
        ),
      ),
    ),
  );
}

void _push(
  BuildContext context,
  TelemetryRepository repo,
  Widget Function(ControlSession) build,
) {
  final session = repo.session;
  if (session == null) return;

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: repo,
        builder: (context, _) => build(session),
      ),
    ),
  );
}
