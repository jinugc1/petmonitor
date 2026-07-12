import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import 'owner_pairing_screen.dart' show pairingServiceProvider;
import 'pairing_service.dart';

/// Monitor: enter the pairing PIN shown in the owner app to complete the
/// key exchange and register this phone as a pet monitor.
class MonitorPairingScreen extends ConsumerStatefulWidget {
  const MonitorPairingScreen({super.key});

  @override
  ConsumerState<MonitorPairingScreen> createState() =>
      _MonitorPairingScreenState();
}

class _MonitorPairingScreenState extends ConsumerState<MonitorPairingScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _pair() async {
    final pin = _pin.text.replaceAll('-', '').trim();
    if (pin.length < 6) {
      setState(() => _error = 'Enter the 6-character PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(firebaseAuthProvider);
      final uid = auth.currentUser?.uid;
      if (uid == null) throw const PairingException('Not signed in');

      final fcmToken = await ref.read(messagingProvider).getToken();
      await ref.read(pairingServiceProvider).completeMonitorPairing(
            pin: pin,
            signedInUid: uid,
            deviceName: 'Pet Monitor',
            fcmToken: fcmToken,
          );
      if (mounted) context.go('/standby');
    } on PairingException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Pairing failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with owner'),
        actions: [
          IconButton(
            tooltip: 'Sign out / switch account',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(firebaseAuthProvider).signOut(),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.pets, size: 56),
                const SizedBox(height: 16),
                Text(
                  'On your phone (or PC / web), open PetMonitor with this '
                  'same account and tap "Add monitor". Then type the PIN '
                  'it shows:',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _pin,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: const InputDecoration(hintText: 'ABC-123'),
                  onSubmitted: (_) => _pair(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _pair,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Pair this monitor'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Keys are exchanged directly between your devices — '
                  'the PIN never leaves them.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
