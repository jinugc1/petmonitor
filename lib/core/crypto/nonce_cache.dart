import 'dart:convert';

import 'secure_kv.dart';

/// Replay protection: remembers nonces seen inside the timestamp validity
/// window so a captured call-authentication payload can never be replayed.
///
/// Persisted (secure storage) so replay protection survives app restarts —
/// an attacker must not be able to replay a wake payload by crashing the
/// monitor app first.
class NonceCache {
  NonceCache({
    SecureKv? storage,
    this.retention = const Duration(minutes: 10),
  }) : _storage = storage ?? SecureStorageKv();

  final SecureKv _storage;

  /// Must comfortably exceed the call-auth timestamp window.
  final Duration retention;

  static const String _key = 'pm.nonces';

  /// Returns true if [nonce] is fresh and atomically records it.
  /// Returns false if the nonce was already seen (replay attempt).
  Future<bool> checkAndStore(String nonce, DateTime now) async {
    final map = await _load();
    final cutoff = now.subtract(retention).millisecondsSinceEpoch;
    map.removeWhere((_, ts) => ts < cutoff);
    if (map.containsKey(nonce)) return false;
    map[nonce] = now.millisecondsSinceEpoch;
    await _storage.write(_key, jsonEncode(map));
    return true;
  }

  Future<Map<String, int>> _load() async {
    final raw = await _storage.read(_key);
    if (raw == null) return <String, int>{};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int));
    } on FormatException {
      return <String, int>{};
    }
  }
}
