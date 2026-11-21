import 'dart:math' as math;

/// The largest single write `flutter_blue_plus` accepts on either platform:
/// the 512-byte ATT attribute limit. It rejects anything longer before a byte
/// leaves the phone.
const int kMaxAttributeWriteBytes = 512;

/// The largest DFU packet the phone will send, from the plugin's `mtuNow`.
///
/// `mtuNow - 3` alone is wrong on Android: there `mtuNow` is the raw
/// negotiated ATT MTU (517 is common), so it gave 514 and every write failed
/// with "dataLen: 514 > max: 512 (withoutResponse)". On iOS `mtuNow` already
/// folds the 512 cap in, so the extra `min` changes nothing there.
int nativeDfuWriteLimit(int mtuNow) =>
    math.min(mtuNow - 3, kMaxAttributeWriteBytes);
