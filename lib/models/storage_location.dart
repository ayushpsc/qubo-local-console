// Keep the original URL intact: AWS signatures depend on the host, port and path.
bool isSupportedStorageUri(Uri uri, {bool aiOnly = false}) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment) {
    return false;
  }
  final region = switch (uri.host) {
    'north-az1-s3.cloud.airtel.in' => (code: 'nz', port: 10446),
    'south-az1-s3.cloud.airtel.in' => (code: 'sz', port: 10445),
    _ => null,
  };
  if (region == null || (uri.port != 443 && uri.port != region.port)) {
    return false;
  }
  final segments = uri.pathSegments;
  if (segments.length < 3 || segments.last.isEmpty) return false;
  return segments.first == 'ar-${region.code}-hero-iot-prod-ai-event' ||
      (!aiOnly &&
          segments.first == 'ar-${region.code}-hero-iot-prod-vms-event');
}

const pushPullStorageHost =
    'heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com';

const liveStreamHost = '13.235.191.60';
const liveStreamPort = 1935;

// The only live origin established by the supplied Google Home capture. Keep
// this narrow: accepting arbitrary HTTP hosts would turn the gateway into an
// SSRF/open-proxy endpoint.
bool isSupportedLiveUri(Uri uri, {bool masterOnly = false}) {
  if (uri.scheme != 'http' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.host != liveStreamHost ||
      uri.port != liveStreamPort) {
    return false;
  }
  final match = RegExp(
    r'^/hero-iot-live/HLS_[0-9a-fA-F-]{36}_[0-9]+/((?:[A-Za-z0-9._~=-]+/)*[A-Za-z0-9._~=-]+)$',
    caseSensitive: false,
  ).firstMatch(uri.path);
  if (match == null) return false;
  return !masterOnly || match.group(1)!.toLowerCase() == 'playlist.m3u8';
}

// Push-pull exports are short-lived, signed MP4 objects. Keep this validation
// deliberately narrower than a general Amazon S3 proxy allow-list.
bool isSupportedMediaUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.host != pushPullStorageHost ||
      uri.port != 443) {
    return false;
  }
  final path = Uri.decodeComponent(uri.path);
  return RegExp(
    r'^/sdCardMedia--[0-9a-fA-F-]{36}--/tmp/mnt/sdcard0/.+\.mp4$',
  ).hasMatch(path);
}
