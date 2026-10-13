// Renders the app's screens to PNG for the user manual, which lives in the
// fly-controller repo at docs/manual/. Not part of `flutter test` (it sits
// outside test/); run it through tool/manual_screens.sh.
//
// The images are goldens written with --update-goldens, so they are drawn by
// the real widgets with sample data and no controller. The fonts are loaded
// by hand because flutter_test otherwise draws every glyph as a box.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/app_update_policy.dart';
import 'package:fly_app/state/bms_scan_controller.dart';
import 'package:fly_app/state/buzzer_mirror.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/dfu_session.dart';
import 'package:fly_app/state/firmware_update_checker.dart';
import 'package:fly_app/state/github_release.dart';
import 'package:fly_app/state/log_browser.dart';
import 'package:fly_app/state/log_download.dart';
import 'package:fly_app/state/remote_pairing_controller.dart';
import 'package:fly_app/state/telemetry_repository.dart';
import 'package:fly_app/ui/connection_screen.dart';
import 'package:fly_app/ui/flight_screen.dart';
import 'package:fly_app/ui/settings/bms_settings_screen.dart';
import 'package:fly_app/ui/settings/firmware_screen.dart';
import 'package:fly_app/ui/settings/logs_screen.dart';
import 'package:fly_app/ui/settings/power_settings_screen.dart';
import 'package:fly_app/ui/settings/settings_index_screen.dart';
import 'package:fly_app/ui/settings/system_settings_screen.dart';
import 'package:fly_app/ui/settings/thermal_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test/state/fake_firmware_feed.dart';
import '../../test/state/fake_link.dart';
import '../../test/state/fake_session.dart';
import '../../test/state/fake_tone_player.dart';
import '../../test/ui/settings/bms_settings_screen_test.dart' as b;
import '../../test/ui/settings/firmware_screen_test.dart' as fw;
import '../../test/ui/settings/logs_screen_test.dart' as l;
import '../../test/ui/settings/power_settings_screen_test.dart' as p;
import '../../test/ui/settings/system_settings_screen_test.dart' as s;

/// A copy of the theme in lib/ui/app.dart, which builds it inline. Two
/// differences: the filled-button label names Roboto, because the test
/// binding has no platform default font, and a fallback family supplies the
/// glyphs Roboto lacks (the ⇄ on the bottom-row cards).
ThemeData appTheme() => ThemeData(
      fontFamilyFallback: const ['Sym'],
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF3FB950),
        secondary: Color(0xFF3B82F6),
        error: Color(0xFFF85149),
        tertiary: Color(0xFFD29922),
        surface: Color(0xFF0D1117),
        surfaceContainer: Color(0xFF161B22),
        surfaceContainerHigh: Color(0xFF1C222B),
        surfaceContainerHighest: Color(0xFF272D38),
        onSurface: Color(0xFFE6EDF3),
        onSurfaceVariant: Color(0xFF8B949E),
        outline: Color(0xFF6E7681),
        outlineVariant: Color(0xFF272D38),
      ),
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
                fontFamily: 'Roboto', fontSize: 15, fontWeight: FontWeight.w600),
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
    );

Widget app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: child,
    );

/// Roboto and the Material icons ship with the Flutter SDK. The ⇄ fallback
/// comes from macOS; without it the images still render, with a box there.
Future<void> loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Thin', 'Light', 'Regular', 'Medium', 'Bold', 'Black']) {
    final bytes = File('$dir/Roboto-$w.ttf').readAsBytesSync();
    roboto.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(
        File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
  final symbols = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
  if (symbols.existsSync()) {
    final sym = FontLoader('Sym')
      ..addFont(Future.value(ByteData.sublistView(symbols.readAsBytesSync())));
    await sym.load();
  }
}

const power = PowerConfig(
  capacityMah: 34000,
  minVoltageMv: 44100,
  maxVoltageMv: 58100,
  powerControlEnabled: true,
  voltageDividerRatio: 11.0,
);

const thermal = ThermalConfig(
  motorReductionStartC: 80,
  motorMaxC: 100,
  escReductionStartC: 70,
  escMaxC: 95,
  motorTempSource: 0,
);

/// A 393x852 pt phone at 2x. Long settings screens get a taller surface so
/// the whole form fits in one image.
void phone(WidgetTester tester, {bool landscape = false, double? height}) {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = landscape
      ? const Size(1704, 786)
      : Size(786, height ?? 1704);
  addTearDown(tester.view.reset);
}

Future<void> shot(WidgetTester tester, String name) async {
  await expectLater(
      find.byType(MaterialApp).first, matchesGoldenFile('shots/$name.png'));
}

