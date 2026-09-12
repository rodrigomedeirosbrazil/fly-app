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

/// What a settled adapter state means for the link, or null to go ahead.
///
/// Pure and table-tested for the same reason the API-level branches are: the
/// state this most needed to get right — CoreBluetooth's `unknown` — cannot be
/// produced on a test machine at all.
///
/// **`unknown` is not "off".** It is the adapter not having answered yet, and
/// on iOS that includes the whole window before the permission prompt has been
/// shown. Treating it as off made the first tap of a fresh install report
/// "Bluetooth desligado" and return without scanning — so the prompt never
/// appeared, and the second tap worked only because the state had settled by
/// then. Proceeding is what lets the scan raise the prompt.
BleAdapterVerdict verdictForAdapter(BleAdapterState state) => switch (state) {
      BleAdapterState.off => BleAdapterVerdict.bluetoothOff,
      // iOS refusing Bluetooth to this app. It needs the Settings page, not
      // the switch that the "turn Bluetooth on" copy points at.
      BleAdapterState.unauthorized => BleAdapterVerdict.unauthorized,
      BleAdapterState.on || BleAdapterState.unknown => BleAdapterVerdict.proceed,
    };

/// The subset of the plugin's adapter states this decision turns on, so the
/// policy stays free of `flutter_blue_plus`.
enum BleAdapterState { unknown, off, on, unauthorized }

enum BleAdapterVerdict { proceed, bluetoothOff, unauthorized }
