import 'package:shared_preferences/shared_preferences.dart';

/// Vertical is the default and the lock is deliberate: a phone on the leg
/// rotates with the body, and the whole panel swapping mid-flight is the
/// failure this app designs against.
enum OrientationChoice { portrait, landscape, auto }

/// The panel's remembered choices.
///
/// Storage can be unavailable (restricted profile, blocked site data on the
/// web). The defaults are correct without it, so every failure here is
/// swallowed rather than allowed to take the panel down.
class PanelPrefs {
  const PanelPrefs({
    this.perCell = false,
    this.showCurrent = false,
    this.orientation = OrientationChoice.portrait,
  });

  /// Kept from the battery card that introduced it, so a pilot's existing
  /// choice survives the refactor.
  static const _voltKey = 'voltMode';
  static const _powerKey = 'powerMode';
  static const _orientationKey = 'orientation';

  final bool perCell;
  final bool showCurrent;
  final OrientationChoice orientation;

  static Future<PanelPrefs> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final name = p.getString(_orientationKey);
      return PanelPrefs(
        perCell: p.getBool(_voltKey) ?? false,
        showCurrent: p.getBool(_powerKey) ?? false,
        orientation: OrientationChoice.values
                .where((o) => o.name == name)
                .firstOrNull ??
            OrientationChoice.portrait,
      );
    } catch (_) {
      return const PanelPrefs();
    }
  }

  static Future<void> savePerCell(bool v) => _save((p) => p.setBool(_voltKey, v));

  static Future<void> saveShowCurrent(bool v) =>
      _save((p) => p.setBool(_powerKey, v));

  static Future<void> saveOrientation(OrientationChoice v) =>
      _save((p) => p.setString(_orientationKey, v.name));

  static Future<void> _save(
      Future<bool> Function(SharedPreferences) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // The choice still holds for this session.
    }
  }
}
