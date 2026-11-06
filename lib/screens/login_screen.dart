import 'dart:async';
import 'package:flutter/material.dart';
import '../controllers/dashboard_controller.dart';
import '../models/dashboard_models.dart';
import '../services/dashboard_api.dart';
import '../widgets/dashboard_widgets.dart';

class LoginScreen extends StatefulWidget {
  final DashboardController controller;
  final VoidCallback onConnection;
  const LoginScreen({
    super.key,
    required this.controller,
    required this.onConnection,
  });
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController(),
      password = TextEditingController(),
      token = TextEditingController();
  final form = GlobalKey<FormState>();
  String? error;
  bool busy = false, hidePassword = true;
  @override
  void dispose() {
    for (final c in [email, password, token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> signIn() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final profiles = await widget.controller.api.loginProfilesWithEmail(
        email.text.trim(),
        password.text,
      );
      if (!mounted) return;
      final session = profiles.length == 1
          ? profiles.single
          : await showDialog<Session>(
              context: context,
              barrierDismissible: false,
              builder: (context) => SimpleDialog(
                title: const Text('Choose your Qubo profile'),
                children: [
                  ...profiles.map(
                    (profile) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, profile),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'User ${profile.user}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
      if (session == null || !mounted) return;
      password.clear();
      await widget.controller.signInAndDiscover(session);
      if (!mounted) return;
      unawaited(widget.controller.fetch());
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final card = Surface(
        padding: const EdgeInsets.all(32),
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WELCOME HOME',
                style: TextStyle(
                  color: green,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Sign in to Qubo',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Use the email and password for your Qubo account. Your refresh token stays only in this app session.',
                style: const TextStyle(color: muted, height: 1.6),
              ),
              const SizedBox(height: 28),
              if (widget.controller.expired)
                const Notice(
                  'Your Qubo session could not be renewed. Sign in again to continue.',
                  error: true,
                ),
              if (error != null) Notice(error!, error: true),
              AutofillGroup(
                child: Column(
                  children: [
                    TextFormField(
                      controller: email,
                      enabled: !busy,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [
                        AutofillHints.username,
                        AutofillHints.email,
                      ],
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                      ),
                      validator: (value) =>
                          RegExp(
                            r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                          ).hasMatch(value?.trim() ?? '')
                          ? null
                          : 'Enter a valid email address',
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: password,
                      enabled: !busy,
                      obscureText: hidePassword,
                      enableSuggestions: false,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          tooltip: hidePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: busy
                              ? null
                              : () => setState(
                                  () => hidePassword = !hidePassword,
                                ),
                          icon: Icon(
                            hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => (value?.isNotEmpty ?? false)
                          ? null
                          : 'Enter your Qubo password',
                      onFieldSubmitted: (_) => busy ? null : signIn(),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: busy ? null : signIn,
                        icon: const Icon(Icons.login, size: 18),
                        label: Text(
                          busy ? 'Signing in…' : 'Sign in & open dashboard',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: busy ? null : widget.onConnection,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Connection & device setup'),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Already have a token?',
                  style: TextStyle(fontSize: 13, color: muted),
                ),
                children: [
                  const Text(
                    'Use a server-issued token. It stays in memory for this session.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: token,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Subscriber key (JWT)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final value = token.text.trim(),
                                  claims = Session.claims(token.text.trim());
                              if (claims['user'] == null ||
                                  claims['mob'] == null ||
                                  claims['iss'] == null) {
                                throw const FormatException(
                                  'Use a Qubo token containing user, mob and iss claims.',
                                );
                              }
                              final s = Session.fromJson({
                                'token': value,
                                'uuid': claims['user'],
                              });
                              if (s.expired(DateTime.now())) {
                                throw const FormatException(
                                  'This token has expired. Sign in again.',
                                );
                              }
                              widget.controller.settings.sourceDeviceId =
                                  '${claims['mob']}';
                              widget.controller.settings.tenant =
                                  '${claims['iss']}';
                              await widget.controller.signInAndDiscover(s);
                              if (!mounted) return;
                              unawaited(widget.controller.fetch());
                            } catch (exception) {
                              if (!mounted) return;
                              setState(
                                () => error = exception is ApiException
                                    ? '$exception'
                                    : 'Token is invalid or expired. Use a current server-issued Qubo JWT.',
                              );
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    child: const Text('Use token'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final intro = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFB9D9CA)),
              borderRadius: BorderRadius.circular(30),
            ),
            child: const Text(
              'YOUR CONNECTED HOME',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 26),
          const Text(
            'A little closer\nto home.',
            style: TextStyle(
              fontSize: 58,
              height: 1.08,
              fontWeight: FontWeight.w700,
              letterSpacing: -2.5,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'See who stopped by. Find the moment that matters.\nKeep your everyday devices within reach.',
            style: TextStyle(color: muted, height: 1.7, fontSize: 16),
          ),
          const SizedBox(height: 38),
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: const Color(0xFF193E40),
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home_outlined, size: 80, color: Color(0xFFB7D8BE)),
                  SizedBox(height: 20),
                  Text(
                    'ONE HOME. EVERY MOMENT.',
                    style: TextStyle(
                      color: Color(0xFFC8DECE),
                      fontSize: 11,
                      letterSpacing: 3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Email sign-in  /  Automatic token renewal  /  Real API data',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      );
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: box.maxWidth > 950
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: intro),
                    const SizedBox(width: 80),
                    Expanded(child: card),
                  ],
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: card,
                ),
        ),
      );
    },
  );
}
