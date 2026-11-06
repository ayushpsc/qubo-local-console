import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../controllers/dashboard_controller.dart';
import '../models/dashboard_models.dart';
import '../models/local_stream_models.dart';
import '../models/live_stream_models.dart';
import '../models/storage_location.dart';
import '../services/dashboard_api.dart';
import '../services/external_link.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/live_hls_player.dart';

class StreamSetupScreen extends StatefulWidget {
  final DashboardController controller;
  const StreamSetupScreen({super.key, required this.controller});
  @override
  State<StreamSetupScreen> createState() => _StreamSetupScreenState();
}

class _StreamSetupScreenState extends State<StreamSetupScreen> {
  static const _localRelayKey = 'go2rtc_base_url';
  static const _localStreamKey = 'go2rtc_stream_name';

  bool busy = false;
  String? error, operation;
  dynamic result;
  final manualLiveUrl = TextEditingController();
  Uint8List? homeCapture;
  String? homeCaptureName, liveError;
  LiveStreamSession? live;
  String? liveAuthorization;
  bool liveBusy = false;
  bool configuredLive = false;
  int automaticRenewals = 0;
  int liveGeneration = 0;
  String? liveStatus;
  final localRelay = TextEditingController();
  final localStream = TextEditingController(text: 'qubo_doorbell');
  final localUsername = TextEditingController();
  final localPassword = TextEditingController();
  SharedPreferencesAsync? localPreferences;
  String? localSource, localAuthorizationHeader, localError;
  bool hideLocalPassword = true;

  @override
  void initState() {
    super.initState();
    try {
      localPreferences = SharedPreferencesAsync();
      unawaited(_restoreLocalSettings());
    } on StateError {
      // Widget tests and unsupported embedders may not register a preferences
      // implementation. Local relay settings remain session-only there.
    }
  }

  Future<void> _restoreLocalSettings() async {
    final preferences = localPreferences;
    if (preferences == null) return;
    try {
      final relay = await preferences.getString(_localRelayKey);
      final stream = await preferences.getString(_localStreamKey);
      if (!mounted) return;
      if (relay?.isNotEmpty ?? false) localRelay.text = relay!;
      if (stream?.isNotEmpty ?? false) localStream.text = stream!;
    } on StateError {
      // Optional persistence must never prevent the player from rendering.
    }
  }

  Future<void> _saveLocalSettings(Go2RtcEndpoint endpoint) async {
    final preferences = localPreferences;
    if (preferences == null) return;
    try {
      await Future.wait([
        preferences.setString(_localRelayKey, endpoint.base.toString()),
        preferences.setString(_localStreamKey, endpoint.stream),
      ]);
    } on StateError {
      // Keep the local player usable when persistence is unavailable.
    }
  }

  Go2RtcEndpoint _localEndpoint() =>
      Go2RtcEndpoint.parse(localRelay.text, localStream.text);

  String _localAuthorization() {
    final username = localUsername.text.trim();
    final password = localPassword.text;
    if (username.isEmpty && password.isEmpty) return '';
    if (username.isEmpty || password.isEmpty) {
      throw const FormatException(
        'Enter both the go2rtc username and password, or leave both empty.',
      );
    }
    return 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  }

  void startLocalStream() {
    try {
      final endpoint = _localEndpoint();
      if (!canEmbedLocalStream(endpoint.hlsUrl)) {
        throw const FormatException(
          'This hosted HTTPS app cannot embed an HTTP LAN stream. Open the go2rtc player in a new tab, or expose go2rtc through a trusted HTTPS reverse proxy.',
        );
      }
      final authorization = _localAuthorization();
      liveGeneration++;
      setState(() {
        live = null;
        liveAuthorization = null;
        configuredLive = false;
        liveBusy = false;
        liveStatus = null;
        localSource = endpoint.hlsUrl.toString();
        localAuthorizationHeader = authorization;
        localError = null;
      });
      unawaited(_saveLocalSettings(endpoint));
    } on FormatException catch (error) {
      setState(() => localError = error.message);
    }
  }

  void openLocalPlayer() {
    try {
      final endpoint = _localEndpoint();
      if (!openExternalLink(endpoint.playerUrl)) {
        throw const FormatException(
          'Opening the go2rtc browser player is supported in the web app.',
        );
      }
      setState(() => localError = null);
      unawaited(_saveLocalSettings(endpoint));
    } on FormatException catch (error) {
      setState(() => localError = error.message);
    }
  }

