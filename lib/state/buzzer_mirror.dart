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

  Future<void> dispose() => _player.dispose();
}

class _StatePattern {
  const _StatePattern(this.frequency, this.onMs, this.offMs);
  final int frequency;
  final int onMs;
  final int offMs;
}
