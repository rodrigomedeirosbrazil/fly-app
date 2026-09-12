import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';

void main() {
  List<int> result(List<int> mac, int rssi, int type) =>
      [...mac, rssi & 0xFF, type];

  test('decodes status and an empty list', () {
    final s = BmsScanState.decode([2, 0])!;
    expect(s.status, BmsScanStatus.complete);
    expect(s.total, 0);
    expect(s.results, isEmpty);
  });

  test('decodes each result, rssi signed', () {
    final s = BmsScanState.decode([
      1,
      2,
      ...result([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF], -62, 3),
      ...result([1, 2, 3, 4, 5, 6], -88, 0),
    ])!;
    expect(s.status, BmsScanStatus.scanning);
    expect(s.total, 2);
    expect(s.results, hasLength(2));
    expect(s.results.first.mac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    expect(s.results.first.rssi, -62);
    expect(s.results.first.detectedType, 3);
    expect(s.results[1].rssi, -88);
    expect(s.results[1].detectedType, 0);
  });

  test('a count larger than the list is the controller truncating', () {
    // The firmware reports the true total and sends what fits in one frame.
    // Believing the list length would under-report what the scan saw.
    final s = BmsScanState.decode([
      2,
      30,
      ...result([1, 2, 3, 4, 5, 6], -50, 1),
    ])!;
    expect(s.total, 30);
    expect(s.results, hasLength(1));
    expect(s.truncated, isTrue);
  });

  test('a complete list is not truncated', () {
    final s = BmsScanState.decode(
        [2, 1, ...result([1, 2, 3, 4, 5, 6], -50, 1)])!;
    expect(s.truncated, isFalse);
  });

  test('a trailing partial result is dropped, not half decoded', () {
    final s = BmsScanState.decode([
      2,
      2,
      ...result([1, 2, 3, 4, 5, 6], -50, 1),
      1, 2, 3, // four bytes short of a result
    ])!;
    expect(s.results, hasLength(1));
    expect(s.total, 2);
  });

  test('a payload too short to hold the header is rejected whole', () {
    expect(BmsScanState.decode([2]), isNull);
    expect(BmsScanState.decode(const []), isNull);
  });

  test('an unknown status degrades instead of throwing', () {
    expect(BmsScanState.decode([9, 0])!.status, BmsScanStatus.unknown);
  });
}
