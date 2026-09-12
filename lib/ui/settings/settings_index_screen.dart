import 'package:flutter/material.dart';

class SettingsIndexScreen extends StatelessWidget {
  const SettingsIndexScreen({
    super.key,
    required this.onOpenPower,
    required this.onOpenThermal,
    required this.onOpenBms,
    required this.onOpenSystem,
  });

  final VoidCallback onOpenPower;
  final VoidCallback onOpenThermal;
  final VoidCallback onOpenBms;
  final VoidCallback onOpenSystem;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações'),
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
        ],
      ),
    );
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
