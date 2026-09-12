import 'dart:async';

import '../audio/tone_player.dart';
import '../protocol/beep_event.dart';

/// How many repetitions a `reps: 0` event is played as.
///
/// The firmware means "continuous" and stops it with a later event on the
/// same layer — but layer 0 carries no stop, so a client that took it
/// literally would beep until the app closed. Six is long enough to be
/// unmistakable and short enough to end.
const int kContinuousCap = 6;

/// Plays the controller's buzzer on the phone.
///
/// Pure: it takes a [TonePlayer] and never touches an audio device, so every
/// rule below is table-tested in milliseconds. The rules come from
/// `bzPlayQueue` in the firmware's own telemetry page, which is the working
/// implementation of the same two layers.
///
/// **Two layers that compose rather than queue.** A state is a looping tone
/// that is on until stopped; an event is a finite pattern that must be *heard
/// over* a running state, so the state is paused, the event plays, and the
/// state resumes. Playing both at once is two tones, which is not what the
/// pilot hears standing next to the aircraft.
class BuzzerMirror {
  BuzzerMirror(this._player);

  final TonePlayer _player;

  bool _muted = false;
  bool get muted => _muted;

  _StatePattern? _state;

  /// The state pattern currently looping, if any. Exposed for tests and for
  /// nothing else.
  bool get statePlaying => _state != null;

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    if (_muted) {
      // Stops what is sounding now. Nothing is queued for later: unmuting
      // replays nothing, because a beep is a live signal and a backlog of old
      // ones is noise.
      await _player.silence();
    } else if (_state != null) {
      // A state that was still notionally on resumes, because it describes a
      // condition the aircraft is still in.
      await _player.startLoop(
        frequency: _state!.frequency,
        onMs: _state!.onMs,
        offMs: _state!.offMs,
      );
    }
  }

  Future<void> handle(BeepEvent event) async {
    switch (event.layer) {
      case BeepLayer.unknown:
        return;
      case BeepLayer.state:
        await _handleState(event);
      case BeepLayer.event:
        await _handleEvent(event);
    }
  }

  Future<void> _handleState(BeepEvent e) async {
    if (e.active) {
      // A repeated active for a state already running is ignored, or the loop
      // restarts mid-cycle and stutters.
      if (_state != null) return;
      _state = _StatePattern(e.frequency, e.onMs, e.offMs);
      if (_muted) return;
      await _player.startLoop(
          frequency: e.frequency, onMs: e.onMs, offMs: e.offMs);
      return;
    }

    if (_state == null) return;
    _state = null;
    if (_muted) return;
    await _player.stopLoop();
  }

  Future<void> _handleEvent(BeepEvent e) async {
    if (_muted) return;

    final resume = _state;
    if (resume != null) await _player.stopLoop();

    await _player.playPattern(
      frequency: e.frequency,
      onMs: e.onMs,
      offMs: e.offMs,
      reps: e.isContinuous ? kContinuousCap : e.reps,
    );

    // Re-read the field rather than trusting `resume`: a state event may have
    // arrived while the pattern was playing.
    final current = _state;
    if (current != null && !_muted) {
      await _player.startLoop(
        frequency: current.frequency,
        onMs: current.onMs,
        offMs: current.offMs,
      );
    }
  }

  /// A short tone, so the phone can be checked without arming the aircraft.
  ///
  /// Hearing the mirror otherwise requires the controller to do something
  /// worth beeping about, which on the ground means arming it. That made a
  /// silent phone indistinguishable from a phone with nothing to play — and
  /// the first build was silent, because the audio session respected the
  /// iPhone's Ring/Silent switch.
  ///
  /// **Not a replay.** It is the same two notes every time, carrying nothing
  /// about what the controller has been doing, and it goes through the event
  /// path so a running state tone is paused and resumed exactly as a real
  /// event would be.
  /// Moves a running state tone to [frequency], the way the firmware retunes
  /// its buzzer.
  ///
  /// Restarting the loop is correct here and not the stutter the repeated
  /// transition guard exists to prevent: the pitch genuinely changed, and the
  /// firmware does the same thing — `ToneTransition::Retune` is literally
  /// `toneOff(); toneOn(newFreq)`. Nothing happens when the frequency is
  /// unchanged, which is what keeps a 1 Hz caller from restarting the loop
  /// every second.
  Future<void> retuneState(int? frequency) async {
    final current = _state;
    if (current == null || frequency == null) return;
    if (current.frequency == frequency) return;

    _state = _StatePattern(frequency, current.onMs, current.offMs);
    if (_muted) return;
    await _player.startLoop(
      frequency: frequency,
      onMs: current.onMs,
      offMs: current.offMs,
    );
  }

  Future<void> confirmAudible() => handle(const BeepEvent(
        seq: 0,
        frequency: 2000,
        onMs: 90,
        offMs: 60,
        reps: 2,
        layer: BeepLayer.event,
        active: true,
      ));

  Future<void> dispose() => _player.dispose();
}

class _StatePattern {
  const _StatePattern(this.frequency, this.onMs, this.offMs);
  final int frequency;
  final int onMs;
  final int offMs;
}

/// The gesture tones sweep, and this is the firmware's own arithmetic.
///
/// `main.cpp` retunes the state layer on every on→off edge:
///
/// ```c
/// ArmCharging:    SOUND_GESTURE_FREQ_MIN + armCharge * (MAX - MIN) / 100
/// DisarmRamping:  SOUND_GESTURE_FREQ_MAX - (100 - powerScale) * (MAX - MIN) / 100
/// ```
///
/// with `SOUND_GESTURE_FREQ_MIN` 1800 and `_MAX` 2500 in `config.h`. Both
/// reduce to the same line, which is why there is one function here.
///
/// **The sixth hand-copied fly-controller contract in this repo**, and the
/// only one that is arithmetic rather than layout. It exists because the
/// firmware pushes a beep event on the state *transition* only — carrying the
/// base 1800 Hz — and never on a retune, so a client that plays what it is
/// sent holds a flat tone while the aircraft sweeps. The scalars are in every
/// telemetry frame, so the app can derive the same pitch.
///
/// It steps at 1 Hz where the aircraft steps about ten times faster, so the
/// sweep is coarser than the real one. The smooth fix belongs in the
/// firmware: append the state frequency to the telemetry struct, which the
/// append rule allows without a version bump.
const int kGestureFreqMin = 1800;
const int kGestureFreqMax = 2500;

int gestureFrequency(int scalar) =>
    kGestureFreqMin +
    (scalar.clamp(0, 100) * (kGestureFreqMax - kGestureFreqMin)) ~/ 100;

/// Which gesture tone the aircraft is making, from the same conditions
/// `main.cpp` uses to choose one, or null when it is making neither.
int? gestureFrequencyFor({
  required bool isArmed,
  required int? armCharge,
  required int? powerScale,
}) {
  if (!isArmed && (armCharge ?? 0) > 0) return gestureFrequency(armCharge!);
  if (isArmed && (powerScale ?? 100) < 100) {
    return gestureFrequency(powerScale!);
  }
  return null;
}
