import 'package:flutter/foundation.dart';

/// Logging that can never leak sensitive material.
///
/// Rules enforced here rather than by convention:
///  * release builds emit nothing;
///  * known secret-bearing patterns are redacted defensively even in debug.
class SecureLogger {
  SecureLogger(this.tag);

  final String tag;

  static final RegExp _base64ish = RegExp(r'[A-Za-z0-9+/_-]{40,}={0,2}');

  void info(String message) => _log('I', message);
  void warn(String message) => _log('W', message);
  void error(String message, [Object? error]) =>
      _log('E', error == null ? message : '$message: ${_sanitize('$error')}');

  void _log(String level, String message) {
    if (!kDebugMode) return;
    debugPrint('[$level/$tag] ${_sanitize(message)}');
  }

  static String _sanitize(String input) =>
      input.replaceAll(_base64ish, '<redacted>');
}
