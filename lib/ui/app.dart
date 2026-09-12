import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../state/telemetry_repository.dart';
import 'connection_screen.dart';
import 'flight_screen.dart';
import 'settings/settings_navigation.dart';

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
        // Spelled out rather than derived from a seed. ColorScheme.fromSeed
        // tints every surface toward the seed hue, which turned the panel's
        // background green; the web telemetry page it mirrors is neutral, so
        // the only colour on screen is the data.
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3FB950), // gauge fill, live indicator
          secondary: Color(0xFF3B82F6), // throttle
          error: Color(0xFFF85149), // armed, faults, power cut
          tertiary: Color(0xFFD29922), // thermal reduction ramp
          surface: Color(0xFF0D1117), // page
          surfaceContainer: Color(0xFF161B22), // cards
          surfaceContainerHigh: Color(0xFF1C222B), // overlay
          surfaceContainerHighest: Color(0xFF272D38), // gauge track
          onSurface: Color(0xFFE6EDF3),
          onSurfaceVariant: Color(0xFF8B949E), // labels and units
          outline: Color(0xFF6E7681), // idle chips
          outlineVariant: Color(0xFF272D38), // dividers
        ),
        useMaterial3: true,

        // Buttons are chrome, and chrome is neutral here.
        //
        // Material 3's defaults put the label in `primary` on a container
        // barely lighter than the page, so on this palette every button
        // rendered as green text on almost nothing -- a primary action and a
        // disclosure toggle looked identical, and both competed with the one
        // green that means something: the gauge. All four scheme colours are
        // spoken for by data (green gauge, blue throttle, red armed, amber
        // reduction), so the buttons take none of them.
        //
        // The weights are what carry meaning instead: filled for the one
        // action per screen that writes to the aircraft, outlined for a
        // secondary action, text for a disclosure. A destructive action asks
        // for `error` explicitly at its call site.
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? const Color(0xFF1C222B)
                    : const Color(0xFF272D38)),
            foregroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? const Color(0xFF6E7681)
                    : const Color(0xFFE6EDF3)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size.fromHeight(46)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            side: WidgetStateProperty.resolveWith((states) => BorderSide(
                  color: states.contains(WidgetState.disabled)
                      ? const Color(0xFF272D38)
                      : const Color(0xFF6E7681),
                )),
            foregroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? const Color(0xFF6E7681)
                    : const Color(0xFFE6EDF3)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? const Color(0xFF6E7681)
                    : const Color(0xFF8B949E)),
          ),
        ),
      ),
      home: AnimatedBuilder(
        animation: _repo,
        builder: (context, _) {
          final frame = _repo.frame;
          if (frame == null && !_repo.isStale) {
            return ConnectionScreen(
              status: _repo.status,
              rejectedFrames: _repo.rejectedFrames,
              // Deferring the connection to a tap also gives Android's
              // permission dialog a reason the pilot has already seen.
              onConnect: () => _repo.start(),
              onCancel: () => _repo.stop(),
              onOpenSettings: () => _repo.openSettings(),
              onOpenLocationSettings: () => _repo.openLocationSettings(),
            );
          }
          return FlightScreen(
            frame: frame,
            stale: _repo.isStale,
            firmwareVersion: _repo.firmwareVersion,
            thermalConfig: _repo.thermalConfig,
            onOpenSettings: _repo.session == null
                ? null
                : () => openSettings(context, _repo),
          );
        },
      ),
    );
  }
}
