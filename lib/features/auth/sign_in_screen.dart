import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/platform_info.dart';
import 'auth_repository.dart';

/// Shared sign-in screen (owner and monitor apps use the same account).
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, required this.subtitle});

  final String subtitle;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      // Router redirect handles navigation on auth state change.
    } on FirebaseAuthException catch (e) {
      setState(
        () => _error = switch (e.code) {
          'invalid-credential' ||
          'wrong-password' ||
          'user-not-found' =>
            'Incorrect email or password.',
          'canceled' => null,
          _ => 'Sign-in failed. Please try again.',
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(authRepositoryProvider);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.pets, size: 64),
                const SizedBox(height: 8),
                Text(
                  'PetMonitor',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            () => repo.signInWithEmail(
                              _email.text.trim(),
                              _password.text,
                            ),
                          ),
                  child: const Text('Sign in'),
                ),
                // Native Google/Apple sign-in SDKs exist only on mobile;
                // desktop and web clients use email/password.
                if (isMobilePlatform) ...[
                  const Divider(height: 32),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(repo.signInWithGoogle),
                    icon: const Icon(Icons.g_mobiledata),
                    label: const Text('Continue with Google'),
                  ),
                ],
                if (isIosPlatform) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(repo.signInWithApple),
                    icon: const Icon(Icons.apple),
                    label: const Text('Continue with Apple'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
