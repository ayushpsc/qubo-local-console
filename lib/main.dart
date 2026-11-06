import 'dart:async';
import 'package:flutter/material.dart';
import 'controllers/dashboard_controller.dart';
import 'models/dashboard_models.dart';
import 'services/dashboard_api.dart';
import 'services/firebase_live_auth.dart';
import 'screens/login_screen.dart';
import 'screens/firebase_live_login_screen.dart';
import 'screens/events_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/connection_screen.dart';
import 'screens/stream_setup_screen.dart';
import 'widgets/dashboard_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final liveAuth = FirebaseLiveAuth();
  await liveAuth.restore();
  runApp(QuboCameraApp(liveAuth: liveAuth));
}

class QuboCameraApp extends StatelessWidget {
  final DashboardController? controller;
  final LiveAuthController? liveAuth;
  const QuboCameraApp({super.key, this.controller, this.liveAuth});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Qubo · Local console',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF5F7F2),
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        primary: green,
        surface: Colors.white,
      ),
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      dividerColor: line,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFAFBF8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        labelStyle: const TextStyle(color: muted, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 18,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: const BorderSide(color: line),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    ),
    home: HomeConsole(controller: controller, liveAuth: liveAuth),
  );
}

class HomeConsole extends StatefulWidget {
  final DashboardController? controller;
  final LiveAuthController? liveAuth;
  const HomeConsole({super.key, this.controller, this.liveAuth});
  @override
  State<HomeConsole> createState() => _HomeConsoleState();
}

class _HomeConsoleState extends State<HomeConsole> {
  late final bool ownsLiveAuth;
  late final LiveAuthController liveAuth;
  late final DashboardController c;
  final scaffold = GlobalKey<ScaffoldState>();
  int page = 0;
  bool expiryShown = false;
  final nav = const [
    (Icons.grid_view_outlined, 'Events'),
    (Icons.view_timeline_outlined, 'Timeline'),
    (Icons.devices_other_outlined, 'Devices'),
    (Icons.videocam_outlined, 'Live view'),
    (Icons.tune_outlined, 'Connection'),
  ];
  @override
  void initState() {
    super.initState();
    ownsLiveAuth = widget.liveAuth == null;
    liveAuth = widget.liveAuth ?? BypassLiveAuth();
    c =
        widget.controller ??
        DashboardController(
          DashboardApi(ConnectionSettings(), liveAuthToken: liveAuth.idToken),
        );
    c.api.liveAuthToken = liveAuth.idToken;
    c.addListener(changed);
    liveAuth.addListener(changed);
  }

