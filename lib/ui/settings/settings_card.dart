import 'package:flutter/material.dart';

/// One group of related settings, on the same raised surface the flight
/// panel's cards use.
///
/// The settings screens shipped as a flat list of controls on the page
/// background, which is why they read as a different app from the panel: no
/// grouping, no surface, and a save button carrying the same weight as a
/// disclosure toggle. The portal groups its fields too — this is the app's
/// version of the same division.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: settingsSectionLabel(context)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// The small letterspaced caption the dials use for their own labels.
TextStyle settingsSectionLabel(BuildContext context) => TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

/// An identifier the pilot reads character by character — a MAC, a version.
/// Tabular figures so the colons line up and a wrong digit is findable.
TextStyle settingsIdentifier(BuildContext context) => TextStyle(
      fontSize: 17,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: Theme.of(context).colorScheme.onSurface,
    );
