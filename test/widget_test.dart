import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qubo_camera_ai/main.dart';
import 'package:qubo_camera_ai/controllers/dashboard_controller.dart';
import 'package:qubo_camera_ai/models/dashboard_models.dart';

import 'package:qubo_camera_ai/services/dashboard_api.dart';
import 'package:qubo_camera_ai/services/firebase_live_auth.dart';
import 'package:qubo_camera_ai/widgets/dashboard_widgets.dart';
import 'support/test_settings.dart';

class FakeLiveAuth extends LiveAuthController {
  FirebaseLiveUser? currentUser;

  @override
  FirebaseLiveUser? get user => currentUser;

  @override
  bool get restoring => false;

  @override
  Future<String> idToken() async => 'firebase-test-token';

  @override
  Future<void> restore() async {}

  @override
  Future<void> signIn(String email, String password) async {
    currentUser = FirebaseLiveUser(uid: 'viewer', email: email);
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    currentUser = null;
    notifyListeners();
  }
}

http.Response response(dynamic data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);
Session validSession() => Session(
  token: 'test-token',
  user: 'u',
  name: 'Test',
  expires: DateTime.now().add(const Duration(hours: 1)),
);
final captureKey = GlobalKey();
Future<void> screenshot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('/tmp/qubo-previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  if (!File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf').existsSync()) {
    return;
  }
  final loader = FontLoader('Roboto');
  loader.addFont(
    Future.value(
      ByteData.sublistView(
        File(
          '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        ).readAsBytesSync(),
      ),
    ),
  );
  await loader.load();
}

