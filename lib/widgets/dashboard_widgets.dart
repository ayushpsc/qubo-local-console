import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../models/dashboard_models.dart';
import '../models/storage_location.dart';
import '../services/dashboard_api.dart';
import '../services/snapshot_cache.dart';

const ink = Color(0xFF182C32);
const muted = Color(0xFF64777C);
const green = Color(0xFF087F68);
const line = Color(0xFFE0E7E3);
final dateTimeFormat = DateFormat('dd MMM yyyy · HH:mm');
String stamp(int ms) =>
    dateTimeFormat.format(DateTime.fromMillisecondsSinceEpoch(ms));

class Surface extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: line),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: padding,
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

class Notice extends StatelessWidget {
  final String text;
  final bool error;
  final Widget? action;
  const Notice(this.text, {super.key, this.error = false, this.action});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFFF0ED) : const Color(0xFFEAF4EF),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? Icons.error_outline : Icons.info_outline,
          size: 20,
          color: error ? Colors.deepOrange : green,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: error ? const Color(0xFF9D3425) : ink,
              height: 1.5,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class PageTitle extends StatelessWidget {
  final String eyebrow, title, subtitle;
  final Widget? trailing;
  const PageTitle({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 24,
      runSpacing: 16,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                color: green,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: MediaQuery.sizeOf(context).width < 700 ? 280 : 560,
              child: Text(
                subtitle,
                style: const TextStyle(color: muted, height: 1.5),
              ),
            ),
          ],
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final String title, description;
  final IconData icon;
  const EmptyState({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.inbox_outlined,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
    child: Center(
      child: Column(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xFFEEF4F0),
            child: Icon(icon, size: 28, color: green),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, height: 1.6),
            ),
          ),
        ],
      ),
    ),
  );
}

class JsonDetails extends StatelessWidget {
  final dynamic value;
  const JsonDetails(this.value, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF3F6F3),
      borderRadius: BorderRadius.circular(12),
    ),
    child: SelectableText(
      const JsonEncoder.withIndent('  ').convert(redact(value)),
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.6,
      ),
    ),
  );
}

