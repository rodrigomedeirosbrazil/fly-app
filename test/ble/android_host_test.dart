import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/android_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidHost.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sdkInt returns what the host reports', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sdkInt');
      return 30;
    });

    expect(await const AndroidHost().sdkInt(), 30);
  });

  test('a host that reports nothing is an error, not a guess', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    // Any substituted number is wrong in one direction: too low asks a
    // modern phone for location, too high skips the permission an old phone
    // needs to scan at all. Both end in a scan that finds nothing.
    expect(const AndroidHost().sdkInt(), throwsStateError);
  });

  test('openLocationSettings reaches the host', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });

    await const AndroidHost().openLocationSettings();
    expect(calls, ['openLocationSettings']);
  });
}
