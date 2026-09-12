import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/state/telemetry_repository.dart';
import 'package:fly_app/ui/settings/settings_navigation.dart';

import '../../state/fake_link.dart';

void main() {
  late FakeLink link;
  late TelemetryRepository repo;

  setUp(() {
    link = FakeLink();
    repo = TelemetryRepository(link: link, clock: DateTime.now);
  });

  tearDown(() => repo.dispose());

  /// Pumps a host with one button that opens settings, the way app.dart does.
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => openSettings(context, repo),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
  }

  testWidgets('the power screen keeps seeing the aircraft arm', (tester) async {
    // THE REGRESSION THIS FILE EXISTS FOR.
    //
    // app.dart read repo.frame?.isArmed inside a MaterialPageRoute builder,
    // which runs once, so arming with the settings screen open left saving
    // enabled. Every widget test passed, because each pumped a fresh widget
    // with the flag already set -- they tested the widget, not the wiring.
    //
    // BOTH assertions matter. Without the first one this test is vacuous: the
    // button is also inert when there is no config to edit, so "disabled at
    // the end" passes whether or not the route follows the repository. The
    // first assertion is what proves the button had somewhere to fall from.
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample(armed: false));
    await tester.pumpAndSettle();

    // The screen needs a Power group to edit before its save button can ever
    // be live. Thermal is requested first, then Power.
    // pumpEventQueue, not pumpAndSettle: the reply reaches the session through
    // a broadcast stream, and the repository only asks for Power after that
    // await resolves. Pumping frames alone never drains it.
    link.replyThermal(0);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();
    expect(link.commands, hasLength(2),
        reason: 'the repository asks for Thermal then Power');
    link.replyPower(1);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await pumpHost(tester);
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Energia'));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save-power'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
        reason: 'disarmed with a config loaded, saving is available');

    link.feedBinary(binarySample(armed: true));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(save).onPressed, isNull,
        reason: 'the route must follow the repository, not a snapshot');
  });

  testWidgets('the power screen keeps seeing the live pack voltage',
      (tester) async {
    // Calibration needs the reading that is true when it is applied, not the
    // one that was true when the screen opened.
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample(batteryMv: 50400));
    await tester.pumpAndSettle();

    // Wait for and reply to CFG_GET requests for configs.
    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.isNotEmpty) link.replyThermal(0);
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 1) link.replyPower(1);
    await tester.pumpAndSettle();

    await pumpHost(tester);
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Energia'));
    await tester.pumpAndSettle();

    expect(find.textContaining('50.40'), findsWidgets);

    link.feedBinary(binarySample(batteryMv: 49000));
    await tester.pumpAndSettle();

    expect(find.textContaining('49.00'), findsWidgets);
  });

  testWidgets('the index reaches the thermal screen too', (tester) async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample());
    await tester.pumpAndSettle();

    // Wait for and reply to CFG_GET requests for configs.
    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.isNotEmpty) link.replyThermal(0);
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 1) link.replyPower(1);
    await tester.pumpAndSettle();

    await pumpHost(tester);
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Térmica'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('save-thermal')), findsOneWidget);
  });

  testWidgets('the bms screen keeps seeing the aircraft arm', (tester) async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample(armed: false));
    await tester.pumpAndSettle();

    // Wait for and reply to CFG_GET requests for configs.
    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.isNotEmpty) link.replyThermal(0);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 1) link.replyPower(1);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 2) link.replyBms(2);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 3) link.replySystem(3);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await pumpHost(tester);
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BMS'));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save-bms'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
        reason: 'disarmed with a config loaded, saving is available');

    link.feedBinary(binarySample(armed: true));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(save).onPressed, isNull,
        reason: 'the route must follow the repository, not a snapshot');
  });

  testWidgets('the system screen keeps seeing the aircraft arm',
      (tester) async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample(armed: false));
    await tester.pumpAndSettle();

    // Wait for and reply to CFG_GET requests for configs.
    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.isNotEmpty) link.replyThermal(0);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 1) link.replyPower(1);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 2) link.replyBms(2);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 50));
    if (link.commands.length > 3) link.replySystem(3);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    await pumpHost(tester);
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sistema'));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save-system'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
        reason: 'disarmed with a config loaded, saving is available');

    link.feedBinary(binarySample(armed: true));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(save).onPressed, isNull,
        reason: 'the route must follow the repository, not a snapshot');
  });
}
