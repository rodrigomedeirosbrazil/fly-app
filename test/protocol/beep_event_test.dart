import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/beep_event.dart';

Uint8List sample({
  int seq = 7,
  int frequency = 2000,
  int onMs = 120,
  int offMs = 80,
  int reps = 3,
  int layer = 0,
  int active = 1,
}) {
  final d = ByteData(13);
  d.setUint32(0, seq, Endian.little);
  d.setUint16(4, frequency, Endian.little);
  d.setUint16(6, onMs, Endian.little);
  d.setUint16(8, offMs, Endian.little);
  d.setUint8(10, reps);
  d.setUint8(11, layer);
  d.setUint8(12, active);
  return d.buffer.asUint8List();
}

void main() {
  test('decodes all seven fields at their offsets', () {
    final e = BeepEvent.decode(sample())!;
    expect(e.seq, 7);
    expect(e.frequency, 2000);
    expect(e.onMs, 120);
    expect(e.offMs, 80);
    expect(e.reps, 3);
    expect(e.layer, BeepLayer.event);
    expect(e.active, isTrue);
  });

  test('layer 1 is the state layer', () {
    expect(BeepEvent.decode(sample(layer: 1))!.layer, BeepLayer.state);
  });

  test('an unknown layer degrades instead of throwing', () {
    // Same rule as DisarmReason: newer firmware must not crash this app.
    expect(BeepEvent.decode(sample(layer: 9))!.layer, BeepLayer.unknown);
  });

  test('active is a flag, not a count', () {
    expect(BeepEvent.decode(sample(active: 0))!.active, isFalse);
    expect(BeepEvent.decode(sample(active: 1))!.active, isTrue);
  });

  test('reps 0 means continuous', () {
    expect(BeepEvent.decode(sample(reps: 0))!.isContinuous, isTrue);
    expect(BeepEvent.decode(sample(reps: 1))!.isContinuous, isFalse);
  });

  test('a short payload is rejected whole', () {
    // Same rule as every other decode here: half a struct is corruption, and
    // decoding as far as the bytes go would play a plausible wrong tone.
    expect(BeepEvent.decode(sample().sublist(0, 12)), isNull);
    expect(BeepEvent.decode(const []), isNull);
  });

  test('a longer payload decodes its known prefix', () {
    expect(BeepEvent.decode([...sample(), 9, 9])!.frequency, 2000);
  });
}
