/// What the OS must grant before a BLE scan can return results.
///
/// Pure on purpose. Imports nothing from `package:flutter`, like
/// [LinkHealth] beside it: Android 12 moved BLE scanning from a location
/// permission to `BLUETOOTH_SCAN` + `neverForLocation`, so the two ranges
/// need opposite things and there is no single request that satisfies both.
///
/// The API <= 30 branch is the one a modern test device never executes, which
/// is why this decision lives here and not inside [FlyControllerLink]: a unit
/// test is the only thing that can keep it honest.
class BleScanRequirements {
  const BleScanRequirements({
    required this.needsBluetoothRuntimePermissions,
    required this.needsLocationPermission,
    required this.needsLocationServiceOn,
  });

  /// API 31+: `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` are runtime
  /// permissions and must be requested before scanning.
  final bool needsBluetoothRuntimePermissions;

  /// API <= 30: a BLE scan counts as a location capability. Without
  /// `ACCESS_FINE_LOCATION`, `startScan` returns zero results and raises
  /// nothing — `permission_handler` reports `bluetoothScan` as granted there
  /// because below 31 it maps to no runtime permission at all.
  final bool needsLocationPermission;

  /// API <= 30: the location *service* must also be on. Holding the
  /// permission is not enough, and the failure looks identical — an empty
  /// scan.
  final bool needsLocationServiceOn;

  /// iOS. CoreBluetooth prompts on the first scan; there is nothing to ask
  /// for in advance.
  static const none = BleScanRequirements(
    needsBluetoothRuntimePermissions: false,
    needsLocationPermission: false,
    needsLocationServiceOn: false,
  );
}

/// Android 12. The release where `BLUETOOTH_SCAN` became a runtime permission
/// and `neverForLocation` began dispensing with location entirely.
const int androidApi31 = 31;

BleScanRequirements requirementsForAndroid(int apiLevel) =>
    apiLevel >= androidApi31
        ? const BleScanRequirements(
            needsBluetoothRuntimePermissions: true,
            needsLocationPermission: false,
            needsLocationServiceOn: false,
          )
        : const BleScanRequirements(
            needsBluetoothRuntimePermissions: false,
            needsLocationPermission: true,
            needsLocationServiceOn: true,
          );
