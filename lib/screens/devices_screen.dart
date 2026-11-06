import 'dart:convert';
import 'package:flutter/material.dart';
import '../controllers/dashboard_controller.dart';
import '../models/dashboard_models.dart';
import '../widgets/dashboard_widgets.dart';

class DevicesScreen extends StatefulWidget {
  final DashboardController controller;
  const DevicesScreen({super.key, required this.controller});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String? active;
  String mode = 'qsense', route = 'shadow';
  final editor = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert({
      'serviceName': 'lcSwitchControl',
      'attributeName': 'power',
      'attributeValue': 'on',
      'instanceId': 0,
    }),
  );
  late String customDevice = widget.controller.settings.devices.first.id;
  String? error, message;
  dynamic result;
  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> send(
    Device d,
    String kind,
    Map<String, dynamic> body, {
    bool observed = true,
  }) async {
    if (d.entity.isEmpty) {
      setState(
        () => error =
            'Add this device’s entity UUID in Connection before sending controls.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send command to ${d.name}?'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Notice(
                  observed
                      ? 'This payload shape was observed in the captures. An acknowledgement will not confirm the physical device state.'
                      : 'This command or value was not observed in the captures. The device may reject it. Check the service and attributes before sending.',
                ),
                Text(
                  'PUT · ${kind == 'shadow' ? 'shadow/attribute' : 'command'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                JsonDetails(body),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send command'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      active = d.id;
      error = null;
      message = null;
      result = null;
    });
    try {
      final res = kind == 'shadow'
          ? await widget.controller.api.shadow(d, body)
          : await widget.controller.api.command(d, body);
      if (mounted) {
        setState(() {
          result = res;
          message =
              '${d.name}: request acknowledged. Physical device state has not been read back.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => active = null);
    }
  }

  Map<String, dynamic> power(String value) => {
    'attributeName': 'power',
    'attributeValue': value,
    'instanceId': 0,
    'serviceName': 'lcSwitchControl',
  };
  Map<String, dynamic> fan(Device d) => {
    'topic':
        '/control/${d.unit.isNotEmpty ? d.unit : widget.controller.settings.unit}/${d.id}/fanControlMode',
    'payload': {
      'devices': {
        'deviceUUID': d.id,
        'handleName': d.handle,
        'services': {
          'fanControlMode': {
            'instanceId': 0,
            'attributes': {'state': mode},
          },
        },
      },
    },
  };
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageTitle(
          eyebrow: 'Home / Devices',
          title: 'Your home, at your fingertips.',
          subtitle:
              'Send device controls with a clear preview of every command.',
        ),
        const Notice(
          'Controls show request acknowledgements, not live device state. Units and devices are discovered from the signed-in Qubo account; advanced entity or handle metadata can be adjusted in Connection if the discovery response omits it.',
        ),
        if (error != null) Notice(error!, error: true),
        if (message != null) Notice(message!),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: JsonDetails(result),
          ),
        LayoutBuilder(
          builder: (context, box) {
            final count = box.maxWidth >= 1000
                ? 3
                : box.maxWidth > 620
                ? 2
                : 1;
            return Wrap(
              spacing: 18,
              runSpacing: 18,
              children: c.settings.devices.map((d) {
                final purifier = d.productType == 'smartAirPurifierX4';
                final switchable =
                    d.entity.isNotEmpty &&
                    (purifier ||
                        d.productType.isEmpty ||
                        d.productType.startsWith('smartPlug'));
                return SizedBox(
                  width: (box.maxWidth - 18 * (count - 1)) / count,
                  child: Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 25,
                              backgroundColor: const Color(0xFFEAF3EC),
                              child: Icon(
                                purifier
                                    ? Icons.air
                                    : d.productType == 'videoDoorbellPro'
                                    ? Icons.doorbell_outlined
                                    : Icons.power_outlined,
                                color: green,
                              ),
                            ),
                            const Spacer(),
                            const Chip(
                              label: Text(
                                'State unknown',
                                style: TextStyle(fontSize: 10),
                              ),
                              side: BorderSide.none,
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        Text(
                          d.name,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          d.productType.isEmpty
                              ? 'Product type not established'
                              : d.productType,
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                        const SizedBox(height: 22),
                        if (switchable)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: active != null
                                    ? null
                                    : () => send(d, 'shadow', power('on')),
                                icon: const Icon(
                                  Icons.power_settings_new,
                                  size: 18,
                                ),
                                label: const Text('Power on'),
                              ),
                              OutlinedButton(
                                onPressed: active != null
                                    ? null
                                    : () => send(
                                        d,
                                        'shadow',
                                        power('off'),
                                        observed: false,
                                      ),
                                child: const Text('Off · unverified'),
                              ),
                            ],
                          )
                        else
                          const Text(
                            'Configure an entity UUID and a supported service to send custom controls.',
                            style: TextStyle(
                              color: muted,
                              height: 1.5,
                              fontSize: 12,
                            ),
                          ),
                        if (purifier) ...[
                          const SizedBox(height: 18),
                          DropdownButtonFormField<String>(
                            initialValue: mode,
                            decoration: const InputDecoration(
                              labelText: 'Fan mode',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'qsense',
                                child: Text('QSense'),
                              ),
                              DropdownMenuItem(
                                value: 'sleep',
                                child: Text('Sleep'),
                              ),
                            ],
                            onChanged: active != null
                                ? null
                                : (v) => setState(() => mode = v!),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: active != null || d.handle.isEmpty
                                ? null
                                : () => send(d, 'command', fan(d)),
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('Apply mode'),
                          ),
                        ],
                        if (active == d.id)
                          const Padding(
                            padding: EdgeInsets.only(top: 14),
                            child: LinearProgressIndicator(),
                          ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 24),
        Surface(
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Advanced device commands',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Custom attributes, speed and modes · unverified values',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            children: [
              const SizedBox(height: 16),
              const Notice(
                'No fan speed payload was captured. Enter a service command or shadow attribute only when you know its schema. Custom values are sent as entered.',
              ),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      initialValue: customDevice,
                      decoration: const InputDecoration(labelText: 'Device'),
                      items: c.settings.devices
                          .map(
                            (d) => DropdownMenuItem(
                              value: d.id,
                              child: Text(d.name),
                            ),
                          )
                          .toList(),
                      onChanged: active != null
                          ? null
                          : (v) => setState(() => customDevice = v!),
                    ),
                  ),
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      initialValue: route,
                      decoration: const InputDecoration(labelText: 'Endpoint'),
                      items: const [
                        DropdownMenuItem(
                          value: 'shadow',
                          child: Text('Shadow attribute'),
                        ),
                        DropdownMenuItem(
                          value: 'command',
                          child: Text('Service command'),
                        ),
                      ],
                      onChanged: active != null
                          ? null
                          : (v) => setState(() => route = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: editor,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'JSON request body',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: active != null
                    ? null
                    : () {
                        try {
                          final value = jsonDecode(editor.text);
                          if (value is! Map<String, dynamic>) {
                            throw const FormatException();
                          }
                          send(
                            c.settings.devices.firstWhere(
                              (d) => d.id == customDevice,
                            ),
                            route,
                            value,
                            observed: false,
                          );
                        } catch (_) {
                          setState(
                            () => error =
                                'The custom request body must be a valid JSON object.',
                          );
                        }
                      },
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Preview custom command'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
