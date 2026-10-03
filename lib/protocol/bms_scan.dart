/// The `BMS_SCAN_STATUS` (`0x22`) reply.
///
/// `[status u8][count u8]` then `[mac 6][rssi i8][type u8]` per result.
///
/// The scan runs for 5 s on the controller (`WEB_SCAN_DURATION_SECONDS`) and
/// stores at most 16 results. **Advertising is suppressed for the whole
/// scan**: an existing connection survives it, but a client that drops cannot
/// find the controller again until it ends.
library;

import 'dart:convert';

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

/// One `BMS_SCAN_RESULT` (`0x2B`) reply:
/// `[mac 6][rssi i8][type u8][nameLen u8][name…][svcLen u8][services…]`.
///
/// What `BMS_SCAN_STATUS` cannot fit eight bytes a result: the advertised
/// name and the service UUIDs, as the portal shows them. Fetched per result
/// after a scan completes; firmware without it answers `ErrBadOp`.
class BmsScanDetail {
  const BmsScanDetail({
    required this.mac,
    required this.rssi,
    required this.detectedType,
    required this.name,
    required this.services,
  });

  final List<int> mac;
  final int rssi;
  final int detectedType;

  /// As advertised. Empty when the device advertised none.
  final String name;

  /// Comma-separated UUIDs, possibly truncated by the firmware to fit a frame.
  final String services;

  static BmsScanDetail? decode(List<int> bytes) {
    if (bytes.length < 9) return null;
    final nameLen = bytes[8];
    final svcLenAt = 9 + nameLen;
    if (bytes.length < svcLenAt + 1) return null;
    final svcLen = bytes[svcLenAt];
    if (bytes.length < svcLenAt + 1 + svcLen) return null;

    final rawRssi = bytes[6];
    return BmsScanDetail(
      mac: List<int>.unmodifiable(bytes.sublist(0, 6)),
      rssi: rawRssi > 127 ? rawRssi - 256 : rawRssi,
      detectedType: bytes[7],
      // A BLE name is UTF-8 and may be cut mid-character by the firmware's
      // truncation; a replacement character beats throwing.
      name: utf8.decode(bytes.sublist(9, svcLenAt), allowMalformed: true),
      services: utf8.decode(
        bytes.sublist(svcLenAt + 1, svcLenAt + 1 + svcLen),
        allowMalformed: true,
      ),
    );
  }
}
