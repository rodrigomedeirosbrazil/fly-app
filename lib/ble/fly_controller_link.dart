import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../state/ble_permission_policy.dart';
import 'android_host.dart';

/// What the UI needs to know about the radio, without knowing about the radio.
///
/// The last three are preconditions the pilot has to fix rather than attempts
/// in progress: they keep the Conectar button and never show a spinner.
enum LinkStatus {
  idle,
  scanning,
  connecting,
  connected,
  disconnected,
  unauthorized,
  bluetoothOff,
  locationOff,
}

/// Owns the BLE conversation with the controller.
///
/// Emits raw notification payloads on [payloads]; it does not know what a
/// `$XCTOD` line is. Everything above this class is testable without hardware
/// because this class is the only thing that touches a radio.
class FlyControllerLink {
  /// Nordic UART Service, as advertised by the controller's `Xctod` component.
  static final Guid serviceUuid =
      Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');

  /// Notify-only TX characteristic. There is no write characteristic on the
  /// controller — this app can listen and nothing else.
  static final Guid txCharacteristicUuid =
      Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');

  static const String deviceName = 'FlyController';

  /// The `$XCTOD` line runs to roughly 90 bytes. Android's default ATT MTU is
  /// 23, which caps a notification at 20 bytes and would truncate every frame.
  /// iOS negotiates 185 on its own and rejects this call.
  static const int desiredMtu = 247;

  /// How long one scan attempt looks before giving up and backing off. The
  /// pilot may be walking towards a controller that is still powered off, so
  /// an empty window is expected rather than exceptional.
  static const Duration scanWindow = Duration(seconds: 10);

  FlyControllerLink({AndroidHost? host}) : _host = host ?? const AndroidHost();

  /// Only touched on Android. iOS never calls the channel.
  final AndroidHost _host;

  final _statusController = StreamController<LinkStatus>.broadcast();
  final _payloadController = StreamController<List<int>>.broadcast();

  Stream<LinkStatus> get status => _statusController.stream;
  Stream<List<int>> get payloads => _payloadController.stream;

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  bool _wantConnection = false;
  int _attempt = 0;

  /// Invalidates in-flight attempts. `_wantConnection` alone cannot: it flips
  /// back to true on the next connect(), which lets an attempt abandoned by a
  /// cancel sail through its own guards. Every attempt carries the generation
  /// it was born in and dies when that stops being current.
  int _generation = 0;

  /// Why a connection cannot be attempted yet, or null when it can.
  ///
  /// Returns a [LinkStatus] rather than a bool because the three ways this
  /// fails need three different things from the pilot, and every one of them
  /// otherwise looks identical from the outside: a scan that finds nothing.
  Future<LinkStatus?> blockingCondition() async {
    if (Platform.isAndroid) {
      final required = requirementsForAndroid(await _host.sdkInt());

      if (required.needsBluetoothRuntimePermissions) {
        final results = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();
        if (!results.values.every((s) => s.isGranted)) {
          return LinkStatus.unauthorized;
        }
      }

      if (required.needsLocationPermission) {
        // Below API 31 a BLE scan is a location capability. Without this,
        // permission_handler reports bluetoothScan as granted — there it maps
        // to no runtime permission at all — and startScan returns an empty
        // list forever, raising nothing.
        if (!(await Permission.locationWhenInUse.request()).isGranted) {
          return LinkStatus.unauthorized;
        }
      }

      if (required.needsLocationServiceOn &&
          await Permission.location.serviceStatus != ServiceStatus.enabled) {
        // Holding the permission is not enough, and the failure is the same
        // empty scan.
        return LinkStatus.locationOff;
      }
    }

    // Checked last, deliberately: on API 31+ the permissions requested above
    // are what make the adapter readable in the first place.
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      return LinkStatus.bluetoothOff;
    }

