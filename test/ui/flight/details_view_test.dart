import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/telemetry_source_policy.dart';
import 'package:fly_app/ui/flight/details_view.dart';

TelemetryFrame frame() => TelemetryFrame(
      socCoulomb: 62,
      socVoltage: 58,
      voltage: 50.8,
      powerKw: 7.5,
      throttlePct: 55,
      throttleRaw: 14210,
      powerPct: 70,
      motorTempC: 89,
      motorTempSource: MotorTempSource.can,
      rpm: 5830,
      currentA: 148,
      escTempC: 65,
      armState: ArmState.armed,
      disarmReason: DisarmReason.none,
      bmsMaxTempC: 34,
      cellMinMv: 3610,
      cellMaxMv: 3650,
      receivedAt: DateTime.utc(2026, 10, 12),
      hourMeterSec: const Duration(seconds: 148328),
      cellDeltaMv: 40,
      motorTempState: SignalState.valid,
      escTempState: SignalState.valid,
      hasTelemetry: true,
    );

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('sections are named like the alert components', (tester) async {
    await tester.pumpWidget(wrap(DetailsView(
      frame: frame(),
      stale: false,
      alerts: const [],
      onClose: () {},
    )));
    for (final s in ['BATERIA', 'MOTOR', 'ESC', 'ACELERADOR', 'SISTEMA']) {
      await tester.scrollUntilVisible(find.text(s), 200);
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });

  testWidgets('readings use the panel\'s formatting', (tester) async {
    await tester.pumpWidget(wrap(DetailsView(
      frame: frame(),
      stale: false,
      alerts: const [],
      thermalConfig: const ThermalConfig(
        motorReductionStartC: 80,
        motorMaxC: 110,
        escReductionStartC: 70,
        escMaxC: 100,
        motorTempSource: 0,
      ),
      controllerType: ControllerType.tmotor,
      telemetrySource: TelemetrySource.control,
      onClose: () {},
    )));
    expect(find.text('50,8 V'), findsOneWidget);
    expect(find.text('148 A'), findsOneWidget);
    expect(find.text('3,61 V'), findsOneWidget); // BMS minimum cell
    await tester.scrollUntilVisible(find.text('5.830'), 200);
    expect(find.text('80 °C · 110 °C'), findsOneWidget);
    expect(find.text('CAN · válido'), findsNWidgets(2)); // motor and ESC
    await tester.scrollUntilVisible(find.text('41:12:08'), 200);
    expect(find.text('binária (Fly Control)'), findsOneWidget);
  });

  testWidgets('the strip carries state and battery', (tester) async {
    await tester.pumpWidget(wrap(DetailsView(
      frame: frame(),
      stale: false,
      alerts: const [],
      onClose: () {},
    )));
    final strip = find.byKey(const Key('details-strip'));
    expect(find.descendant(of: strip, matching: find.text('ARMADO')),
        findsOneWidget);
    // Scoped: the Bateria section repeats the same 62 %.
    expect(find.descendant(of: strip, matching: find.text('62 %')),
        findsOneWidget);
  });

  testWidgets('the strip draws the live dot like the status row', (
    tester,
  ) async {
    Color dot() =>
        ((tester
                    .widget<Container>(find.byKey(const Key('details-dot')))
                    .decoration)
                as BoxDecoration)
            .color!;
    await tester.pumpWidget(
      wrap(
        DetailsView(
          frame: frame(),
          stale: false,
          alerts: const [],
          onClose: () {},
        ),
      ),
    );
    final s = Theme.of(tester.element(find.byType(DetailsView))).colorScheme;
    expect(dot(), s.primary);
    await tester.pumpWidget(
      wrap(
        DetailsView(
          frame: frame(),
          stale: true,
          alerts: const [],
          onClose: () {},
        ),
      ),
    );
    expect(dot(), s.outline);
  });

  testWidgets('a retrying link says RECONECTANDO, not SEM SINAL', (
    tester,
  ) async {
    Widget view({required bool reconnecting}) => wrap(
      DetailsView(
        frame: null,
        stale: true,
        reconnecting: reconnecting,
        alerts: const [],
        onClose: () {},
      ),
    );
    await tester.pumpWidget(view(reconnecting: true));
    expect(find.text('RECONECTANDO'), findsOneWidget);
    await tester.pumpWidget(view(reconnecting: false));
    expect(find.text('SEM SINAL'), findsOneWidget);
  });

  testWidgets('an absent reading is a dash', (tester) async {
    await tester.pumpWidget(wrap(DetailsView(
      frame: null,
      stale: true,
      alerts: const [],
      onClose: () {},
    )));
    expect(find.text('0 %'), findsNothing);
    expect(find.text('–'), findsWidgets);
  });

  testWidgets('the close button calls back', (tester) async {
    var closed = 0;
    await tester.pumpWidget(wrap(DetailsView(
      frame: frame(),
      stale: false,
      alerts: const [],
      onClose: () => closed++,
    )));
    await tester.scrollUntilVisible(
        find.byKey(const Key('details-close')), 200);
    await tester.tap(find.byKey(const Key('details-close')));
    expect(closed, 1);
  });

  testWidgets('two columns fit a landscape phone', (tester) async {
    tester.view.physicalSize = const Size(852, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(DetailsView(
      frame: frame(),
      stale: false,
      alerts: const [],
      columns: 2,
      onClose: () {},
    )));
    expect(tester.takeException(), isNull);
  });
}
