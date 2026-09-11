/// The `BMS_SCAN_STATUS` (`0x22`) reply.
///
/// `[status u8][count u8]` then `[mac 6][rssi i8][type u8]` per result.
///
/// The scan runs for 5 s on the controller (`WEB_SCAN_DURATION_SECONDS`) and
/// stores at most 16 results. **Advertising is suppressed for the whole
/// scan**: an existing connection survives it, but a client that drops cannot
/// find the controller again until it ends.
library;

/// What the controller's scanner is doing. `unknown` exists so a status from
/// newer firmware degrades instead of throwing, the same rule `DisarmReason`
/// follows.
enum BmsScanStatus { idle, scanning, complete, error, unknown }

class BmsScanResult {
  const BmsScanResult({
    required this.mac,
    required this.rssi,
    required this.detectedType,
  });

  final List<int> mac;

  /// dBm, negative. Signed on the wire, so it is read as `int8`.
  final int rssi;

  /// 0 none/unidentified, 1 JBD, 2 Daly, 3 JK — filled in from the
  /// advertisement, without connecting to the device.
  final int detectedType;
}

class BmsScanState {
  const BmsScanState({
    required this.status,
    required this.total,
    required this.results,
  });

  final BmsScanStatus status;

  /// What the controller says it saw. **Not `results.length`** — the reply is
  /// truncated to one frame while this still reports the true count.
  final int total;

  final List<BmsScanResult> results;

  /// The controller saw more than it could send.
  bool get truncated => total > results.length;

  static const int _headerLength = 2;
  static const int _resultLength = 8;

  static BmsScanState? decode(List<int> bytes) {
    if (bytes.length < _headerLength) return null;

    final results = <BmsScanResult>[];
    var offset = _headerLength;
    while (offset + _resultLength <= bytes.length) {
      final mac = List<int>.unmodifiable(bytes.sublist(offset, offset + 6));
      final raw = bytes[offset + 6];
      results.add(BmsScanResult(
        mac: mac,
        rssi: raw > 127 ? raw - 256 : raw,
        detectedType: bytes[offset + 7],
      ));
      offset += _resultLength;
    }

    return BmsScanState(
      status: _status(bytes[0]),
      total: bytes[1],
      results: List<BmsScanResult>.unmodifiable(results),
    );
  }

  static BmsScanStatus _status(int raw) => switch (raw) {
        0 => BmsScanStatus.idle,
        1 => BmsScanStatus.scanning,
        2 => BmsScanStatus.complete,
        3 => BmsScanStatus.error,
        _ => BmsScanStatus.unknown,
      };
}

/// Names for the four BMS types, for a dropdown and for a scan result's tag.
/// Matching the portal's labels exactly, so a pilot who knows one surface
/// recognises the other.
const Map<int, String> kBmsTypeNames = {
  0: 'Nenhum',
  1: 'JBD',
  2: 'Daly (D2 BLE)',
  3: 'JK BMS',
};
