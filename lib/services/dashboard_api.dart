import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/dashboard_models.dart';
import '../models/live_stream_models.dart';
import '../models/storage_location.dart';

class ApiException implements Exception {
  final String message;
  final bool auth;
  const ApiException(this.message, {this.auth = false});
  @override
  String toString() => message;
}

class _ApiResponse {
  final http.Response response;
  final dynamic data;
  final String code;
  const _ApiResponse(this.response, this.data, this.code);
}

class DashboardApi {
  final http.Client client;
  final ConnectionSettings settings;
  final bool useProxy;
  Future<String> Function()? liveAuthToken;
  Session? session;
  VoidCallback? onExpired;
  void Function(String method, String path, int status)? onRequest;
  Future<Session>? _refreshing;
  DashboardApi(
    this.settings, {
    http.Client? client,
    bool? useProxy,
    this.liveAuthToken,
  }) : client = client ?? http.Client(),
       useProxy = useProxy ?? kIsWeb;
  static const host = 'https://srvcapp.platform.quboworld.com:443';
  String get sp => Uri.encodeComponent(settings.tenant);
  String unitId(Device d) => d.unit.isNotEmpty ? d.unit : settings.unit;
  String unitFor(Device d) {
    final value = unitId(d);
    if (value.isEmpty) {
      throw const ApiException(
        'This device has no unit UUID. Discover the account again or add it in Connection.',
      );
    }
    return Uri.encodeComponent(value);
  }

  String devicePath(Device d) =>
      'units/${unitFor(d)}/entities/${Uri.encodeComponent(d.entity)}/devices/${Uri.encodeComponent(d.id)}';
  Uri get proxyEndpoint {
    if (settings.proxy.trim().isEmpty) {
      throw const ApiException(
        'Hosted gateway is not configured. Set the deployed Supabase qubo-proxy URL in Connection or build with QUBO_PROXY_URL.',
      );
    }
    final endpoint = Uri.parse(settings.proxy.trim());
    if (!endpoint.hasScheme ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        (endpoint.scheme != 'https' &&
            !(endpoint.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(endpoint.host)))) {
      throw const ApiException(
        'Use an HTTPS hosted gateway URL (HTTP is allowed only for local development).',
      );
    }
    return endpoint;
  }

