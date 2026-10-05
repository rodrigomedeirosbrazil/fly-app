import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/state/firmware_update_policy.dart';
import 'package:fly_app/state/github_release.dart';

GitHubRelease release(String tag, {List<String>? names}) => GitHubRelease(
      tag: tag,
      assets: [
        for (final n in names ??
            ['firmware-tmotor-$tag.bin', 'firmware-xag-$tag.bin'])
          ReleaseAsset(name: n, size: n.contains('xag') ? 1594624 : 1605776),
      ],
    );

FirmwareAvailability eval({
  String? installed = '2026-09-12.1',
  ControllerType type = ControllerType.xag,
  GitHubRelease? r,
  bool noRelease = false,
}) =>
    evaluateFirmware(
      installedVersion: installed,
      controllerType: type,
      release: noRelease ? null : (r ?? release('2026-10-02.2')),
    );

void main() {
  group('evaluateFirmware', () {
    test('an older installed build gets the image for its own type', () {
      expect(
        eval(type: ControllerType.xag),
        const FirmwareAvailable(
          tag: '2026-10-02.2',
          assetName: 'firmware-xag-2026-10-02.2.bin',
          size: 1594624,
          installedUnreadable: false,
        ),
      );
      expect(
        eval(type: ControllerType.tmotor),
        const FirmwareAvailable(
          tag: '2026-10-02.2',
          assetName: 'firmware-tmotor-2026-10-02.2.bin',
          size: 1605776,
          installedUnreadable: false,
        ),
      );
    });

    test('the same build is up to date', () {
      expect(eval(installed: '2026-10-02.2'), const FirmwareUpToDate());
    });

    test('a build newer than the release is up to date, not a downgrade', () {
      expect(eval(installed: '2026-10-03.1'), const FirmwareUpToDate());
    });

    test('up to date does not depend on the assets', () {
      expect(
        eval(
          installed: '2026-10-02.2',
          type: ControllerType.unknown,
          r: release('2026-10-02.2', names: []),
        ),
        const FirmwareUpToDate(),
      );
    });

    for (final installed in ['dev', '', null, 'v1.4.0', '2026-10-02']) {
      test('installed "$installed" cannot be up to date, so it is offered',
          () {
        final result = eval(installed: installed);
        expect(result, isA<FirmwareAvailable>());
        expect((result as FirmwareAvailable).installedUnreadable, isTrue);
      });
    }

    test('an unknown controller type gets no image', () {
      expect(eval(type: ControllerType.unknown),
          const FirmwareNoAssetForType());
    });

    test('a release without this type\'s image offers nothing', () {
      expect(
        eval(
            r: release('2026-10-02.2',
                names: ['firmware-tmotor-2026-10-02.2.bin'])),
        const FirmwareNoAssetForType(),
      );
    });

    for (final nearMiss in [
      'firmware-xag-2026-10-02.2.bin.sig',
      'firmware-xag-2026-09-12.1.bin',
      'Firmware-XAG-2026-10-02.2.bin',
      'xfirmware-xag-2026-10-02.2.bin',
    ]) {
      test('"$nearMiss" is not this release\'s XAG image', () {
        expect(eval(r: release('2026-10-02.2', names: [nearMiss])),
            const FirmwareNoAssetForType());
      });
    }

    test('no release known is unknown', () {
      expect(eval(noRelease: true), const FirmwareUnknown());
    });

    test('a release tag out of pattern is unknown', () {
      expect(eval(r: release('v2.0.0')), const FirmwareUnknown());
    });
  });

  group('firmwareDownloadUrl', () {
    test('is the release download URL GitHub serves, built by the app', () {
      expect(
        firmwareDownloadUrl('2026-10-02.2', 'firmware-xag-2026-10-02.2.bin'),
        Uri.parse('https://github.com/rodrigomedeirosbrazil/fly-controller/'
            'releases/download/2026-10-02.2/firmware-xag-2026-10-02.2.bin'),
      );
      expect(
        firmwareDownloadUrl('2026-10-02.2', 'firmware-tmotor-2026-10-02.2.bin')
            .path,
        '/rodrigomedeirosbrazil/fly-controller/releases/download/'
        '2026-10-02.2/firmware-tmotor-2026-10-02.2.bin',
      );
    });

    test('refuses a tag that is not a release tag', () {
      expect(() => firmwareDownloadUrl('../x', 'firmware-xag-../x.bin'),
          throwsArgumentError);
    });

    test('refuses a name that is not one of the two built forms', () {
      expect(() => firmwareDownloadUrl('2026-10-02.2', 'evil.bin'),
          throwsArgumentError);
      expect(
          () => firmwareDownloadUrl(
              '2026-10-02.2', 'firmware-xag-2026-09-12.1.bin'),
          throwsArgumentError);
    });
  });
}
