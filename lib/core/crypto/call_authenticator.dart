import 'dart:convert';
import 'dart:typed_data';

import 'crypto_engine.dart';
import 'nonce_cache.dart';

/// The plaintext call-authentication payload. It is NEVER transmitted in
/// the clear: [CallAuthenticator.seal] encrypts it under the wake key
/// (derived from the pairing master key) before it goes to Firestore/FCM.
class CallAuthPayload {
  const CallAuthPayload({
    required this.sessionId,
    required this.deviceId,
    required this.ownerUid,
    required this.timestampMs,
    required this.nonce,
    required this.ephemeralPublicKey,
    required this.signature,
  });

  final String sessionId;
  final String deviceId;
  final String ownerUid;
  final int timestampMs;
  final String nonce;

  /// Caller's per-call ephemeral X25519 public key (base64) — the PFS root.
  final String ephemeralPublicKey;

  /// HMAC-SHA256(sessionId|timestamp|nonce|ephemeralPub, masterKey), base64.
  final String signature;

  Map<String, dynamic> toJson() => {
        'sid': sessionId,
        'did': deviceId,
        'uid': ownerUid,
        'ts': timestampMs,
        'n': nonce,
        'epk': ephemeralPublicKey,
        'sig': signature,
      };

  factory CallAuthPayload.fromJson(Map<String, dynamic> json) =>
      CallAuthPayload(
        sessionId: json['sid'] as String,
        deviceId: json['did'] as String,
        ownerUid: json['uid'] as String,
        timestampMs: json['ts'] as int,
        nonce: json['n'] as String,
        ephemeralPublicKey: json['epk'] as String,
        signature: json['sig'] as String,
      );
}

/// Why an incoming call was rejected. Only [accepted] may auto-answer.
enum CallAuthResult {
  accepted,
  expiredTimestamp,
  replayedNonce,
  invalidSignature,
  wrongDevice,
  unknownOwner,
  malformed,
}

/// Builds and verifies the authenticated wake payload that gates
/// automatic call acceptance on the monitor.
class CallAuthenticator {
  CallAuthenticator({
    NonceCache? nonceCache,
    this.maxClockSkew = const Duration(seconds: 90),
  }) : _nonceCache = nonceCache ?? NonceCache();

  final NonceCache _nonceCache;

  /// Requests outside now +/- [maxClockSkew] are rejected as expired.
  final Duration maxClockSkew;

  static String _signedMessage(
    String sessionId,
    int timestampMs,
    String nonce,
    String ephemeralPublicKey,
  ) =>
      '$sessionId|$timestampMs|$nonce|$ephemeralPublicKey';

  // -------------------------------------------------------------------
  // Owner side
  // -------------------------------------------------------------------

  /// Creates and encrypts a call-auth payload. Returns the base64
  /// AES-256-GCM ciphertext safe to place in Firestore / an FCM data
  /// message, plus the plaintext payload for local session bookkeeping.
  Future<(String sealed, CallAuthPayload payload)> seal({
    required Uint8List masterKey,
    required String sessionId,
    required String deviceId,
    required String ownerUid,
    required String ephemeralPublicKey,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    final nonce = CryptoEngine.randomId(16);
    final signature = await CryptoEngine.hmac(
      masterKey,
      _signedMessage(sessionId, ts, nonce, ephemeralPublicKey),
    );
    final payload = CallAuthPayload(
      sessionId: sessionId,
      deviceId: deviceId,
      ownerUid: ownerUid,
      timestampMs: ts,
      nonce: nonce,
      ephemeralPublicKey: ephemeralPublicKey,
      signature: signature,
    );
    final wakeKey = await CryptoEngine.deriveWakeKey(masterKey);
    final sealed = await CryptoEngine.encrypt(
      key: wakeKey,
      plaintext: utf8.encode(jsonEncode(payload.toJson())),
      aad: utf8.encode(sessionId),
    );
    return (sealed, payload);
  }

  // -------------------------------------------------------------------
  // Monitor side
  // -------------------------------------------------------------------

  /// Decrypts and fully validates a sealed payload. Every check in the
  /// spec is enforced: decryption (owner identity — only the paired owner
  /// holds the master key), timestamp window, nonce freshness, signature,
  /// session id binding (AAD), and target device id.
  Future<(CallAuthResult, CallAuthPayload?)> verify({
    required Uint8List masterKey,
    required String sealedPayload,
    required String sessionId,
    required String expectedDeviceId,
    required String expectedOwnerUid,
    DateTime? now,
  }) async {
    final CallAuthPayload payload;
    try {
      final wakeKey = await CryptoEngine.deriveWakeKey(masterKey);
      final clear = await CryptoEngine.decrypt(
        key: wakeKey,
        packedBase64: sealedPayload,
        aad: utf8.encode(sessionId),
      );
      payload = CallAuthPayload.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } catch (_) {
      // Wrong key, tampering, or garbage — treat identically (no oracle).
      return (CallAuthResult.malformed, null);
    }

    if (payload.deviceId != expectedDeviceId) {
      return (CallAuthResult.wrongDevice, null);
    }
    if (payload.ownerUid != expectedOwnerUid) {
      return (CallAuthResult.unknownOwner, null);
    }
    if (payload.sessionId != sessionId) {
      return (CallAuthResult.invalidSignature, null);
    }

    final clock = now ?? DateTime.now().toUtc();
    final skew = (clock.millisecondsSinceEpoch - payload.timestampMs).abs();
    if (skew > maxClockSkew.inMilliseconds) {
      return (CallAuthResult.expiredTimestamp, null);
    }

    final expected = await CryptoEngine.hmac(
      masterKey,
      _signedMessage(
        payload.sessionId,
        payload.timestampMs,
        payload.nonce,
        payload.ephemeralPublicKey,
      ),
    );
    if (!CryptoEngine.constantTimeEquals(expected, payload.signature)) {
      return (CallAuthResult.invalidSignature, null);
    }

    // Nonce check LAST so a rejected request cannot poison the cache.
    if (!await _nonceCache.checkAndStore(payload.nonce, clock)) {
      return (CallAuthResult.replayedNonce, null);
    }

    return (CallAuthResult.accepted, payload);
  }
}
