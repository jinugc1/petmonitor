import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/crypto/key_store.dart';
import '../../core/firebase/firestore_paths.dart';
import '../../core/platform/wake_channel.dart';
import '../../core/providers.dart';
import 'monitor_call_controller.dart';
import 'monitor_service.dart';
import 'status_reporter.dart';

/// Dormant standby: a nearly black, static screen (OLED-friendly) with no
/// timers except the cheap status heartbeat. The phone is free to sleep;
/// FCM wakes us for authenticated calls.
class StandbyScreen extends ConsumerStatefulWidget {
  const StandbyScreen({super.key});

  @override
  ConsumerState<StandbyScreen> createState() => _StandbyScreenState();
}

class _StandbyScreenState extends ConsumerState<StandbyScreen> {
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final deviceId = await KeyStore().readLocalDeviceId();
    if (!mounted) return;
    if (deviceId == null) {
      context.go('/pair');
      return;
    }
    setState(() => _deviceId = deviceId);
    await ref.read(monitorServiceProvider).start(deviceId);
    await ref.read(statusReporterProvider).start(deviceId);
    // Pet Mode nicety: while on the charger, keep the screen dimly on so
    // the pet isn't startled by it lighting up; on battery, sleep freely.
    final charging = await Battery().batteryState;
    await WakeChannel.setKeepScreenOnWhileCharging(
      charging == BatteryState.charging || charging == BatteryState.full,
    );
  }

  /// Unpair: forget this monitor's identity and keys so it can be paired
  /// again (e.g. with a different owner phone). The pairing key never
  /// leaves the owner device that scanned the QR, so switching owner
  /// phones requires a fresh pairing.
  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unpair this monitor?'),
        content: const Text(
          'This removes the monitor from your account and erases its '
          'encryption keys. You can then pair it again by scanning a '
          'new QR code from any owner phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Stop background work FIRST so the heartbeat cannot resurrect the
    // device document after we delete it.
    ref.read(monitorServiceProvider).dispose();
    final deviceId = _deviceId;
    try {
      await ref.read(statusReporterProvider).stop();
    } catch (_) {}
    try {
      if (deviceId != null) {
        await ref
            .read(firestoreProvider)
            .doc(FirestorePaths.device(deviceId))
            .delete();
      }
    } catch (_) {}
    await KeyStore().wipe();
    if (mounted) context.go('/pair');
  }

  @override
  Widget build(BuildContext context) {
    // Navigate to the call screen the moment a call gets past auth.
    ref.listen(monitorCallControllerProvider, (prev, next) {
      if (next.phase == MonitorCallPhase.connecting &&
          prev?.phase != MonitorCallPhase.connecting) {
        context.go('/call');
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.pets,
                  size: 64,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                const SizedBox(height: 16),
                Text(
                  _deviceId == null ? 'Starting…' : 'Standing by',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25),
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Waiting for an authenticated call',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.15),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // Discreet unpair control (dim, bottom corner — not reachable
          // by accident during calls, which use a different screen).
          Positioned(
            right: 8,
            bottom: 8,
            child: IconButton(
              tooltip: 'Unpair / pair with a different phone',
              icon: Icon(
                Icons.link_off,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              onPressed: _unpair,
            ),
          ),
        ],
      ),
    );
  }
}
