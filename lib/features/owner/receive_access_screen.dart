import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import 'access_grant_service.dart';
import 'devices_screen.dart' show deviceKeyPresentProvider;
import 'key_sync_service.dart';

/// Enter the PIN shown on the owner device that can already call the
/// monitor. Works on every platform (no camera needed).
class ReceiveAccessScreen extends ConsumerStatefulWidget {
  const ReceiveAccessScreen({super.key});

  @override
  ConsumerState<ReceiveAccessScreen> createState() =>
      _ReceiveAccessScreenState();
}

class _ReceiveAccessScreenState extends ConsumerState<ReceiveAccessScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _redeem() async {
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
      final uid = ref.read(firebaseAuthProvider).currentUser!.uid;
      final deviceId = await ref
          .read(accessGrantServiceProvider)
          .redeemPin(ownerUid: uid, pin: pin);
      ref.invalidate(deviceKeyPresentProvider);
      // Keep the encrypted cloud backup fresh (no-op if sync is off).
      await ref.read(keySyncServiceProvider).backupDevice(uid, deviceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This device can now call.')),
        );
        context.pop();
      }
    } on AccessGrantException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter access PIN')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.key, size: 56),
                const SizedBox(height: 16),
                Text(
                  'On the device that can already call the monitor, open '
                  'its menu and choose "Share call access", then type the '
                  'PIN it shows here.',
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
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[A-Za-z0-9-]'),
                    ),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: const InputDecoration(hintText: 'ABC-123'),
                  onSubmitted: (_) => _redeem(),
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
                  onPressed: _busy ? null : _redeem,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock calling on this device'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
