import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qubo_camera_ai/controllers/dashboard_controller.dart';
import 'package:qubo_camera_ai/models/dashboard_models.dart';
import 'package:qubo_camera_ai/services/dashboard_api.dart';
import '../bin/proxy.dart' as proxy;
import 'support/test_settings.dart';

Session session() => Session(
  token: 'test-server-token',
  user: 'user',
  name: 'Test home',
  expires: DateTime.now().add(const Duration(hours: 1)),
);
http.Response jsonResponse(dynamic value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'server JWT expiry is decoded in seconds and missing expiry stays unknown',
    () {
      final exp =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
      final payload = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'user': 'u',
                'mob': 'installation',
                'iss': 'tenant',
                'exp': exp,
              }),
            ),
          )
          .replaceAll('=', '');
      final parsed = Session.fromJson({
        'uuid': 'u',
        'token': 'header.$payload.test-signature',
      });
      expect(parsed.expires!.millisecondsSinceEpoch, exp * 1000);
      expect(
        parsed.expired(DateTime.fromMillisecondsSinceEpoch(exp * 1000)),
        true,
      );
      expect(Session.claims(parsed.token)['mob'], 'installation');
      expect(
        Session.fromJson({'uuid': 'u', 'token': 'opaque-server-token'}).expires,
        isNull,
      );
    },
  );

  test('email login and all authenticated routes match qubopy', () async {
    final settings = testSettings();
    final calls = <http.Request>[];
    final api = DashboardApi(
      settings,
      useProxy: false,
      client: MockClient((r) async {
        calls.add(r);
        if (r.url.path.endsWith('/user/login')) {
          return jsonResponse({
            'uuid': 'user',
            'accessToken': 'server-token',
            'refreshToken': 'refresh-token',
            'name': 'Home',
          });
        }
        if (r.url.path == '/push-pull/request') {
          return jsonResponse({
            'transactionId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          });
        }
        if (r.url.path.startsWith('/push-pull/transaction/')) {
          return jsonResponse({
            'files': [
              {
                'file': '/tmp/mnt/sdcard0/camera/clip.mp4',
                'downloadURL':
                    'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/sdCardMedia--bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb--/tmp/mnt/sdcard0/camera/clip.mp4?X-Amz-Signature=abc&X-Amz-Date=20261024T092355Z&X-Amz-Expires=300',
              },
            ],
          });
        }
        if (r.url.path.contains('/contents/')) {
          return jsonResponse({
            'preSignedDownloadUrl':
                'https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-vms-event/t/c?X-Amz-Signature=abc',
          });
        }
        if (r.url.path.endsWith('/shadow/attribute')) {
          return http.Response('SUCCESS', 200);
        }
        if (r.url.path.endsWith('/command')) {
          return jsonResponse({'code': 'SUCCESS_UM_006'});
        }
        if (r.url.path.endsWith('/stream/rtsp')) {
          return http.Response('Ok', 200);
        }
        return jsonResponse([]);
      }),
    );
    addTearDown(api.dispose);
    final auth = await api.loginWithEmail('owner@example.test', 'secret');
    expect(auth.user, 'user');
    expect(auth.token, 'server-token');
    expect(auth.refreshToken, 'refresh-token');
    expect(calls.first.method, 'POST');
    expect(calls.first.headers.containsKey('Subscriber-Key'), false);
    expect(calls.first.url.queryParameters, {'system': 'CS'});
    expect(calls.first.headers['App-Id'], 'com.hero.iot');
    expect(calls.first.headers['Source'], 'USER');
    expect(jsonDecode(calls.first.body), {
      'username': 'owner@example.test',
      'email': 'owner@example.test',
      'password': 'secret',
      'deviceAttribute': 'Apple iPhone15,5',
    });
    api.session = auth;
    final d = settings.devices.first, purifier = settings.devices[1];
    final from = DateTime(2026, 10, 23), to = DateTime(2026, 10, 24);
    await api.vms(d, to.millisecondsSinceEpoch);
    await api.timeline(d, from, to);
    await api.latest();
    await api.contentUrl(d, 'transaction', 'content');
    await api.shadow(purifier, {
      'attributeName': 'power',
      'attributeValue': 'on',
    });
    await api.command(purifier, {'topic': 'topic', 'payload': {}});
    await api.rtspSupport(d);
    await api.streamRequest(d);
    await api.credentials(d);
    final media = await api.prepareRecording(
      d,
      '/tmp/mnt/sdcard0/camera/clip.mp4',
      pollInterval: Duration.zero,
      attempts: 1,
    );
    expect(media.transactionId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(calls.length, 12);
    for (final r in calls.skip(1)) {
      expect(r.headers['Subscriber-Key'], 'server-token');
      expect(r.headers['Authorization'], isNull);
      expect(r.headers['User-UUID'], 'user');
      expect(r.headers['Source-Device-Id'], settings.sourceDeviceId);
      expect(r.headers['Source'], 'IOS');
      expect(r.headers['App-Id'], settings.appId);
    }
    final timeline = calls.firstWhere(
      (r) => r.url.path.endsWith('/time-scrubber'),
    );
    expect(timeline.method, 'GET');
    expect(
      timeline.url.queryParameters['startTime'],
      '${from.millisecondsSinceEpoch}',
    );
    expect(
      timeline.url.queryParameters['endTime'],
      '${DateTime(to.year, to.month, to.day, 23, 59, 59).millisecondsSinceEpoch}',
    );
    expect(timeline.url.queryParameters['skipIntervalValue'], '30');
    expect(
      calls.firstWhere((r) => r.url.path.endsWith('/lastEvent')).method,
      'PUT',
    );
    final credentials = calls.firstWhere(
      (r) => r.url.path.endsWith('/devices/pp2p/credentials'),
    );
    expect(credentials.url.path, contains('/api/v3/'));
    expect(jsonDecode(credentials.body), {
      'unitUUID': settings.unit,
      'userAppID': settings.sourceDeviceId,
      'devices': [
        {'protocol': 'udp', 'deviceUUID': d.id},
      ],
    });
    final export = calls.firstWhere((r) => r.url.path == '/push-pull/request');
    expect(export.method, 'POST');
    expect(jsonDecode(export.body), {
      'files': [
        {'file': '/tmp/mnt/sdcard0/camera/clip.mp4'},
      ],
      'filesType': 'sdCardMedia',
      'target': {
        'unitUUID': settings.unit,
        'targetUUID': d.id,
        'entityUUID': d.entity,
        'targetType': 'device',
      },
    });
  });

  test(
    'email login never silently selects the first account profile',
    () async {
      final api = DashboardApi(
        testSettings(),
        useProxy: false,
        client: MockClient(
          (_) async => jsonResponse([
            {
              'uuid': 'old-user',
              'accessToken': 'old-token',
              'name': 'Old home',
            },
            {
              'uuid': 'new-user',
              'accessToken': 'new-token',
              'name': 'New home',
            },
          ]),
        ),
      );
      addTearDown(api.dispose);

      final profiles = await api.loginProfilesWithEmail('owner@test', 'secret');
      expect(profiles.map((profile) => profile.user), ['old-user', 'new-user']);
      await expectLater(
        api.loginWithEmail('owner@test', 'secret'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('Select the intended profile'),
          ),
        ),
      );
    },
  );

  test(
    'account discovery replaces capture-era unit and device identifiers',
    () async {
      final settings = testSettings();
      final capturedUnit = settings.unit;
      final capturedDevice = settings.devices.first.id;
      final calls = <http.Request>[];
      final api = DashboardApi(
        settings,
        useProxy: false,
        client: MockClient((request) async {
          calls.add(request);
          if (request.url.path.endsWith('/units')) {
            return jsonResponse({
              'data': {
                'units': [
                  {'unitUUID': 'current-unit'},
                ],
              },
            });
          }
          if (request.url.path.endsWith('/units/current-unit/devices')) {
            return jsonResponse({
              'devices': [
                {
                  'deviceUUID': 'current-camera',
                  'deviceName': 'Current doorbell',
                  'productType': 'videoDoorbellPro',
                  'entityUUID': 'current-entity',
                  'deviceAModelNo': 'HCD04A',
                  'macAddress': '00:11:22:33:44:55',
                },
              ],
            });
          }
          return jsonResponse([]);
        }),
      );
      final controller = DashboardController(api, tick: false);
      addTearDown(controller.dispose);

      await controller.signInAndDiscover(
        Session(
          token: 'access',
          user: 'current-user',
          name: 'Current home',
          expires: DateTime.now().add(const Duration(hours: 1)),
          refreshToken: 'refresh',
        ),
      );

      expect(capturedUnit, isNot('current-unit'));
      expect(capturedDevice, isNot('current-camera'));
      expect(settings.unit, 'current-unit');
      expect(settings.devices, hasLength(1));
      expect(settings.devices.single.id, 'current-camera');
      expect(settings.devices.single.unit, 'current-unit');
      expect(controller.selected!.id, 'current-camera');
      expect(calls, hasLength(2));
      expect(
        calls.every((request) => request.headers['Source'] == 'Android'),
        true,
      );
      expect(
        calls.every(
          (request) => request.headers['App-Id'] == settings.authAppId,
        ),
        true,
      );
    },
  );

  test('near-expiry access token is refreshed before the API call', () async {
    final calls = <http.Request>[];
    final settings = testSettings();
    final api = DashboardApi(
      settings,
      useProxy: false,
      client: MockClient((request) async {
        calls.add(request);
        if (request.url.path.endsWith('/auth/refresh')) {
          expect(request.headers['Authorization'], 'Bearer old-access');
          expect(request.headers['Subscriber-Key'], 'old-access');
          expect(jsonDecode(request.body), {
            'accessToken': 'old-access',
            'refreshToken': 'old-refresh',
          });
          return jsonResponse({
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        }
        expect(request.headers['Authorization'], isNull);
        expect(request.headers['Subscriber-Key'], 'new-access');
        return jsonResponse([]);
      }),
    );
    addTearDown(api.dispose);
    api.session = Session(
      token: 'old-access',
      user: 'user',
      name: 'Home',
      expires: DateTime.now().add(const Duration(minutes: 1)),
      refreshToken: 'old-refresh',
    );

    await api.vms(
      settings.devices.first,
      DateTime.now().millisecondsSinceEpoch,
    );

    expect(calls.map((request) => request.url.path), [
      endsWith('/users/user/auth/refresh'),
      endsWith('/devices/${settings.devices.first.id}'),
    ]);
    expect(api.session!.token, 'new-access');
    expect(api.session!.refreshToken, 'new-refresh');
  });

  test('a 401 refreshes once and retries the original request', () async {
    var eventCalls = 0;
    final calls = <http.Request>[];
    final settings = testSettings();
    final api = DashboardApi(
      settings,
      useProxy: false,
      client: MockClient((request) async {
        calls.add(request);
        if (request.url.path.endsWith('/auth/refresh')) {
          return jsonResponse({'accessToken': 'new-access'});
        }
        eventCalls++;
        if (eventCalls == 1) {
          expect(request.headers['Subscriber-Key'], 'old-access');
          return jsonResponse({'code': 'ERR_AUTH_001'}, 401);
        }
        expect(request.headers['Subscriber-Key'], 'new-access');
        return jsonResponse([]);
      }),
    );
    addTearDown(api.dispose);
    api.session = Session(
      token: 'old-access',
      user: 'user',
      name: 'Home',
      expires: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'old-refresh',
    );

    await api.vms(
      settings.devices.first,
      DateTime.now().millisecondsSinceEpoch,
    );

    expect(eventCalls, 2);
    expect(
      calls.where((request) => request.url.path.endsWith('/auth/refresh')),
      hasLength(1),
    );
    expect(api.session!.refreshToken, 'old-refresh');
  });

  test('a rejected refresh expires the Qubo session', () async {
    final settings = testSettings();
    final api = DashboardApi(
      settings,
      useProxy: false,
      client: MockClient(
        (_) async => jsonResponse({
          'code': 'ERR_AUTH_REFRESH',
          'message': ['Refresh token expired'],
        }, 401),
      ),
    );
    addTearDown(api.dispose);
    var expired = false;
    api.onExpired = () {
      expired = true;
      api.session = null;
    };
    api.session = Session(
      token: 'old-access',
      user: 'user',
      name: 'Home',
      expires: DateTime.now().add(const Duration(minutes: 1)),
      refreshToken: 'old-refresh',
    );

    await expectLater(
      api.vms(settings.devices.first, 1),
      throwsA(isA<ApiException>().having((error) => error.auth, 'auth', true)),
    );
    expect(expired, true);
    expect(api.session, isNull);
  });

  test('AI capture metadata, URL expiry and recording correlation are exact', () {
    final ai = EventItem.ai({
      'deviceUUID': 'camera',
      'lastEvent': {
        'timestamp': 1792826261457,
        'services': {
          'recordingControl': {
            'events': {
              'stateChanged': {
                'cause': 'PERSON_DETECTED',
                'coordinates': '346,257,67,172',
                'imageFileName':
                    '/tmp/images//camera_PRIMARY_1792826259808.jpeg',
              },
            },
          },
        },
      },
    })!;
    expect(ai.captureTimestamp, 1792826259808);
    expect(ai.mediaTimestamp, 1792826259808);
    expect(ai.detection!.label, '346, 257, 67 × 172 px');
    final signed = SignedUrlInfo.parse(
      'https://example.test/image?X-Amz-Date=20261024T092355Z&X-Amz-Expires=300',
    )!;
    expect(signed.expiresAt, DateTime.utc(2026, 10, 24, 9, 28, 55));
    expect(signed.expired(DateTime.utc(2026, 10, 24, 9, 28, 54)), false);
    expect(signed.expired(DateTime.utc(2026, 10, 24, 9, 28, 55)), true);

    final controller = DashboardController(
      DashboardApi(testSettings()),
      tick: false,
    );
    addTearDown(controller.dispose);
    controller.recordings = [
      EventItem.recording({
        'contentID': 'clip',
        'deviceUUID': 'camera',
        'timestamp': 1792826253279,
        'endTime': 1792826309279,
      }),
    ];
    expect(controller.matchingRecording(ai)?.id, 'clip');
  });

  for (final status in [200, 401, 403]) {
    test('authentication rejection HTTP $status expires the session', () async {
      final api = DashboardApi(
        testSettings(),
        client: MockClient(
          (_) async => jsonResponse({'code': 'ERR_AUTH_001'}, status),
        ),
        useProxy: false,
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      await expectLater(
        api.latest(),
        throwsA(isA<ApiException>().having((e) => e.auth, 'auth', true)),
      );
      expect(c.expired, true);
      expect(c.session, isNull);
    });
  }
  test(
    'expired JWT is blocked before an HTTP request and prompts re-login',
    () async {
      int calls = 0;
      final api = DashboardApi(
        testSettings(),
        client: MockClient((_) async {
          calls++;
          return jsonResponse([]);
        }),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      api.session = Session(
        token: 'expired',
        user: 'u',
        name: '',
        expires: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      await expectLater(api.latest(), throwsA(isA<ApiException>()));
      expect(calls, 0);
      expect(c.expired, true);
    },
  );
  test('clock expiry invalidates the session at the exact boundary', () {
    final time = DateTime.now();
    var clock = time;
    final c = DashboardController(
      DashboardApi(testSettings()),
      now: () => clock,
      tick: false,
    );
    addTearDown(c.dispose);
    c.signIn(
      Session(
        token: 'token',
        user: 'u',
        name: '',
        expires: time.add(const Duration(seconds: 5)),
      ),
    );
    clock = time.add(const Duration(seconds: 5));
    c.checkExpiry();
    expect(c.expired, true);
  });

  test(
    'date-range fetch paginates, deduplicates and filters VMS, AI and overlapping recordings',
    () async {
      final from = DateTime.now().subtract(const Duration(hours: 1)),
          to = DateTime.now();
      final upper = to.millisecondsSinceEpoch,
          lower = from.millisecondsSinceEpoch;
      final settings = testSettings();
      final device = settings.devices.first.id;
      int page = 0;
      Map<String, dynamic> vms(int i, int ts) => {
        'transactionUUID': 't$i',
        'deviceUUID': device,
        'createdTimestamp': ts,
        'callStatus': 'MISSED',
      };
      final first = List.generate(20, (i) => vms(i, upper - i * 10000));
      final api = DashboardApi(
        settings,
        useProxy: false,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/lastEvent')) {
            return jsonResponse([
              {
                'deviceUUID': device,
                'lastEvent': {
                  'timestamp': upper - 5000,
                  'services': {
                    'recordingControl': {
                      'events': {
                        'stateChanged': {
                          'cause': 'PERSON_DETECTED',
                          'imageFileName': '/tmp/image.jpeg',
                        },
                      },
                    },
                  },
                },
              },
              {
                'deviceUUID': 'other',
                'lastEvent': {'timestamp': upper - 1000},
              },
            ]);
          }
          if (r.url.path.endsWith('/time-scrubber')) {
            return jsonResponse([
              {
                'contentID': 'overlap',
                'deviceUUID': device,
                'timestamp': lower - 1000,
                'endTime': lower + 2000,
              },
              {
                'contentID': 'outside',
                'deviceUUID': device,
                'timestamp': lower - 10000,
                'endTime': lower - 1,
              },
            ]);
          }
          page++;
          if (page == 1) return jsonResponse(first);
          expect(r.url.queryParameters['toTimestamp'], '${upper - 190000}');
          return jsonResponse([
            first.last,
            vms(20, lower + 1000),
            vms(21, lower - 1),
          ]);
        }),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      c.setRange(from, to);
      await c.fetch();
      expect(page, 2);
      expect(c.vms.length, 21);
      expect(c.vms.map((e) => e.id).toSet().length, 21);
      expect(c.recordings.single.id, 'overlap');
      expect(c.ai.single.title, 'PERSON DETECTED');
      expect(c.ai.single.imageUrl, isNull);
      expect(c.loading, false);
      expect(c.errors, isEmpty);
    },
  );
  test(
    'one source failure leaves other successful results available',
    () async {
      final settings = testSettings();
      final api = DashboardApi(
        settings,
        useProxy: false,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/time-scrubber')) {
            return jsonResponse({'code': 'ERR_CONTENT'}, 500);
          }
          return jsonResponse([]);
        }),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      await c.fetch();
      expect(c.errors.keys, ['recording']);
      expect(c.fetchedAt, isNotNull);
      expect(c.loading, false);
    },
  );
  test(
    'non-advancing pagination stops with an incomplete-history warning',
    () async {
      final settings = testSettings(), now = DateTime.now();
      var count = 0;
      final api = DashboardApi(
        settings,
        useProxy: false,
        client: MockClient((r) async {
          count++;
          return jsonResponse(
            List.generate(
              20,
              (i) => {
                'transactionUUID': '$i',
                'deviceUUID': settings.devices.first.id,
                'createdTimestamp': now.millisecondsSinceEpoch - i * 1000,
              },
            ),
          );
        }),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      c.setRange(now.subtract(const Duration(hours: 1)), now);
      await c.fetch(only: 'vms');
      expect(count, 2);
      expect(c.vmsNotice, contains('did not advance'));
    },
  );
  test(
    'a delayed old response cannot repopulate a signed-out session',
    () async {
      final pending = Completer<http.Response>();
      final api = DashboardApi(
        testSettings(),
        useProxy: false,
        client: MockClient((_) => pending.future),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      final fetch = c.fetch(only: 'vms');
      c.signOut();
      pending.complete(
        jsonResponse([
          {
            'transactionUUID': 'stale',
            'createdTimestamp': DateTime.now().millisecondsSinceEpoch,
          },
        ]),
      );
      await fetch;
      expect(c.vms, isEmpty);
      expect(c.fetchedAt, isNull);
      expect(c.session, isNull);
    },
  );
  test(
    'an old authentication rejection cannot invalidate a newer session',
    () async {
      final pending = Completer<http.Response>();
      final api = DashboardApi(
        testSettings(),
        useProxy: false,
        client: MockClient((_) => pending.future),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      final request = api.latest();
      c.signIn(session());
      pending.complete(jsonResponse({}, 401));
      await expectLater(request, throwsA(isA<ApiException>()));
      expect(c.session, isNotNull);
      expect(c.expired, false);
    },
  );
  test(
    'signed snapshot URLs are encoded once and unsafe targets are rejected',
    () {
      final api = DashboardApi(
        testSettings()
          ..proxy = 'https://project.supabase.co/functions/v1/qubo-proxy',
        useProxy: true,
      );
      addTearDown(api.dispose);
      const signed =
          'https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-ai-event/u/image.jpeg?X-Amz-Signature=a%2Fb&X-Amz-Date=20261024';
      expect(Uri.parse(api.imageSource(signed)).queryParameters['url'], signed);
      expect(
        () => api.imageSource('http://example.com/picture'),
        throwsA(isA<ApiException>()),
      );
      expect(proxy.allowedTarget(Uri.parse(signed)), true);
      expect(proxy.allowedTarget(Uri.parse('https://example.com')), false);
      expect(
        proxy.allowedTarget(
          Uri.parse('https://srvcapp.platform.quboworld.com.evil.test/'),
        ),
        false,
      );
      expect(
        redact({'token': 'SECRET', 'url': signed, 'aesKey': 'KEY'}).toString(),
        isNot(contains('SECRET')),
      );
      expect(redact({'url': signed}).toString(), isNot(contains('a%2Fb')));
    },
  );
  test(
    'hosted gateway URL is configurable and no localhost proxy is required',
    () {
      final settings = testSettings()
        ..proxy = 'https://project.supabase.co/functions/v1/qubo-proxy';
      final api = DashboardApi(settings, useProxy: true);
      addTearDown(api.dispose);
      final uri = api.transportUri(
        'https://srvcapp.platform.quboworld.com/path?a=1&b=2',
      );
      expect(uri.host, 'project.supabase.co');
      expect(
        uri.queryParameters['url'],
        'https://srvcapp.platform.quboworld.com/path?a=1&b=2',
      );
      settings.proxy = '';
      expect(
        () => api.transportUri('https://example.com'),
        throwsA(isA<ApiException>()),
      );
    },
  );
  for (final body in [
    '<html>Forbidden</html>',
    '{"code":"PROXY_ORIGIN_FORBIDDEN","message":"Origin denied"}',
    '{"message":"Missing authorization header","code":401}',
  ]) {
    test(
      'gateway or HTML access failures do not discard the Qubo session: $body',
      () async {
        final settings = testSettings()
          ..proxy = 'https://project.supabase.co/functions/v1/qubo-proxy';
        final api = DashboardApi(
          settings,
          useProxy: true,
          client: MockClient((_) async => http.Response(body, 403)),
        );
        final c = DashboardController(api, tick: false);
        addTearDown(c.dispose);
        c.signIn(session());
        await expectLater(
          api.latest(),
          throwsA(isA<ApiException>().having((e) => e.auth, 'auth', false)),
        );
        expect(c.session, isNotNull);
        expect(c.expired, false);
      },
    );
  }
  test(
    'an upstream permission 403 without an auth error does not imply token expiry',
    () async {
      final api = DashboardApi(
        testSettings(),
        useProxy: false,
        client: MockClient(
          (_) async => jsonResponse({'code': 'FORBIDDEN'}, 403),
        ),
      );
      final c = DashboardController(api, tick: false);
      addTearDown(c.dispose);
      c.signIn(session());
      await expectLater(
        api.latest(),
        throwsA(isA<ApiException>().having((e) => e.auth, 'auth', false)),
      );
      expect(c.session, isNotNull);
    },
  );
}
