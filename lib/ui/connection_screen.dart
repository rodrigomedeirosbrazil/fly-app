import 'package:flutter/material.dart';

import '../ble/fly_controller_link.dart';

/// Shown until the first frame arrives. Deliberately plain: this screen is what
/// the pilot sees on the ground, not in the air.
class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({
    super.key,
    required this.status,
    required this.rejectedFrames,
  });

  final LinkStatus status;

  /// Lines that arrived but did not decode. Non-zero here with no telemetry is
  /// the signature of an MTU that never grew past 23 bytes.
  final int rejectedFrames;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final message = switch (status) {
      LinkStatus.idle => 'Desconectado',
      LinkStatus.scanning => 'Procurando o controlador…',
      LinkStatus.connecting => 'Conectando…',
      LinkStatus.connected => 'Aguardando telemetria…',
      LinkStatus.disconnected => 'Conexão perdida. Tentando de novo…',
    };

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(message, style: theme.textTheme.titleMedium),
            if (rejectedFrames > 0) ...[
              const SizedBox(height: 16),
              Text(
                '$rejectedFrames quadros descartados',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
