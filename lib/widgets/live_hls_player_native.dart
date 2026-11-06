import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'dashboard_widgets.dart';

class LiveHlsPlayer extends StatefulWidget {
  final String source;
  final String authorizationHeader;
  final VoidCallback? onSessionEnded;
  const LiveHlsPlayer({
    super.key,
    required this.source,
    this.authorizationHeader = '',
    this.onSessionEnded,
  });

  @override
  State<LiveHlsPlayer> createState() => _LiveHlsPlayerState();
}

class _LiveHlsPlayerState extends State<LiveHlsPlayer> {
  VideoPlayerController? controller;
  String? error;

  @override
  void initState() {
    super.initState();
    open();
  }

  @override
  void didUpdateWidget(covariant LiveHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.authorizationHeader != widget.authorizationHeader) {
      open();
    }
  }

  Future<void> open() async {
    final next = VideoPlayerController.networkUrl(
      Uri.parse(widget.source),
      httpHeaders: widget.authorizationHeader.isEmpty
          ? const {}
          : {'Authorization': widget.authorizationHeader},
    );
    try {
      await next.initialize();
      await next.play();
      if (!mounted) {
        await next.dispose();
        return;
      }
      final previous = controller;
      setState(() {
        controller = next;
        error = null;
      });
      await previous?.dispose();
    } catch (_) {
      await next.dispose();
      if (mounted) {
        setState(() => error = 'The device could not play this HLS stream.');
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    if (error != null) return Notice(error!, error: true);
    if (player == null || !player.value.isInitialized) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Color(0xFF101512),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: player.value.aspectRatio == 0
            ? 16 / 9
            : player.value.aspectRatio,
        child: VideoPlayer(player),
      ),
    );
  }
}
