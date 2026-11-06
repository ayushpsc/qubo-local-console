import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qubo_camera_ai/models/live_stream_models.dart';
import 'package:qubo_camera_ai/models/storage_location.dart';
import 'package:qubo_camera_ai/services/dashboard_api.dart';
import 'support/test_settings.dart';

const master =
    'http://13.235.191.60:1935/hero-iot-live/HLS_22222222-2222-4222-8222-222222222222_93/playlist.m3u8?wowzatoken=signed%2Bvalue&sessionId=session';

Uint8List captureBytes() {
  const headers =
      'POST /google.internal.home.foyer.v1.HomeControlService/UpdateTraits HTTP/2\r\n'
      'host: googlehomefoyer-pa.googleapis.com\r\n'
      'content-type: application/grpc\r\n'
      'authorization: Bearer fresh-google-token\r\n'
      'x-goog-ext-202964622-bin: YWJjZGVmZ2g=\r\n'
      'foyer-gha-environment: aWprbG1ub3A=\r\n'
      'accept-language: en-IN\r\n'
      'grpc-timeout: 9993228u\r\n\r\n';
  return Uint8List.fromList([...latin1.encode(headers), 0, 0, 0, 0, 1, 8]);
}

void main() {
  test('Home UpdateTraits capture extracts only replay inputs', () {
    final capture = GoogleHomeCapture.parse(captureBytes());
    expect(capture.authorization, 'Bearer fresh-google-token');
    expect(capture.googleExtension, 'YWJjZGVmZ2g=');
    expect(capture.environment, 'aWprbG1ub3A=');
    expect(capture.grpcTimeout, '9993228u');
    expect(capture.body, Uint8List.fromList([0, 0, 0, 0, 1, 8]));
  });

  test('unrelated, truncated and unauthenticated captures are rejected', () {
    for (final bytes in [
      Uint8List.fromList(utf8.encode('GET / HTTP/2\r\n\r\nhello')),
      Uint8List.fromList(
        utf8.encode(
          'POST ${GoogleHomeCapture.methodPath} HTTP/2\r\nhost: ${GoogleHomeCapture.host}\r\n\r\nhello',
        ),
      ),
      Uint8List.fromList(captureBytes().sublist(0, 100)),
    ]) {
      expect(() => GoogleHomeCapture.parse(bytes), throwsFormatException);
    }
  });

  test('protobuf response yields the observed master playlist URL', () {
    final bytes = Uint8List.fromList([
      0,
      0,
      0,
      ...latin1.encode('cameraStreamAccessUrl\x12$master'),
      0,
      ...latin1.encode('cameraStreamProtocol'),
    ]);
    expect(findHlsMasterUrl(bytes), master);
  });

  test(
    'live origin accepts only the observed HTTP host, port and HLS path',
    () {
      expect(isSupportedLiveUri(Uri.parse(master), masterOnly: true), true);
      expect(
        isSupportedLiveUri(
          Uri.parse(master.replaceFirst('playlist.m3u8', 'media_42.ts')),
        ),
        true,
      );
      expect(
        isSupportedLiveUri(
          Uri.parse(master.replaceFirst('playlist.m3u8', 'keys/media.key')),
        ),
        true,
      );
      expect(
        isSupportedLiveUri(
          Uri.parse(
            master.replaceFirst(
              'playlist.m3u8',
              'chunklist_w123_tkdZHVtbXktdG9rZW4==.m3u8',
            ),
          ),
        ),
        true,
      );
      expect(
        isSupportedLiveUri(
          Uri.parse(master.replaceFirst('playlist.m3u8', 'playlist.txt')),
          masterOnly: true,
        ),
        false,
      );
      for (final invalid in [
        master.replaceFirst('http://', 'https://'),
        master.replaceFirst('13.235.191.60', '127.0.0.1'),
        master.replaceFirst(':1935', ':8080'),
        master.replaceFirst('/hero-iot-live/', '/private/'),
        master.replaceFirst('playlist.m3u8', 'bad:name'),
      ]) {
        expect(isSupportedLiveUri(Uri.parse(invalid)), false);
      }
    },
  );

  test('API replays gRPC bytes and returns a proxied HLS source', () async {
    late http.Request forwarded;
    final responseBytes = Uint8List.fromList([
      0,
      0,
      0,
      0,
      1,
      ...latin1.encode('cameraStreamAccessUrl\x12$master'),
      0,
    ]);
    final settings = testSettings()
      ..proxy = 'https://project.supabase.co/functions/v1/qubo-proxy';
    final api = DashboardApi(
      settings,
      useProxy: true,
      liveAuthToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=256000\nchunklist.m3u8',
            200,
          );
        }
        forwarded = request;
        return http.Response.bytes(
          responseBytes,
          200,
          headers: {'content-type': 'application/grpc'},
        );
      }),
    );
    addTearDown(api.dispose);
    final session = await api.openGoogleHomeLive(captureBytes());
    expect(session.masterUrl, master);
    expect(forwarded.url.host, 'project.supabase.co');
    expect(
      forwarded.url.queryParameters['url'],
      'https://googlehomefoyer-pa.googleapis.com${GoogleHomeCapture.methodPath}',
    );
    expect(forwarded.headers['Content-Type'], 'application/octet-stream');
    expect(forwarded.headers['Authorization'], 'Bearer firebase-id-token');
    expect(
      forwarded.headers['X-Google-Authorization'],
      'Bearer fresh-google-token',
    );
    expect(forwarded.bodyBytes, [0, 0, 0, 0, 1, 8]);

    expect(Uri.parse(api.liveSource(master)).queryParameters['url'], master);
  });

  test('configured live view uses Firebase without a Qubo session', () async {
    late http.Request forwarded;
    final api = DashboardApi(
      testSettings(),
      useProxy: true,
      liveAuthToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        if (request.method == 'GET') {
          expect(request.headers['Authorization'], 'Bearer firebase-id-token');
          return http.Response('#EXTM3U\n#EXT-X-VERSION:3', 200);
        }
        forwarded = request;
        return http.Response(
          jsonEncode({'masterUrl': master}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.dispose);

    final live = await api.openConfiguredGoogleHomeLive();
    expect(live.masterUrl, master);
    expect(forwarded.method, 'POST');
    expect(forwarded.url.queryParameters, {'action': 'google-home-live'});
    expect(forwarded.headers['Authorization'], 'Bearer firebase-id-token');
    expect(forwarded.headers.containsKey('Subscriber-Key'), false);
    expect(forwarded.headers.containsKey('User-UUID'), false);
    expect(forwarded.headers.containsKey('X-Google-Authorization'), false);
    expect(forwarded.bodyBytes, isEmpty);
  });

  test('configured live view explains an expired Google capture', () async {
    final api = DashboardApi(
      testSettings(),
      useProxy: true,
      liveAuthToken: () async => 'firebase-id-token',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'code': 'PROXY_GOOGLE_AUTH_EXPIRED',
            'message': 'The configured Google Home request has expired.',
          }),
          401,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(api.dispose);

    expect(
      api.openConfiguredGoogleHomeLive(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          contains('Google Home request expired'),
        ),
      ),
    );
  });

  test(
    'live view waits through transient playlist startup responses',
    () async {
      var readinessCalls = 0;
      final api = DashboardApi(
        testSettings(),
        useProxy: true,
        liveAuthToken: () async => 'firebase-id-token',
        client: MockClient((request) async {
          if (request.method == 'GET') {
            expect(
              request.headers['Authorization'],
              'Bearer firebase-id-token',
            );
            readinessCalls++;
            if (readinessCalls < 3) {
              return http.Response(
                '{"code":"PROXY_HLS_NOT_READY"}',
                503,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('#EXTM3U\n#EXT-X-VERSION:3', 200);
          }
          return http.Response.bytes(
            Uint8List.fromList([
              0,
              0,
              ...latin1.encode('cameraStreamAccessUrl\x12$master'),
              0,
            ]),
            200,
          );
        }),
      );
      addTearDown(api.dispose);

      final live = await api.openConfiguredGoogleHomeLive(
        readinessInterval: Duration.zero,
        readinessAttempts: 3,
      );
      expect(live.masterUrl, master);
      expect(readinessCalls, 3);
    },
  );
}
