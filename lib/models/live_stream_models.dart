import 'dart:convert';
import 'dart:typed_data';

class GoogleHomeCapture {
  static const methodPath =
      '/google.internal.home.foyer.v1.HomeControlService/UpdateTraits';
  static const host = 'googlehomefoyer-pa.googleapis.com';

  final Uint8List body;
  final String authorization;
  final String googleExtension;
  final String environment;
  final String acceptLanguage;
  final String grpcTimeout;

  const GoogleHomeCapture({
    required this.body,
    required this.authorization,
    required this.googleExtension,
    required this.environment,
    required this.acceptLanguage,
    required this.grpcTimeout,
  });

  factory GoogleHomeCapture.parse(Uint8List bytes) {
    if (bytes.length > 256 * 1024) {
      throw const FormatException('The Home capture exceeds 256 KB.');
    }
    final boundary = _headerBoundary(bytes);
    if (boundary == null) {
      throw const FormatException(
        'This is not a complete HTTP capture: the header/body boundary is missing.',
      );
    }
    final headerText = latin1.decode(bytes.sublist(0, boundary.$1));
    final lines = headerText.replaceAll('\r', '').split('\n');
    if (lines.isEmpty || lines.first.trim() != 'POST $methodPath HTTP/2') {
      throw const FormatException(
        'Choose a Google Home UpdateTraits request capture.',
      );
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final split = line.indexOf(':');
      if (split <= 0) continue;
      headers[line.substring(0, split).trim().toLowerCase()] = line
          .substring(split + 1)
          .trim();
    }
    final capturedHost = headers['host']?.toLowerCase();
    if (capturedHost != host && capturedHost != '$host:443') {
      throw const FormatException('The capture is not from Google Home Foyer.');
    }
    final authorization = headers['authorization'] ?? '';
    final extension = headers['x-goog-ext-202964622-bin'] ?? '';
    final environment = headers['foyer-gha-environment'] ?? '';
    if (!authorization.startsWith('Bearer ') ||
        authorization.length <= 'Bearer '.length) {
      throw const FormatException(
        'The capture does not contain a Google OAuth bearer token.',
      );
    }
    if (!_base64Header.hasMatch(extension) ||
        !_base64Header.hasMatch(environment)) {
      throw const FormatException(
        'The capture is missing its Google Home execution context.',
      );
    }
    final body = Uint8List.sublistView(bytes, boundary.$2);
    if (body.length < 6 || body[0] != 0) {
      throw const FormatException(
        'The capture does not contain an uncompressed gRPC request frame.',
      );
    }
    final declared =
        (body[1] << 24) | (body[2] << 16) | (body[3] << 8) | body[4];
    if (declared <= 0 || declared > body.length - 5) {
      throw const FormatException('The captured gRPC frame is incomplete.');
    }
    return GoogleHomeCapture(
      body: Uint8List.fromList(body),
      authorization: authorization,
      googleExtension: extension,
      environment: environment,
      acceptLanguage: headers['accept-language'] ?? 'en-IN,en;q=0.8',
      grpcTimeout: headers['grpc-timeout'] ?? '9999999u',
    );
  }

  static final _base64Header = RegExp(r'^[A-Za-z0-9_+/=-]{8,16384}$');

  static (int, int)? _headerBoundary(Uint8List bytes) {
    for (var i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return (i, i + 4);
      }
    }
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 10 && bytes[i + 1] == 10) return (i, i + 2);
    }
    return null;
  }
}

class LiveStreamSession {
  final String masterUrl;
  final DateTime createdAt;

  const LiveStreamSession({required this.masterUrl, required this.createdAt});

  String get originLabel {
    final uri = Uri.parse(masterUrl);
    return '${uri.host}:${uri.port}';
  }
}

String? findHlsMasterUrl(Uint8List grpcResponse) {
  // The observed protobuf response stores cameraStreamAccessUrl as a UTF-8
  // string. Reading printable bytes keeps this independent of Google's private
  // protobuf schema while remaining strict about the URL accepted afterwards.
  final text = latin1.decode(grpcResponse);
  final match = RegExp(
    r'https?://[^\x00-\x20"<>]+/playlist\.m3u8(?:\?[^\x00-\x20"<>]+)?',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(0);
}
