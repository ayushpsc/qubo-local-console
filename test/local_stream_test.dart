import 'package:flutter_test/flutter_test.dart';
import 'package:qubo_camera_ai/models/local_stream_models.dart';

void main() {
  test('go2rtc URLs preserve a reverse-proxy base path and encode the stream', () {
    final endpoint = Go2RtcEndpoint.parse(
      'https://camera.example.test/rtc',
      'qubo_doorbell',
    );

    expect(
      endpoint.hlsUrl.toString(),
      'https://camera.example.test/rtc/api/stream.m3u8?src=qubo_doorbell&video=h264&audio=aac',
    );
    expect(
      endpoint.playerUrl.toString(),
      'https://camera.example.test/rtc/stream.html?src=qubo_doorbell&mode=webrtc%2Cwebrtc%2Ftcp%2Cmse%2Chls',
    );
    expect(
      endpoint.talkPlayerUrl.toString(),
      'https://camera.example.test/rtc/webrtc.html?src=qubo_doorbell&media=video%2Baudio%2Bmicrophone',
    );
  });

  for (final invalid in [
    'ftp://camera.local',
    'https://user:pass@camera.local',
    'https://camera.local?secret=value',
    'https://camera.local/#fragment',
  ]) {
    test('unsafe go2rtc base URL is rejected: $invalid', () {
      expect(
        () => Go2RtcEndpoint.parse(invalid, 'qubo_doorbell'),
        throwsFormatException,
      );
    });
  }

  test('unsafe go2rtc stream name is rejected', () {
    expect(
      () => Go2RtcEndpoint.parse('http://camera.local:1984', '../secret'),
      throwsFormatException,
    );
  });
}