TelemetryFrame cruise({
  ArmState arm = ArmState.armed,
  DisarmReason reason = DisarmReason.none,
  double? motor = 64,
  int powerPct = 100,
  Set<LimitCause>? causes,
  SignalState motorState = SignalState.valid,
  double throttle = 58,
}) =>
    TelemetryFrame(
      socCoulomb: 72,
      socVoltage: 69,
      voltage: 51.6,
      powerKw: 6.2,
      throttlePct: throttle.round(),
      throttleRaw: 14210,
      powerPct: powerPct,
      motorTempC: motor,
      motorTempSource: MotorTempSource.can,
      rpm: 5310,
      currentA: 121,
      escTempC: 52,
      armState: arm,
      disarmReason: reason,
      bmsMaxTempC: 33,
      cellMinMv: 3680,
      cellMaxMv: 3712,
      receivedAt: DateTime.utc(2026, 10, 12),
      limitCauses: causes,
      sessionSec: const Duration(minutes: 23, seconds: 41),
      remainingMin: 18,
      hourMeterSec: const Duration(hours: 41, minutes: 12, seconds: 8),
      uptimeSec: const Duration(minutes: 31, seconds: 5),
      cellDeltaMv: 32,
      motorTempState: motorState,
      escTempState: SignalState.valid,
      batteryVoltageState: SignalState.valid,
      hasTelemetry: true,
      bmsConnected: true,
      bmsConfigured: true,
      bmsLinkState: BmsLinkState.connected,
    );

Widget flight(TelemetryFrame? frame,
        {bool stale = false, LinkStatus? status, bool lastArmed = false}) =>
    app(FlightScreen(
      frame: frame,
      stale: stale,
      firmwareVersion: '2026-10-12.1',
      thermalConfig: thermal,
      controllerType: ControllerType.tmotor,
      powerConfig: power,
      linkStatus: status ?? LinkStatus.connected,
      lastFrameAt: DateTime.utc(2026, 10, 12),
      lastFrameArmed: lastArmed,
      now: () => DateTime.utc(2026, 10, 12, 0, 0, 7),
      onReconnect: () {},
      onDisconnect: () {},
      onOpenSettings: () {},
      onSetMuted: (_) async {},
    ));

ConnectionScreen connection(LinkStatus status,
        {UpdateAvailability update = const UpdateUnknown()}) =>
    ConnectionScreen(
      status: status,
      rejectedFrames: 0,
      onConnect: () {},
      onCancel: () {},
      onOpenSettings: () {},
      onOpenLocationSettings: () {},
      update: update,
      onOpenRelease: () {},
    );

/// An editor that has not authenticated yet, so the first save asks for the
/// PIN.
class _NeedsPin extends p.RecordingEditor {
  _NeedsPin() {
    queued.add(const SaveNeedsPin());
  }

  @override
  bool get authenticated => false;
}

