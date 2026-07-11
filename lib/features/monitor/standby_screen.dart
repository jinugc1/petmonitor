import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/crypto/key_store.dart';
import '../../core/platform/wake_channel.dart';
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
      body: Center(
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
    );
  }
}
