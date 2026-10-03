import 'package:flutter/material.dart';

import '../ble/fly_controller_link.dart';
import '../state/app_update_policy.dart';
import 'update_notice.dart';
import 'widgets/aerovolt_logo.dart';

/// Shown until the first frame arrives — and, deliberately, never again.
///
/// Once telemetry has been seen, a dropped link is the flight screen's stale
/// state, not a trip back to here: replacing the instrument panel with a logo
/// is the last thing a pilot in the air needs. See
/// [TelemetryRepository] for the half of that rule which lives in state.
///
/// Two modes share one layout. At rest the button starts the radio; while
/// trying it cancels. Neither the logo nor the button moves between them —
/// only the label changes and the status line fills in.
class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({
    super.key,
    required this.status,
    required this.rejectedFrames,
    required this.onConnect,
    required this.onCancel,
    required this.onOpenSettings,
    required this.onOpenLocationSettings,
    this.update = const UpdateUnknown(),
    this.onOpenRelease,
  });

  final LinkStatus status;

  /// Lines that arrived but did not decode. Non-zero here with no telemetry is
  /// the signature of an MTU that never grew past 23 bytes.
  final int rejectedFrames;

  final VoidCallback onConnect;
  final VoidCallback onCancel;

  /// Opens the OS settings page for the app. Android can refuse the Bluetooth
  /// permission permanently, and then this is the only way back.
  final VoidCallback onOpenSettings;

  /// Opens the system location settings. On API <= 30 a BLE scan needs the
  /// location service on, and the app's own settings page cannot switch it.
  final VoidCallback onOpenLocationSettings;

  /// Whether a newer build exists. Only [UpdateAvailable] shows anything.
  final UpdateAvailability update;

  /// Opens the release page. Null where a release cannot be installed (iOS),
  /// and then the notice is text, not a button.
  final VoidCallback? onOpenRelease;

  /// Reserved at the bottom whether or not a notice fills it, so an answer
  /// arriving never moves Conectar.
  static const double _noticeHeight = 48;

  /// [FlyControllerLink.connect] retries forever with a backoff, so there is
  /// no failure state to render. The preconditions are the exception: none of
  /// them is an attempt, so they keep the Conectar button.
  bool get _trying => status != LinkStatus.idle && !_blocked;

  /// Something the pilot has to fix before a scan can return anything.
  bool get _blocked =>
      status == LinkStatus.unauthorized ||
      status == LinkStatus.bluetoothOff ||
      status == LinkStatus.locationOff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final message = switch (status) {
      LinkStatus.idle => null,
      LinkStatus.scanning => 'Procurando o controlador…',
      LinkStatus.connecting => 'Conectando…',
      LinkStatus.connected => 'Aguardando telemetria…',
      LinkStatus.disconnected => 'Conexão perdida. Tentando de novo…',
      LinkStatus.unauthorized => 'Permissão de Bluetooth negada',
      LinkStatus.bluetoothOff => 'Bluetooth desligado',
      LinkStatus.locationOff => 'Localização desligada',
    };

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Proportional, never a point constant — the rule the dials
            // follow. Clamped so the lockup neither vanishes on a 320 pt
            // phone nor bloats across a tablet.
            final logoWidth =
                (constraints.maxWidth * 0.62).clamp(150.0, 380.0);

            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AerovoltLogo(width: logoWidth),
                          const SizedBox(height: 40),
                          _button(),
                          const SizedBox(height: 16),
                          // The line is reserved whether or not there is a
                          // message, so the button does not jump when one
                          // appears.
                          SizedBox(
                            height: 20,
                            child: message == null
                                ? null
                                : Text(
                                    message,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: _blocked
                                          ? theme.colorScheme.error
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                          // Bluetooth off gets no button: the pilot flips the
                          // adapter from the shade, and the app's own settings
                          // page cannot toggle it either.
                          if (status == LinkStatus.unauthorized)
                            TextButton(
                              onPressed: onOpenSettings,
                              child: const Text('Abrir Ajustes'),
                            ),
                          if (status == LinkStatus.locationOff)
                            TextButton(
                              onPressed: onOpenLocationSettings,
                              child: const Text('Abrir Localização'),
                            ),
                          if (rejectedFrames > 0) ...[
                            const SizedBox(height: 12),
                            Text(
                              '$rejectedFrames quadros descartados',
                              maxLines: 1,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // Anchored to the bottom and always reserved: an answer from
                // GitHub can land while the finger travels to Conectar, and
                // the target must not move under it.
                SizedBox(height: _noticeHeight, child: _updateNotice(theme)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _button() {
    if (!_trying) {
      return FilledButton(
        onPressed: onConnect,
        child: const Text('Conectar'),
      );
    }
    return OutlinedButton.icon(
      onPressed: onCancel,
      icon: const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      label: const Text('Cancelar'),
    );
  }

  Widget? _updateNotice(ThemeData theme) {
    final update = this.update;
    if (update is! UpdateAvailable) return null;

    final text = Text(
      updateNoticeText(update.tag, canOpen: onOpenRelease != null),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    return Center(
      child: onOpenRelease == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: text,
            )
          : TextButton(onPressed: onOpenRelease, child: text),
    );
  }
}
