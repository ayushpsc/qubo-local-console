import 'dart:convert';
import 'package:flutter/material.dart';
import '../controllers/dashboard_controller.dart';
import '../models/dashboard_models.dart';
import '../widgets/dashboard_widgets.dart';

class ConnectionScreen extends StatefulWidget {
  final DashboardController controller;
  final VoidCallback onSaved;
  const ConnectionScreen({
    super.key,
    required this.controller,
    required this.onSaved,
  });
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final form = GlobalKey<FormState>();
  late final fields = <String, TextEditingController>{
    'Tenant ID': TextEditingController(text: widget.controller.settings.tenant),
    'App ID': TextEditingController(text: widget.controller.settings.appId),
    'Installation ID': TextEditingController(
      text: widget.controller.settings.sourceDeviceId,
    ),
    'Unit UUID': TextEditingController(text: widget.controller.settings.unit),
    'Login device': TextEditingController(
      text: widget.controller.settings.deviceAttribute,
    ),
    'Hosted gateway URL': TextEditingController(
      text: widget.controller.settings.proxy,
    ),
  };
  late final devices = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(
      widget.controller.settings.devices.map((d) => d.toJson()).toList(),
    ),
  );
  String? error;
  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    devices.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    try {
      final values = objects(
        jsonDecode(devices.text),
      ).map(Device.fromJson).toList();
      if (values.isEmpty ||
          values.map((d) => d.id).toSet().length != values.length) {
        throw const FormatException(
          'Add at least one device and keep device UUIDs unique.',
        );
      }
      final proxy = fields['Hosted gateway URL']!.text.trim();
      if (proxy.isNotEmpty) {
        final uri = Uri.parse(proxy);
        if (uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            (uri.scheme != 'https' &&
                !(uri.scheme == 'http' &&
                    ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
          throw const FormatException(
            'Use an HTTPS gateway URL. HTTP is allowed only for localhost.',
          );
        }
      }
      final c = widget.controller;
      c.signOut();
      c.settings.tenant = fields['Tenant ID']!.text.trim();
      c.settings.appId = fields['App ID']!.text.trim();
      c.settings.sourceDeviceId = fields['Installation ID']!.text.trim();
      c.settings.unit = fields['Unit UUID']!.text.trim();
      c.settings.deviceAttribute = fields['Login device']!.text.trim();
      c.settings.proxy = proxy;
      c.settings.devices = values;
      c.changeDevice(
        values.where((d) => d.productType == 'videoDoorbellPro').firstOrNull ??
            values.first,
      );
      widget.onSaved();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connection updated. Sign in with the new settings.'),
        ),
      );
    } catch (e) {
      setState(
        () => error = e is FormatException
            ? e.message
            : 'Check the device JSON and connection values.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const PageTitle(
        eyebrow: 'Home / Setup',
        title: 'Make yourself at home.',
        subtitle:
            'Connect your Qubo account and the devices you want to manage.',
      ),
      const Notice(
        'Production starts with no unit or device identifiers. Qubo email sign-in must discover the current account’s units and devices before any event request is made. This editor is an advanced fallback for metadata omitted by discovery. Settings and tokens stay in memory and reset on reload.',
      ),
      if (widget.controller.session case final session?)
        Notice(
          'Active Qubo profile: ${session.name} (${session.user}). Discovered unit: ${widget.controller.settings.unit}. Selected device: ${widget.controller.selected?.id ?? 'none'}.',
        ),
      if (error != null) Notice(error!, error: true),
      Form(
        key: form,
        child: Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Account connection',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, box) => Wrap(
                  spacing: 18,
                  runSpacing: 20,
                  children: fields.entries
                      .map(
                        (entry) => SizedBox(
                          width: box.maxWidth > 700
                              ? (box.maxWidth - 18) / 2
                              : box.maxWidth,
                          child: TextFormField(
                            controller: entry.value,
                            decoration: InputDecoration(
                              labelText: entry.key,
                              helperText: entry.key == 'Hosted gateway URL'
                                  ? 'Supabase function URL; prefilled by QUBO_PROXY_URL at build time.'
                                  : entry.key == 'Installation ID'
                                  ? 'Keep the same ID across email login, token refresh and API calls.'
                                  : null,
                            ),
                            validator: (v) =>
                                entry.key != 'Hosted gateway URL' &&
                                    (v == null || v.trim().isEmpty)
                                ? 'Required'
                                : null,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 22),
              const Text(
                'Device registry',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                'name and deviceUUID identify each device. productType is needed for latest events. Controls also need entityUUID; fan commands need handleName. RTSP support lookup uses deviceAModelNo and macAddress.',
                style: TextStyle(color: muted, height: 1.6),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: devices,
                maxLines: 16,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Devices (JSON array)',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save & go to sign-in'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Saving connection settings signs out the current session.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
