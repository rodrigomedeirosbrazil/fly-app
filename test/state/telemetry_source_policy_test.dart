import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/telemetry_source_policy.dart';

void main() {
  group('chooseAtDiscovery', () {
    test('the control service present and readable wins', () {
      expect(
        chooseAtDiscovery(controlServicePresent: true, infoReadable: true),
        TelemetrySource.control,
      );
    });

    test('an absent service falls back — that is the capability handshake', () {
      expect(
        chooseAtDiscovery(controlServicePresent: false, infoReadable: true),
        TelemetrySource.xctod,
      );
      expect(
        chooseAtDiscovery(controlServicePresent: false, infoReadable: false),
        TelemetrySource.xctod,
      );
    });

    test('a service whose INFO will not read is not a service', () {
      expect(
        chooseAtDiscovery(controlServicePresent: true, infoReadable: false),
        TelemetrySource.xctod,
      );
    });
  });

  group('shouldFallBackOnFrame', () {
    test('a decodable frame locks the source', () {
      expect(
        shouldFallBackOnFrame(decoded: true, anyFrameRendered: false),
        isFalse,
      );
    });

    test('an undecodable first frame falls back before anything renders', () {
      expect(
        shouldFallBackOnFrame(decoded: false, anyFrameRendered: false),
        isTrue,
      );
    });

    test('once a frame has rendered the source is fixed for the connection', () {
      // A mid-flight source flip would silently change which fields are
      // populated. Rejected frames age out into staleness instead, which is
      // already this app's answer to silence.
      expect(
        shouldFallBackOnFrame(decoded: false, anyFrameRendered: true),
        isFalse,
      );
    });
  });
}
