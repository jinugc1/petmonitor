import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_engine.dart';

/// Per-call signaling cipher with Perfect Forward Secrecy.
///
/// Established from a fresh ephemeral X25519 exchange authenticated by the
/// pairing master key (see CallAuthenticator / SignalingChannel). Keys:
///   * exist only in memory,
///   * are split per direction (no IV/counter collisions between peers),
///   * ratchet forward every [ratchetInterval] messages (old keys are
///     destroyed — compromise never decrypts earlier traffic),
///   * bind a monotonically increasing counter as AAD, so signaling
///     messages cannot be replayed or reordered undetected.
class SessionCrypto {
  SessionCrypto._({
    required Uint8List sendKey,
    required Uint8List receiveKey,
  })  : _sendKey = sendKey,
        _receiveKey = receiveKey;

  /// [isCaller] selects direction keys: the caller (owner) sends on the
  /// owner->monitor key, the monitor on the reverse key.
  static Future<SessionCrypto> establish({
    required SimpleKeyPair ourEphemeral,
    required Uint8List theirEphemeralPublicKey,
    required String sessionId,
    required bool isCaller,
  }) async {
    final secret =
        await CryptoEngine.sharedSecret(ourEphemeral, theirEphemeralPublicKey);
    final (ownerToMonitor, monitorToOwner) =
        await CryptoEngine.deriveSessionKeys(
      ephemeralSecret: secret,
      sessionId: sessionId,
    );
    secret.fillRange(0, secret.length, 0);
    return SessionCrypto._(
      sendKey: isCaller ? ownerToMonitor : monitorToOwner,
      receiveKey: isCaller ? monitorToOwner : ownerToMonitor,
    );
  }

  Uint8List _sendKey;
  Uint8List _receiveKey;
  int _sendCounter = 0;
  int _receiveCounter = 0;
  static const int ratchetInterval = 50;
  bool _destroyed = false;

  /// Encrypts one signaling message. Returns {c: counter, d: ciphertext}.
  Future<Map<String, dynamic>> encryptMessage(
    Map<String, dynamic> message,
  ) async {
    _ensureLive();
    final counter = _sendCounter++;
    final sealed = await CryptoEngine.encrypt(
      key: _sendKey,
      plaintext: utf8.encode(jsonEncode(message)),
      aad: utf8.encode('c:$counter'),
    );
    if (_sendCounter % ratchetInterval == 0) {
      final next = await CryptoEngine.ratchetKey(_sendKey);
      _sendKey.fillRange(0, _sendKey.length, 0);
      _sendKey = next;
    }
    return {'c': counter, 'd': sealed};
  }

  /// Decrypts one signaling message, enforcing strict counter ordering
  /// (replay / reorder rejection). Returns null for stale duplicates.
  Future<Map<String, dynamic>?> decryptMessage(
    Map<String, dynamic> envelope,
  ) async {
    _ensureLive();
    final counter = envelope['c'] as int;
    if (counter < _receiveCounter) return null; // replay — drop silently
    // Advance ratchet if the sender rotated between counters we missed.
    while (_receiveCounter < counter) {
      _receiveCounter++;
      if (_receiveCounter % ratchetInterval == 0) {
        await _ratchetReceive();
      }
    }
    final clear = await CryptoEngine.decrypt(
      key: _receiveKey,
      packedBase64: envelope['d'] as String,
      aad: utf8.encode('c:$counter'),
    );
    _receiveCounter = counter + 1;
    if (_receiveCounter % ratchetInterval == 0) {
      await _ratchetReceive();
    }
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  Future<void> _ratchetReceive() async {
    final next = await CryptoEngine.ratchetKey(_receiveKey);
    _receiveKey.fillRange(0, _receiveKey.length, 0);
    _receiveKey = next;
  }

  void _ensureLive() {
    if (_destroyed) {
      throw StateError('SessionCrypto used after destroy()');
    }
  }

  /// Zeroes all key material. MUST be called when the call ends (PFS).
  void destroy() {
    _sendKey.fillRange(0, _sendKey.length, 0);
    _receiveKey.fillRange(0, _receiveKey.length, 0);
    _destroyed = true;
  }
}
