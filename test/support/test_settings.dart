import 'package:qubo_camera_ai/models/dashboard_models.dart';

/// Synthetic identifiers used only by deterministic API and widget tests.
ConnectionSettings testSettings() => ConnectionSettings()
  ..proxy = 'https://project.supabase.co/functions/v1/qubo-proxy'
  ..unit = '11111111-1111-4111-8111-111111111111'
  ..devices = const [
    Device(
      id: '22222222-2222-4222-8222-222222222222',
      name: 'Front door',
      productType: 'videoDoorbellPro',
      entity: '33333333-3333-4333-8333-333333333333',
      model: 'HCD04A',
      mac: '02:00:00:00:00:01',
    ),
    Device(
      id: '44444444-4444-4444-8444-444444444444',
      name: 'Air purifier',
      productType: 'smartAirPurifierX4',
      entity: '55555555-5555-4555-8555-555555555555',
      handle: '66666666-6666-4666-8666-666666666666',
    ),
    Device(
      id: '77777777-7777-4777-8777-777777777777',
      name: 'Switch',
      productType: '',
      entity: '88888888-8888-4888-8888-888888888888',
    ),
    Device(
      id: '99999999-9999-4999-8999-999999999999',
      name: 'Display',
      productType: 'displayTablet',
    ),
    Device(
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      name: 'Smart plug',
      productType: 'smartPlugWifi16A',
    ),
  ];
