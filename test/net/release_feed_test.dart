import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/net/release_feed.dart';

// DO NOT call TestWidgetsFlutterBinding.ensureInitialized() or use
// testWidgets in this file. The binding installs HttpOverrides that answer
// every request with 400, which would make every test below pass for the
// wrong reason. Plain `test` keeps the real HttpClient, talking to a
// loopback server — no network leaves the machine.

/// Fields copied from the real
/// GET /repos/rodrigomedeirosbrazil/fly-app/releases/latest on 2026-10-03.
const String realBody = '''
{"url":"https://api.github.com/repos/rodrigomedeirosbrazil/fly-app/releases/402492676",
 "html_url":"https://github.com/rodrigomedeirosbrazil/fly-app/releases/tag/2026-10-03.1",
 "id":402492676,"tag_name":"2026-10-03.1","target_commitish":"main",
 "name":"2026-10-03.1","draft":false,"prerelease":false,
 "created_at":"2026-10-03T11:52:52Z","published_at":"2026-10-03T11:59:28Z"}
''';

void main() {
  group('parseLatestTag', () {
    test('reads tag_name from a real response', () {
      expect(parseLatestTag(realBody), '2026-10-03.1');
    });

    test('a body without tag_name is null', () {
      expect(parseLatestTag('{"name":"x"}'), isNull);
    });

    test('a non-string tag_name is null', () {
      expect(parseLatestTag('{"tag_name":7}'), isNull);
    });

    test('a JSON array is null', () {
      expect(parseLatestTag('[]'), isNull);
    });

    test('a body that is not JSON is null', () {
      expect(parseLatestTag('<html>rate limited</html>'), isNull);
    });
  });

  group('GitHubReleaseFeed', () {
    late HttpServer server;
    late void Function(HttpRequest) handler;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => handler(request));
    });

    tearDown(() => server.close(force: true));

    GitHubReleaseFeed feed({Duration timeout = const Duration(seconds: 2)}) =>
        GitHubReleaseFeed(
          endpoint: Uri.http('127.0.0.1:${server.port}', '/latest'),
          timeout: timeout,
        );

    void answer(int status, String body) {
      handler = (request) {
        request.response
          ..statusCode = status
          ..write(body)
          ..close();
      };
    }

    test('200 with a release returns its tag', () async {
      answer(200, realBody);
      expect(await feed().latestTag(), '2026-10-03.1');
    });

    test('sends the User-Agent GitHub requires and the API media type',
        () async {
      HttpHeaders? seen;
      handler = (request) {
        seen = request.headers;
        request.response
          ..write(realBody)
          ..close();
      };

      await feed().latestTag();

      // dart:io would otherwise send its own default ("Dart/x (dart:io)"), so
      // only an exact match proves the code sets the header itself.
      expect(seen!.value(HttpHeaders.userAgentHeader), 'aerovolt-app');
      expect(seen!.value(HttpHeaders.acceptHeader),
          'application/vnd.github+json');
    });

    test('403 (rate limit) is null', () async {
      answer(403, '{"message":"API rate limit exceeded"}');
      expect(await feed().latestTag(), isNull);
    });

    test('404 (no release yet) is null', () async {
      answer(404, '{"message":"Not Found"}');
      expect(await feed().latestTag(), isNull);
    });

    test('a 200 that is not JSON is null', () async {
      answer(200, '<html></html>');
      expect(await feed().latestTag(), isNull);
    });

    test('a server that never answers is null after the timeout', () async {
      handler = (_) {}; // hold the request open forever
      final watch = Stopwatch()..start();

      final tag =
          await feed(timeout: const Duration(milliseconds: 200)).latestTag();

      expect(tag, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a refused connection is null', () async {
      final port = server.port;
      await server.close(force: true);

      final tag = await GitHubReleaseFeed(
        endpoint: Uri.http('127.0.0.1:$port', '/latest'),
      ).latestTag();

      expect(tag, isNull);
    });
  });
}
