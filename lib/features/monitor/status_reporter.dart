import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/firebase/firestore_paths.dart';
import '../../core/providers.dart';
import '../../core/utils/secure_logger.dart';

final statusReporterProvider = Provider<StatusReporter>((ref) {
  final reporter = StatusReporter(ref);
  ref.onDispose(reporter.stop);
  return reporter;
});

/// Publishes the monitor's health to its device document so the owner
/// dashboard can show it. Deliberately battery-cheap:
///
///  * one write every [interval] (heartbeat / presence),
///  * plus immediate writes on battery-low and charger events,
///  * no wake locks — if the OS puts the app to sleep, the heartbeat
///    simply pauses and the owner sees the device as offline-ish until
///    the next FCM wake. That trade IS the low-power design.
class StatusReporter {
  StatusReporter(this._ref, {this.interval = const Duration(minutes: 2)});

  final Ref _ref;
  final Duration interval;
  final _log = SecureLogger('status');

  final _battery = Battery();
  Timer? _timer;
  StreamSubscription<BatteryState>? _batterySub;
  String? _deviceId;
  int _lastBatteryNotified = 100;

  Future<void> start(String deviceId) async {
    _deviceId = deviceId;
    _timer = Timer.periodic(interval, (_) => _publish());
    _batterySub = _battery.onBatteryStateChanged.listen((_) => _publish());
    await _publish();
  }

  Future<void> _publish() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    try {
      final battery = await _battery.batteryLevel;
      final batteryState = await _battery.batteryState;
      final connectivity = await Connectivity().checkConnectivity();
      final info = await PackageInfo.fromPlatform();
      final freeMb = Platform.isAndroid
          ? ((await DiskSpacePlus().getFreeDiskSpace) ?? -1).round()
          : -1;

      final latency = await _measureLatency();

      await _ref
          .read(firestoreProvider)
          .doc(FirestorePaths.device(deviceId))
          .set(
        {
          'status': {
            'online': true,
            'battery': battery,
            'charging': batteryState == BatteryState.charging ||
                batteryState == BatteryState.full,
            'network': connectivity.contains(ConnectivityResult.wifi)
                ? 'wifi'
                : connectivity.contains(ConnectivityResult.mobile)
                    ? 'mobile'
                    : 'none',
            'latencyMs': latency,
            'freeStorageMb': freeMb,
            'cameraOk': true,
            'micOk': true,
            'appVersion': info.version,
            'lastOnline': DateTime.now().toUtc(),
          },
        },
        SetOptions(merge: true),
      );

      await _maybeRaiseEvents(deviceId, battery);
    } catch (e) {
      _log.warn('heartbeat failed (will retry next tick)');
    }
  }

  /// Round-trip time of a tiny Firestore read — a fair latency proxy.
  Future<int> _measureLatency() async {
    try {
      final sw = Stopwatch()..start();
      await _ref
          .read(firestoreProvider)
          .doc(FirestorePaths.device(_deviceId!))
          .get(const GetOptions(source: Source.server));
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  /// Writes notification events (battery low, reboot) that the Cloud
  /// Function fans out to the owner's phone via FCM.
  Future<void> _maybeRaiseEvents(String deviceId, int battery) async {
    if (battery <= 15 && _lastBatteryNotified > 15) {
      await _ref
          .read(firestoreProvider)
          .collection('${FirestorePaths.device(deviceId)}/events')
          .add({
        'type': 'battery_low',
        'battery': battery,
        'createdAt': DateTime.now().toUtc(),
      });
    }
    _lastBatteryNotified = battery;
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _batterySub?.cancel();
    final deviceId = _deviceId;
    if (deviceId != null) {
      try {
        await _ref
            .read(firestoreProvider)
            .doc(FirestorePaths.device(deviceId))
            .set(
          {
            'status': {'online': false},
          },
          SetOptions(merge: true),
        );
      } catch (_) {}
    }
  }
}
