import 'package:fly_app/audio/tone_player.dart';

/// Records what it was asked to play and makes no sound.
///
/// Extracted so any test that builds a [TelemetryRepository] can hand it a
/// mirror. The repository's default builds a real `AudioPlayersTonePlayer`,
/// which touches the audioplayers platform channel — in a widget test that
/// throws `MissingPluginException` **asynchronously**, after the test has
/// already completed, and the failure is reported against whichever test the
/// runner is on. One repository built without a mirror reds a whole file, and
/// the stack trace points at the wrong line.
class FakeTonePlayer implements TonePlayer {
  final calls = <String>[];

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
  }) async =>
      calls.add('loop $frequency/$onMs/$offMs');

  @override
  Future<void> stopLoop() async => calls.add('stop');

  @override
  Future<void> silence() async => calls.add('silence');

  @override
  Future<void> dispose() async {}
}