  void openTalkPlayer() {
    try {
      final endpoint = _localEndpoint();
      if (endpoint.base.scheme != 'https') {
        throw const FormatException(
          'Two-way talk requires an HTTPS go2rtc URL because browsers allow microphone access only from a secure page.',
        );
      }
      if (!openExternalLink(endpoint.talkPlayerUrl)) {
        throw const FormatException(
          'Opening the go2rtc talk player is supported in the web app.',
        );
      }
      setState(() => localError = null);
      unawaited(_saveLocalSettings(endpoint));
    } on FormatException catch (error) {
      setState(() => localError = error.message);
    }
  }

  void stopLocalStream() {
    setState(() {
      localSource = null;
      localAuthorizationHeader = null;
      localError = null;
    });
  }

  @override
  void dispose() {
    manualLiveUrl.dispose();
    localRelay.dispose();
    localStream.dispose();
    localUsername.dispose();
    localPassword.dispose();
    super.dispose();
  }

  Future<void> chooseHomeCapture() async {
    try {
      final file = await openFile();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      GoogleHomeCapture.parse(bytes);
      if (!mounted) return;
      setState(() {
        homeCapture = bytes;
        homeCaptureName = file.name;
        liveError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          liveError = e is FormatException
              ? e.message
              : 'Could not read this Home capture.';
        });
      }
    }
  }

  Future<void> startLive(
    Future<LiveStreamSession> Function() action, {
    bool renewable = false,
  }) async {
    if (liveBusy) return;
    final generation = ++liveGeneration;
    setState(() {
      liveBusy = true;
      liveError = null;
      liveStatus = null;
      configuredLive = renewable;
      automaticRenewals = 0;
      localSource = null;
      localAuthorizationHeader = null;
      localError = null;
    });
    try {
      final session = await action();
      final authorization = await widget.controller.api.firebaseLiveToken();
      if (mounted && generation == liveGeneration) {
        setState(() {
          live = session;
          liveAuthorization = authorization;
        });
      }
    } catch (e) {
      if (mounted && generation == liveGeneration) {
        setState(() => liveError = '$e');
      }
    } finally {
      if (mounted && generation == liveGeneration) {
        setState(() => liveBusy = false);
      }
    }
  }

  Future<void> startCapturedLive() async {
    final capture = homeCapture;
    if (capture == null) return;
    await startLive(() => widget.controller.api.openGoogleHomeLive(capture));
  }

  void stopLive() {
    liveGeneration++;
    setState(() {
      live = null;
      liveAuthorization = null;
      liveBusy = false;
      liveStatus = null;
      configuredLive = false;
      automaticRenewals = 0;
    });
  }

  Future<void> renewConfiguredLive() async {
    final previous = live;
    if (!configuredLive || previous == null || liveBusy) return;
    final sessionAge = DateTime.now().difference(previous.createdAt);
    // A session that played for a useful interval is not a failed reconnect.
    // Some observed Wowza sessions stop publishing after roughly 20 seconds.
    if (sessionAge >= const Duration(seconds: 12)) {
      automaticRenewals = 0;
    }
    if (automaticRenewals >= 3) {
      liveGeneration++;
      setState(() {
        live = null;
        liveAuthorization = null;
        configuredLive = false;
        liveStatus = null;
        liveError =
            'Three new live sessions failed within 12 seconds. Start live view again after a short wait.';
      });
      return;
    }
    final attempt = ++automaticRenewals;
    final generation = liveGeneration;
    setState(() {
      liveBusy = true;
      liveStatus = 'Live session ended · reconnecting ($attempt/3)…';
      liveError = null;
    });
    try {
      await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
      if (!mounted || generation != liveGeneration || live != previous) return;
      final session = await widget.controller.api
          .openConfiguredGoogleHomeLive();
      final authorization = await widget.controller.api.firebaseLiveToken();
      if (!mounted || generation != liveGeneration || live != previous) return;
      setState(() {
        live = session;
        liveAuthorization = authorization;
        liveStatus = null;
      });
    } catch (e) {
      if (mounted && generation == liveGeneration) {
        setState(() {
          live = null;
          liveAuthorization = null;
          configuredLive = false;
          liveStatus = null;
          liveError = 'Automatic live reconnection failed. $e';
        });
      }
    } finally {
      if (mounted && generation == liveGeneration) {
        setState(() => liveBusy = false);
      }
    }
  }

  Future<void> openManualLive() async {
    try {
      final value = manualLiveUrl.text.trim();
      final uri = Uri.tryParse(value);
      if (uri == null || !isSupportedLiveUri(uri, masterOnly: true)) {
        throw const ApiException(
          'Paste the complete HLS playlist URL returned by Google Home.',
        );
      }
      widget.controller.api.liveSource(value);
      final authorization = await widget.controller.api.firebaseLiveToken();
      liveGeneration++;
      setState(() {
        live = LiveStreamSession(masterUrl: value, createdAt: DateTime.now());
        liveAuthorization = authorization;
        liveError = null;
        liveStatus = null;
        configuredLive = false;
        automaticRenewals = 0;
        localSource = null;
        localAuthorizationHeader = null;
        localError = null;
      });
    } catch (e) {
      setState(() => liveError = '$e');
    }
  }

  Future<void> run(
    String title,
    Future<dynamic> Function(Device d) action,
  ) async {
    final d = widget.controller.selected;
    if (d == null) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
      operation = title;
    });
    try {
      final value = await action(d);
      if (mounted) setState(() => result = value);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageTitle(
          eyebrow: 'Home / Camera',
          title: 'Live camera & connection tools',
          subtitle:
              'Watch the LAN go2rtc relay, start a Google Home session, or inspect camera connectivity.',
        ),
        const Notice(
          'Local view keeps media on your LAN after a short Qubo cloud handshake. It requires the companion go2rtc and P2P client on the same network as the doorbell. Google Home view remains available as a cloud fallback.',
        ),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF3EC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.lan_outlined, color: green),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Local doorbell stream',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Doorbell → encrypted UDP on your LAN → go2rtc → this player',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (localSource != null)
                    IconButton(
                      tooltip: 'Stop local view',
                      onPressed: stopLocalStream,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              if (localSource case final source?) ...[
                LiveHlsPlayer(
                  source: source,
                  authorizationHeader: localAuthorizationHeader ?? '',
                ),
                const SizedBox(height: 12),
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(Icons.circle, color: green, size: 10),
                      label: Text('LAN relay'),
                    ),
                    Chip(label: Text('H.264 + AAC · HLS')),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: openLocalPlayer,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open low-latency player'),
                    ),
                    FilledButton.icon(
                      onPressed: openTalkPlayer,
                      icon: const Icon(Icons.mic_outlined),
                      label: const Text('Open two-way talk'),
                    ),
                  ],
                ),
              ] else ...[
                LayoutBuilder(
                  builder: (context, box) {
                    final fieldWidth = box.maxWidth >= 760
                        ? (box.maxWidth - 18) / 2
                        : box.maxWidth;
                    return Wrap(
                      spacing: 18,
                      runSpacing: 14,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: TextField(
                            controller: localRelay,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'go2rtc base URL',
                              hintText: 'https://host.tailnet-name.ts.net:8443',
                            ),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: TextField(
                            controller: localStream,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Stream name',
                              hintText: 'qubo_doorbell',
                            ),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: TextField(
                            controller: localUsername,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'go2rtc username (optional)',
                            ),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: TextField(
                            controller: localPassword,
                            obscureText: hideLocalPassword,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: 'go2rtc password (optional)',
                              suffixIcon: IconButton(
                                tooltip: hideLocalPassword
                                    ? 'Show password'
                                    : 'Hide password',
                                onPressed: () => setState(
                                  () => hideLocalPassword = !hideLocalPassword,
                                ),
                                icon: Icon(
                                  hideLocalPassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: startLocalStream,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play locally'),
                    ),
                    OutlinedButton.icon(
                      onPressed: openLocalPlayer,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open low-latency player'),
                    ),
                    OutlinedButton.icon(
                      onPressed: openTalkPlayer,
                      icon: const Icon(Icons.mic_outlined),
                      label: const Text('Open two-way talk'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'The hosted app can embed only an HTTPS go2rtc endpoint. A normal HTTP LAN endpoint can still be opened in its own tab. Two-way talk requires HTTPS, QTALK=true on the relay, and microphone permission. Username and password stay in memory and are used only for embedded HLS requests.',
                  style: TextStyle(color: muted, height: 1.5, fontSize: 12),
                ),
              ],
              if (localError != null) ...[
                const SizedBox(height: 14),
                Notice(localError!, error: true),
              ],
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text(
                  'Companion setup values',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Use these with tools/go2rtc on the LAN host.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      'QDEVICE=${c.selected?.id ?? '<sign in to Qubo to discover>'}\n'
                      'QUNIT=${c.selected == null ? '<sign in to Qubo to discover>' : c.api.unitId(c.selected!)}\n'
                      'QMOB=<paired phone UUID>\n'
                      'QADVERT=<go2rtc host LAN IP>\n'
                      'QPORT=49700\nQQUALITY=high\nQDUR=86400',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'QMOB comes from the paired phone entry in Qubo Account → Logged In Devices (or the ha-qubo config entry). Do not use the generated login installation ID.',
                      style: TextStyle(color: muted, height: 1.5, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF3EC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.live_tv_outlined, color: green),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Google Home live view',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Fresh request → master.m3u8 → chunklist.m3u8 → .ts segments',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (live != null)
                    IconButton(
                      tooltip: 'Stop live view',
                      onPressed: stopLive,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              if (live != null && liveAuthorization != null) ...[
                LiveHlsPlayer(
                  source: widget.controller.api.liveSource(live!.masterUrl),
                  authorizationHeader: 'Bearer $liveAuthorization',
                  onSessionEnded: configuredLive ? renewConfiguredLive : null,
                ),
                if (liveStatus != null) ...[
                  const SizedBox(height: 12),
                  Notice(liveStatus!),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    const Chip(
                      avatar: Icon(Icons.circle, color: green, size: 10),
                      label: Text('Live'),
                    ),
                    Chip(label: Text('Origin ${live!.originLabel}')),
                    const Chip(label: Text('HLS · MPEG-TS')),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Playback starts muted because browsers block unprompted audio. Use the player control to unmute.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: liveBusy
                      ? null
                      : () => startLive(
                          widget.controller.api.openConfiguredGoogleHomeLive,
                          renewable: true,
                        ),
                  icon: liveBusy
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(
                    liveBusy ? 'Requesting live URL…' : 'Start live view',
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Uses the configured Home request. Nothing needs to be selected on this device.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 18),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text(
                    'Use a different Home request capture',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Temporary fallback when the configured request expires.',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                  children: [
                    LayoutBuilder(
                      builder: (context, box) => Wrap(
                        spacing: 14,
                        runSpacing: 14,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: liveBusy ? null : chooseHomeCapture,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text('Choose request capture'),
                          ),
                          if (homeCaptureName != null)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: box.maxWidth > 650
                                    ? box.maxWidth - 430
                                    : box.maxWidth,
                              ),
                              child: Text(
                                '$homeCaptureName · ready in memory',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: green,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: homeCapture == null || liveBusy
                                ? null
                                : startCapturedLive,
                            icon: const Icon(Icons.play_circle_outline),
                            label: const Text('Replay selected capture'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text(
                    'Already have a live HLS URL?',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Paste it without exposing the token on screen.',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                  children: [
                    TextField(
                      controller: manualLiveUrl,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'HLS master URL',
                        hintText: 'http://…/playlist.m3u8?wowzatoken=…',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => openManualLive(),
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Open live URL'),
                      ),
                    ),
                  ],
                ),
              ],
              if (liveError != null) ...[
                const SizedBox(height: 14),
                Notice(liveError!, error: true),
              ],
              const SizedBox(height: 12),
              const Text(
                'The configured Google request is short-lived. When Google rejects it, replace the hosted preset with a fresh UpdateTraits request; manual capture import remains available as a fallback.',
                style: TextStyle(color: muted, height: 1.5, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: c.selected?.id,
                decoration: const InputDecoration(labelText: 'Camera'),
                items: c.settings.devices
                    .map(
                      (d) => DropdownMenuItem(value: d.id, child: Text(d.name)),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (id) {
                        if (id != null) {
                          c.changeDevice(
                            c.settings.devices.firstWhere((d) => d.id == id),
                          );
                          setState(() {
                            result = null;
                            error = null;
                          });
                        }
                      },
              ),
              const SizedBox(height: 24),
              const Text(
                'Low-level diagnostics',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        busy ||
                            c.selected == null ||
                            c.selected!.mac.isEmpty ||
                            c.selected!.model.isEmpty
                        ? null
                        : () => run('RTSP support', c.api.rtspSupport),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Check RTSP support'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || c.selected == null
                        ? null
                        : () => run(
                            'Stream setup acknowledgement',
                            c.api.streamRequest,
                          ),
                    icon: const Icon(Icons.settings_input_antenna),
                    label: const Text('Request stream setup'),
                  ),
                  FilledButton.icon(
                    onPressed: busy || c.selected == null
                        ? null
                        : () =>
                              run('UDP session credentials', c.api.credentials),
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('Fetch session credentials'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'RTSP support needs a model and MAC address in Connection. A false rtspstart flag does not establish whether RTSP is unsupported or currently inactive.',
                style: TextStyle(color: muted, height: 1.5, fontSize: 12),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: LinearProgressIndicator(),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Notice(error!, error: true),
                ),
              if (result != null) ...[
                const SizedBox(height: 24),
                Text(
                  operation!,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                JsonDetails(result),
                const SizedBox(height: 10),
                const Text(
                  'Session keys and IVs are masked.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
