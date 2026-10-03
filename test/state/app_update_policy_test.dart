import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/app_update_policy.dart';

void main() {
  group('releaseBuildNumber', () {
    // Each row: tag → build number, or null when the tag is not one CI
    // would have built.
    const table = <String, int?>{
      '2026-10-03.1': 2026100301,
      '2026-09-12.1': 2026091201,
      '2026-10-03.12': 2026100312,
      '2026-10-03.99': 2026100399,
      '2026-10-03.0': 2026100300, // CI accepts N = 0
      '2026-10-03.100': null, // CI refuses N > 99
      '2026-10-03.99999999999999999999': null, // overflow must be null, not a throw
      '2026-10-03.01': null, // one spelling per build number
      '2026-10-03': null,
      'v2026-10-03.1': null,
      '2026-10-03.1-beta': null,
      '1999-10-03.1': null, // CI's pattern starts with 2
      '26-10-03.1': null,
      '': null,
    };
    for (final entry in table.entries) {
      test('"${entry.key}" → ${entry.value}', () {
        expect(releaseBuildNumber(entry.key), entry.value);
      });
    }
  });

  group('formatBuildNumber', () {
    test('is the inverse of releaseBuildNumber', () {
      for (final tag in ['2026-10-03.1', '2026-09-12.1', '2026-10-03.42']) {
        expect(formatBuildNumber(releaseBuildNumber(tag)!), tag);
      }
    });

    test('N = 0 keeps its zero', () {
      expect(formatBuildNumber(2026100300), '2026-10-03.0');
    });

    test('the old local build number is not a version', () {
      // Every build before this feature, and every iOS build, was 1.0.0+1.
      expect(formatBuildNumber(1), isNull);
    });

    test('numbers outside the ten-digit 2xxx range are not versions', () {
      expect(formatBuildNumber(1999123101), isNull);
      expect(formatBuildNumber(3000010101), isNull);
      expect(formatBuildNumber(-2026100301), isNull);
    });
  });

  group('evaluateUpdate', () {
    test('a strictly newer release is available', () {
      final result =
          evaluateUpdate(installed: 2026100301, latestTag: '2026-10-04.1');
      expect(result, const UpdateAvailable('2026-10-04.1'));
    });

    test('the same build is up to date', () {
      expect(evaluateUpdate(installed: 2026100301, latestTag: '2026-10-03.1'),
          isA<UpToDate>());
    });

    test('an installed build newer than the release is silent', () {
      // The developer's own build, before the tag exists.
      expect(evaluateUpdate(installed: 2026100302, latestTag: '2026-10-03.1'),
          isA<UpToDate>());
    });

    test('a second release on the same day is available', () {
      expect(evaluateUpdate(installed: 2026100301, latestTag: '2026-10-03.2'),
          const UpdateAvailable('2026-10-03.2'));
    });

    test('different tags are different notices', () {
      expect(const UpdateAvailable('2026-10-04.1'),
          isNot(const UpdateAvailable('2026-10-04.2')));
    });

    test('no installed number is unknown, never a notice', () {
      expect(evaluateUpdate(installed: null, latestTag: '2026-10-04.1'),
          isA<UpdateUnknown>());
    });

    test('an installed number that is not a version is unknown', () {
      expect(evaluateUpdate(installed: 1, latestTag: '2026-10-04.1'),
          isA<UpdateUnknown>());
    });

    test('no known release is unknown', () {
      expect(evaluateUpdate(installed: 2026100301, latestTag: null),
          isA<UpdateUnknown>());
    });

    test('an unreadable tag never produces a notice', () {
      expect(evaluateUpdate(installed: 2026100301, latestTag: 'v9'),
          isA<UpdateUnknown>());
    });
  });

  group('releasePageUrl', () {
    test('is built from the tag, on github.com', () {
      expect(
        releasePageUrl('2026-10-03.1').toString(),
        'https://github.com/rodrigomedeirosbrazil/fly-app/releases/tag/2026-10-03.1',
      );
    });

    test('refuses a tag that did not pass the format check', () {
      expect(() => releasePageUrl('../../evil'), throwsArgumentError);
    });
  });
}
