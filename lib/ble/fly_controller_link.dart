import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../protocol/control_info.dart';
import '../state/ble_permission_policy.dart';
import '../state/telemetry_source_policy.dart';
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

/// One notification, tagged with the characteristic that produced it.
///
/// Tagged rather than read from a `source` getter at handling time: a stream
/// event has to be self-describing, or a payload still queued across a
/// reconnect gets handed to the wrong decoder.
class TelemetryPayload {
  const TelemetryPayload(this.source, this.bytes);

  final TelemetrySource source;
  final List<int> bytes;
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

  /// The controller's own binary service. **Not advertised** — the 31-byte
  /// advertising payload cannot hold a second 128-bit UUID — so the scan
  /// filter stays on the NUS UUID and this is only ever found after
  /// connecting. Its presence is the capability handshake.
  static final Guid controlServiceUuid =
      Guid('D4CF0001-9B9D-4BFD-8F7F-40C6989D3EA9');
  static final Guid controlInfoUuid =
      Guid('D4CF0002-9B9D-4BFD-8F7F-40C6989D3EA9');
  static final Guid controlTelemetryUuid =
      Guid('D4CF0003-9B9D-4BFD-8F7F-40C6989D3EA9');
  static final Guid controlCmdUuid =
      Guid('D4CF0004-9B9D-4BFD-8F7F-40C6989D3EA9');
  static final Guid controlRspUuid =
      Guid('D4CF0005-9B9D-4BFD-8F7F-40C6989D3EA9');
  static final Guid controlDfuUuid =
      Guid('D4CF0006-9B9D-4BFD-8F7F-40C6989D3EA9');

  static const String deviceName = 'FlyController';

  /// The `$XCTOD` line runs to roughly 90 bytes. Android's default ATT MTU is
  /// 23, which caps a notification at 20 bytes and would truncate every frame.
  /// Passed to [BluetoothDevice.connect], which negotiates it once and leaves
  /// iOS alone. Measured granted on a Galaxy A12 against this controller.
  static const int desiredMtu = 247;

  /// How long one scan attempt looks before giving up and backing off. The
  /// pilot may be walking towards a controller that is still powered off, so
  /// an empty window is expected rather than exceptional.
  static const Duration scanWindow = Duration(seconds: 10);

  FlyControllerLink({AndroidHost? host}) : _host = host ?? const AndroidHost();

  /// Only touched on Android. iOS never calls the channel.
  final AndroidHost _host;

  final _statusController = StreamController<LinkStatus>.broadcast();
  final _payloadController = StreamController<TelemetryPayload>.broadcast();

  Stream<LinkStatus> get status => _statusController.stream;
  Stream<TelemetryPayload> get payloads => _payloadController.stream;

  /// Read once at discovery; null on the `$XCTOD` path.
  ControlInfo? get info => _info;
  ControlInfo? _info;

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _valueSub;

  /// The characteristic currently notifying, so a fallback can quieten it.
  /// Dropping only the Dart subscription leaves the controller pushing 56-byte
  /// frames at 1 Hz to nobody for the rest of the flight.
  BluetoothCharacteristic? _notifying;
  BluetoothCharacteristic? _cmd;
  StreamSubscription<List<int>>? _rspSub;
  final _responseController = StreamController<List<int>>.broadcast();

  /// Frames arriving on `RSP` — replies and events both. Empty on the
  /// `$XCTOD` path, where the control service does not exist.
  Stream<List<int>> get responses => _responseController.stream;

  /// True when this connection can carry requests at all.
  bool get canSendCommands => _cmd != null;

  /// True when this connection can carry DFU data transfers.
  bool get canUpdateFirmware => _dfu != null;
  BluetoothCharacteristic? _dfu;

  /// Writes one `CMD` frame.
  ///
  /// Throws when there is no command characteristic, which
  /// [ControlSession] turns into ControlDropped — the honest answer, since a
  /// controller without the service will never reply.
  Future<void> sendCommand(List<int> bytes) async {
    final cmd = _cmd;
    if (cmd == null) {
      throw StateError('no CMD characteristic on this connection');
    }
    // withoutResponse: false — an ATT write response is the only
    // acknowledgement that the frame reached the controller at all.
    await cmd.write(bytes, withoutResponse: false);
  }

