import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/ble_permission_policy.dart';

void main() {
  group('requirementsForAndroid', () {
    // The whole reason this module exists: a modern test device never runs
    // this branch, so the table is the only thing keeping it correct.
    for (final api in [24, 26, 28, 29, 30]) {
      test('API $api needs location and the location service, not runtime BT',
          () {
        final r = requirementsForAndroid(api);
        expect(r.needsLocationPermission, isTrue);
        expect(r.needsLocationServiceOn, isTrue);
        expect(r.needsBluetoothRuntimePermissions, isFalse);
      });
    }

    for (final api in [31, 33, 36]) {
      test('API $api needs runtime BT permissions and no location', () {
        final r = requirementsForAndroid(api);
        expect(r.needsBluetoothRuntimePermissions, isTrue);
        expect(r.needsLocationPermission, isFalse);
        expect(r.needsLocationServiceOn, isFalse);
      });
    }

    test('31 is the boundary, exactly', () {
      expect(requirementsForAndroid(30).needsLocationPermission, isTrue);
      expect(requirementsForAndroid(31).needsLocationPermission, isFalse);
    });
  });

  test('iOS asks for nothing in advance', () {
    const r = BleScanRequirements.none;
    expect(r.needsBluetoothRuntimePermissions, isFalse);
    expect(r.needsLocationPermission, isFalse);
    expect(r.needsLocationServiceOn, isFalse);
  });
}