  void changed() {
    if (page != 3 && c.expired && !expiryShown) {
      expiryShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Sign in again'),
            content: const Text(
              'Your Qubo session expired, its refresh token was rejected, or the server rejected the renewed session. Sign in with your Qubo email and password again.',
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  setState(() => page = 0);
                },
                child: const Text('Go to sign-in'),
              ),
            ],
          ),
        );
      });
    }
    if (!c.expired) expiryShown = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(changed);
    liveAuth.removeListener(changed);
    if (widget.controller == null) c.dispose();
    if (ownsLiveAuth) liveAuth.dispose();
    super.dispose();
  }

  void navigate(int index) {
    setState(() => page = index);
    scaffold.currentState?.closeDrawer();
  }

  Widget sidebar() => SizedBox(
    width: 230,
    child: Material(
      color: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 32, 24, 30),
              child: Row(
                children: [
                  Container(
                    width: 35,
                    height: 35,
                    decoration: BoxDecoration(
                      color: ink,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.home_outlined,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 11),
                  const Text(
                    'qubo',
                    style: TextStyle(
                      fontSize: 30,
                      letterSpacing: -2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(30, 8, 0, 18),
              child: Text(
                'HOME CONSOLE',
                style: TextStyle(
                  color: muted,
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (int i = 0; i < nav.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                child: ListTile(
                  selected: page == i,
                  selectedColor: green,
                  selectedTileColor: const Color(0xFFEAF3EC),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  leading: Icon(nav[i].$1, size: 21),
                  title: Text(
                    nav[i].$2,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () => navigate(i),
                ),
              ),
            const Spacer(),
            Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6F0),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: green, size: 22),
                  SizedBox(height: 10),
                  Text(
                    'Your session, your control',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Qubo and Firebase sessions are isolated. Sign out whenever you finish.',
                    style: TextStyle(fontSize: 11, color: muted, height: 1.6),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(30, 0, 24, 24),
              child: Text(
                'QUBO / HOME CONSOLE',
                style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.5),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget content() {
    if (page == 3) {
      if (liveAuth.restoring) {
        return const Center(child: CircularProgressIndicator());
      }
      if (liveAuth.user == null) {
        return FirebaseLiveLoginScreen(auth: liveAuth);
      }
      return StreamSetupScreen(controller: c);
    }
    if (page == 4) {
      return ConnectionScreen(
        controller: c,
        onSaved: () => setState(() => page = 0),
      );
    }
    if (c.session == null) {
      return LoginScreen(controller: c, onConnection: () => navigate(4));
    }
    return switch (page) {
      1 => EventsScreen(
        key: const ValueKey('timeline'),
        controller: c,
        timeline: true,
      ),
      2 => DevicesScreen(controller: c),
      _ => EventsScreen(key: const ValueKey('events'), controller: c),
    };
  }

  void showActivity() => showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: SizedBox(
        width: 720,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Request activity',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close activity',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                'Routes and HTTP status only. Credentials and bodies are not logged.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: c.requests.isEmpty
                    ? const EmptyState(
                        title: 'No requests yet',
                        description:
                            'API calls will appear here as you use the console.',
                      )
                    : ListView.separated(
                        itemCount: c.requests.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, i) {
                          final r = c.requests[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Text(
                              '${r.status}',
                              style: TextStyle(
                                color: r.status < 300
                                    ? green
                                    : Colors.deepOrange,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            title: Text(
                              r.method,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              r.route,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1050;
    return Scaffold(
      key: scaffold,
      drawer: wide ? null : Drawer(child: sidebar()),
      body: Row(
        children: [
          if (wide) sidebar(),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 80,
                  padding: EdgeInsets.symmetric(horizontal: wide ? 36 : 16),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: line)),
                  ),
                  child: Row(
                    children: [
                      if (!wide)
                        IconButton(
                          tooltip: 'Open navigation',
                          onPressed: () => scaffold.currentState?.openDrawer(),
                          icon: const Icon(Icons.menu),
                        ),
                      const Icon(Icons.home_outlined, color: muted, size: 18),
                      const SizedBox(width: 9),
                      Text(
                        wide ? 'My connected home' : 'Qubo',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (page == 3 && liveAuth.user != null && wide)
                        Chip(
                          avatar: const Icon(Icons.verified_user_outlined),
                          label: Text(
                            liveAuth.user!.email.isEmpty
                                ? 'Firebase viewer'
                                : liveAuth.user!.email,
                          ),
                        )
                      else if (page == 3 && liveAuth.user != null)
                        const Tooltip(
                          message: 'Firebase viewer signed in',
                          child: Icon(
                            Icons.verified_user_outlined,
                            color: green,
                          ),
                        )
                      else if (c.session != null)
                        SessionStatus(session: c.session!),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Request activity',
                        onPressed: showActivity,
                        icon: const Icon(Icons.receipt_long_outlined, size: 21),
                      ),
                      if ((page == 3 && liveAuth.user != null) ||
                          (page != 3 && c.session != null))
                        IconButton(
                          tooltip: 'Sign out',
                          onPressed: () async {
                            if (page == 3) {
                              await liveAuth.signOut();
                            } else {
                              c.signOut();
                              setState(() => page = 0);
                            }
                          },
                          icon: const Icon(Icons.logout, size: 21),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey(
                      '${c.session == null ? 'login' : 'home'}-$page',
                    ),
                    padding: EdgeInsets.all(wide ? 36 : 18),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1500),
                        child: content(),
                      ),
                    ),
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

class SessionStatus extends StatefulWidget {
  final Session session;
  const SessionStatus({super.key, required this.session});
  @override
  State<SessionStatus> createState() => _SessionStatusState();
}

class _SessionStatusState extends State<SessionStatus> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expiry = widget.session.expires;
    final seconds = expiry
        ?.difference(DateTime.now())
        .inSeconds
        .clamp(0, 99999999);
    final short = seconds != null && seconds < 300;
    return Tooltip(
      message: expiry == null
          ? 'Token expiry unknown. Server authentication failures will prompt sign-in.'
          : widget.session.refreshToken?.isNotEmpty ?? false
          ? 'Access token renews automatically by ${dateTimeFormat.format(expiry)}.'
          : 'Session expires at ${dateTimeFormat.format(expiry)}. Sign in again after expiry.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: short ? const Color(0xFFFFEAD5) : const Color(0xFFEAF3EC),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              short ? Icons.schedule : Icons.lock_outline,
              size: 14,
              color: short ? Colors.deepOrange : green,
            ),
            const SizedBox(width: 7),
            Text(
              seconds == null
                  ? 'Expiry unknown'
                  : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}${widget.session.refreshToken?.isNotEmpty ?? false ? '' : ' left'}',
              style: TextStyle(
                fontSize: 11,
                color: short ? Colors.deepOrange : green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
