import 'package:flutter_test/flutter_test.dart';
import 'package:qubo_camera_ai/models/storage_location.dart';
import 'package:qubo_camera_ai/services/dashboard_api.dart';
import '../bin/proxy.dart' as local;
import 'support/test_settings.dart';

void main() {
  const media =
      'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/sdCardMedia--bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb--/tmp/mnt/sdcard0/camera/clip.mp4?X-Amz-Signature=abc&X-Amz-Date=20261024T092355Z&X-Amz-Expires=300';
  test(
    'captured push-pull MP4 URL is accepted without changing its signature',
    () {
      final api = DashboardApi(testSettings(), useProxy: true);
      addTearDown(api.dispose);
      expect(isSupportedMediaUri(Uri.parse(media)), true);
      expect(local.allowedTarget(Uri.parse(media)), true);
      expect(Uri.parse(api.mediaSource(media)).queryParameters['url'], media);
    },
  );
  for (final invalid in [
    'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/other/clip.mp4?X-Amz-Signature=abc',
    'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/sdCardMedia--not-a-uuid--/tmp/mnt/sdcard0/clip.mp4?X-Amz-Signature=abc',
    'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/sdCardMedia--bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb--/tmp/mnt/sdcard0/clip.jpg?X-Amz-Signature=abc',
    'https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com.evil.test/sdCardMedia--bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb--/tmp/mnt/sdcard0/clip.mp4?X-Amz-Signature=abc',
  ]) {
    test('unrelated media target remains blocked: $invalid', () {
      expect(isSupportedMediaUri(Uri.parse(invalid)), false);
    });
  }
  for (final region in [('north', 'nz', 10446), ('south', 'sz', 10445)]) {
    for (final port in ['', ':443', ':${region.$3}']) {
      for (final kind in ['ai', 'vms']) {
        final target =
            'https://${region.$1}-az1-s3.cloud.airtel.in$port/ar-${region.$2}-hero-iot-prod-$kind-event/unit/image.jpeg?X-Amz-Signature=a%2Fb&X-Amz-Date=20261024';
        test(
          '${region.$1} $kind snapshot $port preserves the entire signed URL',
          () {
            final api = DashboardApi(testSettings(), useProxy: true);
            addTearDown(api.dispose);
            expect(isSupportedStorageUri(Uri.parse(target)), true);
            expect(
              isSupportedStorageUri(Uri.parse(target), aiOnly: true),
              kind == 'ai',
            );
            expect(local.allowedTarget(Uri.parse(target)), true);
            expect(
              Uri.parse(api.imageSource(target)).queryParameters['url'],
              target,
            );
          },
        );
      }
    }
  }
  for (final target in [
    'http://south-az1-s3.cloud.airtel.in/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in.evil.test/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in:10446/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://north-az1-s3.cloud.airtel.in:10445/ar-nz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in/ar-nz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in/unrelated-bucket/u/image.jpeg',
    'https://user:pass@south-az1-s3.cloud.airtel.in/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in/ar-sz-hero-iot-prod-ai-event/u/image.jpeg#fragment',
  ]) {
    test('unsupported storage target remains blocked: $target', () {
      expect(isSupportedStorageUri(Uri.parse(target)), false);
      expect(local.allowedTarget(Uri.parse(target)), false);
    });
  }
}