    return null;
  }

  /// Opens the OS settings page for this app. The only route back from a
  /// permanently refused Android permission.
  Future<void> openSettings() => openAppSettings();

  /// The only route back from a location service switched off on API <= 30.
  /// [openSettings] reaches the app's own page, which cannot toggle it.
  Future<void> openLocationSettings() => _host.openLocationSettings();

  /// Scans for the controller and stays connected until [disconnect].
  ///
  /// Reentrant calls are ignored. Between the tap and the first status there
  /// is a whole await — on Android, a permission dialog — during which the
  /// button is still live, and two overlapping attempts would race for
  /// [_device] and leak whichever lost.
  Future<void> connect() async {
    if (_wantConnection) return;
    _wantConnection = true;
    _attempt = 0;
    await _attemptConnection(++_generation);
  }

  Future<void> disconnect() async {
    _wantConnection = false;
    // Orphan whatever is still in flight. FlutterBluePlus.scanResults is a
    // process-wide stream that never closes, so stopScan() does not wake the
    // scan loop out of its await — only a stale generation does.
    _generation++;
    // A scan started by an attempt that is still in flight keeps the radio
    // busy for the rest of its 10 s timeout otherwise.
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Not scanning. Nothing to stop.
    }
    await _teardown();
    _statusController.add(LinkStatus.idle);
  }

  Future<void> _attemptConnection(int generation) async {
    bool abandoned() => !_wantConnection || generation != _generation;

    if (abandoned()) return;

    try {
      _statusController.add(LinkStatus.scanning);

      final device = await _scanForController(generation);
      if (abandoned()) return;
      if (device == null) return _scheduleRetry(generation);

      _statusController.add(LinkStatus.connecting);
      _device = device;
      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
      );

      // Android only: iOS throws for requestMtu because CoreBluetooth owns it.
      if (Platform.isAndroid) {
        await device.requestMtu(desiredMtu);
      }

      // connect() can outlive a cancel: the OS-level connection completes
      // even though the pilot already tapped Cancelar. Without this the
      // method goes on to subscribe and emit `connected` after the screen
      // has returned to rest, leaving a live subscription the app does not
      // know about.
      if (abandoned()) {
        await _teardown();
        return;
      }

      final characteristic = await _findTxCharacteristic(device);
      if (characteristic == null) {
        await _teardown();
        return _scheduleRetry(generation);
      }

      if (abandoned()) {
        await _teardown();
        return;
      }

      await characteristic.setNotifyValue(true);
      _valueSub = characteristic.onValueReceived.listen(_payloadController.add);

      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _statusController.add(LinkStatus.disconnected);
          _teardown().then((_) => _scheduleRetry(generation));
        }
      });

      _attempt = 0;
      _statusController.add(LinkStatus.connected);
    } catch (_) {
      await _teardown();
      _scheduleRetry(generation);
    }
  }

  Future<BluetoothDevice?> _scanForController(int generation) async {
    final result = Completer<BluetoothDevice?>();
    void finish(BluetoothDevice? device) {
      if (!result.isCompleted) result.complete(device);
    }

    // onScanResults, not scanResults: the latter re-emits the previous scan's
    // last value to every new listener, so a fresh attempt would match a
    // controller that has since been switched off and then burn an attempt
    // connecting to it.
    final resultsSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        // A cancelled attempt must not wake up inside the next one's results
        // and race it for _device. The generation is the way out.
        if (generation != _generation) return finish(null);
        for (final r in results) {
          // Two different names: platformName is what the OS has cached for
          // the device, advName is what the advertisement carries. Android
          // leaves the first empty for a device it has never bonded with, so
          // matching on it alone is not enough.
          if (r.device.platformName == deviceName ||
              r.advertisementData.advName == deviceName) {
            return finish(r.device);
          }
        }
      },
      onError: (_) => finish(null),
    );

    await FlutterBluePlus.startScan(
      withServices: [serviceUuid],
      withNames: [deviceName],
      timeout: scanWindow,
    );

    // The scan *ending* is what finishes an unsuccessful attempt, and it has
    // to be watched explicitly. FlutterBluePlus.scanResults is process-wide
    // and is never closed — stopScan cancels its subscriptions without
    // emitting anything — so waiting on results alone hangs forever once the
    // window expires: no retry, no error, the pilot left on "Procurando o
    // controlador…" indefinitely. That is measured behaviour, not a
    // precaution. Subscribed after startScan because isScanning re-emits its
    // current value, which is false until the scan is actually running.
    unawaited(FlutterBluePlus.isScanning
        .where((scanning) => !scanning)
        .first
        .then((_) => finish(null)));

    final found = await result.future;
    await resultsSub.cancel();
    await FlutterBluePlus.stopScan();
    return found;
  }

  Future<BluetoothCharacteristic?> _findTxCharacteristic(
    BluetoothDevice device,
  ) async {
    for (final service in await device.discoverServices()) {
      if (service.uuid != serviceUuid) continue;
      for (final c in service.characteristics) {
        if (c.uuid == txCharacteristicUuid) return c;
      }
    }
    return null;
  }

  /// Backoff caps at 8 s: the pilot may be walking back to a controller that is
  /// still powered off, and a tight retry loop would drain the phone.
  void _scheduleRetry(int generation) {
    if (!_wantConnection || generation != _generation) return;
    _attempt++;
    final delay = Duration(
      seconds: [1, 2, 4, 8][_attempt.clamp(1, 4) - 1],
    );
    Timer(delay, () => _attemptConnection(generation));
  }

  Future<void> _teardown() async {
    await _valueSub?.cancel();
    _valueSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {
      // Already gone. Nothing to salvage.
    }
    _device = null;
  }

  Future<void> dispose() async {
    _wantConnection = false;
    _generation++;
    await _teardown();
    await _statusController.close();
    await _payloadController.close();
  }
}
