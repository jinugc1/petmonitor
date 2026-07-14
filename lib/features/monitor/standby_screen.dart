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

    // Account-mismatch recovery: if someone signed in with a DIFFERENT
    // account than the one this monitor was paired under, the local
    // pairing is orphaned (rules block every write, calls can't
    // authenticate). Detect it and reset to the pairing screen.
    final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
    var ownedByUs = false;
    try {
      final doc = await ref
          .read(firestoreProvider)
          .doc(FirestorePaths.device(deviceId))
          .get();
      ownedByUs = doc.exists && doc.data()?['ownerUid'] == uid;
    } catch (_) {
      // PERMISSION_DENIED == owned by another account.
      ownedByUs = false;
    }
    if (!ownedByUs) {
      await KeyStore().wipe();
      if (mounted) context.go('/pair');
      return;
    }

    setState(() => _deviceId = deviceId);
    await ref.read(monitorServiceProvider).start(deviceId);
    await ref.read(statusReporterProvider).start(deviceId);
    // Keep the process alive in standby and ask (once) to be exempted
    // from battery optimization — without these, aggressive OEMs kill
    // the app after a while and the monitor goes unreachable.
    await WakeChannel.startStandbyService();
    await WakeChannel.requestBatteryExemption();
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
    await WakeChannel.stopStandbyService();
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

  /// Sign out (e.g. to hand the monitor to a different owner account).
  /// Fully resets: unpairs locally, removes the registration if this
  /// account still owns it, then signs out of Firebase.
  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out of this monitor?'),
        content: const Text(
          'The monitor stops working and its pairing is erased. Sign in '
          '(with any account) and pair again to reuse it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    ref.read(monitorServiceProvider).dispose();
    await WakeChannel.stopStandbyService();
    try {
      await ref.read(statusReporterProvider).stop();
    } catch (_) {}
    final deviceId = _deviceId;
    try {
      if (deviceId != null) {
        await ref
            .read(firestoreProvider)
            .doc(FirestorePaths.device(deviceId))
            .delete();
      }
    } catch (_) {} // not ours anymore / offline — local wipe still applies
    await KeyStore().wipe();
    await ref.read(firebaseAuthProvider).signOut();
    // Router redirect sends us to /signin automatically.
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
          // Discreet controls (dim, bottom corners — not reachable by
          // accident during calls, which use a different screen).
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
          Positioned(
            left: 8,
            bottom: 8,
            child: IconButton(
              tooltip: 'Sign out / switch account',
              icon: Icon(
                Icons.logout,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              onPressed: _signOut,
            ),
          ),
        ],
      ),
    );
  }
}
