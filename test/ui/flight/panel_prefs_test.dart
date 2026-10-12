import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/flight/panel_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults: pack voltage, power, portrait', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await PanelPrefs.load();
    expect(p.perCell, isFalse);
    expect(p.showCurrent, isFalse);
    expect(p.orientation, OrientationChoice.portrait);
  });

  test('the existing voltage key is honoured', () async {
    SharedPreferences.setMockInitialValues({'voltMode': true});
    expect((await PanelPrefs.load()).perCell, isTrue);
  });

  test('each choice round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    await PanelPrefs.savePerCell(true);
    await PanelPrefs.saveShowCurrent(true);
    await PanelPrefs.saveOrientation(OrientationChoice.landscape);
    final p = await PanelPrefs.load();
    expect(p.perCell, isTrue);
    expect(p.showCurrent, isTrue);
    expect(p.orientation, OrientationChoice.landscape);
  });

  test('an unknown stored orientation falls back to portrait', () async {
    SharedPreferences.setMockInitialValues({'orientation': 'sideways'});
    expect((await PanelPrefs.load()).orientation, OrientationChoice.portrait);
  });
}
