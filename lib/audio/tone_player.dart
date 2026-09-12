import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// What `BuzzerMirror` talks to. Abstract so every rule about layers,
/// transitions and resumes is table-tested with no sound card — the same
/// reason `ble/` is the only file that touches a radio.
abstract class TonePlayer {
  /// Plays [reps] repetitions of [onMs] on and [offMs] off, and completes
  /// when the last one has been scheduled.
  Future<void> playPattern({
    required int frequency,
    required int onMs,
    required int offMs,
    required int reps,
  });

  /// Starts a tone that loops until [stopLoop].
  Future<void> startLoop({
    required int frequency,
    required int onMs,
    required int offMs,
  });

  Future<void> stopLoop();

  /// Silences everything now and drops anything scheduled.
  Future<void> silence();

  Future<void> dispose();
}

const int kSampleRate = 22050;

/// A mono 16-bit PCM square wave, as a WAV a player will take from memory.
///
/// Square rather than sine because that is what the controller's piezo makes,
/// and the point of this feature is that the two sound like the same
/// instrument.
///
/// Returns empty for anything unplayable rather than a header describing
/// samples that are not there.
Uint8List buildSquareWaveWav({
  required int frequency,
  required int milliseconds,
}) {
  if (milliseconds <= 0 || frequency <= 0) return Uint8List(0);

  final sampleCount = (kSampleRate * milliseconds / 1000).round();
  if (sampleCount <= 0) return Uint8List(0);

  final dataBytes = sampleCount * 2;
  final out = ByteData(44 + dataBytes);

  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little); // PCM chunk size
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, kSampleRate, Endian.little);
  out.setUint32(28, kSampleRate * 2, Endian.little); // byte rate
  out.setUint16(32, 2, Endian.little); // block align
  out.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);

  // Half amplitude: the phone's speaker clips a full-scale square, and a
  // clipped square is a rasp rather than the controller's tone.
  const amplitude = 12000;
  final samplesPerCycle = max(2, (kSampleRate / frequency).round());

  for (var i = 0; i < sampleCount; i++) {
    final high = (i % samplesPerCycle) < samplesPerCycle / 2;
    out.setInt16(44 + i * 2, high ? amplitude : -amplitude, Endian.little);
  }

  return out.buffer.asUint8List();
}

/// The only thing in this app that makes a sound.
///
/// **Mixes rather than interrupts.** A paramotor pilot may be flying by
/// XCTrack's vario, and an app that seized the audio session to beep would
/// silence the instrument being flown by. That is a requirement, not a
/// preference, and it is why the audio context is set explicitly on both
/// platforms rather than left at the plugin's default.
class AudioPlayersTonePlayer implements TonePlayer {
  AudioPlayersTonePlayer();

  final AudioPlayer _player = AudioPlayer();
  final Map<int, Uint8List> _cache = {};

  bool _loopStopped = true;
  int _generation = 0;

  static final AudioContext _mixing = AudioContext(
    iOS: AudioContextIOS(
      // `playback`, NOT `ambient`. The plugin's own documentation is explicit:
      // ambient is "Silenced by the Ring/Silent switch = Yes". A pilot's phone
      // is on silent, in a pocket, under a motor -- so ambient meant no sound
      // at all, which is exactly what the first build did.
      //
      // playback ignores the switch, and `mixWithOthers` is the override that
      // stops it interrupting other audio. Both properties are needed and
      // only this pair gives both: a warning has to be audible on a silenced
      // phone, and it must not silence the vario the pilot is flying by.
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
    android: AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _player.setAudioContext(_mixing);
    await _player.setReleaseMode(ReleaseMode.stop);
    _configured = true;
  }

  Uint8List _wav(int frequency, int onMs) =>
      _cache.putIfAbsent(frequency * 100000 + onMs,
          () => buildSquareWaveWav(frequency: frequency, milliseconds: onMs));

  @override
  Future<void> playPattern({
    required int frequency,
    required int onMs,
    required int offMs,
    required int reps,
  }) async {
    await _ensureConfigured();
    final bytes = _wav(frequency, onMs);
    if (bytes.isEmpty) return;

    for (var i = 0; i < reps; i++) {
      await _player.play(BytesSource(bytes));
      await Future<void>.delayed(Duration(milliseconds: onMs + offMs));
    }
  }

  @override
  Future<void> startLoop({
    required int frequency,
    required int onMs,
    required int offMs,
  }) async {
    await _ensureConfigured();
    final bytes = _wav(frequency, onMs);
    if (bytes.isEmpty) return;

    _loopStopped = false;
    final generation = ++_generation;

    // A Dart-timed loop rather than ReleaseMode.loop: the pattern has a gap,
    // and looping the file alone would run the tone together.
    while (!_loopStopped && generation == _generation) {
      await _player.play(BytesSource(bytes));
      await Future<void>.delayed(Duration(milliseconds: onMs + offMs));
    }
  }

  @override
  Future<void> stopLoop() async {
    _loopStopped = true;
    _generation++;
    await _player.stop();
  }

  @override
  Future<void> silence() async {
    await stopLoop();
  }

  @override
  Future<void> dispose() async {
    _loopStopped = true;
    _generation++;
    await _player.dispose();
  }
}
