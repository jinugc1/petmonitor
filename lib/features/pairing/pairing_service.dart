import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/key_store.dart';
import '../../core/firebase/firestore_paths.dart';
import '../../core/utils/secure_logger.dart';

/// Secure PIN-based pairing handshake.
///
/// Trust model: Firestore only relays public keys — the PIN travels over
/// the *human* channel (read off the owner's screen, typed on the
/// monitor). The pairing master key is
/// HKDF(X25519(privA, pubB), salt = PBKDF2(PIN)), so an attacker who
/// fully controls Firestore still cannot derive it passively (no private
/// keys), and an active MITM must brute-force the 6-char PIN against
/// 150k-round PBKDF2 inside the 5-minute pairing window. Neither the
/// PIN, the master key, nor any private key is ever stored server-side.
///
/// Flow:
///  1. Owner: keypair + PIN + pairing doc {ownerPub}; shows the PIN.
///  2. Monitor (same signed-in account) enters the PIN, finds the open
///     pairing doc, makes its keypair + deviceId, derives masterKey,
///     writes {monitorPub, deviceId, confirmTag} + the device document.
///  3. Owner derives the same masterKey, verifies confirmTag (proves the
///     monitor knew the PIN), stores the key, marks it confirmed.
///  4. Monitor sees 'confirmed', stores its key + permanent identity.
class PairingService {
  PairingService({required this.firestore, required this.keyStore});

  final FirebaseFirestore firestore;
  final KeyStore keyStore;
  final _log = SecureLogger('pairing');

  static const Duration pairingTtl = Duration(minutes: 5);

  static String _confirmMessage(
    String pairingId,
    String monitorPub,
    String deviceId,
  ) =>
      'confirm|$pairingId|$monitorPub|$deviceId';

  /// Domain-separated key derivation for pairing (distinct from access
  /// grants even with an identical PIN).
  static Future<Uint8List> _deriveKey({
    required Uint8List ecdhSecret,
    required String pin,
    required String pairingId,
  }) =>
      CryptoEngine.deriveAccessKey(
        ecdhSecret: ecdhSecret,
        pin: pin,
        grantId: 'pairing|$pairingId',
      );

  // -------------------------------------------------------------------
  // Owner side
  // -------------------------------------------------------------------

  /// Creates a pairing session; returns the PIN to display and a future
  /// resolving to the new deviceId once the monitor confirms.
  Future<OwnerPairingSession> startOwnerPairing(String ownerUid) async {
    final pairingId = CryptoEngine.randomId();
    final keyPair = await CryptoEngine.generateKeyPair();
    final ownerPub = base64Encode(await CryptoEngine.publicKeyBytes(keyPair));
    final pin = CryptoEngine.randomPin();

    await firestore.doc(FirestorePaths.pairing(pairingId)).set({
      'ownerUid': ownerUid,
      'ownerPub': ownerPub,
      'status': 'waiting',
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(pairingTtl)),
    });