class Snapshot extends StatelessWidget {
  final DashboardApi api;
  final String? url;
  final double height;
  final bool fullResolution;
  final String emptyMessage;
  final Uint8List? bytes;
  final DetectionBox? detection;
  const Snapshot({
    super.key,
    required this.api,
    required this.url,
    this.height = 160,
    this.fullResolution = false,
    this.emptyMessage = 'Snapshot not provided',
    this.bytes,
    this.detection,
  });
  @override
  Widget build(BuildContext context) {
    Widget placeholder(String title) => Container(
      height: height,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF193E40), Color(0xFF2C5652)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.camera_outdoor_outlined,
              color: Color(0xFF9FC8B6),
              size: 32,
            ),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFCCE0D4), fontSize: 12),
            ),
          ],
        ),
      ),
    );
    if ((url == null || url!.isEmpty) && bytes == null) {
      return placeholder(emptyMessage);
    }
    final signed = SignedUrlInfo.parse(url);
    if (bytes == null && signed?.expired() == true) {
      return placeholder('Signed snapshot link expired · request a fresh link');
    }
    String source;
    try {
      source = bytes == null ? api.imageSource(url!) : '';
    } catch (_) {
      return placeholder('Unsupported snapshot URL');
    }
    final image = bytes != null
        ? Image.memory(
            bytes!,
            height: height,
            width: double.infinity,
            fit: BoxFit.contain,
          )
        : Image.network(
            source,
            height: height,
            width: double.infinity,
            fit: BoxFit.contain,
            cacheWidth: fullResolution
                ? null
                : height > 200
                ? 1200
                : 600,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
            errorBuilder: (_, _, _) =>
                placeholder('Image unavailable · URL may have expired'),
          );
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ColoredBox(
        color: const Color(0xFF193E40),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (detection != null)
              IgnorePointer(
                child: CustomPaint(painter: _DetectionPainter(detection!)),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  final DetectionBox box;
  const _DetectionPainter(this.box);
  @override
  void paint(Canvas canvas, Size size) {
    // Every captured AI snapshot is 480×640. Coordinates in the API match this
    // source frame and must be transformed into the BoxFit.contain rectangle.
    const source = Size(480, 640);
    final fitted = applyBoxFit(BoxFit.contain, source, size).destination;
    final origin = Offset(
      (size.width - fitted.width) / 2,
      (size.height - fitted.height) / 2,
    );
    final sx = fitted.width / source.width;
    final sy = fitted.height / source.height;
    final rect = Rect.fromLTWH(
      origin.dx + box.x * sx,
      origin.dy + box.y * sy,
      box.width * sx,
      box.height * sy,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0xFFFFC44D),
    );
    final tag = Rect.fromLTWH(
      rect.left,
      (rect.top - 22).clamp(0, size.height),
      72,
      22,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(tag, const Radius.circular(4)),
      Paint()..color = const Color(0xE6FFC44D),
    );
    final text = TextPainter(
      text: const TextSpan(
        text: 'PERSON',
        style: TextStyle(
          color: Color(0xFF182C32),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    text.paint(canvas, tag.topLeft + const Offset(8, 5));
  }

  @override
  bool shouldRepaint(covariant _DetectionPainter oldDelegate) =>
      oldDelegate.box != box;
}

class FullSnapshot extends StatelessWidget {
  final DashboardApi api;
  final String? url;
  final Uint8List? bytes;
  final DetectionBox? detection;
  const FullSnapshot({
    super.key,
    required this.api,
    this.url,
    this.bytes,
    this.detection,
  });
  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      backgroundColor: const Color(0xFF193E40),
      appBar: AppBar(
        title: const Text('Full snapshot'),
        actions: [
          IconButton(
            tooltip: 'Close full snapshot',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => InteractiveViewer(
          minScale: 1,
          maxScale: 8,
          child: Snapshot(
            api: api,
            url: url,
            bytes: bytes,
            detection: detection,
            height: box.maxHeight,
            fullResolution: true,
          ),
        ),
      ),
    ),
  );
}

class EventDetails extends StatefulWidget {
  final EventItem event;
  final Device device;
  final DashboardApi api;
  final EventItem? matchingRecording;
  const EventDetails({
    super.key,
    required this.event,
    required this.device,
    required this.api,
    this.matchingRecording,
  });
  @override
  State<EventDetails> createState() => _EventDetailsState();
}

class _EventDetailsState extends State<EventDetails> {
  late String? url = widget.event.imageUrl;
  final _url = TextEditingController();
  final _content = TextEditingController();
  String? error;
  bool busy = false, cacheBusy = false;
  Uint8List? cachedBytes;
  SnapshotCache? cache;
  @override
  void initState() {
    super.initState();
    try {
      cache = SnapshotCache();
    } catch (_) {
      cache = null;
    }
    _loadCache();
  }

  Future<void> _loadCache() async {
    final storage = cache;
    if (storage == null) return;
    try {
      final bytes = await storage.read(widget.event.cacheKey);
      if (mounted) setState(() => cachedBytes = bytes);
    } catch (_) {
      // Offline caching is optional; event details must remain usable when a
      // platform does not provide persistent preferences.
    }
  }

  Future<void> cacheSnapshot() async {
    if (url == null) return;
    setState(() {
      cacheBusy = true;
      error = null;
    });
    try {
      final storage = cache;
      if (storage == null) {
        throw const ApiException(
          'Offline snapshot storage is not available on this platform.',
        );
      }
      final bytes = await widget.api.snapshotBytes(url!);
      await storage.write(widget.event.cacheKey, bytes);
      if (mounted) setState(() => cachedBytes = bytes);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => cacheBusy = false);
    }
  }

  Future<void> removeCachedSnapshot() async {
    setState(() => cacheBusy = true);
    await cache?.remove(widget.event.cacheKey);
    if (mounted) {
      setState(() {
        cachedBytes = null;
        cacheBusy = false;
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> resolve() async {
    final id = _content.text.trim().isNotEmpty
        ? _content.text.trim()
        : object(widget.event.raw['snapshot'])['contentUUID']?.toString() ?? '';
    if (id.isEmpty) {
      setState(() => error = 'Enter a content UUID from the transaction.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.api.contentUrl(
        widget.device,
        widget.event.id,
        id,
      );
      if (mounted) setState(() => url = value);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      e.title,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close details',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                '${widget.device.name} · ${stamp(e.timestamp)}',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 22),
              if (e.kind != 'recording')
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Snapshot(
                    api: widget.api,
                    url: url,
                    bytes: cachedBytes,
                    detection: e.detection,
                    height: 300,
                    emptyMessage: e.kind == 'ai'
                        ? 'AI snapshot URL was not returned by the event API'
                        : 'Snapshot not provided',
                  ),
                ),
              if (e.kind != 'recording' && (url != null || cachedBytes != null))
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => FullSnapshot(
                          api: widget.api,
                          url: url,
                          bytes: cachedBytes,
                          detection: e.detection,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_full, size: 18),
                      label: const Text('View full image'),
                    ),
                    TextButton.icon(
                      onPressed: cacheBusy
                          ? null
                          : cachedBytes == null
                          ? cacheSnapshot
                          : removeCachedSnapshot,
                      icon: Icon(
                        cachedBytes == null
                            ? Icons.download_for_offline_outlined
                            : Icons.delete_outline,
                        size: 18,
                      ),
                      label: Text(
                        cacheBusy
                            ? 'Saving…'
                            : cachedBytes == null
                            ? 'Save offline'
                            : 'Remove saved copy',
                      ),
                    ),
                  ],
                ),
              if (cachedBytes != null)
                const Notice(
                  'This snapshot is saved on this device. Signed URLs are not stored.',
                ),
              const SizedBox(height: 12),
              _EventFacts(
                event: e,
                recording: widget.matchingRecording,
                imageUrl: url,
              ),
              if (e.kind == 'ai' && e.imageFile != null) ...[
                const SizedBox(height: 16),
                const Notice(
                  'This event API supplies an image filename. Paste its signed image URL or the full image capture text to load the matching snapshot.',
                ),
                TextField(
                  controller: _url,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Signed AI snapshot URL or capture text',
                    hintText: 'Signed north or south Airtel image URL',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    try {
                      final value = findAiSnapshotUrlInText(
                        _url.text,
                        filename: e.imageFile,
                      );
                      if (value == null) {
                        throw const ApiException(
                          'No supported AI image URL matching this event was found in the pasted text.',
                        );
                      }
                      widget.api.imageSource(value);
                      final uri = Uri.parse(value);
                      final file = e.imageFile!.split('/').last;
                      if (uri.pathSegments.last != file ||
                          !isSupportedStorageUri(uri, aiOnly: true)) {
                        throw const ApiException(
                          'Use the signed URL for this event’s image filename.',
                        );
                      }
                      if (!uri.queryParameters.containsKey('X-Amz-Signature')) {
                        throw const ApiException(
                          'The image needs a signed URL with X-Amz-Signature.',
                        );
                      }
                      setState(() {
                        url = value;
                        error = null;
                      });
                    } catch (err) {
                      setState(() => error = '$err');
                    }
                  },
                  child: const Text('Load snapshot'),
                ),
              ],
              if (e.kind == 'vms') ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _content,
                  decoration: const InputDecoration(
                    labelText: 'Content UUID (optional)',
                    helperText: 'Leave blank to use the snapshot content UUID.',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: busy ? null : resolve,
                  icon: const Icon(Icons.refresh),
                  label: Text(busy ? 'Resolving…' : 'Get a fresh content URL'),
                ),
              ],
              if (e.kind == 'recording')
                RecordingPlayback(
                  api: widget.api,
                  device: widget.device,
                  recording: e,
                ),
              if (e.kind != 'recording' &&
                  widget.matchingRecording != null) ...[
                const SizedBox(height: 14),
                RecordingPlayback(
                  api: widget.api,
                  device: widget.device,
                  recording: widget.matchingRecording!,
                  compact: true,
                ),
              ],
              if (error != null) Notice(error!, error: true),
              const SizedBox(height: 16),
              Text(
                'Event details',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              JsonDetails(e.raw),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventFacts extends StatelessWidget {
  final EventItem event;
  final EventItem? recording;
  final String? imageUrl;
  const _EventFacts({
    required this.event,
    required this.recording,
    required this.imageUrl,
  });

  String _duration(Duration duration) {
    if (duration.isNegative || duration.inSeconds <= 0) return 'expired';
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m remaining';
    }
    return '${duration.inMinutes}m remaining';
  }

  @override
  Widget build(BuildContext context) {
    final signed = SignedUrlInfo.parse(imageUrl);
    final capture = event.captureTimestamp;
    final rows = <(String, String)>[
      ('Source', event.sourceLabel),
      ('Event time', stamp(event.timestamp)),
      if (capture != null) ('Frame capture', stamp(capture)),
      if (capture != null)
        (
          'Processing delay',
          '${((event.timestamp - capture) / 1000).toStringAsFixed(2)} seconds',
        ),
      if (event.detection != null) ('Detection box', event.detection!.label),
      if (signed != null)
        (
          'Signed link',
          signed.expired()
              ? 'Expired ${dateTimeFormat.format(signed.expiresAt.toLocal())}'
              : '${_duration(signed.remaining())} · expires ${DateFormat.Hm().format(signed.expiresAt.toLocal())}',
        ),
      if (event.kind == 'ai' && capture != null)
        (
          'Expected retention',
          'Approximately until ${dateTimeFormat.format(DateTime.fromMillisecondsSinceEpoch(capture).add(const Duration(days: 10)))}',
        ),
      if (recording != null)
        (
          'Matching recording',
          '${stamp(recording!.timestamp)} · alert ${(event.mediaTimestamp - recording!.timestamp) / 1000}s after start',
        ),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 28,
        runSpacing: 14,
        children: rows
            .map(
              (row) => SizedBox(
                width: 205,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.$1.toUpperCase(),
                      style: const TextStyle(
                        color: muted,
                        fontSize: 9,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(row.$2, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class RecordingPlayback extends StatefulWidget {
  final DashboardApi api;
  final Device device;
  final EventItem recording;
  final bool compact;
  const RecordingPlayback({
    super.key,
    required this.api,
    required this.device,
    required this.recording,
    this.compact = false,
  });

  @override
  State<RecordingPlayback> createState() => _RecordingPlaybackState();
}

class _RecordingPlaybackState extends State<RecordingPlayback> {
  final manualUrl = TextEditingController();
  VideoPlayerController? player;
  MediaDownload? media;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    manualUrl.dispose();
    final current = player;
    player = null;
    current?.removeListener(_refreshPlayer);
    current?.dispose();
    super.dispose();
  }

  void _refreshPlayer() {
    if (mounted) setState(() {});
  }

  Future<void> _open(String url) async {
    final source = widget.api.mediaSource(url);
    final next = VideoPlayerController.networkUrl(Uri.parse(source));
    try {
      await next.initialize();
      await next.setVolume(1);
      if (!mounted) {
        await next.dispose();
        return;
      }
      final previous = player;
      previous?.removeListener(_refreshPlayer);
      player = next..addListener(_refreshPlayer);
      await previous?.dispose();
      setState(() {});
    } catch (_) {
      await next.dispose();
      rethrow;
    }
  }

  Future<void> prepare() async {
    final path = widget.recording.raw['localPath']?.toString() ?? '';
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.prepareRecording(widget.device, path);
      await _open(result.url);
      if (mounted) setState(() => media = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openManual() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = manualUrl.text.trim();
      if (value.isEmpty) {
        throw const ApiException('Paste a signed push-pull MP4 URL.');
      }
      await _open(value);
      if (mounted) {
        setState(
          () => media = MediaDownload(
            transactionId: 'manual',
            file: widget.recording.raw['localPath']?.toString() ?? '',
            url: value,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String duration(Duration value) =>
      '${value.inMinutes}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final initialized = player?.value.isInitialized == true;
    final expires = media?.signedUrl?.expiresAt.toLocal();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.compact ? 'Matching SD-card recording' : 'SD-card playback',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '${stamp(widget.recording.timestamp)} · ${widget.recording.endTime == null ? 'duration unavailable' : duration(Duration(milliseconds: widget.recording.endTime! - widget.recording.timestamp))}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (!initialized)
            FilledButton.icon(
              onPressed: busy ? null : prepare,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              label: Text(busy ? 'Preparing recording…' : 'Prepare & play'),
            ),
          if (initialized) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 520),
                    child: AspectRatio(
                      aspectRatio: player!.value.aspectRatio == 0
                          ? 3 / 4
                          : player!.value.aspectRatio,
                      child: VideoPlayer(player!),
                    ),
                  ),
                ),
              ),
            ),
            VideoProgressIndicator(
              player!,
              allowScrubbing: true,
              colors: const VideoProgressColors(playedColor: green),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: player!.value.isPlaying ? 'Pause' : 'Play',
                  onPressed: () => player!.value.isPlaying
                      ? player!.pause()
                      : player!.play(),
                  icon: Icon(
                    player!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                Text(
                  '${duration(player!.value.position)} / ${duration(player!.value.duration)}',
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : prepare,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('Fresh export'),
                ),
              ],
            ),
            if (expires != null)
              Text(
                'Temporary playback link expires ${dateTimeFormat.format(expires)}.',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
          ],
          if (error != null) ...[
            const SizedBox(height: 10),
            Notice(error!, error: true),
          ],
          const SizedBox(height: 8),
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text(
                'Advanced: signed video URL',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                TextField(
                  controller: manualUrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Push-pull download URL',
                    hintText: 'https://heroiot-prod-push-pull.s3…/…mp4?X-Amz-…',
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: busy ? null : openManual,
                    child: const Text('Load signed URL'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
