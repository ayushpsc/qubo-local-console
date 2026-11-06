import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'dashboard_widgets.dart';

@JS('startQuboHls')
external void _startQuboHls(
  web.HTMLVideoElement video,
  String source,
  String authorizationHeader,
);

@JS('stopQuboHls')
external void _stopQuboHls(web.HTMLVideoElement video);

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
  late final String viewType = 'qubo-live-${identityHashCode(this)}';
  late final web.HTMLVideoElement video;
  late final JSFunction errorListener;
  String? error;
  bool renewalReported = false;

  @override
  void initState() {
    super.initState();
    video = web.HTMLVideoElement()
      ..controls = true
      ..autoplay = true
      ..muted = true
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#101512'
      ..setAttribute('playsinline', '')
      ..setAttribute('aria-label', 'Live camera stream');
    errorListener = ((web.Event _) {
      if (!mounted) return;
      final shouldRenew =
          video.getAttribute('data-qubo-renew-session') == 'true';
      setState(() {
        error =
            video.getAttribute('data-qubo-error') ??
            'The browser could not play this live stream.';
      });
      if (shouldRenew && !renewalReported && widget.onSessionEnded != null) {
        renewalReported = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onSessionEnded?.call();
        });
      }
    }).toJS;
    video.addEventListener('error', errorListener);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (_) => video);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startQuboHls(video, widget.source, widget.authorizationHeader);
      }
    });
  }

  @override
  void didUpdateWidget(covariant LiveHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.authorizationHeader != widget.authorizationHeader) {
      error = null;
      renewalReported = false;
      _startQuboHls(video, widget.source, widget.authorizationHeader);
    }
  }

  @override
  void dispose() {
    video.removeEventListener('error', errorListener);
    _stopQuboHls(video);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: const Color(0xFF101512),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: HtmlElementView(viewType: viewType),
          ),
        ),
      ),
      if (error != null) ...[
        const SizedBox(height: 12),
        Notice(error!, error: true),
      ],
    ],
  );
}
