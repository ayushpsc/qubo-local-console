// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'package:qubo_camera_ai/models/storage_location.dart';

bool allowedTarget(Uri uri, [String method = 'GET']) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  if (uri.host == 'srvcapp.platform.quboworld.com' && uri.port == 443) {
    final appApi = RegExp(
      r'^/(sms|unit-entity-management|roi-manager|stream-manager|content-manager|vms|control-monitor)/api/v[1-3]/sp/[a-zA-Z0-9-]+/',
    ).hasMatch(uri.path);
    final pushRequest = method == 'POST' && uri.path == '/push-pull/request';
    final pushStatus =
        method == 'GET' &&
        RegExp(r'^/push-pull/transaction/[0-9a-fA-F-]{36}$').hasMatch(uri.path);
    return appApi || pushRequest || pushStatus;
  }
  return isSupportedStorageUri(uri) || isSupportedMediaUri(uri);
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  print('Qubo local proxy: http://localhost:8080/proxy?url=TARGET_URL');
  print(
    'For local Flutter web clients. Requests are restricted to the captured Qubo and storage hosts.',
  );
  await for (final request in server) {
    unawaited(handleProxy(request, client));
  }
}

Future<void> handleProxy(HttpRequest request, HttpClient client) async {
  final response = request.response;
  response.headers.set('X-Qubo-Proxy', 'gateway');
  response.headers.set(
    'Access-Control-Expose-Headers',
    'X-Qubo-Proxy, X-Qubo-Upstream-Status, Content-Range, Accept-Ranges, Content-Length',
  );
  final origin = request.headers.value('origin');
  if (origin != null) {
    final parsed = Uri.tryParse(origin);
    if (parsed == null ||
        !['localhost', '127.0.0.1', '::1'].contains(parsed.host) ||
        !['http', 'https'].contains(parsed.scheme)) {
      response.statusCode = 403;
      response.headers.contentType = ContentType.json;
      response.write(
        '{"code":"PROXY_ORIGIN_FORBIDDEN","message":"Origin is not enabled for this gateway."}',
      );
      await response.close();
      return;
    }
    response.headers.set('Access-Control-Allow-Origin', origin);
    response.headers.set('Vary', 'Origin');
  }
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET, POST, PUT, OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'App-Id, Token-Type, Source-Device-Id, Source, User-UUID, Subscriber-Key, Content-Type, Accept, App-Type, Login-Device-Name, Range',
  );
  response.headers.set('Cache-Control', 'no-store');
  if (request.method == 'OPTIONS') {
    response.statusCode = 204;
    await response.close();
    return;
  }
  final uri = Uri.tryParse(request.uri.queryParameters['url'] ?? '');
  if (request.uri.path != '/proxy' ||
      uri == null ||
      !allowedTarget(uri, request.method) ||
      !['GET', 'POST', 'PUT'].contains(request.method)) {
    response.statusCode = 400;
    response.write('Invalid proxy target or method.');
    await response.close();
    return;
  }
  try {
    final upstream = await client
        .openUrl(request.method, uri)
        .timeout(const Duration(seconds: 25));
    upstream.followRedirects = false;
    if (uri.host == 'srvcapp.platform.quboworld.com') {
      upstream.headers.set(
        'User-Agent',
        'Qubo/29 CFNetwork/3860.600.12 Darwin/25.5.0',
      );
    }
    const headers = [
      'app-id',
      'token-type',
      'source-device-id',
      'source',
      'user-uuid',
      'subscriber-key',
      'content-type',
      'accept',
      'app-type',
      'login-device-name',
    ];
    if (uri.host == 'srvcapp.platform.quboworld.com') {
      for (final name in headers) {
        final value = request.headers.value(name);
        if (value != null) upstream.headers.set(name, value);
      }
    } else if (isSupportedMediaUri(uri)) {
      final range = request.headers.value('range');
      if (range != null) upstream.headers.set('range', range);
    }
    // Authentication headers are never forwarded to the object storage host.
    await upstream.addStream(request.timeout(const Duration(seconds: 25)));
    final incoming = await upstream.close().timeout(
      const Duration(seconds: 25),
    );
    response.headers.set('X-Qubo-Proxy', 'upstream');
    response.headers.set('X-Qubo-Upstream-Status', '${incoming.statusCode}');
    response.statusCode = incoming.statusCode;
    final contentType = incoming.headers.contentType;
    if (isSupportedMediaUri(uri)) {
      response.headers.contentType =
          incoming.statusCode >= 200 && incoming.statusCode < 300
          ? ContentType('video', 'mp4')
          : contentType ?? ContentType.binary;
      for (final name in [
        'content-range',
        'accept-ranges',
        'content-length',
        'etag',
        'last-modified',
      ]) {
        final value = incoming.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
    } else if (contentType != null) {
      response.headers.contentType = contentType;
    }
    // HttpClient automatically decompresses gzip. Do not forward stale encoding/length headers.
    await incoming.timeout(const Duration(seconds: 30)).pipe(response);
  } catch (_) {
    try {
      response.statusCode = 502;
      response.write('Upstream connection failed.');
      await response.close();
    } catch (_) {
      /* Client disconnected. */
    }
  }
}
