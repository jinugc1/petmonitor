import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/key_store.dart';
import '../../core/providers.dart';
import '../../core/utils/secure_logger.dart';

final accessGrantServiceProvider = Provider<AccessGrantService>(
  (ref) => AccessGrantService(
    firestore: ref.watch(firestoreProvider),
    keyStore: ref.watch(keyStoreProvider),
  ),
);

/// PIN-based transfer of a monitor's pairing key between the owner's OWN
/// devices (e.g. iPhone -> Windows PC), replacing the QR flow so that
/// camera-less devices can receive access.
///
/// Protocol (users/{uid}/grants/active, TTL 5 min):
///  1. Source (holds key): ephemeral X25519 keypair + 6-char PIN; writes
///     {grantId, deviceId, srcPub, status: waiting}. Shows the PIN.
///  2. Receiver: enters PIN; writes its own ephemeral rcvPub (claimed).
///  3. Source: K = HKDF(X25519(src, rcv), salt = PBKDF2(PIN, grantId));
///     writes AES-256-GCM(masterKey) under K (delivered).
///  4. Receiver derives the same K, decrypts, stores the key (done);
///     the grant document is deleted.
///
/// Firestore only ever carries public keys and ciphertext. A passive
/// server-side observer lacks both ephemeral private keys; an active
/// MITM must defeat 150k-round PBKDF2 over the PIN inside the 5-minute
/// window. Rules additionally restrict the document to the signed-in
/// owner.
class AccessGrantService {
  AccessGrantService({required this.firestore, required this.keyStore});

  final FirebaseFirestore firestore;
  final KeyStore keyStore;
  final _log = SecureLogger('access-grant');

  static const Duration ttl = Duration(minutes: 5);

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      firestore.doc('users/$uid/grants/active');

  // -------------------------------------------------------------------
  // Source side (device that can already call)
  // -------------------------------------------------------------------

  Future<ShareGrantSession> startSharing({
    required String ownerUid,
    required String deviceId,
  }) async {
    final masterKey = await keyStore.readMasterKey(deviceId);
    if (masterKey == null) {
      throw StateError('this device does not hold the key for $deviceId');
    }

    final pin = CryptoEngine.randomPin();
    final grantId = CryptoEngine.randomId(8);
    final keyPair = await CryptoEngine.generateKeyPair();
    final srcPub = base64Encode(await CryptoEngine.publicKeyBytes(keyPair));

    await _doc(ownerUid).set({
      'grantId': grantId,
      'deviceId': deviceId,
      'srcPub': srcPub,
      'status': 'waiting',
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(ttl)),
    });

    final completer = Completer<void>();
    late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
    sub = _doc(ownerUid).snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null || data['grantId'] != grantId) return;
      try {
        if (data['status'] == 'claimed' && data['sealed'] == null) {
          final rcvPub = base64Decode(data['rcvPub'] as String);
          final secret = await CryptoEngine.sharedSecret(keyPair, rcvPub);
          final k = await CryptoEngine.deriveAccessKey(
            ecdhSecret: secret,
            pin: pin,
            grantId: grantId,
          );
          final sealed = await CryptoEngine.encrypt(
            key: k,
            plaintext: utf8.encode(
              jsonEncode({
                'did': deviceId,
                'key': base64Encode(masterKey),
              }),
            ),
            aad: utf8.encode(grantId),
          );
          await snap.reference.update({
            'sealed': sealed,
            'status': 'delivered',
          });
        } else if (data['status'] == 'done') {
          await snap.reference.delete();
          if (!completer.isCompleted) completer.complete();
          await sub.cancel();
        }
      } catch (e) {
        _log.error('grant sharing failed', e);
        if (!completer.isCompleted) completer.completeError(e);
        await sub.cancel();
      }
    });

    return ShareGrantSession(
      pin: pin,
      completed: completer.future.timeout(ttl),
      cancel: () async {
        await sub.cancel();
        try {
          await _doc(ownerUid).delete();
        } catch (_) {}
      },
    );
  }

  // -------------------------------------------------------------------
  // Receiver side (device that wants to call)
  // -------------------------------------------------------------------

  /// Redeems a PIN; returns the deviceId now callable from this device.
  Future<String> redeemPin({
    required String ownerUid,
    required String pin,
  }) async {
    final snap = await _doc(ownerUid).get();
    final data = snap.data();
    if (data == null || data['status'] != 'waiting') {
      throw const AccessGrantException(
        'No active share found. On the device that can call, choose '
        '"Share call access" first.',
      );
    }
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    if (expiresAt == null || DateTime.now().isAfter(expiresAt)) {
      throw const AccessGrantException('That share expired — start again.');
    }

    final grantId = data['grantId'] as String;
    final deviceId = data['deviceId'] as String;
    final srcPub = base64Decode(data['srcPub'] as String);

    final keyPair = await CryptoEngine.generateKeyPair();
    await snap.reference.update({
      'rcvPub': base64Encode(await CryptoEngine.publicKeyBytes(keyPair)),
      'status': 'claimed',
    });

    final sealed = await snap.reference
        .snapshots()
        .map((s) => s.data()?['sealed'] as String?)
        .firstWhere((s) => s != null)
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw const AccessGrantException(
            'The sharing device did not respond — keep its screen on '
            'and try again.',
          ),
        );

    final secret = await CryptoEngine.sharedSecret(keyPair, srcPub);
    final k = await CryptoEngine.deriveAccessKey(
      ecdhSecret: secret,
      pin: pin,
      grantId: grantId,
    );
    final Map<String, dynamic> clear;
    try {
      final bytes = await CryptoEngine.decrypt(
        key: k,
        packedBase64: sealed!,
        aad: utf8.encode(grantId),
      );
      clear = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const AccessGrantException('Wrong PIN — check and try again.');
    }
    if (clear['did'] != deviceId) {
      throw const AccessGrantException('Share mismatch — start again.');
    }

    await keyStore.saveMasterKey(
      deviceId,
      base64Decode(clear['key'] as String),
    );
    await snap.reference.update({'status': 'done'});
    return deviceId;
  }
}

class ShareGrantSession {
  const ShareGrantSession({
    required this.pin,
    required this.completed,
    required this.cancel,
  });

  final String pin;
  final Future<void> completed;
  final Future<void> Function() cancel;
}

class AccessGrantException implements Exception {
  const AccessGrantException(this.message);
  final String message;
  @override
  String toString() => message;
}
