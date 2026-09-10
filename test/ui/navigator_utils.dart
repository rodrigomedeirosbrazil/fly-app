import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulates a system back, like the back gesture or button on Android.
///
/// Sends the same platform channel message the engine sends when it receives
/// one. Copied from Flutter's own widget tests
/// (`packages/flutter/test/widgets/navigator_utils.dart`) because
/// `flutter_test` does not export it.
Future<void> simulateSystemBack() {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'flutter/navigation',
    const JSONMessageCodec().encodeMessage(<String, dynamic>{
      'method': 'popRoute',
    }),
    (ByteData? _) {},
  );
}
