import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/link_health.dart';

const healthy =
    r'$XCTOD,87,91,50.400,1.5,42,1234,100,61,can,4200,30,54,ARMED,38,3712,3745';

final t0 = DateTime.utc(2026, 9, 9, 12, 0, 0);
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

void main() {
  test('starts with no frame and no rejections', () {
    final h = LinkHealth();
    expect(h.frameAt(t0), isNull);
    expect(h.isStale(t0), isFalse);
    expect(h.rejectedCount, 0);
  });

  test('a valid line becomes the current frame', () {
    final h = LinkHealth();
    expect(h.onLine(healthy, t0), isTrue);
    expect(h.frameAt(t0)!.socCoulomb, 87);
  });

  test('the frame survives up to the staleness threshold', () {
    final h = LinkHealth()..onLine(healthy, t0);
    expect(h.frameAt(at(2)), isNotNull);
    expect(h.isStale(at(2)), isFalse);
  });

  test('past the threshold the frame is withheld, not frozen', () {
    final h = LinkHealth()..onLine(healthy, t0);
    expect(h.frameAt(at(4)), isNull);
    expect(h.isStale(at(4)), isTrue);
  });

  test('a fresh line clears staleness', () {
    final h = LinkHealth()..onLine(healthy, t0);
    expect(h.isStale(at(4)), isTrue);
    h.onLine(healthy, at(5));
    expect(h.isStale(at(5)), isFalse);
    expect(h.frameAt(at(5)), isNotNull);
  });

  test('a rejected line is counted and does not replace the good frame', () {
    final h = LinkHealth()..onLine(healthy, t0);
    expect(h.onLine(r'$XCTOD,87,91,', at(1)), isFalse);
    expect(h.rejectedCount, 1);
    expect(h.frameAt(at(1))!.socCoulomb, 87);
  });

  test('a rejected line does not refresh the clock', () {
    final h = LinkHealth()..onLine(healthy, t0);
    h.onLine('garbage', at(2));
    expect(h.isStale(at(4)), isTrue);
  });

  test('reset clears the frame but keeps the rejection tally', () {
    final h = LinkHealth()
      ..onLine(healthy, t0)
      ..onLine('garbage', t0);
    h.reset();
    expect(h.frameAt(t0), isNull);
    expect(h.isStale(t0), isFalse);
    expect(h.rejectedCount, 1);
  });
}
