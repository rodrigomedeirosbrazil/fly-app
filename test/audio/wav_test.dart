import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/audio/tone_player.dart';

void main() {
  test('writes a RIFF/WAVE header a player will accept', () {
    final wav = buildSquareWaveWav(frequency: 1000, milliseconds: 100);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
  });

  test('the declared sizes match the bytes that follow them', () {
    // A header that lies about its length is the failure mode here: some
    // players truncate, some play noise, and neither says why.
    final wav = buildSquareWaveWav(frequency: 1000, milliseconds: 100);
    final view = ByteData.sublistView(wav);

    expect(view.getUint32(4, Endian.little), wav.length - 8);
    expect(view.getUint32(40, Endian.little), wav.length - 44);
  });

  test('length follows the duration', () {
    final short = buildSquareWaveWav(frequency: 1000, milliseconds: 60);
    final long = buildSquareWaveWav(frequency: 1000, milliseconds: 120);
    expect(long.length - 44, (short.length - 44) * 2);
  });

  test('a zero or negative duration produces nothing playable', () {
    expect(buildSquareWaveWav(frequency: 1000, milliseconds: 0), isEmpty);
    expect(buildSquareWaveWav(frequency: 1000, milliseconds: -5), isEmpty);
  });

  test('a frequency outside hearing is clamped, not rendered', () {
    // The firmware can ask for anything a uint16 holds. Rendering 40 kHz
    // wastes samples on nothing and 0 Hz is a divide by zero.
    expect(buildSquareWaveWav(frequency: 0, milliseconds: 50), isEmpty);
    expect(
        buildSquareWaveWav(frequency: 65535, milliseconds: 50), isNotEmpty);
  });
}
