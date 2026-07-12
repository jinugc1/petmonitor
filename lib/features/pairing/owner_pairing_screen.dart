import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../owner/devices_screen.dart' show deviceKeyPresentProvider;
import 'pairing_service.dart';

final pairingServiceProvider = Provider<PairingService>(
  (ref) => PairingService(
    firestore: ref.watch(firestoreProvider),
    keyStore: ref.watch(keyStoreProvider),
  ),
);

/// Owner: shows the pairing PIN and waits for the monitor to claim it.
class OwnerPairingScreen extends ConsumerStatefulWidget {
  const OwnerPairingScreen({super.key});

  @override
  ConsumerState<OwnerPairingScreen> createState() =>
      _OwnerPairingScreenState();
}

class _OwnerPairingScreenState extends ConsumerState<OwnerPairingScreen> {
  OwnerPairingSession? _session;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) return;
    try {
      final session =
          await ref.read(pairingServiceProvider).startOwnerPairing(uid);
      if (!mounted) {
        await session.cancel();
        return;
      }
      setState(() => _session = session);
      final deviceId = await session.pairedDeviceId;
      _done = true;
      // The dashboard may have checked for this device's key before we
      // stored it — force a re-read now that pairing is complete.
      ref.invalidate(deviceKeyPresentProvider);
      if (mounted) context.go('/devices?paired=$deviceId');
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PairingException
              ? e.message
              : 'Pairing timed out. Try again.',
        );
      }
    }
  }

  @override
  void dispose() {
    if (!_done) _session?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = _session?.pin;
    return Scaffold(
      appBar: AppBar(title: const Text('Add Pet Monitor')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _session = null;
                        });
                        _start();
                      },
                      child: const Text('Try again'),
                    ),
                  ],
                )
              : pin == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'On the Android monitor phone:\n'
                          '1. Install PetMonitor and sign in with THIS '
                          'account\n'
                          '2. Type this pairing PIN when asked:',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            '${pin.substring(0, 3)}-${pin.substring(3)}',
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                                  letterSpacing: 4,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(
                          'Waiting for the monitor… PIN expires in 5 minutes',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