  Uri transportUri(String target) {
    if (!useProxy) return Uri.parse(target);
    final endpoint = proxyEndpoint;
    return endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'url': target},
    );
  }

  Uri gatewayActionUri(String action) {
    if (!useProxy) {
      throw const ApiException(
        'The configured live-view request is available through the hosted gateway.',
      );
    }
    final endpoint = proxyEndpoint;
    return endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'action': action},
    );
  }

  String imageSource(String target) {
    final uri = Uri.tryParse(target);
    if (uri == null || !isSupportedStorageUri(uri)) {
      throw const ApiException(
        'Use a signed HTTPS snapshot URL from the supported north or south Airtel storage bucket.',
      );
    }
    return transportUri(target).toString();
  }

  String mediaSource(String target) {
    final uri = Uri.tryParse(target);
    if (uri == null || !isSupportedMediaUri(uri)) {
      throw const ApiException(
        'Use a signed Qubo SD-card video URL from the captured push-pull bucket.',
      );
    }
    return transportUri(target).toString();
  }

  String liveSource(String target) {
    final uri = Uri.tryParse(target);
    if (uri == null || !isSupportedLiveUri(uri, masterOnly: true)) {
      throw const ApiException(
        'Use the HLS master URL returned by the captured Google Home live-view call.',
      );
    }
    return transportUri(target).toString();
  }

  Future<String> firebaseLiveToken() async {
    final provider = liveAuthToken;
    if (provider == null) {
      throw const ApiException('Sign in with Firebase to view the camera.');
    }
    try {
      final token = await provider();
      if (token.isEmpty) throw const FormatException();
      return token;
    } catch (error) {
      if (error is ApiException) rethrow;
      throw ApiException('$error', auth: true);
    }
  }

  Future<LiveStreamSession> openGoogleHomeLive(
    Uint8List captureBytes, {
    Duration readinessInterval = const Duration(seconds: 2),
    int readinessAttempts = 15,
  }) async {
    late final GoogleHomeCapture capture;
    try {
      capture = GoogleHomeCapture.parse(captureBytes);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
    const target =
        'https://googlehomefoyer-pa.googleapis.com${GoogleHomeCapture.methodPath}';
    final req = http.Request('POST', transportUri(target));
    if (useProxy) {
      // Supabase's outer Cloudflare layer treats application/grpc as a direct
      // gRPC request and rejects it before the Edge Function. The gateway
      // restores application/grpc without changing these protobuf bytes.
      req.headers.addAll({
        'Authorization': 'Bearer ${await firebaseLiveToken()}',
        'Content-Type': 'application/octet-stream',
        'Accept': 'application/grpc',
        'X-Google-Authorization': capture.authorization,
        'X-Google-Ext': capture.googleExtension,
        'X-Google-Environment': capture.environment,
        'X-Google-Accept-Language': capture.acceptLanguage,
        'X-Google-Grpc-Timeout': capture.grpcTimeout,
      });
    } else {
      req.headers.addAll({
        'Content-Type': 'application/grpc',
        'Accept': 'application/grpc',
        'Authorization': capture.authorization,
        'X-Goog-Ext-202964622-Bin': capture.googleExtension,
        'Foyer-Gha-Environment': capture.environment,
        'Accept-Language': capture.acceptLanguage,
        'Grpc-Timeout': capture.grpcTimeout,
      });
    }
    req.bodyBytes = capture.body;
    try {
      final response = await (() async => http.Response.fromStream(
        await client.send(req),
      ))().timeout(const Duration(seconds: 45));
      onRequest?.call(
        'POST',
        GoogleHomeCapture.methodPath,
        response.statusCode,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ApiException(
          'Google rejected this Home capture. Capture a fresh UpdateTraits request and try again.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          'Google Home live-view request failed with HTTP ${response.statusCode}.',
        );
      }
      final live = _liveSession(response.bodyBytes);
      await _waitForLiveReady(
        live,
        interval: readinessInterval,
        attempts: readinessAttempts,
      );
      return live;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Google Home live-view request timed out.');
    } catch (_) {
      throw const ApiException(
        'Could not replay the Google Home live-view request through the gateway.',
      );
    }
  }

  Future<LiveStreamSession> openConfiguredGoogleHomeLive({
    Duration readinessInterval = const Duration(seconds: 2),
    int readinessAttempts = 15,
  }) async {
    final req = http.Request('POST', gatewayActionUri('google-home-live'));
    req.headers.addAll({
      'Authorization': 'Bearer ${await firebaseLiveToken()}',
      'Accept': 'application/grpc',
    });
    try {
      final response = await (() async => http.Response.fromStream(
        await client.send(req),
      ))().timeout(const Duration(seconds: 45));
      onRequest?.call('POST', '/google-home-live', response.statusCode);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        Map<String, dynamic> data = const {};
        try {
          data = object(jsonDecode(response.body));
        } catch (_) {
          // Preserve the generic message for non-JSON gateway failures.
        }
        final code = data['code']?.toString() ?? '';
        if (code == 'PROXY_FIREBASE_AUTH_REQUIRED' ||
            code == 'PROXY_FIREBASE_AUTH_INVALID') {
          throw const ApiException(
            'Your Firebase live-view session ended. Sign in again.',
            auth: true,
          );
        }
        if (code == 'PROXY_LIVE_PRESET_MISSING') {
          throw const ApiException(
            'The hosted gateway does not have a configured Home request.',
          );
        }
        if (code == 'PROXY_GOOGLE_AUTH_EXPIRED') {
          throw const ApiException(
            'The configured Google Home request expired. Capture a fresh UpdateTraits request and replace the hosted preset.',
          );
        }
        if (code == 'PROXY_LIVE_RESPONSE_EMPTY' ||
            code == 'PROXY_LIVE_RESPONSE_INVALID') {
          throw ApiException(
            data['message']?.toString() ??
                'Google Home did not return a new live URL.',
          );
        }
        throw ApiException(
          'Configured live-view request failed${code.isEmpty ? '' : ' ($code)'} with HTTP ${response.statusCode}.',
        );
      }
      final live = _liveSession(response.bodyBytes);
      await _waitForLiveReady(
        live,
        interval: readinessInterval,
        attempts: readinessAttempts,
      );
      return live;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Configured live-view request timed out.');
    } catch (_) {
      throw const ApiException(
        'Could not reach the configured live-view gateway.',
      );
    }
  }

  LiveStreamSession _liveSession(Uint8List responseBytes) {
    final url = findHlsMasterUrl(responseBytes);
    final uri = url == null ? null : Uri.tryParse(url);
    if (url == null ||
        uri == null ||
        !isSupportedLiveUri(uri, masterOnly: true)) {
      throw const ApiException(
        'Google Home responded without a supported HLS master URL. The configured request may have expired, or a new live origin may need to be added to the gateway allow-list.',
      );
    }
    liveSource(url);
    return LiveStreamSession(masterUrl: url, createdAt: DateTime.now());
  }

  Future<void> _waitForLiveReady(
    LiveStreamSession live, {
    required Duration interval,
    required int attempts,
  }) async {
    if (attempts <= 0) return;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(interval);
      try {
        final response = await client
            .get(
              Uri.parse(liveSource(live.masterUrl)),
              headers: {
                'Accept': 'application/vnd.apple.mpegurl',
                'Authorization': 'Bearer ${await firebaseLiveToken()}',
              },
            )
            .timeout(const Duration(seconds: 12));
        onRequest?.call('GET', '/live-hls-ready', response.statusCode);
        if (response.statusCode == 200 &&
            response.body.trimLeft().startsWith('#EXTM3U')) {
          return;
        }
        if (response.statusCode == 502) {
          try {
            final data = object(jsonDecode(response.body));
            final code = data['code']?.toString();
            if (code == 'PROXY_HLS_CHILD_UNSUPPORTED') {
              final origin = data['resourceOrigin']?.toString() ?? '';
              final path = data['resourcePath']?.toString() ?? '';
              final resource = origin.isNotEmpty && path.isNotEmpty
                  ? ' ($origin$path)'
                  : '';
              throw ApiException(
                'The live playlist contains a media path that is not yet supported by the gateway$resource.',
              );
            }
          } on ApiException {
            rethrow;
          } catch (_) {
            // A transient non-HLS response can occur while Wowza is starting.
          }
        }
      } on ApiException {
        rethrow;
      } catch (_) {
        // Network errors and 404/503 responses are retried during camera start.
      }
    }
    throw const ApiException(
      'The live URL was created, but the camera did not publish an HLS playlist within 30 seconds. Try Start live view again.',
    );
  }

  Future<Uint8List> snapshotBytes(String target) async {
    final source = imageSource(target);
    try {
      final response = await client
          .get(Uri.parse(source), headers: const {'Accept': 'image/*'})
          .timeout(const Duration(seconds: 40));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          'Snapshot download failed with HTTP ${response.statusCode}. The signed link may have expired.',
        );
      }
      if (response.bodyBytes.length > 5 * 1024 * 1024) {
        throw const ApiException('Snapshot exceeds the 5 MB offline limit.');
      }
      return response.bodyBytes;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Snapshot download timed out.');
    } catch (_) {
      throw const ApiException(
        'Could not download the snapshot for offline use.',
      );
    }
  }

  Future<_ApiResponse> _send(
    String method,
    String path, {
    Map<String, String>? query,
    dynamic body,
    required Map<String, String> headers,
  }) async {
    final target = Uri.parse('$host$path').replace(queryParameters: query);
    final req = http.Request(method, transportUri(target.toString()));
    req.headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      final response = await (() async => http.Response.fromStream(
        await client.send(req),
      ))().timeout(const Duration(seconds: 40));
      onRequest?.call(method, path, response.statusCode);
      dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        data = response.body.trim();
      }
      final code = data is Map ? '${data['code'] ?? ''}' : '';
      if (useProxy &&
          response.headers['x-qubo-proxy'] != 'upstream' &&
          (response.statusCode == 401 || response.statusCode == 403) &&
          !code.startsWith('PROXY_')) {
        throw ApiException(
          'The hosted gateway rejected the request before Qubo authentication (HTTP ${response.statusCode}). Check its deployment, allowed origins and Supabase verify_jwt=false configuration.',
        );
      }
      final proxyFailure =
          response.headers['x-qubo-proxy'] == 'gateway' ||
          code.startsWith('PROXY_');
      if (proxyFailure) {
        throw ApiException(
          'Gateway error ($code), HTTP ${response.statusCode}. ${data is Map ? data['message'] ?? '' : ''}',
        );
      }
      if (response.body.trimLeft().toLowerCase().startsWith('<!doctype html') ||
          response.body.trimLeft().toLowerCase().startsWith('<html')) {
        throw ApiException(
          response.statusCode == 403
              ? 'Qubo or the gateway returned an HTML 403 page. This is an access restriction, not evidence of token expiry.'
              : 'The gateway URL returned a web page instead of API data. Configure the deployed Supabase function URL in Connection.',
        );
      }
      return _ApiResponse(response, data, code);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'The request timed out. Check your connection and retry.',
      );
    } catch (_) {
      throw const ApiException(
        'Could not reach the gateway. Check the hosted gateway URL, its deployment and CORS settings in Connection.',
      );
    }
  }

  String _serverMessage(dynamic data) {
    if (data is! Map) return '';
    final value = data['message'] ?? data['errorMessage'] ?? data['error'];
    if (value is List) return value.map((item) => '$item').join(' ');
    return value?.toString() ?? '';
  }

  bool _failed(_ApiResponse result) =>
      result.response.statusCode < 200 ||
      result.response.statusCode >= 300 ||
      result.code.startsWith('ERR') ||
      (result.data is Map && result.data['success'] == false);

  bool _authFailed(_ApiResponse result) =>
      result.response.statusCode == 401 ||
      result.code.startsWith('ERR_AUTH') ||
      result.code == 'TOKEN_EXPIRED';

  ApiException _failure(_ApiResponse result, {bool auth = false}) {
    final detail = _serverMessage(result.data);
    return ApiException(
      '${auth ? 'Qubo rejected this session' : 'Request failed'}'
      '${result.code.isNotEmpty ? ' (${result.code})' : ''}, '
      'HTTP ${result.response.statusCode}${detail.isEmpty ? '.' : ': $detail'}',
      auth: auth,
    );
  }

  Future<Session> _validSession() async {
    final active = session;
    if (active == null) {
      onExpired?.call();
      throw const ApiException('Sign in to Qubo to continue.', auth: true);
    }
    final now = DateTime.now();
    final canRefresh = active.refreshToken?.isNotEmpty ?? false;
    if (canRefresh && active.expiresWithin(now, const Duration(minutes: 5))) {
      try {
        return await refreshSession();
      } on ApiException catch (error) {
        final current = session;
        if (!error.auth && current != null && !current.expired(now)) {
          return current;
        }
        if (identical(session, active)) onExpired?.call();
        if (error.auth) rethrow;
        throw const ApiException(
          'Your Qubo session expired and could not be renewed. Sign in again.',
          auth: true,
        );
      }
    }
    if (active.expired(now)) {
      if (identical(session, active)) onExpired?.call();
      throw const ApiException(
        'Your Qubo session expired. Sign in again.',
        auth: true,
      );
    }
    return active;
  }

  Future<Session> ensureValidSession() => _validSession();

  Future<dynamic> request(
    String method,
    String path, {
    Map<String, String>? query,
    dynamic body,
    bool authenticated = true,
    bool retried = false,
    bool useAuthProfile = false,
  }) async {
    if (settings.validationError.isNotEmpty) {
      throw ApiException(settings.validationError);
    }
    final activeSession = authenticated ? await _validSession() : null;
    final headers = <String, String>{
      'App-Id': useAuthProfile ? settings.authAppId : settings.appId,
      'Token-Type': 'USER',
      'Source-Device-Id': settings.sourceDeviceId,
      'Source': authenticated ? (useAuthProfile ? 'Android' : 'IOS') : 'USER',
      'Accept': useAuthProfile ? 'application/json' : '*/*',
    };
    if (authenticated) {
      headers.addAll({
        'User-UUID': activeSession!.user,
        'Subscriber-Key': activeSession.token,
      });
      if (useAuthProfile) {
        headers.addAll({
          'Authorization': 'Bearer ${activeSession.token}',
          'Content-Type': 'application/json',
        });
      }
    } else {
      headers.addAll({
        'App-Type': 'HOME',
        'Login-Device-Name': settings.deviceAttribute,
      });
    }
    final result = await _send(
      method,
      path,
      query: query,
      body: body,
      headers: headers,
    );
    if (authenticated &&
        result.response.statusCode == 401 &&
        !retried &&
        (activeSession!.refreshToken?.isNotEmpty ?? false)) {
      try {
        await refreshSession(failedToken: activeSession.token);
        return request(
          method,
          path,
          query: query,
          body: body,
          authenticated: true,
          retried: true,
          useAuthProfile: useAuthProfile,
        );
      } on ApiException {
        if (identical(session, activeSession)) onExpired?.call();
        rethrow;
      }
    }
    if (authenticated && _authFailed(result)) {
      if (identical(session, activeSession)) onExpired?.call();
      throw _failure(result, auth: true);
    }
    if (_failed(result)) throw _failure(result);
    return result.data;
  }

  Future<List<Session>> loginProfilesWithEmail(
    String email,
    String password,
  ) async {
    if (settings.validationError.isNotEmpty) {
      throw ApiException(settings.validationError);
    }
    final result = await _send(
      'POST',
      '/sms/api/v1/sp/$sp/user/login',
      query: const {'system': 'CS'},
      body: {
        'username': email,
        'email': email,
        'password': password,
        'deviceAttribute': settings.deviceAttribute,
      },
      headers: {
        'Content-Type': 'application/json',
        'App-Id': settings.authAppId,
        'Source-Device-Id': settings.sourceDeviceId,
        'Source': 'USER',
        'Token-Type': 'USER',
        'Accept': 'application/json',
      },
    );
    if (_failed(result)) throw _failure(result);
    final values = result.data is List ? result.data as List : [result.data];
    if (values.isEmpty || values.any((value) => value is! Map)) {
      throw const ApiException(
        'Qubo returned an unexpected email login response.',
      );
    }
    try {
      return values
          .map(
            (value) => Session.fromJson(
              Map<String, dynamic>.from(value as Map),
              fallbackExpiry: DateTime.now().add(const Duration(hours: 24)),
            ),
          )
          .toList();
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<Session> loginWithEmail(String email, String password) async {
    final profiles = await loginProfilesWithEmail(email, password);
    if (profiles.length != 1) {
      throw ApiException(
        'Qubo returned ${profiles.length} account profiles. Select the intended profile in the app instead of silently using the first one.',
      );
    }
    return profiles.single;
  }

  Future<Session> refreshSession({String? failedToken}) async {
    final active = session;
    if (active == null || (active.refreshToken?.isEmpty ?? true)) {
      throw const ApiException(
        'This Qubo session cannot be renewed. Sign in again.',
        auth: true,
      );
    }
    if (failedToken != null && active.token != failedToken) return active;
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _performRefresh(active);
    _refreshing = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  Future<Session> _performRefresh(Session active) async {
    final result = await _send(
      'POST',
      '/sms/api/v1/sp/$sp/users/${Uri.encodeComponent(active.user)}/auth/refresh',
      body: {'accessToken': active.token, 'refreshToken': active.refreshToken},
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${active.token}',
        'Subscriber-Key': active.token,
        'User-UUID': active.user,
        'Token-Type': 'USER',
        'Source-Device-Id': settings.sourceDeviceId,
        'App-Id': settings.authAppId,
        'Source': 'Android',
        'Accept': 'application/json',
      },
    );
    if (_failed(result)) {
      throw _failure(
        result,
        auth: const [400, 401, 403].contains(result.response.statusCode),
      );
    }
    if (result.data is! Map) {
      throw const ApiException(
        'Qubo returned an invalid token refresh response.',
      );
    }
    final data = Map<String, dynamic>.from(result.data as Map);
    late final Session updated;
    try {
      updated = Session.fromJson({
        ...data,
        'uuid': active.user,
        'name': active.name,
        'refreshToken':
            data['refreshToken'] ??
            data['refresh_token'] ??
            active.refreshToken,
        'mqttPassword': data['mqttPassword'] ?? active.mqttPassword,
      }, fallbackExpiry: DateTime.now().add(const Duration(hours: 24)));
    } on FormatException catch (error) {
      throw ApiException(
        'Invalid Qubo token refresh response: ${error.message}',
      );
    }
    if (identical(session, active)) {
      session = updated;
      return updated;
    }
    return session ??
        (throw const ApiException(
          'The Qubo session changed while it was being renewed.',
          auth: true,
        ));
  }

  List<Map<String, dynamic>> _records(
    dynamic value,
    List<String> collectionKeys,
  ) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    if (value is! Map) return const [];
    final map = Map<String, dynamic>.from(value);
    for (final key in collectionKeys) {
      final nested = map[key];
      if (nested is List) {
        return nested
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
      if (nested is Map) {
        final records = _records(nested, collectionKeys);
        if (records.isNotEmpty) return records;
      }
    }
    return [map];
  }

  Future<AccountDiscovery> discoverAccount() async {
    final unitRows = _records(
      await request(
        'GET',
        '/unit-entity-management/api/v1/sp/$sp/units',
        useAuthProfile: true,
      ),
      const ['data', 'units'],
    );
    final units = <String>[];
    final devices = <String, Device>{};

    void addDevice(
      Map<String, dynamic> raw,
      String unit, [
      String entity = '',
    ]) {
      final enriched = <String, dynamic>{
        ...raw,
        if ((raw['unitUUID']?.toString().isEmpty ?? true)) 'unitUUID': unit,
        if (entity.isNotEmpty &&
            (raw['entityUUID']?.toString().isEmpty ?? true))
          'entityUUID': entity,
      };
      try {
        final device = Device.fromJson(enriched);
        final label = '${device.name} ${device.model}'.toLowerCase();
        if (label.startsWith('mobileapp_') ||
            device.model.toLowerCase() == 'mobile') {
          return;
        }
        devices[device.id] = device;
      } on FormatException {
        // Ignore non-device objects returned alongside the account hierarchy.
      }
    }

    for (final unitRow in unitRows) {
      final unit =
          unitRow['unitUUID']?.toString() ??
          unitRow['uuid']?.toString() ??
          unitRow['unitId']?.toString() ??
          '';
      if (unit.isEmpty || units.contains(unit)) continue;
      units.add(unit);

      final entities = unitRow['entities'];
      if (entities is List) {
        for (final value in entities.whereType<Map>()) {
          final entity = Map<String, dynamic>.from(value);
          final entityId =
              entity['entityUUID']?.toString() ??
              entity['uuid']?.toString() ??
              entity['entityId']?.toString() ??
              '';
          for (final raw in _records(entity, const ['devices'])) {
            if (raw.containsKey('deviceUUID') ||
                raw.containsKey('deviceId') ||
                raw.containsKey('deviceName')) {
              addDevice(raw, unit, entityId);
            }
          }
        }
      }

      try {
        final rows = _records(
          await request(
            'GET',
            '/unit-entity-management/api/v1/sp/$sp/units/${Uri.encodeComponent(unit)}/devices',
            useAuthProfile: true,
          ),
          const ['data', 'devices'],
        );
        for (final row in rows) {
          addDevice(row, unit);
        }
      } on ApiException catch (error) {
        if (error.auth) rethrow;
        // A unit may contain only nested entity devices or deny this aggregate
        // route. Keep any devices already extracted from the unit response.
      }
    }

    if (units.isEmpty) {
      throw const ApiException(
        'Qubo returned no homes for this email account. Check that the account has accepted its home invitation.',
      );
    }
    if (devices.isEmpty) {
      throw const ApiException(
        'Qubo returned no devices for this email account. The captured device identifiers were not used.',
      );
    }
    return AccountDiscovery(units: units, devices: devices.values.toList());
  }

  Future<String> login(String phone, String isd) async {
    final j = object(
      await request(
        'POST',
        '/sms/api/v1/sp/$sp/user/phone/login',
        authenticated: false,
        body: {
          'isdCode': isd,
          'phone': phone,
          'deviceAttribute': settings.deviceAttribute,
        },
      ),
    );
    final uuid = j['uuid']?.toString() ?? '';
    if (uuid.isEmpty) {
      throw const ApiException(
        'The login response did not include a user UUID.',
      );
    }
    return uuid;
  }

  Future<Session> verify(
    String phone,
    String isd,
    String otp,
    String uuid,
  ) async {
    final rows = objects(
      await request(
        'POST',
        '/sms/api/v1/sp/$sp/user/phone/verify',
        authenticated: false,
        body: {
          'otp': otp,
          'phone': phone,
          'isdCode': isd,
          'deviceAttribute': settings.deviceAttribute,
          'uuid': uuid,
        },
      ),
    );
    if (rows.isEmpty) {
      throw const ApiException(
        'Verification returned no user. Request a new code.',
      );
    }
    return Session.fromJson(rows.first);
  }

  Future<List<Map<String, dynamic>>> vms(Device d, int cursor) async => objects(
    await request(
      'GET',
      '/vms/api/v1/sp/$sp/units/${unitFor(d)}/devices/${Uri.encodeComponent(d.id)}',
      query: {'recordNumber': '20', 'toTimestamp': '$cursor'},
    ),
  );
  Future<List<Map<String, dynamic>>> timeline(
    Device d,
    DateTime start,
    DateTime end,
  ) async {
    // Both successful native captures query complete local calendar days,
    // including a future end-of-day boundary on the current date. Fetch the
    // containing day partitions and let DashboardController apply the user's
    // exact start/end times to the returned clips.
    final queryStart = DateTime(start.year, start.month, start.day);
    final queryEnd = DateTime(end.year, end.month, end.day, 23, 59, 59);
    return objects(
      await request(
        'GET',
        '/content-manager/api/v1/sp/$sp/unit/${unitFor(d)}/device/${Uri.encodeComponent(d.id)}/time-scrubber',
        query: {
          'startTime': '${queryStart.millisecondsSinceEpoch}',
          'endTime': '${queryEnd.millisecondsSinceEpoch}',
          'skipIntervalName': 'seconds',
          'skipIntervalValue': '30',
          'contentType': 'video',
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> latest() async => objects(
    await request(
      'PUT',
      '/control-monitor/api/v1/sp/$sp/lastEvent',
      body: settings.devices
          .where((d) => d.productType.isNotEmpty)
          .map((d) => {'deviceUUID': d.id, 'productType': d.productType})
          .toList(),
    ),
  );
  Future<String> contentUrl(
    Device d,
    String transaction,
    String content,
  ) async {
    final j = object(
      await request(
        'GET',
        '/vms/api/v1/sp/$sp/units/${unitFor(d)}/devices/${Uri.encodeComponent(d.id)}/transactions/${Uri.encodeComponent(transaction)}/contents/${Uri.encodeComponent(content)}',
      ),
    );
    final url = j['preSignedDownloadUrl']?.toString() ?? '';
    if (url.isEmpty) {
      throw const ApiException('The server returned no download URL.');
    }
    imageSource(url);
    return url;
  }

  Future<MediaDownload> prepareRecording(
    Device d,
    String file, {
    Duration pollInterval = const Duration(seconds: 2),
    int attempts = 15,
  }) async {
    if (d.entity.isEmpty) {
      throw const ApiException(
        'This camera needs an entity UUID before SD-card playback can be requested.',
      );
    }
    if (!file.startsWith('/tmp/mnt/sdcard0/') ||
        !file.toLowerCase().endsWith('.mp4')) {
      throw const ApiException(
        'The recording does not contain a supported SD-card MP4 path.',
      );
    }
    final created = object(
      await request(
        'POST',
        '/push-pull/request',
        body: {
          'files': [
            {'file': file},
          ],
          'filesType': 'sdCardMedia',
          'target': {
            'unitUUID': unitId(d),
            'targetUUID': d.id,
            'entityUUID': d.entity,
            'targetType': 'device',
          },
        },
      ),
    );
    final transaction = created['transactionId']?.toString() ?? '';
    if (transaction.isEmpty) {
      throw const ApiException(
        'Qubo accepted the export request but returned no transaction ID.',
      );
    }
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(pollInterval);
      final status = object(
        await request(
          'GET',
          '/push-pull/transaction/${Uri.encodeComponent(transaction)}',
        ),
      );
      final files = status['files'];
      if (files is! List) continue;
      for (final value in files) {
        final item = object(value);
        if (item['file']?.toString() != file) continue;
        final url = item['downloadURL']?.toString() ?? '';
        if (url.isEmpty) continue;
        mediaSource(url);
        return MediaDownload(transactionId: transaction, file: file, url: url);
      }
    }
    throw const ApiException(
      'The camera did not finish staging this recording within 30 seconds. Try again while it is online.',
    );
  }

  Future<dynamic> shadow(Device d, Map<String, dynamic> body) => request(
    'PUT',
    '/unit-entity-management/api/v1/sp/$sp/${devicePath(d)}/shadow/attribute',
    body: body,
  );
  Future<dynamic> command(Device d, Map<String, dynamic> body) => request(
    'PUT',
    '/unit-entity-management/api/v1/sp/$sp/${devicePath(d)}/command',
    body: body,
  );
  Future<dynamic> rtspSupport(Device d) => request(
    'POST',
    '/unit-entity-management/api/v1/sp/$sp/units/${unitFor(d)}/devices/rtsp/support',
    body: [
      {'deviceAModelNo': d.model, 'macAddress': d.mac, 'deviceUUID': d.id},
    ],
  );
  Future<dynamic> streamRequest(Device d) => request(
    'PUT',
    '/roi-manager/api/v1/sp/$sp/device/${Uri.encodeComponent(d.id)}/stream/rtsp',
    body: {'transportType': 'turn', 'protocol': 'p2p'},
  );
  Future<dynamic> credentials(Device d) => request(
    'POST',
    '/stream-manager/api/v3/sp/$sp/unit/${unitFor(d)}/devices/pp2p/credentials',
    body: {
      'unitUUID': unitId(d),
      'userAppID': settings.sourceDeviceId,
      'devices': [
        {'protocol': 'udp', 'deviceUUID': d.id},
      ],
    },
  );
  void dispose() => client.close();
}