  /// Writes DFU bulk data without response.
  ///
  /// Throws when there is no DFU data characteristic, which is expected
  /// behaviour when the controller does not support DFU yet.
  Future<void> writeDfuData(List<int> bytes) async {
    final dfu = _dfu;
    if (dfu == null) {
      throw StateError('no DFU data characteristic on this connection');
    }
    // withoutResponse: true — bulk transfers cannot afford to wait for an ACK
    // on every frame, and the offset in each packet is redundant anyway.
    await dfu.write(bytes, withoutResponse: true);
  }

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
    //
    // `.first` was wrong here. CoreBluetooth reports `unknown` until its
    // central manager finishes starting, which on iOS is also *before the
    // permission prompt has been shown* -- so the first tap of a fresh
    // install read `unknown`, reported "Bluetooth desligado", and returned
    // without ever scanning. No prompt appeared, and the second tap worked
    // because the state had settled by then. Exactly the symptom reported.
    //
    // So wait for the adapter to say something definite. If it does not
    // within the window, proceed: starting the scan is what makes iOS ask,
    // and refusing to scan is what guarantees it never does.
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => BluetoothAdapterState.unknown,
        );

    return switch (verdictForAdapter(_adapterState(state))) {
      BleAdapterVerdict.proceed => null,
      BleAdapterVerdict.bluetoothOff => LinkStatus.bluetoothOff,
      BleAdapterVerdict.unauthorized => LinkStatus.unauthorized,
    };
  }

  /// The plugin's state, narrowed to what the policy decides on. Anything
  /// transient -- turning on, turning off -- is not yet an answer.
  BleAdapterState _adapterState(BluetoothAdapterState s) => switch (s) {
        BluetoothAdapterState.on => BleAdapterState.on,
        BluetoothAdapterState.off => BleAdapterState.off,
        BluetoothAdapterState.unauthorized => BleAdapterState.unauthorized,
        _ => BleAdapterState.unknown,
      };

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
      // The mtu argument is what lifts Android's default ATT MTU of 23, which
      // caps a notification at 20 bytes and would truncate every ~90-byte
      // sentence. flutter_blue_plus performs the exchange as part of connect()
      // and skips it on iOS, where CoreBluetooth owns the value and negotiates
      // 185 by itself — so this needs no platform branch.
      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
        mtu: desiredMtu,
      );

      // connect() can outlive a cancel: the OS-level connection completes
      // even though the pilot already tapped Cancelar. Without this the
      // method goes on to subscribe and emit `connected` after the screen
      // has returned to rest, leaving a live subscription the app does not
      // know about.
      if (abandoned()) {
        await _teardown();
        return;
      }

      final selected = await _selectTelemetry(device);
      if (selected == null) {
        await _teardown();
        return _scheduleRetry(generation);
      }

      if (abandoned()) {
        await _teardown();
        return;
      }

      final (source, characteristic) = selected;
      await characteristic.setNotifyValue(true);
      _notifying = characteristic;
      _valueSub = characteristic.onValueReceived
          .listen((bytes) => _payloadController.add(TelemetryPayload(source, bytes)));

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

  /// Finds the telemetry characteristic to subscribe to, consulting
  /// [chooseAtDiscovery] for the decision. Returns null when neither service
  /// offers one, which retries the whole attempt.
  Future<(TelemetrySource, BluetoothCharacteristic)?> _selectTelemetry(
    BluetoothDevice device,
  ) async {
    final services = await device.discoverServices();

    BluetoothCharacteristic? find(Guid service, Guid characteristic) {
      for (final s in services) {
        if (s.uuid != service) continue;
        for (final c in s.characteristics) {
          if (c.uuid == characteristic) return c;
        }
      }
      return null;
    }

    final controlTelemetry = find(controlServiceUuid, controlTelemetryUuid);
    final infoCharacteristic = find(controlServiceUuid, controlInfoUuid);

    _info = null;
    if (controlTelemetry != null && infoCharacteristic != null) {
      try {
        _info = ControlInfo.decode(await infoCharacteristic.read());
      } catch (_) {
        // Unreadable INFO is treated as no service at all, below.
      }
    }

    final source = chooseAtDiscovery(
      controlServicePresent: controlTelemetry != null,
      infoReadable: _info != null,
    );

    if (source == TelemetrySource.control) {
      _cmd = find(controlServiceUuid, controlCmdUuid);
      final rsp = find(controlServiceUuid, controlRspUuid);
      if (rsp != null) {
        await rsp.setNotifyValue(true);
        _rspSub = rsp.onValueReceived.listen(_responseController.add);
      } else {
        // A control service without RSP can still stream telemetry. Requests
        // are simply unavailable, which canSendCommands reports.
        _cmd = null;
      }
      // DFU is optional, and this line is the whole of that guarantee: `find`
      // returns null and nothing reacts. No controller in existence has this
      // characteristic today, so making its absence fatal would take the app
      // off every aircraft at once.
      //
      // **No test covers this line.** Discovery only runs against a real
      // radio — every test above substitutes FakeLink wholesale — so making
      // the characteristic mandatory here goes unnoticed by the suite. It was
      // checked by hand: adding a throw leaves all tests green.
      // `telemetry_repository_test.dart` covers the layer above, where a link
      // reporting no DFU must still connect and stream.
      _dfu = find(controlServiceUuid, controlDfuUuid);
      return (TelemetrySource.control, controlTelemetry!);
    }

    _info = null;
    final tx = find(serviceUuid, txCharacteristicUuid);
    return tx == null ? null : (TelemetrySource.xctod, tx);
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

  /// Re-runs discovery on the live connection, forced onto `$XCTOD`.
  ///
  /// Called once, and only before any frame has reached the screen — see
  /// [shouldFallBackOnFrame]. After that the source is fixed for the
  /// connection, because a flip would change which readings exist under a
  /// pilot who is reading them.
  Future<void> fallBackToXctod() async {
    final device = _device;
    if (device == null) return;

    // Guarded like every other in-flight operation in this class: a
    // disconnect racing the fallback must not leave a subscription attached
    // across a teardown.
    final generation = _generation;

    try {
      await _valueSub?.cancel();
      _valueSub = null;
      _info = null;
      await _rspSub?.cancel();
      _rspSub = null;
      _cmd = null;

      final previous = _notifying;
      _notifying = null;
      if (previous != null) {
        try {
          await previous.setNotifyValue(false);
        } catch (_) {
          // Already gone. Nothing left to quieten.
        }
      }

      if (generation != _generation) return;

      for (final s in await device.discoverServices()) {
        if (s.uuid != serviceUuid) continue;
        for (final c in s.characteristics) {
          if (c.uuid != txCharacteristicUuid) continue;
          if (generation != _generation) return;
          await c.setNotifyValue(true);
          _notifying = c;
          _valueSub = c.onValueReceived.listen(
            (bytes) => _payloadController.add(
              TelemetryPayload(TelemetrySource.xctod, bytes),
            ),
          );
          return;
        }
      }

      // A controller serving the control service but no NUS characteristic is
      // not something this connection can recover from. Dropping out silently
      // would leave a live link with nothing subscribed to it -- the panel
      // stale forever, with no retry and no error, which is the exact failure
      // the scan loop was already fixed for once.
      await _teardown();
      _scheduleRetry(generation);
    } catch (_) {
      // Called through unawaited(), so a throw here would surface as an
      // unhandled zone error instead of a reconnection.
      await _teardown();
      _scheduleRetry(generation);
    }
  }

  Future<void> _teardown() async {
    await _valueSub?.cancel();
    _valueSub = null;
    _notifying = null;
    await _rspSub?.cancel();
    _rspSub = null;
    _cmd = null;
    _dfu = null;
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
    await _responseController.close();
  }
}
