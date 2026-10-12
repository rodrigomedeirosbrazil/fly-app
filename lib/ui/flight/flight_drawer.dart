import 'package:flutter/material.dart';

import '../../state/flight_alerts.dart';
import 'alert_card.dart';
import 'alert_text.dart';

/// The overlay behind the bottom bar: alerts, sound, orientation, settings.
///
/// In the tree, not a pushed route. A modal route builds once from the frame
/// captured when it opened and never sees another, so its alerts would
/// silently freeze at 1 Hz.
class FlightDrawer extends StatelessWidget {
  const FlightDrawer({
    super.key,
    required this.alerts,
    required this.hasFrame,
    required this.muted,
    this.audioError,
    this.onSetMuted,
    required this.armed,
    this.onOpenSettings,
    required this.onClose,
    this.orientationControl,
    this.leftInset = 0,
  });

  final List<FlightAlert> alerts;
  final bool hasFrame;
  final bool muted;
  final String? audioError;
  final Future<void> Function(bool)? onSetMuted;
  final bool armed;
  final VoidCallback? onOpenSettings;
  final VoidCallback onClose;

  /// The orientation selector, when this platform can lock orientation.
  final Widget? orientationControl;

  /// Landscape leaves the battery column uncovered.
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      left: leftInset,
      top: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        onTap: onClose,
        child: ColoredBox(
          color: Colors.black54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: () {},
                child: Container(
                  key: const Key('drawer'),
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(18)),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.8),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: Tooltip(
                              message: 'Fechar',
                              child: IconButton(
                                icon: const Icon(Icons.keyboard_arrow_down),
                                onPressed: onClose,
                              ),
                            ),
                          ),
                          _heading(theme, 'ALERTAS ATIVOS'),
                          _AlertList(
                              key: const Key('drawer-alerts'),
                              alerts: alerts,
                              hasFrame: hasFrame),
                          const SizedBox(height: 12),
                          _MuteControl(
                            key: const Key('mute-buzzer'),
                            muted: muted,
                            audioError: audioError,
                            onSetMuted: onSetMuted,
                          ),
                          if (orientationControl != null) ...[
                            const SizedBox(height: 4),
                            orientationControl!,
                          ],
                          const SizedBox(height: 8),
                          _SettingsEntry(
                            key: const Key('settings-entry'),
                            // Disabled rather than hidden: presence is fixed
                            // and only the state changes. A gate the pilot can
                            // see beats an ErrState arriving after the tap.
                            onTap: armed ? null : onOpenSettings,
                            reason: armed
                                ? 'Indisponível com a aeronave armada'
                                : onOpenSettings == null
                                    ? 'Indisponível nesta conexão'
                                    : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _heading(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            )),
      );
}

class _AlertList extends StatelessWidget {
  const _AlertList({super.key, required this.alerts, required this.hasFrame});

  final List<FlightAlert> alerts;
  final bool hasFrame;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    if (!hasFrame) {
      return Text('Sem dados do controlador.',
          style: TextStyle(color: s.onSurfaceVariant));
    }
    if (alerts.isEmpty) {
      return Text('Tudo certo', style: TextStyle(color: s.primary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in alerts)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: s.surfaceContainer,
              border: Border(
                left: BorderSide(
                  width: 4,
                  color: alertStyle(s, a.severity).border ?? s.outline,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${alertLabel(a).line1} · ${alertLabel(a).line2}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: alertStyle(s, a.severity).accent,
                  ),
                ),
                const SizedBox(height: 3),
                Text(alertSentence(a), style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
  }
}

/// The way out of the panel and into settings. The only navigation this app
/// offers from the flight screen, and deliberately behind the drawer the
/// pilot has to open on purpose.
class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({super.key, required this.onTap, required this.reason});

  final VoidCallback? onTap;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final color = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.tune, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              'CONFIGURAÇÕES',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            if (reason != null)
              Expanded(
                child: Text(
                  reason!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mute control for the buzzer. Toggles sound on and off.
class _MuteControl extends StatelessWidget {
  const _MuteControl({
    super.key,
    required this.muted,
    required this.onSetMuted,
    this.audioError,
  });

  final bool muted;
  final Future<void> Function(bool)? onSetMuted;

  /// What the speaker last refused to do. Named rather than swallowed: the
  /// pilot is the only one who can tell a silent app from a quiet aircraft,
  /// and this subsystem reached hardware inaudible twice without a word.
  final String? audioError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                muted ? Icons.volume_off : Icons.volume_up,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'SOM DO CONTROLADOR',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: !muted,
                onChanged: (value) => onSetMuted?.call(!value),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 70,
                child: Text(
                  muted ? 'DESLIGADO' : 'LIGADO',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (audioError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Falha no som: $audioError',
                key: const Key('audio-error'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
