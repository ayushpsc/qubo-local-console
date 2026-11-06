import 'dart:convert';
import 'dart:math';
import 'storage_location.dart';

String installationId() {
  final r = Random.secure();
  final bytes = List.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}'
      .toUpperCase();
}

class Device {
  final String id, name, productType, unit, entity, model, mac, handle;
  const Device({
    required this.id,
    required this.name,
    required this.productType,
    this.unit = '',
    this.entity = '',
    this.model = '',
    this.mac = '',
    this.handle = '',
  });
  Map<String, dynamic> toJson() => {
    'deviceUUID': id,
    'name': name,
    'productType': productType,
    'unitUUID': unit,
    'entityUUID': entity,
    'deviceAModelNo': model,
    'macAddress': mac,
    'handleName': handle,
  };
  factory Device.fromJson(Map<String, dynamic> j) {
    final extra = object(j['extraData']);
    String value(List<String> keys) {
      for (final key in keys) {
        final candidate = j[key] ?? extra[key];
        if (candidate != null && candidate.toString().isNotEmpty) {
          return candidate.toString();
        }
      }
      return '';
    }

    final id = value(['deviceUUID', 'deviceId', 'uuid']);
    if (id.isEmpty) {
      throw const FormatException('Each device needs a deviceUUID.');
    }
    return Device(
      id: id,
      name: value(['name', 'deviceName']).isEmpty
          ? id
          : value(['name', 'deviceName']),
      productType: value(['productType', 'deviceType', 'type']),
      unit: value(['unitUUID', 'unitId', 'unit_uuid']),
      entity: value(['entityUUID', 'entityId', 'entity_uuid']),
      model: value(['deviceAModelNo', 'aModelNo', 'deviceModel', 'model']),
      mac: value(['macAddress', 'mac', 'dmac']),
      handle: value(['handleName', 'handleUUID', 'handleId']),
    );
  }

  bool get isCamera {
    final kind = '$productType $model'.toLowerCase();
    return kind.contains('camera') ||
        kind.contains('doorbell') ||
        RegExp(r'\bhc[dpmois]').hasMatch(kind);
  }
}

class AccountDiscovery {
  final List<String> units;
  final List<Device> devices;
  const AccountDiscovery({required this.units, required this.devices});
}

class ConnectionSettings {
  ConnectionSettings();

  String tenant = 'd10e4bfb0153496e8e8bb955f7ebe413';
  // Native iOS API identity observed on content, VMS and device requests.
  String appId =
      '686C53EF8A9EC021A56FF31ED4DE3B7C9A9A020511418E58F080539DBF33DF94';
  // Android package identity required by the qubopy email/refresh flow.
  String authAppId = 'com.hero.iot';
  String sourceDeviceId = installationId();
  // Account-owned identifiers are populated only by authenticated discovery.
  String unit = '';
  String proxy = const String.fromEnvironment(
    'QUBO_PROXY_URL',
    defaultValue: '',
  );
  String deviceAttribute = 'Apple iPhone15,5';
  List<Device> devices = const [];
  String get validationError =>
      tenant.isEmpty ||
          appId.isEmpty ||
          authAppId.isEmpty ||
          sourceDeviceId.isEmpty
      ? 'Tenant, API app ID, auth app ID and installation ID are required.'
      : '';
}

