import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/ble_permission_policy.dart';

void main() {
  test('an adapter that has not answered yet is not an adapter that is off',
      () {
    // THE REGRESSION THIS FILE EXISTS FOR.
    //
    // CoreBluetooth reports `unknown` until its central manager starts, which
    // on iOS is also before the permission prompt has been shown. Reading that
    // as "off" made the first tap of a fresh install say "Bluetooth
    // desligado" and return without ever scanning -- so no prompt appeared,
    // and only the second tap worked. Starting the scan is what makes iOS
    // ask, so an undecided adapter must not stop it.
    expect(verdictForAdapter(BleAdapterState.unknown),
        BleAdapterVerdict.proceed);
  });

  test('an adapter that is on proceeds', () {
    expect(verdictForAdapter(BleAdapterState.on), BleAdapterVerdict.proceed);
  });

  test('an adapter that is off is reported as off', () {
    expect(verdictForAdapter(BleAdapterState.off),
        BleAdapterVerdict.bluetoothOff);
  });

  test('a refused adapter is unauthorized, which needs Settings, not a switch',
      () {
    expect(verdictForAdapter(BleAdapterState.unauthorized),
        BleAdapterVerdict.unauthorized);
  });

  test('every state has a verdict', () {
    for (final s in BleAdapterState.values) {
      expect(() => verdictForAdapter(s), returnsNormally, reason: '$s');
    }
  });
}
