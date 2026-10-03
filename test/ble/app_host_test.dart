import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/android_host.dart';
import 'package:fly_app/ble/app_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidHost.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('shares the channel AndroidHost already uses', () {
    expect(const AppHost().channel.name, AndroidHost.channelName);
  });

  test('buildNumber returns what the host reports', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'buildNumber');
      return 2026100301;
    });

    expect(await const AppHost().buildNumber(), 2026100301);
  });

  test('a host that reports nothing is null, not an error', () async {
    // Unlike sdkInt, a safe substitute exists here: no number means no
    // notice, which is silence.
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await const AppHost().buildNumber(), isNull);
  });

  test('a host that fails is null', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'x'));
    expect(await const AppHost().buildNumber(), isNull);
  });

  test('a host without the method is null', () async {
    // No handler at all: MissingPluginException.
    expect(await const AppHost().buildNumber(), isNull);
  });

  test('openUrl hands the URL to the host as a string', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await const AppHost().openUrl(Uri.parse('https://github.com/x'));

    expect(calls, hasLength(1));
    expect(calls.single.method, 'openUrl');
    expect(calls.single.arguments, {'url': 'https://github.com/x'});
  });

  test('openUrl does not throw when the host cannot open it', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'no-browser'));

    await const AppHost().openUrl(Uri.parse('https://github.com/x'));
  });
}
