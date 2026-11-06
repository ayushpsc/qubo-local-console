class Go2RtcEndpoint {
  final Uri base;
  final String stream;

  const Go2RtcEndpoint({required this.base, required this.stream});

  factory Go2RtcEndpoint.parse(String baseUrl, String streamName) {
    final base = Uri.tryParse(baseUrl.trim());
    final stream = streamName.trim();
    if (base == null ||
        !base.hasScheme ||
        base.host.isEmpty ||
        (base.scheme != 'http' && base.scheme != 'https') ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException(
        'Enter the HTTP or HTTPS base URL of your LAN go2rtc server.',
      );
    }
    if (stream.isEmpty ||
        stream.length > 80 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(stream)) {
      throw const FormatException(
        'Stream name may contain only letters, numbers, dots, dashes and underscores.',
      );
    }
    return Go2RtcEndpoint(base: base, stream: stream);
  }

  Uri _child(String path, Map<String, String> query) {
    final prefix = base.pathSegments.where((segment) => segment.isNotEmpty);
    final suffix = path.split('/').where((segment) => segment.isNotEmpty);
    return base.replace(
      pathSegments: [...prefix, ...suffix],
      queryParameters: query,
    );
  }

  Uri get hlsUrl => _child('api/stream.m3u8', {
    'src': stream,
    'video': 'h264',
    'audio': 'aac',
  });

  Uri get playerUrl => _child('stream.html', {
    'src': stream,
    'mode': 'webrtc,webrtc/tcp,mse,hls',
  });

  Uri get talkPlayerUrl =>
      _child('webrtc.html', {'src': stream, 'media': 'video+audio+microphone'});
}
