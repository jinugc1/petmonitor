import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/firebase/firestore_paths.dart';
import '../../core/providers.dart';
import '../../core/webrtc/ice_config.dart';
import 'devices_screen.dart' show deviceKeyPresentProvider;
import 'key_sync_service.dart';

/// Whether the direct wake-push key is configured (Spark-plan mode).
final wakePushConfiguredProvider = FutureProvider<bool>(
  (ref) => ref.watch(fcmDirectSenderProvider).isConfigured,
);

/// Key-sync status: (enabled on this device, cloud backups exist).
final keySyncStatusProvider =
    FutureProvider.autoDispose<(bool, bool)>((ref) async {
  final service = ref.watch(keySyncServiceProvider);
  final uid = ref.watch(firebaseAuthProvider).currentUser?.uid;
  final local = await service.isEnabledHere;
  final cloud = uid == null ? false : await service.hasCloudBackups(uid);
  return (local, cloud);
});

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
  final _syncPass = TextEditingController();
  String? _keyMessage;
  bool _keyError = false;
  String? _syncMessage;
  bool _syncError = false;
  bool _syncBusy = false;

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

  Future<void> _runSync(
    Future<String> Function(String uid, String passphrase) action,
  ) async {
    final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) return;
    setState(() {
      _syncBusy = true;
      _syncMessage = null;
    });
    try {
      final message = await action(uid, _syncPass.text);
      _syncPass.clear();
      ref.invalidate(keySyncStatusProvider);
      ref.invalidate(deviceKeyPresentProvider);
      setState(() {
        _syncMessage = message;
        _syncError = false;
      });
    } on KeySyncException catch (e) {
      setState(() {
        _syncMessage = e.message;
        _syncError = true;
      });
    } catch (_) {
      setState(() {
        _syncMessage = 'Something went wrong. Try again.';
        _syncError = true;
      });
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _enableSync() => _runSync((uid, passphrase) async {
        final devices = await ref
            .read(firestoreProvider)
            .collection(FirestorePaths.devices)
            .where('ownerUid', isEqualTo: uid)
            .get();
        final count = await ref.read(keySyncServiceProvider).enable(
              ownerUid: uid,
              passphrase: passphrase,
              deviceIds: devices.docs.map((d) => d.id).toList(),
            );
        return count == 0
            ? 'Sync enabled. No local keys to back up yet — restore or '
                'pair on this device first.'
            : 'Sync enabled — $count key(s) backed up.';
      });

  Future<void> _restoreSync() => _runSync((uid, passphrase) async {
        final count = await ref
            .read(keySyncServiceProvider)
            .restore(ownerUid: uid, passphrase: passphrase);
        return 'Restored $count key(s) — this device can now call.';
      });

  Future<void> _disableSync() async {
    final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) return;
    await ref.read(keySyncServiceProvider).disable(uid);
    ref.invalidate(keySyncStatusProvider);
    setState(() {
      _syncMessage = 'Cloud backups deleted.';
      _syncError = false;
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
    final syncStatus = ref.watch(keySyncStatusProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Cloud key sync',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Back up monitor call keys, encrypted with a passphrase only '
            'you know, so signing in on any device just needs this '
            'passphrase to enable calling. The server can never read '
            'your keys.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (syncStatus != null)
            Row(
              children: [
                Icon(
                  syncStatus.$1
                      ? Icons.cloud_done
                      : syncStatus.$2
                          ? Icons.cloud_download
                          : Icons.cloud_off,
                  size: 18,
                  color: syncStatus.$1 ? Colors.green : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    syncStatus.$1
                        ? 'Sync active on this device'
                        : syncStatus.$2
                            ? 'Backups exist — enter the passphrase to '
                                'unlock calling here'
                            : 'Not set up yet',
                  ),
                ),
                if (syncStatus.$1 || syncStatus.$2)
                  TextButton(
                    onPressed: _syncBusy ? null : _disableSync,
                    child: const Text('Delete backups'),
                  ),
              ],
            ),
          TextField(
            controller: _syncPass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Sync passphrase (8+ characters)',
            ),
          ),
          if (_syncMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _syncMessage!,
              style: TextStyle(
                color: _syncError
                    ? Theme.of(context).colorScheme.error
                    : Colors.green,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _syncBusy ? null : _enableSync,
                  child: const Text('Enable / back up'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _syncBusy ? null : _restoreSync,
                  child: const Text('Restore here'),
                ),
              ),
            ],
          ),
          const Divider(height: 40),
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