void main() {
  setUpAll(loadFonts);
  for (final width in [1440.0, 390.0]) {
    testWidgets('Email login and authenticated pages fit at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <http.Request>[];
      final api = DashboardApi(
        testSettings(),
        useProxy: false,
        client: MockClient((r) async {
          calls.add(r);
          if (r.url.path.endsWith('/user/login')) {
            return response({
              'uuid': 'u',
              'accessToken': 'test-token',
              'refreshToken': 'refresh-token',
            });
          }
          if (r.url.path.endsWith('/units')) {
            return response([
              {'unitUUID': 'current-unit'},
            ]);
          }
          if (r.url.path.endsWith('/units/current-unit/devices')) {
            return response([
              {
                'deviceUUID': 'current-camera',
                'deviceName': 'Current doorbell',
                'productType': 'videoDoorbellPro',
                'entityUUID': 'current-entity',
                'deviceAModelNo': 'HCD04A',
              },
            ]);
          }
          return response([]);
        }),
      );
      final c = DashboardController(api, tick: false);
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: QuboCameraApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign in to Qubo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot(tester, width > 1000 ? 'login-desktop' : 'login-mobile');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'owner@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'secret',
      );
      await tester.tap(find.text('Sign in & open dashboard'));
      await tester.pumpAndSettle();
      expect(find.text('Every moment, in view.'), findsOneWidget);
      expect(calls.where((r) => r.url.path.endsWith('/lastEvent')).length, 1);
      expect(tester.takeException(), isNull);
      await screenshot(
        tester,
        width > 1000 ? 'events-desktop' : 'events-mobile',
      );
      for (final page in ['Timeline', 'Devices', 'Live view', 'Connection']) {
        if (width < 1050) {
          await tester.tap(find.byTooltip('Open navigation'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(page).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$page at $width');
        if (page == 'Devices') {
          await screenshot(
            tester,
            width > 1000 ? 'devices-desktop' : 'devices-mobile',
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pumpAndSettle();
    });
  }
  testWidgets('Live view uses Firebase without a Qubo session', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = DashboardController(
      DashboardApi(
        testSettings(),
        useProxy: true,
        client: MockClient((_) async => response([])),
      ),
      tick: false,
    );
    final liveAuth = FakeLiveAuth();
    await tester.pumpWidget(QuboCameraApp(controller: c, liveAuth: liveAuth));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Qubo'), findsOneWidget);

    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live view').first);
    await tester.pumpAndSettle();
    expect(find.text('Sign in for live view'), findsOneWidget);
    expect(find.text('Sign in to Qubo'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'viewer@example.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password',
    );
    await tester.tap(find.text('Open live view'));
    await tester.pumpAndSettle();
    expect(find.text('Live camera & connection tools'), findsOneWidget);
    expect(find.text('Local doorbell stream'), findsOneWidget);
    expect(find.text('go2rtc base URL'), findsOneWidget);
    expect(find.text('Open low-latency player'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    liveAuth.dispose();
  });
  testWidgets('Expiry alert returns the user to email sign-in', (tester) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = DashboardController(
      DashboardApi(
        testSettings(),
        client: MockClient((_) async => response([])),
      ),
      tick: false,
    );
    c.signIn(validSession());
    await tester.pumpWidget(QuboCameraApp(controller: c));
    await tester.pumpAndSettle();
    c.expire();
    await tester.pumpAndSettle();
    expect(find.text('Sign in again'), findsOneWidget);
    await tester.tap(find.text('Go to sign-in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Qubo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
    'Control confirmation sends nothing until confirmed and displays acknowledgement',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <http.Request>[];
      final c = DashboardController(
        DashboardApi(
          testSettings(),
          useProxy: false,
          client: MockClient((r) async {
            calls.add(r);
            return http.Response('SUCCESS', 200);
          }),
        ),
        tick: false,
      )..signIn(validSession());
      await tester.pumpWidget(QuboCameraApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Power on').first);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('Send command to Air purifier?'), findsOneWidget);
      await tester.tap(find.text('Send command'));
      await tester.pumpAndSettle();
      expect(calls.single.url.path, endsWith('/shadow/attribute'));
      expect(jsonDecode(calls.single.body)['attributeValue'], 'on');
      expect(find.textContaining('request acknowledged'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Timeline and details render overlapping clips at the range boundaries',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = DashboardController(DashboardApi(testSettings()), tick: false)
        ..signIn(validSession());
      final ts = c.end.millisecondsSinceEpoch;
      c.recordings = [
        EventItem.recording({
          'contentID': 'clip',
          'deviceUUID': c.selected!.id,
          'timestamp': ts,
          'endTime': ts + 10000,
          'storageType': 'sdCard',
        }),
      ];
      await tester.pumpWidget(QuboCameraApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Camera recording'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Camera recording'));
      await tester.pumpAndSettle();
      expect(find.text('Event details'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Leaving login before email authentication completes cannot restore an old session',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final authentication = Completer<http.Response>();
      final c = DashboardController(
        DashboardApi(
          testSettings(),
          useProxy: false,
          client: MockClient((r) async {
            return authentication.future;
          }),
        ),
        tick: false,
      );
      await tester.pumpWidget(QuboCameraApp(controller: c));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'owner@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'secret',
      );
      await tester.tap(find.text('Sign in & open dashboard'));
      await tester.pump();
      await tester.tap(find.text('Connection').first);
      await tester.pumpAndSettle();
      authentication.complete(
        response({
          'uuid': 'u',
          'accessToken': 'old-server-token',
          'refreshToken': 'old-refresh-token',
        }),
      );
      await tester.pumpAndSettle();
      expect(c.session, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('Wide snapshots retain both edges instead of cropping the image', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const url =
        'https://south-az1-s3.cloud.airtel.in:10445/ar-sz-hero-iot-prod-ai-event/u/image.jpeg?X-Amz-Signature=test';
    final api = DashboardApi(testSettings(), useProxy: false);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 800, 200),
      Paint()..color = const Color(0xFF00FF00),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 200, 200),
      Paint()..color = const Color(0xFFFF0000),
    );
    canvas.drawRect(
      const Rect.fromLTWH(600, 0, 200, 200),
      Paint()..color = const Color(0xFF0000FF),
    );
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(800, 200));
    picture.dispose();
    final provider = ResizeImage.resizeIfNeeded(
      1200,
      null,
      const NetworkImage(url),
    );
    final key = await provider.obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      key,
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: captureKey,
              child: SizedBox(
                width: 360,
                height: 300,
                child: Snapshot(api: api, url: url, height: 300),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final frame = await boundary.toImage(pixelRatio: 1);
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      List<int> pixel(int x, int y) => List.generate(
        3,
        (c) => bytes!.getUint8((y * frame.width + x) * 4 + c),
      );
      expect(pixel(18, 150), [255, 0, 0], reason: 'Left edge must be visible.');
      expect(pixel(342, 150), [
        0,
        0,
        255,
      ], reason: 'Right edge must be visible.');
      expect(pixel(180, 18), [
        25,
        62,
        64,
      ], reason: 'Letterboxing preserves the full aspect ratio.');
      frame.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    api.dispose();
  });
  testWidgets(
    'Event details open an uncropped full-screen zoom view with the same signed URL',
    (tester) async {
      const url =
          'https://south-az1-s3.cloud.airtel.in:10445/ar-sz-hero-iot-prod-vms-event/t/content?X-Amz-Signature=test';
      final api = DashboardApi(testSettings(), useProxy: false);
      final item = EventItem.vms({
        'transactionUUID': 't',
        'deviceUUID': 'device',
        'createdTimestamp': 1792778173015,
        'snapshot': {'downloadURL': url},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EventDetails(
              event: item,
              device: api.settings.devices.first,
              api: api,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('View full image'));
      await tester.tap(find.text('View full image'));
      await tester.pumpAndSettle();
      expect(find.byType(FullSnapshot), findsOneWidget);
      expect(tester.widget<FullSnapshot>(find.byType(FullSnapshot)).url, url);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('Close full snapshot'));
      await tester.pumpAndSettle();
      expect(find.byType(FullSnapshot), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
  testWidgets(
    'AI details show detection metadata and the correlated recording action',
    (tester) async {
      final api = DashboardApi(testSettings(), useProxy: false);
      final ai = EventItem.ai({
        'deviceUUID': api.settings.devices.first.id,
        'lastEvent': {
          'timestamp': 1792826261457,
          'services': {
            'recordingControl': {
              'events': {
                'stateChanged': {
                  'cause': 'PERSON_DETECTED',
                  'coordinates': '346,257,67,172',
                  'imageFileName':
                      '/tmp/images//${api.settings.devices.first.id}_PRIMARY_1792826259808.jpeg',
                },
              },
            },
          },
        },
      })!;
      final recording = EventItem.recording({
        'contentID': 'clip',
        'deviceUUID': ai.deviceId,
        'timestamp': 1792826253279,
        'endTime': 1792826309279,
        'localPath': '/tmp/mnt/sdcard0/camera/clip.mp4',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EventDetails(
              event: ai,
              device: api.settings.devices.first,
              api: api,
              matchingRecording: recording,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('DETECTION BOX'), findsOneWidget);
      expect(find.text('346, 257, 67 × 172 px'), findsOneWidget);
      expect(find.text('PROCESSING DELAY'), findsOneWidget);
      expect(find.text('Matching SD-card recording'), findsOneWidget);
      expect(find.text('Prepare & play'), findsOneWidget);
      final snapshot = tester.widget<Snapshot>(find.byType(Snapshot));
      expect(snapshot.detection, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
}
