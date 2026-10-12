import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/flight/number_format.dart';

void main() {
  test('decimal uses a comma', () {
    expect(decimal(50.84, 1), '50,8');
    expect(decimal(3.6, 2), '3,60');
    expect(decimal(-1.26, 1), '-1,3');
  });

  test('grouped separates thousands with a dot', () {
    expect(grouped(0), '0');
    expect(grouped(999), '999');
    expect(grouped(5830), '5.830');
    expect(grouped(1234567), '1.234.567');
    expect(grouped(-5830), '-5.830');
  });

  test('clock keeps counting minutes past an hour', () {
    expect(clock(const Duration(seconds: 330)), '05:30');
    expect(clock(const Duration(minutes: 75, seconds: 2)), '75:02');
  });

  test('hours is h:mm:ss for counters that run to hundreds of hours', () {
    expect(hours(const Duration(seconds: 123456)), '34:17:36');
  });
}