void main() {
  setUpAll(loadFonts);
  // ignore: invalid_use_of_visible_for_testing_member
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('01 connection', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(connection(LinkStatus.idle,
        update: const UpdateAvailable('2026-10-12.1'))));
    await shot(tester, '01_conectar');
  });

  testWidgets('02 scanning', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(connection(LinkStatus.scanning)));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '02_procurando');
  });

  testWidgets('03 panel', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(cruise()));
    await tester.pumpAndSettle();
    await shot(tester, '03_painel');
  });

  testWidgets('04 reduced', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(
        cruise(motor: 91, powerPct: 64, causes: {LimitCause.motorTemp})));
    await tester.pumpAndSettle();
    await shot(tester, '04_potencia_reduzida');
  });

  testWidgets('05 fault', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(cruise(
        arm: ArmState.disarmed,
        reason: DisarmReason.throttleWiredInvalid,
        throttle: 0)));
    await tester.pumpAndSettle();
    await shot(tester, '05_falha_desarme');
  });

  testWidgets('06 reconnecting', (tester) async {
    phone(tester);
    await tester
        .pumpWidget(flight(null, stale: true, status: LinkStatus.scanning));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '06_reconectando');
  });

  testWidgets('07 sensor missing', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(cruise(
        arm: ArmState.disarmed,
        motor: null,
        motorState: SignalState.stale,
        throttle: 0)));
    await tester.pumpAndSettle();
    await shot(tester, '07_sensor_ausente');
  });

  testWidgets('08 drawer', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(
        cruise(motor: 91, powerPct: 64, causes: {LimitCause.motorTemp})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-bar')));
    await tester.pumpAndSettle();
    await shot(tester, '08_gaveta');
  });

  testWidgets('09 details', (tester) async {
    phone(tester);
    await tester.pumpWidget(flight(cruise()));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const Key('details-handle')), const Offset(0, 600));
    await tester.pumpAndSettle();
    await shot(tester, '09_detalhes');
  });

  testWidgets('10 chip dialog', (tester) async {
    phone(tester);
    await tester.pumpWidget(
        flight(null, stale: true, status: LinkStatus.idle, lastArmed: true));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('SEM SINAL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '10_dialogo_conexao');
  });

  testWidgets('11 landscape', (tester) async {
    phone(tester, landscape: true);
    await tester.pumpWidget(flight(cruise()));
    await tester.pumpAndSettle();
    await shot(tester, '11_paisagem');
  });

  testWidgets('12 settings index', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
      onOpenLogs: () {},
      firmwareVersion: '2026-10-12.1 · Tmotor',
      appVersion: '2026-10-12.1',
      appUpdate: const UpToDate(),
    )));
    await tester.pumpAndSettle();
    await shot(tester, '12_configuracoes');
  });

  testWidgets('13 power', (tester) async {
    phone(tester, height: 2150);
    await tester.pumpWidget(app(PowerSettingsScreen(
      editor: p.RecordingEditor(),
      config: power,
      armed: false,
      sensorVolts: 51.6,
      hasVoltageSensor: true,
      defaultDividerRatio: 11.0,
    )));
    await tester.pumpAndSettle();
    await shot(tester, '13_energia');
  });

  testWidgets('14 thermal', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(ThermalSettingsScreen(
      editor: p.RecordingEditor(),
      config: thermal,
      armed: false,
      selectableMotorTempSource: true,
    )));
    await tester.pumpAndSettle();
    await shot(tester, '14_termica');
  });

  testWidgets('15 bms connected', (tester) async {
    phone(tester, height: 2000);
    await tester.pumpWidget(app(BmsSettingsScreen(
      editor: b.RecordingEditor(),
      scanController: BmsScanController(b.RecordingEditor()),
      config: b.bmsConfig,
      armed: false,
      bmsConnected: true,
      bmsConfigured: true,
      bmsLinkState: BmsLinkState.connected,
      bmsPackVoltage: 51.62,
      bmsCurrentA: 120.4,
      bmsSoc: 71,
      bmsCellCount: 14,
      bmsMaxTempC: 33,
      cellDeltaMv: 32,
    )));
    await tester.pumpAndSettle();
    await shot(tester, '15_bms');
  });

  testWidgets('16 bms scan', (tester) async {
    phone(tester, height: 2000);
    final controller = BmsScanController(b.RecordingEditor(),
        pollInterval: const Duration(milliseconds: 10));
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(BmsSettingsScreen(
      editor: b.RecordingEditor(),
      scanController: controller,
      config: b.noBmsConfig,
      armed: false,
      bmsConnected: false,
      bmsConfigured: false,
    )));
    await tester.pumpAndSettle();
    await shot(tester, '16_bms_busca');
  });

  testWidgets('17 system', (tester) async {
    phone(tester, height: 2300);
    final editor = s.RecordingEditor();
    final pairing = RemotePairingController(editor);
    addTearDown(pairing.dispose);
    await tester.pumpWidget(app(SystemSettingsScreen(
      editor: editor,
      pairingController: pairing,
      config: s.remoteSystem,
      armed: false,
      hasRemoteLink: true,
    )));
    await tester.pumpAndSettle();
    await shot(tester, '17_sistema');
  });

  testWidgets('18 logs', (tester) async {
    phone(tester);
    final listSession = FakeSession();
    final browser = LogBrowser(listSession);
    addTearDown(browser.dispose);
    listSession.queueOk(l.page([
      ('20261012_002.csv', 61440),
      ('20261012_001.csv', 48200),
      ('20261005_001.csv', 15300),
    ], used: 126000));
    await tester.pumpWidget(app(LogsScreen(
      browser: browser,
      editor: l.DeletingEditor(),
      armed: false,
      download: () => LogDownload(FakeSession(), maxChunk: 100),
      share: (_, _) async {},
    )));
    await tester.pumpAndSettle();
    await shot(tester, '18_registros');
  });

  testWidgets('19 firmware', (tester) async {
    phone(tester, height: 2000);
    final link = FakeLink()
      ..fakeInfo = const ControlInfo(
        protocolVersion: 3,
        controllerType: ControllerType.tmotor,
        capabilities: 0,
        appVersion: '2026-10-02.2',
      );
    final feed = FakeFirmwareFeed();
    final updates = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: '2026-10-02.2',
      controllerType: ControllerType.tmotor,
    );
    final session = DfuSession(fw.SilentTransport(),
        pollInterval: const Duration(milliseconds: 10), maxRestarts: 1);
    final repo = TelemetryRepository(
      link: link,
      clock: DateTime.now,
      mirror: BuzzerMirror(FakeTonePlayer()),
    );
    await tester.pumpWidget(app(FirmwareSettingsScreen(
      repo: repo,
      session: session,
      updates: updates,
      armed: false,
      canUpdateFirmware: true,
      pickFile: () async => Uint8List(4)..[0] = 0xE9,
    )));
    await tester.pump();
    feed.releaseCalls.single.complete(GitHubRelease(
      tag: '2026-10-12.1',
      assets: [
        ReleaseAsset(name: 'firmware-tmotor-2026-10-12.1.bin', size: 1648312),
        ReleaseAsset(name: 'firmware-xag-2026-10-12.1.bin', size: 1601104),
      ],
    ));
    await tester.pumpAndSettle();
    await shot(tester, '19_firmware');
    // The repository's periodic tick was created inside the test's fake
    // clock, so it has to be stopped before the test ends.
    await tester.pumpWidget(const SizedBox());
    updates.dispose();
    session.dispose();
    repo.dispose();
  });

  testWidgets('20 pin', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(PowerSettingsScreen(
      editor: _NeedsPin(),
      config: power,
      armed: false,
      sensorVolts: 51.6,
      hasVoltageSensor: true,
    )));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save-power'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    await shot(tester, '20_pin');
  });
}
