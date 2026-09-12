import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/audio/tone_player.dart';
import 'package:fly_app/protocol/beep_event.dart';
import 'package:fly_app/state/buzzer_mirror.dart';

class FakePlayer implements TonePlayer {
  final calls = <String>[];
  bool looping = false;

  @override
  Future<void> playPattern({
    required int frequency,
    required int onMs,
    required int offMs,
    required int reps,
  }) async =>
      calls.add('play $frequency/$onMs/$offMs x$reps');

  @override
  Future<void> startLoop({
    required int frequency,
    required int onMs,
    required int offMs,
  }) async {
    looping = true;
    calls.add('loop $frequency/$onMs/$offMs');
  }

  @override
  Future<void> stopLoop() async {
    looping = false;
    calls.add('stop');
  }

  @override
  Future<void> silence() async => calls.add('silence');

  @override
  Future<void> dispose() async {}
}

void main() {
  test('a state transition starts the loop', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final event = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    await mirror.handle(event);

    expect(player.calls, ['loop 800/100/100']);
  });

  test('a repeated active state does not restart the loop', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final event = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    // Send the same active event twice
    await mirror.handle(event);
    await mirror.handle(event);

    // Should only have one 'loop' call, not two
    expect(player.calls, ['loop 800/100/100']);
  });

  test('a state stops on active false', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final startEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    final stopEvent = BeepEvent(
      seq: 2,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: false,
    );

    await mirror.handle(startEvent);
    await mirror.handle(stopEvent);

    expect(player.calls, ['loop 800/100/100', 'stop']);
  });

  test('a stop with nothing running is ignored', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final stopEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: false,
    );

    await mirror.handle(stopEvent);

    expect(player.calls, []);
  });

  test('an event with no state running just plays', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final event = BeepEvent(
      seq: 1,
      frequency: 1200,
      onMs: 50,
      offMs: 50,
      reps: 3,
      layer: BeepLayer.event,
      active: true,
    );

    await mirror.handle(event);

    expect(player.calls, ['play 1200/50/50 x3']);
  });

  test('an event pauses a running state and resumes it', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final stateEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    final eventEvent = BeepEvent(
      seq: 2,
      frequency: 1200,
      onMs: 50,
      offMs: 50,
      reps: 2,
      layer: BeepLayer.event,
      active: true,
    );

    await mirror.handle(stateEvent);
    await mirror.handle(eventEvent);

    // The state should resume with its ORIGINAL pattern, not the event's
    expect(player.calls, [
      'loop 800/100/100',
      'stop',
      'play 1200/50/50 x2',
      'loop 800/100/100',
    ]);
  });

  test('a continuous event is capped', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final event = BeepEvent(
      seq: 1,
      frequency: 1000,
      onMs: 100,
      offMs: 50,
      reps: 0, // Continuous
      layer: BeepLayer.event,
      active: true,
    );

    await mirror.handle(event);

    expect(player.calls, ['play 1000/100/50 x$kContinuousCap']);
  });

  test('an unknown layer is ignored', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final event = BeepEvent(
      seq: 1,
      frequency: 1000,
      onMs: 100,
      offMs: 50,
      reps: 3,
      layer: BeepLayer.unknown,
      active: true,
    );

    await mirror.handle(event);

    expect(player.calls, []);
  });

  test('muted swallows everything', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    await mirror.setMuted(true);
    player.calls.clear();

    final stateEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    await mirror.handle(stateEvent);

    expect(player.calls, []);
  });

  test('muting mid-state stops the loop', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final stateEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    await mirror.handle(stateEvent);
    await mirror.setMuted(true);

    expect(player.calls, ['loop 800/100/100', 'silence']);
  });

  test('unmuting does not replay what was missed', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    final stateEvent = BeepEvent(
      seq: 1,
      frequency: 800,
      onMs: 100,
      offMs: 100,
      reps: 0,
      layer: BeepLayer.state,
      active: true,
    );

    await mirror.handle(stateEvent);
    await mirror.setMuted(true);
    player.calls.clear();

    await mirror.setMuted(false);

    // Should resume the state, not replay the event
    expect(player.calls, ['loop 800/100/100']);
  });

  test('the confirmation tone plays, and is the same every time', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    await mirror.confirmAudible();
    await mirror.confirmAudible();

    expect(player.calls, ['play 2000/90/60 x2', 'play 2000/90/60 x2'],
        reason: 'it reports the speaker, not the aircraft');
  });

  test('the confirmation pauses and resumes a running state', () async {
    // It goes through the event path deliberately, so it cannot leave a state
    // tone stopped -- which a separate "just play something" shortcut could.
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);

    await mirror.handle(const BeepEvent(
        seq: 1,
        frequency: 800,
        onMs: 100,
        offMs: 100,
        reps: 0,
        layer: BeepLayer.state,
        active: true));
    player.calls.clear();

    await mirror.confirmAudible();

    expect(player.calls, ['stop', 'play 2000/90/60 x2', 'loop 800/100/100']);
  });

  test('muted, the confirmation says nothing', () async {
    final player = FakePlayer();
    final mirror = BuzzerMirror(player);
    await mirror.setMuted(true);
    player.calls.clear();

    await mirror.confirmAudible();

    expect(player.calls, isEmpty);
  });

  group('the gesture sweep', () {
    test('follows the firmware arithmetic', () {
      // main.cpp: MIN + scalar * (MAX - MIN) / 100, with 1800 and 2500.
      expect(gestureFrequency(0), 1800);
      expect(gestureFrequency(100), 2500);
      expect(gestureFrequency(50), 2150);
    });

    test('a scalar past the ends is clamped', () {
      expect(gestureFrequency(-10), 1800);
      expect(gestureFrequency(150), 2500);
    });

    test('arm charge sweeps while disarmed', () {
      expect(
          gestureFrequencyFor(isArmed: false, armCharge: 50, powerScale: 100),
          2150);
    });

    test('the disarm ramp sweeps while armed', () {
      expect(
          gestureFrequencyFor(isArmed: true, armCharge: 0, powerScale: 20),
          1940);
    });

    test('neither gesture, no frequency', () {
      expect(
          gestureFrequencyFor(isArmed: false, armCharge: 0, powerScale: 100),
          isNull);
      expect(
          gestureFrequencyFor(isArmed: true, armCharge: 0, powerScale: 100),
          isNull);
    });

    test('retuning a running state restarts it at the new pitch', () async {
      final player = FakePlayer();
      final mirror = BuzzerMirror(player);
      await mirror.handle(const BeepEvent(
          seq: 1,
          frequency: 1800,
          onMs: 60,
          offMs: 40,
          reps: 0,
          layer: BeepLayer.state,
          active: true));
      player.calls.clear();

      await mirror.retuneState(2150);

      expect(player.calls, ['loop 2150/60/40'],
          reason: 'the envelope is kept; only the pitch moves');
    });

    test('an unchanged frequency does not restart the loop', () async {
      // The caller runs at 1 Hz. Restarting every second would be the same
      // stutter the repeated-transition guard exists to prevent.
      final player = FakePlayer();
      final mirror = BuzzerMirror(player);
      await mirror.handle(const BeepEvent(
          seq: 1,
          frequency: 1800,
          onMs: 60,
          offMs: 40,
          reps: 0,
          layer: BeepLayer.state,
          active: true));
      player.calls.clear();

      await mirror.retuneState(1800);
      await mirror.retuneState(1800);

      expect(player.calls, isEmpty);
    });

    test('retuning with no state running does nothing', () async {
      final player = FakePlayer();
      final mirror = BuzzerMirror(player);

      await mirror.retuneState(2150);

      expect(player.calls, isEmpty);
    });
  });
}
