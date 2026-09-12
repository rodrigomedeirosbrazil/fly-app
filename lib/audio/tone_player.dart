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

/// A whole pattern — [reps] repetitions of a tone and the silence after it —
/// as one WAV.
///
/// Baked into a single buffer rather than played once per repetition with a
/// Dart delay between. The gaps are then **sample-accurate**, where a timed
/// sequence carried the plugin's per-play latency into every gap and made a
/// pattern sound slower and looser than the piezo it mirrors. On iOS that
/// latency includes a temp-file write per play, which is not small.
Uint8List buildPatternWav({
  required int frequency,
  required int onMs,
  required int offMs,
  required int reps,
}) {
  if (reps <= 0) return Uint8List(0);
  final tone = buildSquareWaveWav(frequency: frequency, milliseconds: onMs);
  if (tone.isEmpty) return Uint8List(0);

  final toneData = tone.sublist(44);
  final gapBytes = (kSampleRate * offMs / 1000).round() * 2;
  final dataBytes = (toneData.length + gapBytes) * reps;

  final out = Uint8List(44 + dataBytes);
  // The tone's own header describes one repetition; copy it, then correct the
  // two lengths for the whole buffer.
  out.setRange(0, 44, tone);
  final view = ByteData.sublistView(out);
  view.setUint32(4, 36 + dataBytes, Endian.little);
  view.setUint32(40, dataBytes, Endian.little);

  var offset = 44;
  for (var i = 0; i < reps; i++) {
    out.setRange(offset, offset + toneData.length, toneData);
    // The gap stays zeroed, which is silence.
    offset += toneData.length + gapBytes;
  }

  return out;
}

/// The only thing in this app that makes a sound.
///
/// **Mixes rather than interrupts.** A paramotor pilot may be flying by
/// XCTrack's vario, and an app that seized the audio session to beep would
/// silence the instrument being flown by. That is a requirement, not a
/// preference, and it is why the audio context is set explicitly on both
/// platforms rather than left at the plugin's default.
class AudioPlayersTonePlayer implements TonePlayer {
  AudioPlayersTonePlayer({this.onError});

  /// Called with whatever went wrong, because a beep that fails silently is
  /// indistinguishable from a controller with nothing to say.
  ///
  /// This subsystem reached hardware twice while inaudible, and both times
  /// the app had no way to tell the pilot -- or me -- which of the two it
  /// was. Every call into the plugin is wrapped for that reason.
  final void Function(Object error)? onError;

  final AudioPlayer _player = AudioPlayer();
  final Map<int, Uint8List> _cache = {};

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

  /// The WAV, told apart from anything else by its media type.
  ///
  /// **The mime type is not optional on iOS.** `setSourceBytes` there writes
  /// the bytes to a temp file named after their hash, with **no extension**,
  /// and hands the path to `AVURLAsset`. Without a type to go on, AVFoundation
  /// has to sniff a headerless-looking filename and does not play it. The
  /// darwin side passes this straight to `AVURLAssetOverrideMIMETypeKey`.
  BytesSource _source(Uint8List bytes) =>
      BytesSource(bytes, mimeType: 'audio/wav');

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      onError?.call(e);
    }
  }

  Uint8List _wav(int frequency, int onMs, int offMs, int reps) =>
      _cache.putIfAbsent(
        Object.hash(frequency, onMs, offMs, reps),
        () => buildPatternWav(
          frequency: frequency,
          onMs: onMs,
          offMs: offMs,
          reps: reps,
        ),
      );

  @override
  Future<void> playPattern({
    required int frequency,
    required int onMs,
    required int offMs,
    required int reps,
  }) async {
    await _guard(() async {
      await _ensureConfigured();
      final bytes = _wav(frequency, onMs, offMs, reps);
      if (bytes.isEmpty) return;

      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.play(_source(bytes));
    });
  }

  @override
  Future<void> startLoop({
    required int frequency,
    required int onMs,
    required int offMs,
  }) async {
    await _guard(() async {
      await _ensureConfigured();
      // One cycle — the tone AND the gap after it — looped by the player.
      // The gap is baked into the buffer, so looping the file is seamless;
      // the Dart-timed loop this replaces paid the plugin's play latency on
      // every iteration and drifted slower than the aircraft's buzzer.
      final bytes = _wav(frequency, onMs, offMs, 1);
      if (bytes.isEmpty) return;

      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(_source(bytes));
    });
  }

  @override
  Future<void> stopLoop() async {
    await _guard(_player.stop);
  }

  @override
  Future<void> silence() async {
    await stopLoop();
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
  }
}
