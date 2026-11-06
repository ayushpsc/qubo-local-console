import 'package:flutter/material.dart';

import '../services/firebase_live_auth.dart';
import '../widgets/dashboard_widgets.dart';

class FirebaseLiveLoginScreen extends StatefulWidget {
  final LiveAuthController auth;

  const FirebaseLiveLoginScreen({super.key, required this.auth});

  @override
  State<FirebaseLiveLoginScreen> createState() =>
      _FirebaseLiveLoginScreenState();
}

class _FirebaseLiveLoginScreenState extends State<FirebaseLiveLoginScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.auth.signIn(email.text, password.text);
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Surface(
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3EC),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.videocam_outlined, color: green),
              ),
              const SizedBox(height: 22),
              const Text(
                'Sign in for live view',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Use your Firebase email and password. This is separate from the Qubo email sign-in used for events and device controls.',
                style: TextStyle(color: muted, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  return text.contains('@') ? null : 'Enter a valid email.';
                },
                onFieldSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                validator: (value) => (value?.isNotEmpty ?? false)
                    ? null
                    : 'Enter your password.',
                onFieldSubmitted: (_) => submit(),
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Notice(error!, error: true),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy ? null : submit,
                icon: busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.login),
                label: Text(busy ? 'Signing in…' : 'Open live view'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
