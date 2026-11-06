import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../bin/proxy.dart';

void main() {
  test(
    'local proxy handles preflight and rejects unsupported origins and targets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstream = HttpClient(), browser = HttpClient();
      final subscription = server.listen(
        (req) => unawaited(handleProxy(req, upstream)),
      );
      addTearDown(() async {
        browser.close(force: true);
        upstream.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}/proxy');
      final options = await browser.openUrl('OPTIONS', base);
      options.headers.set('Origin', 'http://localhost:5173');
      final preflight = await options.close();
      await preflight.drain<void>();
      expect(preflight.statusCode, 204);
      expect(
        preflight.headers.value('Access-Control-Allow-Origin'),
        'http://localhost:5173',
      );
      expect(
        preflight.headers.value('Access-Control-Allow-Headers'),
        contains('Subscriber-Key'),
      );
      final hosted = await browser.openUrl('OPTIONS', base);
      hosted.headers.set('Origin', 'http://localhost:8080');
      final hostedPreflight = await hosted.close();
      await hostedPreflight.drain<void>();
      expect(hostedPreflight.statusCode, 204);
      expect(
        hostedPreflight.headers.value('Access-Control-Allow-Origin'),
        'http://localhost:8080',
      );
      final foreign = await browser.getUrl(base);
      foreign.headers.set('Origin', 'https://example.com');
      final rejectedOrigin = await foreign.close();
      await rejectedOrigin.drain<void>();
      expect(rejectedOrigin.statusCode, 403);
      final unsafe = await browser.getUrl(
        base.replace(
          queryParameters: {'url': 'http://169.254.169.254/latest/meta-data/'},
        ),
      );
      final rejectedTarget = await unsafe.close();
      await rejectedTarget.drain<void>();
      expect(rejectedTarget.statusCode, 400);
    },
  );
}