class Session {
  final String token, user, name;
  final DateTime? expires;
  final String? refreshToken, mqttPassword;
  const Session({
    required this.token,
    required this.user,
    required this.name,
    required this.expires,
    this.refreshToken,
    this.mqttPassword,
  });
  static Map<String, dynamic> claims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map,
      );
    } catch (_) {
      return {};
    }
  }

  factory Session.fromJson(Map<String, dynamic> j, {DateTime? fallbackExpiry}) {
    final token =
        j['accessToken']?.toString() ??
        j['access_token']?.toString() ??
        j['token']?.toString() ??
        '';
    final c = claims(token);
    final exp = c['exp'];
    final user =
        j['uuid']?.toString() ??
        j['userUUID']?.toString() ??
        j['userId']?.toString() ??
        c['user']?.toString() ??
        '';
    if (token.isEmpty || user.isEmpty) {
      throw const FormatException(
        'The server did not return a token and user UUID.',
      );
    }
    return Session(
      token: token,
      user: user,
      name: j['name']?.toString() ?? 'Your home',
      expires: exp is num
          ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000)
          : fallbackExpiry,
      refreshToken:
          j['refreshToken']?.toString() ?? j['refresh_token']?.toString(),
      mqttPassword: j['mqttPassword']?.toString(),
    );
  }
  bool expired(DateTime now) => expires != null && !now.isBefore(expires!);
  bool expiresWithin(DateTime now, Duration window) =>
      expires != null && !expires!.isAfter(now.add(window));
}

int? epoch(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value');
Map<String, dynamic> object(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
List<Map<String, dynamic>> objects(dynamic v) {
  if (v is! List) throw const FormatException('Expected a list from the API.');
  return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

class EventItem {
  final String id, kind, title, deviceId;
  final int timestamp;
  final int? endTime;
  final String? imageUrl, imageFile;
  final int? captureTimestamp;
  final DetectionBox? detection;
  final Map<String, dynamic> raw;
  const EventItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.deviceId,
    required this.timestamp,
    required this.raw,
    this.endTime,
    this.imageUrl,
    this.imageFile,
    this.captureTimestamp,
    this.detection,
  });
  factory EventItem.vms(Map<String, dynamic> j) {
    final snapshot = object(j['snapshot']);
    return EventItem(
      id: '${j['transactionUUID']}',
      kind: 'vms',
      title: '${j['callStatus'] ?? 'Doorbell'} call',
      deviceId: '${j['deviceUUID']}',
      timestamp: epoch(j['createdTimestamp']) ?? 0,
      endTime: epoch(j['closedTimestamp']),
      imageUrl: snapshot['downloadURL'] as String?,
      captureTimestamp: epoch(snapshot['timestamp']),
      raw: j,
    );
  }
  factory EventItem.recording(Map<String, dynamic> j) => EventItem(
    id: '${j['contentID']}',
    kind: 'recording',
    title: 'Camera recording',
    deviceId: '${j['deviceUUID']}',
    timestamp: epoch(j['timestamp']) ?? 0,
    endTime: epoch(j['endTime']),
    raw: j,
  );
  static EventItem? ai(Map<String, dynamic> j) {
    final last = object(j['lastEvent']);
    final ts = epoch(last['timestamp']);
    if (ts == null) return null;
    final rec = object(object(last['services'])['recordingControl']);
    final state = object(object(rec['events'])['stateChanged']);
    // Only use an actual URL returned by the API. Never manufacture a signed URL.
    final filename = state['imageFileName']?.toString();
    final url = findAiSnapshotUrl(j, filename: filename);
    final capture = aiImageTimestamp(filename);
    return EventItem(
      id: '${j['deviceUUID']}_$ts',
      kind: 'ai',
      title: (state['cause']?.toString() ?? 'Device event').replaceAll(
        '_',
        ' ',
      ),
      deviceId: '${j['deviceUUID']}',
      timestamp: ts,
      raw: j,
      imageFile: state['imageFileName']?.toString(),
      imageUrl: url,
      captureTimestamp: capture,
      detection: DetectionBox.tryParse(state['coordinates']),
    );
  }

  int get mediaTimestamp => captureTimestamp ?? timestamp;
  String get sourceLabel => switch (kind) {
    'ai' => 'AI detection',
    'vms' => 'Doorbell call',
    _ => 'SD recording',
  };
  String get cacheKey => '$kind:$deviceId:${imageFile ?? id}';

  bool overlaps(DateTime start, DateTime end) =>
      timestamp <= end.millisecondsSinceEpoch &&
      (endTime ?? timestamp) >= start.millisecondsSinceEpoch;
}

int? aiImageTimestamp(String? filename) {
  if (filename == null) return null;
  final match = RegExp(
    r'_PRIMARY_(\d{13})\.jpe?g$',
    caseSensitive: false,
  ).firstMatch(filename.split('/').last);
  return match == null ? null : int.tryParse(match.group(1)!);
}

class DetectionBox {
  final double x, y, width, height;
  const DetectionBox(this.x, this.y, this.width, this.height);

  static DetectionBox? tryParse(dynamic value) {
    final parts = '$value'.split(',').map(double.tryParse).toList();
    if (parts.length != 4 || parts.any((v) => v == null)) return null;
    final values = parts.cast<double>();
    if (values.any((v) => v < 0) || values[2] <= 0 || values[3] <= 0) {
      return null;
    }
    return DetectionBox(values[0], values[1], values[2], values[3]);
  }

  String get label =>
      '${x.round()}, ${y.round()}, ${width.round()} × ${height.round()} px';
}

class SignedUrlInfo {
  final DateTime signedAt, expiresAt;
  const SignedUrlInfo(this.signedAt, this.expiresAt);
  bool expired([DateTime? at]) => !(at ?? DateTime.now()).isBefore(expiresAt);
  Duration remaining([DateTime? at]) =>
      expiresAt.difference(at ?? DateTime.now());

  static SignedUrlInfo? parse(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null) return null;
    String? parameter(String name) {
      for (final entry in uri.queryParameters.entries) {
        if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
      }
      return null;
    }

    final rawDate = parameter('X-Amz-Date');
    final seconds = int.tryParse(parameter('X-Amz-Expires') ?? '');
    if (rawDate == null || seconds == null) return null;
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$',
    ).firstMatch(rawDate);
    if (match == null) return null;
    int part(int index) => int.parse(match.group(index)!);
    final signed = DateTime.utc(
      part(1),
      part(2),
      part(3),
      part(4),
      part(5),
      part(6),
    );
    return SignedUrlInfo(signed, signed.add(Duration(seconds: seconds)));
  }
}

