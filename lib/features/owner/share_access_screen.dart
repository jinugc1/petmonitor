import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import 'access_grant_service.dart';

/// Shows a one-time PIN that lets another of the owner's own devices
/// obtain this monitor's call key. Keep this screen open until the other
/// device confirms — the encrypted hand-off happens live between the two
/// devices (Firestore only relays ciphertext).
class ShareAccessScreen extends ConsumerStatefulWidget {
  const ShareAccessScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<ShareAccessScreen> createState() => _ShareAccessScreenState();
}

class _ShareAccessScreenState extends ConsumerState<ShareAccessScreen> {
  ShareGrantSession? _session;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final uid = ref.read(firebaseAuthProvider).currentUser!.uid;
      final session = await ref.read(accessGrantServiceProvider).startSharing(
            ownerUid: uid,
            deviceId: widget.deviceId,
          );
      if (!mounted) {
        await session.cancel();
        return;
      }
      setState(() => _session = session);
      await session.completed;
      if (mounted) {
        setState(() => _done = true);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted && context.canPop()) context.pop();
      }
    } on StateError {
      if (mounted) {
        setState(
          () => _error = 'This device does not hold the key for that '
              'monitor — share from the device that can call it.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Sharing timed out. Try again.');
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
      appBar: AppBar(title: const Text('Share call access')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error != null
              ? Text(_error!, textAlign: TextAlign.center)
              : pin == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_done) ...[
                          const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 56,
                          ),
                          const SizedBox(height: 12),
                          const Text('Access shared!'),
                        ] else ...[
                          Text(
                            'On your other device, open PetMonitor →\n'
                            'menu on the monitor card → "Enter access PIN"\n'
                            'and type this code:',
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
                                fontFeatures: const [],
                                letterSpacing: 4,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const LinearProgressIndicator(),
                          const SizedBox(height: 8),
                          Text(
                            'Keep this screen open · PIN expires in 5 minutes',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
        ),
      ),
    );
  }
}
