import 'package:shared_preferences/shared_preferences.dart';

/// Where the controller PIN survives between connections and launches, so the
/// pilot types it once rather than once per connection.
///
/// Plain preferences on purpose. The PIN keeps a pilot from writing to the
/// wrong aircraft by mistake; it is not a secret worth a keychain, and the
/// web build has no keychain to offer anyway.
abstract interface class PinStore {
  Future<String?> read();
  Future<void> write(String pin);
  Future<void> clear();
}

/// [PinStore] on `SharedPreferences`.
///
/// Storage can be unavailable (restricted profile, blocked site data on the
/// web). Every failure is swallowed: without storage the app behaves exactly
/// as it did before the PIN was remembered, and asks for it.
class PrefsPinStore implements PinStore {
  const PrefsPinStore();

  static const String key = 'controllerPin';

  @override
  Future<String?> read() async {
    try {
      final pin = (await SharedPreferences.getInstance()).getString(key);
      return pin == null || pin.isEmpty ? null : pin;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String pin) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, pin);
    } catch (_) {
      // Still authenticated for this connection.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } catch (_) {
      // A stale PIN costs one refused AUTH next time, then is cleared again.
    }
  }
}
