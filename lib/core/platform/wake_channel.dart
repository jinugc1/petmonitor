import 'package:flutter/services.dart';

import '../utils/secure_logger.dart';

/// Bridge to the Android native layer (MainActivity.kt) that handles what
/// Flutter cannot: turning the screen on, showing over the lock screen,
/// dismissing the keyguard, and releasing those flags afterwards.
///
/// Every method is a safe no-op on iOS (the owner app never needs it).
class WakeChannel {
  static const _channel = MethodChannel('petmonitor/wake');
  static final _log = SecureLogger('wake');

  /// Acquire wake state for an incoming call: screen on, over lockscreen,
  /// keyguard dismissed if the device is not credential-locked.
  static Future<void> acquireForCall() => _invoke('acquireForCall');

  /// Release all wake flags and let the device sleep again (standby).
  static Future<void> releaseAfterCall() => _invoke('releaseAfterCall');

  /// Keep the screen awake while the monitor is charging (Pet Mode).
  static Future<void> setKeepScreenOnWhileCharging(bool enabled) =>
      _invoke('keepScreenOnWhileCharging', {'enabled': enabled});

  static Future<void> _invoke(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // iOS / tests — intentionally silent.
    } on PlatformException catch (e) {
      _log.error('wake channel $method failed', e);
    }
  }
}
