import 'package:flutter_test/flutter_test.dart';
import 'package:qubo_camera_ai/models/dashboard_models.dart';

Map<String, dynamic> event({dynamic snapshot}) => {
  'deviceUUID': 'device',
  'lastEvent': {
    'timestamp': 1792778173015,
    'services': {
      'recordingControl': {
        'events': {
          'stateChanged': {
            'cause': 'PERSON_DETECTED',
            'imageFileName': '/tmp/images/device_PRIMARY_1792778171271.jpeg',
          },
        },
      },
    },
    'snapshot': snapshot,
  },
};

void main() {
  const north =
      'https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-ai-event/unit/device_PRIMARY_1792778171271.jpeg?X-Amz-Signature=north';
  const south =
      'https://south-az1-s3.cloud.airtel.in:10445/ar-sz-hero-iot-prod-ai-event/unit/device_PRIMARY_1792778171271.jpeg?X-Amz-Signature=south';
  test(
    'nested signed AI snapshot URLs are matched to their event filename in both regions',
    () {
      for (final link in [north, south]) {
        expect(
          EventItem.ai(event(snapshot: {'downloadURL': link}))!.imageUrl,
          link,
        );
        expect(
          EventItem.ai(
            event(
              snapshot: {
                'image': {'preSignedDownloadUrl': link},
              },
            ),
          )!.imageUrl,
          link,
        );
      }
    },
  );
  test(
    'a filename-only latest event does not manufacture a signed snapshot URL',
    () {
      final item = EventItem.ai(event())!;
      expect(item.imageFile, '/tmp/images/device_PRIMARY_1792778171271.jpeg');
      expect(item.imageUrl, isNull);
    },
  );
  test(
    'a different event image or VMS image cannot be substituted for an AI alert',
    () {
      expect(
        EventItem.ai(
          event(
            snapshot: {
              'downloadURL': south.replaceFirst(
                '1792778171271',
                '1792778170000',
              ),
            },
          ),
        )!.imageUrl,
        isNull,
      );
      expect(
        EventItem.ai(
          event(
            snapshot: {
              'downloadURL': south.replaceFirst(
                'prod-ai-event',
                'prod-vms-event',
              ),
            },
          ),
        )!.imageUrl,
        isNull,
      );
    },
  );
  test(
    'image capture text selects the matching AI URL without changing its signature',
    () {
      final capture =
          '## Sniffed Detail - $south \n\nGET $south HTTP/1.1\nSubscriber-Key: unrelated-token';
      expect(
        findAiSnapshotUrlInText(
          capture,
          filename: 'device_PRIMARY_1792778171271.jpeg',
        ),
        south,
      );
      expect(
        findAiSnapshotUrlInText(capture, filename: 'another-event.jpeg'),
        isNull,
      );
    },
  );
}
