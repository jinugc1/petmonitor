import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/firebase/firestore_paths.dart';
import '../../core/models/device.dart';
import '../../core/providers.dart';
import '../auth/auth_repository.dart';
import 'owner_call_controller.dart';
import 'owner_push_service.dart';

/// Whether THIS phone holds the pairing key for a device. Without it,
/// calls are cryptographically impossible (the key never leaves the
/// owner device that scanned the QR) — the UI must not offer them.
///
/// autoDispose: the check may first run mid-pairing (the device doc
/// appears before the owner has verified and stored the key), so the
/// result must never be cached beyond the widget's lifetime. The pairing
/// screen additionally invalidates it on completion.
final deviceKeyPresentProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, deviceId) async {
  final key = await ref.watch(keyStoreProvider).readMasterKey(deviceId);
  return key != null;
});

/// Paired monitors for the signed-in owner (real-time).
final devicesProvider = StreamProvider<List<MonitorDevice>>((ref) {
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref
      .watch(firestoreProvider)
      .collection(FirestorePaths.devices)
      .where('ownerUid', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map(MonitorDevice.fromDoc).toList());
});

/// Owner dashboard: device list with live status, call buttons, pairing.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    ref.watch(ownerPushInitProvider); // register this phone for alerts

    ref.listen(ownerCallControllerProvider, (prev, next) {
      if (next.phase == OwnerCallPhase.ringing &&
          prev?.phase != OwnerCallPhase.ringing) {
        context.go('/call');
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Pet Monitors'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/pair'),
        icon: const Icon(Icons.qr_code),
        label: const Text('Add monitor'),
      ),
      body: _buildDeviceList(context, ref, devices),
    );
  }

  Widget _buildDeviceList(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<MonitorDevice>> devices,
  ) {
    return devices.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => const Center(child: Text('Could not load devices')),
      data: (list) => list.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.pets, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    'No monitors yet',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Install PetMonitor on a spare Android phone\n'
                    'and tap "Add monitor" to pair it securely.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (context, i) => _DeviceCard(device: list[i]),
            ),
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard({required this.device});

  final MonitorDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = device.status;
    final online = device.isOnline;
    final hasKey =
        ref.watch(deviceKeyPresentProvider(device.id)).value ?? false;
    final ready = online && hasKey;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: ready
                      ? Colors.green.withValues(alpha: 0.15)
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.pets,
                    color: ready ? Colors.green : theme.disabledColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name, style: theme.textTheme.titleMedium),
                      Text(
                        !hasKey
                            ? 'Paired with another phone — re-pair to call'
                            : ready
                                ? 'Ready for calls'
                                : s.lastOnline == null
                                    ? 'Never connected'
                                    : 'Offline — open the monitor app · last seen '
                                        '${DateFormat.yMd().add_jm().format(s.lastOnline!)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ready
                              ? Colors.green
                              : hasKey
                                  ? null
                                  : theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: ready
                      ? () => ref
                          .read(ownerCallControllerProvider.notifier)
                          .startCall(device.id)
                      : null,
                  icon: const Icon(Icons.videocam),
                  label: const Text('Call'),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'remove') _remove(context, ref);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove monitor'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _stat(
                  s.charging ? Icons.battery_charging_full : Icons.battery_std,
                  s.batteryPercent < 0 ? '—' : '${s.batteryPercent}%',
                ),
                _stat(
                  s.networkType == 'wifi'
                      ? Icons.wifi
                      : Icons.signal_cellular_alt,
                  s.networkType,
                ),
                _stat(Icons.speed, s.latencyMs < 0 ? '—' : '${s.latencyMs} ms'),
                _stat(
                  Icons.sd_storage,
                  s.freeStorageMb < 0
                      ? '—'
                      : '${(s.freeStorageMb / 1024).toStringAsFixed(1)} GB free',
                ),
                _stat(Icons.camera_alt, s.cameraOk ? 'OK' : 'Error'),
                _stat(Icons.mic, s.microphoneOk ? 'OK' : 'Error'),
                if (s.appVersion.isNotEmpty)
                  _stat(Icons.info_outline, 'v${s.appVersion}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Removes the device registration and this phone's pairing key. The
  /// monitor itself notices the deletion is irrelevant to it — unpair it
  /// locally via the link-off button on its standby screen.
  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${device.name}?'),
        content: const Text(
          'The monitor disappears from your account. To use it again, '
          'unpair it on the monitor screen and scan a new QR code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(firestoreProvider)
          .doc(FirestorePaths.device(device.id))
          .delete();
    } catch (_) {}
    await ref.read(keyStoreProvider).deleteMasterKey(device.id);
  }

  Widget _stat(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      );
}
