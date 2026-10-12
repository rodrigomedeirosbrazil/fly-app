import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'panel_prefs.dart';

/// Locks the app to the pilot's choice. An empty list hands rotation back to
/// the system. Browsers cannot lock orientation (iOS Safari has no Screen
/// Orientation lock), so on the web this does nothing and the drawer hides
/// the choice.
Future<void> applyOrientation(OrientationChoice choice) async {
  if (kIsWeb) return;
  await SystemChrome.setPreferredOrientations(switch (choice) {
    OrientationChoice.portrait => const [DeviceOrientation.portraitUp],
    OrientationChoice.landscape => const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ],
    OrientationChoice.auto => const <DeviceOrientation>[],
  });
}
