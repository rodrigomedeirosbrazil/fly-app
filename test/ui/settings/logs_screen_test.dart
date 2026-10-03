import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/log_browser.dart';
import 'package:fly_app/state/log_download.dart';
import 'package:fly_app/ui/settings/logs_screen.dart';

import '../../state/fake_session.dart';

List<int> page(List<(String, int)> entries, {int used = 8192}) {
  final head = ByteData(12)
    ..setUint32(0, used, Endian.little)
    ..setUint32(4, 131072, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint8(10, 0)
    ..setUint8(11, entries.length);
  final out = [...head.buffer.asUint8List()];
  for (final (name, size) in entries) {
    final s = ByteData(4)..setUint32(0, size, Endian.little);
    out
      ..addAll(s.buffer.asUint8List())
      ..add(name.length)
      ..addAll(name.codeUnits);
  }
  return out;
}

List<int> chunk(int offset, int size, List<int> data) {
  final d = ByteData(8)
    ..setUint32(0, offset, Endian.little)
    ..setUint32(4, size, Endian.little);
  return [...d.buffer.asUint8List(), ...data];
}

class DeletingEditor extends Fake implements ConfigEditor {
  final deleted = <(String, String?)>[];
  final allPins = <String?>[];
  final queued = <SaveOutcome>[];

  SaveOutcome _next() => queued.isEmpty ? const SaveOk() : queued.removeAt(0);

  @override
  Future<SaveOutcome> deleteLog(String name, {String? pin}) async {
    deleted.add((name, pin));
    return _next();
  }

  @override
  Future<SaveOutcome> deleteAllLogs({String? pin}) async {
    allPins.add(pin);
    return _next();
  }
}

/// A delete that answers when the test says so.
class SlowDeleteEditor extends DeletingEditor {
  SlowDeleteEditor(this._answer);
  final Future<SaveOutcome> _answer;

  @override
  Future<SaveOutcome> deleteLog(String name, {String? pin}) => _answer;
}

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  late FakeSession listSession;
  late FakeSession readSession;
  late LogBrowser browser;
  late DeletingEditor editor;
  late List<(String, Uint8List)> shared;

  setUp(() {
    listSession = FakeSession();
    readSession = FakeSession();
    browser = LogBrowser(listSession);
    editor = DeletingEditor();
    shared = [];
  });

  tearDown(() => browser.dispose());

  LogsScreen screen({bool armed = false}) => LogsScreen(
        browser: browser,
        editor: editor,
        armed: armed,
        download: () => LogDownload(readSession, maxChunk: 100),
        share: (name, bytes) async => shared.add((name, bytes)),
      );

  testWidgets('lists the files newest first with their size', (tester) async {
    listSession.queueOk(page([('20261001_001.csv', 4100), ('20261002_003.csv', 900)]));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('02/10/2026 · voo 3'));
    final second = tester.getTopLeft(find.text('01/10/2026 · voo 1'));
    expect(first.dy, lessThan(second.dy));
    expect(find.textContaining('900 B'), findsOneWidget);
    expect(find.text('8,0 KB de 128,0 KB'), findsOneWidget);
  });

  testWidgets('says so when there is nothing', (tester) async {
    listSession.queueOk(page([]));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();
    expect(find.text('Nenhum registro no controlador.'), findsOneWidget);
  });

  testWidgets('old firmware is told to update', (tester) async {
    listSession.queue(const ControlRefused(ControlStatus.errBadOp));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Atualize o firmware'), findsOneWidget);
  });

  testWidgets('downloading hands the bytes to the share sheet', (tester) async {
    listSession.queueOk(page([('20261002_003.csv', 3)]));
    readSession.queueOk(chunk(0, 3, [0x61, 0x2C, 0x62]));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-download-20261002_003.csv')));
    await tester.pumpAndSettle();

    expect(shared.single.$1, '20261002_003.csv');
    expect(shared.single.$2, [0x61, 0x2C, 0x62]);
  });

  testWidgets('a download that fails says why', (tester) async {
    listSession.queueOk(page([('20261002_003.csv', 3)]));
    readSession.queue(const ControlDropped());
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-download-20261002_003.csv')));
    await tester.pumpAndSettle();

    expect(shared, isEmpty);
    expect(find.textContaining('conexão caiu'), findsOneWidget);
  });

  testWidgets('deleting confirms, asks for the PIN, then re-lists',
      (tester) async {
    listSession
      ..queueOk(page([('20261002_003.csv', 3)]))
      ..queueOk(page([]));
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-delete-20261002_003.csv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apagar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(editor.deleted, [('20261002_003.csv', null), ('20261002_003.csv', '1234')]);
    expect(find.text('Nenhum registro no controlador.'), findsOneWidget);
  });

  testWidgets('delete all confirms first', (tester) async {
    listSession
      ..queueOk(page([('20261002_003.csv', 3)]))
      ..queueOk(page([]));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logs-delete-all')));
    await tester.pumpAndSettle();
    expect(editor.allPins, isEmpty, reason: 'nothing before the confirmation');
    await tester.tap(find.text('Apagar todos'));
    await tester.pumpAndSettle();

    expect(editor.allPins, [null]);
  });

  testWidgets('armed makes every action inert and says so', (tester) async {
    listSession.queueOk(page([('20261002_003.csv', 3)]));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrap(screen(armed: true)));
    await tester.pumpAndSettle();

    expect(
      tester.widget<IconButton>(find.byKey(const Key('log-download-20261002_003.csv'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('log-delete-20261002_003.csv'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<OutlinedButton>(find.byKey(const Key('logs-delete-all'))).onPressed,
      isNull,
    );
    expect(find.text('Indisponível com a aeronave armada'), findsOneWidget);
  });

  testWidgets('arming under an open confirmation never reaches a PIN prompt',
      (tester) async {
    listSession.queueOk(page([('20261002_003.csv', 3)]));
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-delete-20261002_003.csv')));
    await tester.pumpAndSettle();
    // The aircraft arms while the dialog is still on screen.
    await tester.pumpWidget(wrap(screen(armed: true)));
    await tester.pump();
    await tester.tap(find.text('Apagar'));
    await tester.pumpAndSettle();

    expect(editor.deleted, isEmpty);
    expect(find.text('PIN'), findsNothing);
    expect(find.text('Recusado: a aeronave está armada'), findsOneWidget);
  });

  testWidgets('arming under an open delete-all confirmation is refused too',
      (tester) async {
    listSession.queueOk(page([('20261002_003.csv', 3)]));
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logs-delete-all')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrap(screen(armed: true)));
    await tester.pump();
    await tester.tap(find.text('Apagar todos'));
    await tester.pumpAndSettle();

    expect(editor.allPins, isEmpty);
    expect(find.text('PIN'), findsNothing);
    expect(find.text('Recusado: a aeronave está armada'), findsOneWidget);
  });

  testWidgets('a delete in flight makes every action inert', (tester) async {
    final pending = Completer<SaveOutcome>();
    final slow = SlowDeleteEditor(pending.future);
    listSession
      ..queueOk(page([('20261002_003.csv', 3)]))
      ..queueOk(page([('20261002_003.csv', 3)]));
    await tester.pumpWidget(wrap(LogsScreen(
      browser: browser,
      editor: slow,
      armed: false,
      download: () => LogDownload(readSession, maxChunk: 100),
      share: (name, bytes) async => shared.add((name, bytes)),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-delete-20261002_003.csv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apagar'));
    await tester.pump();

    IconButton button(String key) =>
        tester.widget<IconButton>(find.byKey(Key(key)));
    expect(button('log-download-20261002_003.csv').onPressed, isNull);
    expect(button('log-delete-20261002_003.csv').onPressed, isNull);
    expect(button('logs-refresh').onPressed, isNull);
    expect(
      tester.widget<OutlinedButton>(find.byKey(const Key('logs-delete-all'))).onPressed,
      isNull,
    );

    pending.complete(const SaveFailed(SaveFailure.noAnswer));
    await tester.pumpAndSettle();

    expect(button('log-download-20261002_003.csv').onPressed, isNotNull);
    expect(button('logs-refresh').onPressed, isNotNull);
  });

  testWidgets('armed refusal with a disarmed screen explains the empty list',
      (tester) async {
    listSession.queue(const ControlRefused(ControlStatus.errState));
    await tester.pumpWidget(wrap(screen()));
    await tester.pumpAndSettle();

    expect(
      find.text('Indisponível com a aeronave armada. Atualize quando desarmar.'),
      findsOneWidget,
    );
  });

  group('layout', () {
    for (final size in const [
      Size(393, 852),
      Size(320, 480),
      Size(852, 393),
      Size(1280, 800),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        listSession.queueOk(page([
          for (var i = 1; i <= 12; i++) ('202610${i.toString().padLeft(2, '0')}_001.csv', 4100 * i),
        ]));
        await tester.pumpWidget(wrap(screen()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
