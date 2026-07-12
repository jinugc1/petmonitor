import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/webrtc/ice_config.dart';

/// Whether the direct wake-push key is configured (Spark-plan mode).
final wakePushConfiguredProvider = FutureProvider<bool>(
  (ref) => ref.watch(fcmDirectSenderProvider).isConfigured,
);

/// Owner settings: the FCM service-account key (required on the free
/// Spark plan so calls can wake a sleeping monitor) and the optional
/// TURN relay for hostile NATs. Both are stored only in secure storage.
class OwnerSettingsScreen extends ConsumerStatefulWidget {
  const OwnerSettingsScreen({super.key});

  @override
  ConsumerState<OwnerSettingsScreen> createState() =>
      _OwnerSettingsScreenState();
}

class _OwnerSettingsScreenState extends ConsumerState<OwnerSettingsScreen> {
  final _keyController = TextEditingController();
  final _turnUrl = TextEditingController();
  final _turnUser = TextEditingController();
  final _turnPass = TextEditingController();
  String? _keyMessage;
  bool _keyError = false;

  @override
  void initState() {
    super.initState();
    ref.read(iceConfigStoreProvider).load().then((cfg) {
      if (!mounted) return;
      _turnUrl.text = cfg.turnUrl ?? '';
      _turnUser.text = cfg.turnUsername ?? '';
      _turnPass.text = cfg.turnPassword ?? '';
    });
  }

  Future<void> _saveKey() async {
    final sender = ref.read(fcmDirectSenderProvider);
    try {
      await sender.saveServiceAccount(_keyController.text);
      _keyController.clear();
      ref.invalidate(wakePushConfiguredProvider);
      setState(() {
        _keyMessage = 'Key saved to the secure keychain.';
        _keyError = false;
      });
    } on FormatException catch (e) {
      setState(() {
        _keyMessage = e.message;
        _keyError = true;
      });
    }
  }

  Future<void> _removeKey() async {
    await ref.read(fcmDirectSenderProvider).clear();
    ref.invalidate(wakePushConfiguredProvider);
    setState(() {
      _keyMessage = 'Key removed.';
      _keyError = false;
    });
  }

  Future<void> _saveTurn() async {
    await ref.read(iceConfigStoreProvider).save(
          IceConfig(
            turnUrl: _turnUrl.text.trim(),
            turnUsername: _turnUser.text.trim(),
            turnPassword: _turnPass.text,
          ),
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TURN settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(wakePushConfiguredProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Wake-up push key',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Lets calls wake the monitor while it sleeps (free Spark '
            'plan). Firebase console → Project settings → Service '
            'accounts → "Generate new private key", then paste the whole '
            'JSON file below. It is stored only in this phone\'s secure '
            'keychain.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          configured.when(
            data: (ok) => Row(
              children: [
                Icon(
                  ok ? Icons.check_circle : Icons.error_outline,
                  color: ok ? Colors.green : Colors.orange,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(ok ? 'Configured' : 'Not configured'),
                const Spacer(),
                if (ok)
                  TextButton(
                    onPressed: _removeKey,
                    child: const Text('Remove'),
                  ),
              ],
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          TextField(
            controller: _keyController,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '{ "type": "service_account", ... }',
            ),
          ),
          if (_keyMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _keyMessage!,
              style: TextStyle(
                color: _keyError
                    ? Theme.of(context).colorScheme.error
                    : Colors.green,
              ),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton(onPressed: _saveKey, child: const Text('Save key')),
          const Divider(height: 40),
          Text(
            'TURN relay (optional)',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Only needed if calls fail to connect on restrictive mobile '
            'networks. Credentials stay on this device.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnUrl,
            decoration: const InputDecoration(
              labelText: 'TURN URL (turn:host:3478)',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnUser,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnPass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: _saveTurn,
            child: const Text('Save TURN settings'),
          ),
        ],
      ),
    );
  }
}
