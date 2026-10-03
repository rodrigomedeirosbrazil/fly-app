import 'package:flutter/material.dart';

import '../../state/app_update_policy.dart';
import '../update_notice.dart';

class SettingsIndexScreen extends StatelessWidget {
  const SettingsIndexScreen({
    super.key,
    required this.onOpenPower,
    required this.onOpenThermal,
    required this.onOpenBms,
    required this.onOpenSystem,
    required this.onOpenFirmware,
    required this.onOpenLogs,
    this.firmwareVersion,
    this.appVersion,
    this.appUpdate = const UpdateUnknown(),
    this.appUpdateChecking = false,
    this.onOpenRelease,
  });

  /// The controller's firmware version and type, as one line. Null on the
  /// `$XCTOD` path, where INFO was never read.
  final String? firmwareVersion;

  /// The installed app version in tag form, `2026-10-03.1`. Null for a build
  /// that carries no usable number.
  final String? appVersion;

  final UpdateAvailability appUpdate;

  /// True while GitHub has not answered yet.
  final bool appUpdateChecking;

  /// Opens the release page. Null where a release cannot be installed (iOS).
  final VoidCallback? onOpenRelease;

  final VoidCallback onOpenPower;
  final VoidCallback onOpenThermal;
  final VoidCallback onOpenBms;
  final VoidCallback onOpenSystem;
  final VoidCallback onOpenFirmware;
  final VoidCallback onOpenLogs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações'),
        // Which firmware is running, pinned under the title.
        //
        // It was already on the update screen and in the flight-screen
        // drawer, and both are places you have to know to look. In the list
        // it would sit either below five cards -- a scroll away, the same
        // problem with extra steps -- or above them, eating the height the
        // cards need. Here it is visible the moment the screen opens and
        // stays put while the list scrolls, which is what reference
        // information should do.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                firmwareVersion == null
                    ? 'Firmware desconhecido'
                    : 'Firmware $firmwareVersion',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsCard(
            label: 'BATERIA E ENERGIA',
            title: 'Energia',
            description: 'Capacidade da bateria, limites de tensão e controle de energia.',
            onTap: onOpenPower,
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            label: 'PROTEÇÃO TÉRMICA',
            title: 'Térmica',
            description: 'Limites de proteção do motor e do ESC e pontos de redução de energia.',
            onTap: onOpenThermal,
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            label: 'BMS BLUETOOTH',
            title: 'BMS',
            description: 'Tipo de BMS e endereço Bluetooth.',
            onTap: onOpenBms,
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            label: 'SISTEMA',
            title: 'Sistema',
            description: 'Volume do buzzer e origem do acelerador.',
            onTap: onOpenSystem,
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            label: 'REGISTROS',
            title: 'Registros de voo',
            description: 'Baixar e apagar os registros de voo.',
            onTap: onOpenLogs,
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            label: 'FIRMWARE',
            title: 'Atualizar',
            description: 'Enviar novo firmware para o controlador.',
            onTap: onOpenFirmware,
          ),
          const SizedBox(height: 12),
          // Always present, whatever the state: fixed presence, varying
          // state, the rule the status chips follow. Labelled "VERSÃO DO
          // APP" so it does not read as a second "Atualizar", which is the
          // firmware.
          _SettingsCard(
            label: 'VERSÃO DO APP',
            title: appVersion ?? 'Desconhecida',
            description: _appUpdateLine(),
            onTap: appUpdate is UpdateAvailable ? onOpenRelease : null,
          ),
        ],
      ),
    );
  }

  String _appUpdateLine() {
    if (appVersion == null) return 'Build sem número de versão';
    return switch (appUpdate) {
      UpdateAvailable(:final tag) =>
        updateNoticeText(tag, canOpen: onOpenRelease != null),
      UpToDate() => 'Atualizado',
      UpdateUnknown() =>
        appUpdateChecking ? 'Verificando…' : 'Não foi possível verificar',
    };
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.label,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final String label;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final textColor = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
