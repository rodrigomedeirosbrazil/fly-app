import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../state/control_session.dart';
import '../../state/bms_scan_controller.dart';
import '../../state/config_editor.dart';
import '../../state/dfu_session.dart';
import '../../state/remote_pairing_controller.dart';
import '../../state/telemetry_repository.dart';
import 'bms_settings_screen.dart';
import 'firmware_screen.dart';
import 'power_settings_screen.dart';
import 'settings_index_screen.dart';
import 'system_settings_screen.dart';
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
          (editor) => PowerSettingsScreen(
            editor: editor,
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
          (editor) => ThermalSettingsScreen(
            editor: editor,
            config: repo.thermalConfig,
            armed: repo.frame?.isArmed ?? false,
            selectableMotorTempSource: repo.selectableMotorTempSource,
          ),
        ),
        onOpenBms: () => _pushBms(indexContext, repo),
        onOpenSystem: () => _pushSystem(indexContext, repo),
        onOpenFirmware: () => _pushFirmware(indexContext, repo),
      ),
    ),
  );
}

void _push(
  BuildContext context,
  TelemetryRepository repo,
  Widget Function(ConfigEditor) build,
) {
  // The connection's editor, not a fresh one: it carries the PIN, and the
  // firmware's own authentication is per connection too.
  final editor = repo.editor;
  if (editor == null) return;

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: repo,
        builder: (context, _) => build(editor),
      ),
    ),
  );
}

void _pushBms(BuildContext context, TelemetryRepository repo) {
  final editor = repo.editor;
  if (editor == null) return;

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _BmsScreenWrapper(
        editor: editor,
        repo: repo,
      ),
    ),
  );
}

void _pushSystem(BuildContext context, TelemetryRepository repo) {
  final editor = repo.editor;
  if (editor == null) return;

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _SystemScreenWrapper(
        editor: editor,
        repo: repo,
      ),
    ),
  );
}

class _BmsScreenWrapper extends StatefulWidget {
  const _BmsScreenWrapper({
    required this.editor,
    required this.repo,
  });

  final ConfigEditor editor;
  final TelemetryRepository repo;

  @override
  State<_BmsScreenWrapper> createState() => _BmsScreenWrapperState();
}

class _BmsScreenWrapperState extends State<_BmsScreenWrapper> {
  late final BmsScanController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = BmsScanController(widget.editor);
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) => BmsSettingsScreen(
        editor: widget.editor,
        scanController: _scanController,
        config: widget.repo.bmsConfig,
        armed: widget.repo.frame?.isArmed ?? false,
        bmsConnected: widget.repo.frame?.bmsConnected,
        bmsConfigured: widget.repo.frame?.bmsConfigured,
      ),
    );
  }
}

class _SystemScreenWrapper extends StatefulWidget {
  const _SystemScreenWrapper({
    required this.editor,
    required this.repo,
  });

  final ConfigEditor editor;
  final TelemetryRepository repo;

  @override
  State<_SystemScreenWrapper> createState() => _SystemScreenWrapperState();
}

class _SystemScreenWrapperState extends State<_SystemScreenWrapper> {
  late final RemotePairingController _pairingController;

  @override
  void initState() {
    super.initState();
    _pairingController = RemotePairingController(widget.editor);
  }

  @override
  void dispose() {
    _pairingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) => SystemSettingsScreen(
        editor: widget.editor,
        pairingController: _pairingController,
        config: widget.repo.systemConfig,
        armed: widget.repo.frame?.isArmed ?? false,
        hasRemoteLink: widget.repo.hasRemoteLink,
      ),
    );
  }
}

void _pushFirmware(BuildContext context, TelemetryRepository repo) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _FirmwareScreenWrapper(repo: repo),
    ),
  );
}

class _FirmwareScreenWrapper extends StatefulWidget {
  const _FirmwareScreenWrapper({required this.repo});

  final TelemetryRepository repo;

  @override
  State<_FirmwareScreenWrapper> createState() => _FirmwareScreenWrapperState();
}

class _FirmwareScreenWrapperState extends State<_FirmwareScreenWrapper> {
  late final DfuSession _session;

  @override
  void initState() {
    super.initState();
    final transport = widget.repo.dfuTransport;
    if (transport != null) {
      _session = DfuSession(transport);
    } else {
      // This should not happen in practice, but handle it gracefully.
      _session = DfuSession(
        _NoOpTransport(),
      );
    }
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  /// Opens the system picker and reads the chosen file.
  ///
  /// `FileType.any`, not `custom` with `['bin']`: iOS filters by UTI and has
  /// no type registered for a bare `.bin`, so a custom filter there shows a
  /// browser in which the firmware cannot be selected at all.
  ///
  /// `readAsBytes()` rather than `PlatformFile.bytes`: on mobile the picker
  /// returns a path and leaves `bytes` null unless asked, and the deprecated
  /// `withData` flag is the old way of asking.
  ///
  /// **Nothing is caught here.** An earlier version wrapped the whole thing
  /// in `catch (_) { return null; }`, which made a failed pick
  /// indistinguishable from a cancelled one — the same silence that cost two
  /// rounds on the audio. The screen reports what went wrong.
  Future<Uint8List?> _pickFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    return file == null ? null : await file.readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) => FirmwareSettingsScreen(
        repo: widget.repo,
        session: _session,
        armed: widget.repo.frame?.isArmed ?? false,
        canUpdateFirmware: widget.repo.canUpdateFirmware,
        pickFile: _pickFile,
      ),
    );
  }
}

/// Fallback transport when the characteristic is absent.
class _NoOpTransport implements DfuTransport {
  @override
  Future<ControlResult> request({required int op, List<int> payload = const []}) async {
    return const ControlTimeout();
  }

  @override
  Future<void> writeData(List<int> bytes) async {}
}