    final completer = Completer<String>();
    late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
    sub = firestore
        .doc(FirestorePaths.pairing(pairingId))
        .snapshots()
        .listen((snap) async {
      final data = snap.data();
      if (data == null || data['status'] != 'claimed') return;
      try {
        final monitorPub = data['monitorPub'] as String;
        final deviceId = data['deviceId'] as String;
        final confirmTag = data['confirmTag'] as String;

        final secret = await CryptoEngine.sharedSecret(
          keyPair,
          base64Decode(monitorPub),
        );
        final masterKey = await _deriveKey(
          ecdhSecret: secret,
          pin: pin,
          pairingId: pairingId,
        );
        final expectedTag = await CryptoEngine.hmac(
          masterKey,
          _confirmMessage(pairingId, monitorPub, deviceId),
        );
        if (!CryptoEngine.constantTimeEquals(expectedTag, confirmTag)) {
          _log.warn('pairing confirm tag mismatch — rejecting');
          await snap.reference.update({'status': 'failed'});
          // Keep listening: the monitor may retry with the correct PIN
          // by claiming again within the TTL. (Each wrong attempt costs
          // the attacker one full round trip.)
          await snap.reference.update({'status': 'waiting'});
          return;
        }
        await keyStore.saveMasterKey(deviceId, masterKey);
        await snap.reference.update({'status': 'confirmed'});
        if (!completer.isCompleted) completer.complete(deviceId);
        await sub.cancel();
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(PairingException('$e'));
        }
        await sub.cancel();
      }
    });

    return OwnerPairingSession(
      pairingId: pairingId,
      pin: pin,
      pairedDeviceId: completer.future.timeout(pairingTtl),
      cancel: () async {
        await sub.cancel();
        try {
          await firestore.doc(FirestorePaths.pairing(pairingId)).delete();
        } catch (_) {}
      },
    );
  }

  // -------------------------------------------------------------------
  // Monitor side
  // -------------------------------------------------------------------

  /// Completes pairing from the typed PIN. The monitor must be signed in
  /// with the same account that opened the pairing. Returns the
  /// permanent device id.
  Future<String> completeMonitorPairing({
    required String pin,
    required String signedInUid,
    required String deviceName,
    String? fcmToken,
  }) async {
    // Find the open pairing for this account (rules restrict reads to
    // the owner, and both devices share the account).
    final open = await firestore
        .collection(FirestorePaths.pairings)
        .where('ownerUid', isEqualTo: signedInUid)
        .where('status', isEqualTo: 'waiting')
        .limit(1)
        .get();
    if (open.docs.isEmpty) {
      throw const PairingException(
        'No pairing in progress. On your phone, tap "Add monitor" first, '
        'then enter the PIN it shows.',
      );
    }
    final pairingDoc = open.docs.first;
    final data = pairingDoc.data();
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    if (expiresAt == null || DateTime.now().isAfter(expiresAt)) {
      throw const PairingException('That pairing expired — start again.');
    }

    final pairingId = pairingDoc.id;
    final ownerPub = base64Decode(data['ownerPub'] as String);

    final keyPair = await CryptoEngine.generateKeyPair();
    final monitorPub = base64Encode(await CryptoEngine.publicKeyBytes(keyPair));
    final deviceId = CryptoEngine.randomId();

    final secret = await CryptoEngine.sharedSecret(keyPair, ownerPub);
    final masterKey = await _deriveKey(
      ecdhSecret: secret,
      pin: pin,
      pairingId: pairingId,
    );
    final confirmTag = await CryptoEngine.hmac(
      masterKey,
      _confirmMessage(pairingId, monitorPub, deviceId),
    );

    // Register the device, then claim the pairing.
    final batch = firestore.batch()
      ..set(firestore.doc(FirestorePaths.device(deviceId)), {
        'ownerUid': signedInUid,
        'name': deviceName,
        'publicKey': monitorPub,
        if (fcmToken != null) 'fcmToken': fcmToken,
        'status': {'online': true},
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..update(pairingDoc.reference, {
        'status': 'claimed',
        'monitorPub': monitorPub,
        'deviceId': deviceId,
        'confirmTag': confirmTag,
      });
    await batch.commit();

    // Wait for the owner to verify our tag and confirm.
    final result = await pairingDoc.reference
        .snapshots()
        .map((s) => s.data()?['status'] as String?)
        .firstWhere((s) => s == 'confirmed' || s == 'failed' || s == 'waiting')
        .timeout(pairingTtl, onTimeout: () => 'failed');

    if (result != 'confirmed') {
      // Clean up the provisional device registration.
      try {
        await firestore.doc(FirestorePaths.device(deviceId)).delete();
      } catch (_) {}
      throw const PairingException('Wrong PIN — check it and try again.');
    }

    await keyStore.saveMasterKey(deviceId, masterKey);
    await keyStore.saveLocalDeviceId(deviceId);
    _log.info('pairing complete');
    return deviceId;
  }
}

class OwnerPairingSession {
  const OwnerPairingSession({
    required this.pairingId,
    required this.pin,
    required this.pairedDeviceId,
    required this.cancel,
  });

  final String pairingId;
  final String pin;
  final Future<String> pairedDeviceId;
  final Future<void> Function() cancel;
}

class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
  @override
  String toString() => 'PairingException: $message';
}
