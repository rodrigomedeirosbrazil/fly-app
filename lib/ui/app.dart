import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../state/telemetry_repository.dart';
import 'connection_screen.dart';
import 'flight_screen.dart';

class FlyApp extends StatefulWidget {
  const FlyApp({super.key});

  @override
  State<FlyApp> createState() => _FlyAppState();
}

class _FlyAppState extends State<FlyApp> {
  final TelemetryRepository _repo = TelemetryRepository();

  @override
  void initState() {
    super.initState();
    // The pilot is not going to tap the screen mid-flight to keep it awake.
    WakelockPlus.enable();
    _repo.start();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _repo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fly Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC84),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: AnimatedBuilder(
        animation: _repo,
        builder: (context, _) {
          final frame = _repo.frame;
          if (frame == null && !_repo.isStale) {
            return ConnectionScreen(
              status: _repo.status,
              rejectedFrames: _repo.rejectedFrames,
            );
          }
          return FlightScreen(frame: frame, stale: _repo.isStale);
        },
      ),
    );
  }
}
