import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Low-level cryptographic primitives for PetMonitor.
///
/// Protocol summary (see docs/SECURITY.md for the full design):
///
///  * Pairing        : X25519 ECDH + out-of-band QR code secret -> HKDF ->
///                      256-bit pairing master key. The QR secret never
///                      touches Firestore, so the server can never derive
///                      the master key (zero-knowledge server).
///  * Call auth      : HMAC-SHA256(sessionId | timestamp | nonce | ephPub,
///                      masterKey) with timestamp window + persistent nonce
///                      cache for replay protection.
///  * Session keys   : fresh ephemeral X25519 per call, authenticated by the
///                      master key -> Perfect Forward Secrecy. HKDF splits
///                      the shared secret into two direction keys.
///  * Signaling      : AES-256-GCM, random 96-bit IV per message, message
///                      counter bound as AAD, forward key ratchet.
///  * Media          : WebRTC DTLS-SRTP; certificate fingerprints travel
///                      only inside encrypted signaling, preventing MITM.
class CryptoEngine {
  CryptoEngine._();

  static final X25519 _x25519 = X25519();
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Hmac _hmacSha256 = Hmac.sha256();

  static const String _pairingInfo = 'petmonitor/pairing/v1';
  static const String _wakeInfo = 'petmonitor/wake/v1';
  static const String _sessionInfo = 'petmonitor/session/v1';
  static const String _ratchetInfo = 'petmonitor/ratchet/v1';

  // ---------------------------------------------------------------------
  // Random
  // ---------------------------------------------------------------------

  /// Cryptographically secure random bytes.
  static Uint8List randomBytes(int length) {
    final bytes = SecretKeyData.random(length: length).bytes;
    return Uint8List.fromList(bytes);
  }

  /// URL-safe random identifier (nonces, session ids, pairing ids).
  static String randomId([int byteLength = 16]) =>
      base64UrlEncode(randomBytes(byteLength)).replaceAll('=', '');

  // ---------------------------------------------------------------------
  // X25519
  // ---------------------------------------------------------------------

  static Future<SimpleKeyPair> generateKeyPair() => _x25519.newKeyPair();

  static Future<Uint8List> publicKeyBytes(SimpleKeyPair pair) async {
    final pub = await pair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  static Future<Uint8List> sharedSecret(
    SimpleKeyPair ourPair,
    Uint8List theirPublicKey,
  ) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: ourPair,
      remotePublicKey:
          SimplePublicKey(theirPublicKey, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  // ---------------------------------------------------------------------
  // HKDF derivations
  // ---------------------------------------------------------------------

  static Future<Uint8List> _hkdf({
    required List<int> ikm,
    required List<int> salt,
    required String info,
    required int length,
  }) async {
    final hkdf = Hkdf(hmac: _hmacSha256, outputLength: length);
    final out = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  /// Pairing master key. `qrSecret` is the out-of-band secret from the QR
  /// code — without it the ECDH output alone is insufficient, defeating a
  /// signaling-channel MITM.
  static Future<Uint8List> derivePairingMasterKey({
    required Uint8List ecdhSecret,
    required Uint8List qrSecret,
  }) =>
      _hkdf(ikm: ecdhSecret, salt: qrSecret, info: _pairingInfo, length: 32);

  /// Key used to encrypt the call-authentication (wake) payload.
  static Future<Uint8List> deriveWakeKey(Uint8List masterKey) =>
      _hkdf(ikm: masterKey, salt: const [], info: _wakeInfo, length: 32);

  /// Splits a per-call ephemeral ECDH secret into two 256-bit direction
  /// keys: bytes 0..31 owner->monitor, 32..63 monitor->owner.
  static Future<(Uint8List, Uint8List)> deriveSessionKeys({
    required Uint8List ephemeralSecret,
    required String sessionId,
  }) async {
    final okm = await _hkdf(
      ikm: ephemeralSecret,
      salt: utf8.encode(sessionId),
      info: _sessionInfo,
      length: 64,
    );
    return (okm.sublist(0, 32), okm.sublist(32, 64));
  }

  /// Forward ratchet: derives the next signaling key from the current one.
  /// The previous key is discarded, giving intra-session forward secrecy.
  static Future<Uint8List> ratchetKey(Uint8List currentKey) =>
      _hkdf(ikm: currentKey, salt: const [], info: _ratchetInfo, length: 32);

  // ---------------------------------------------------------------------
  // AES-256-GCM
  // ---------------------------------------------------------------------

  /// Encrypts [plaintext]; returns iv(12) | ciphertext | tag(16) base64.
  static Future<String> encrypt({
    required Uint8List key,
    required List<int> plaintext,
    List<int> aad = const [],
  }) async {
    final iv = randomBytes(12);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: iv,
      aad: aad,
    );
    final packed = Uint8List.fromList(
      [...iv, ...box.cipherText, ...box.mac.bytes],
    );
    return base64Encode(packed);
  }

  /// Decrypts output of [encrypt]. Throws [SecretBoxAuthenticationError]
  /// on tampering or wrong key/AAD.
  static Future<Uint8List> decrypt({
    required Uint8List key,
    required String packedBase64,
    List<int> aad = const [],
  }) async {
    final packed = base64Decode(packedBase64);
    if (packed.length < 12 + 16) {
      throw const FormatException('ciphertext too short');
    }
    final box = SecretBox(
      packed.sublist(12, packed.length - 16),
      nonce: packed.sublist(0, 12),
      mac: Mac(packed.sublist(packed.length - 16)),
    );
    final clear = await _aesGcm.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  }

  // ---------------------------------------------------------------------
  // HMAC-SHA256
  // ---------------------------------------------------------------------

  static Future<String> hmac(Uint8List key, String message) async {
    final mac = await _hmacSha256.calculateMac(
      utf8.encode(message),
      secretKey: SecretKey(key),
    );
    return base64Encode(mac.bytes);
  }

  /// Constant-time comparison to prevent timing attacks.
  static bool constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ab.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ab.length; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}