class MediaDownload {
  final String transactionId, file, url;
  const MediaDownload({
    required this.transactionId,
    required this.file,
    required this.url,
  });
  SignedUrlInfo? get signedUrl => SignedUrlInfo.parse(url);
}

// Accept returned links from nested event/snapshot objects without constructing
// or reusing signatures for another image. A filename alone is not a signed URL.
String? findAiSnapshotUrl(dynamic value, {String? filename}) {
  if (value is String) {
    final uri = Uri.tryParse(value);
    if (uri == null || !isSupportedStorageUri(uri, aiOnly: true)) return null;
    if (filename != null && uri.pathSegments.last != filename.split('/').last) {
      return null;
    }
    return value;
  }
  if (value is Map) {
    for (final nested in value.values) {
      final url = findAiSnapshotUrl(nested, filename: filename);
      if (url != null) return url;
    }
  } else if (value is List) {
    for (final nested in value) {
      final url = findAiSnapshotUrl(nested, filename: filename);
      if (url != null) return url;
    }
  }
  return null;
}

String? findAiSnapshotUrlInText(String text, {String? filename}) {
  for (final match in RegExp(r'https://[^\s"<>]+').allMatches(text)) {
    final url = findAiSnapshotUrl(match.group(0), filename: filename);
    if (url != null) return url;
  }
  return null;
}

// Keep secrets and signed URL query strings out of detail views and logs.
dynamic redact(dynamic v, [String key = '']) {
  if (RegExp(
    r'token|subscriber|aeskey|^iv$|cookie|signature|credential',
    caseSensitive: false,
  ).hasMatch(key)) {
    return '••••••••';
  }
  if (v is Map) return v.map((k, value) => MapEntry('$k', redact(value, '$k')));
  if (v is List) return v.map((e) => redact(e)).toList();
  if (v is String && v.startsWith('https://') && v.contains('?')) {
    return '${v.split('?').first}?<signed query hidden>';
  }
  return v;
}
