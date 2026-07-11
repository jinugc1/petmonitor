import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/key_store.dart';
import '../../core/firebase/firestore_paths.dart';
import '../../core/utils/secure_logger.dart';

/// Secure pairing handshake.
///
/// Trust model: Firestore only relays public keys — the QR code carries a
/// random secret over the *visual* channel (owner's screen -> monitor's
/// camera). The pairing master key is
/// HKDF(X25519(privA, pubB), salt = qrSecret), so an attacker who fully
/// controls Firestore still cannot derive it or forge the confirmation
/// tag. Neither the qrSecret, the master key, nor any private key is ever
/// transmitted or stored server-side.
///
/// Flow:
///  1. Owner: keypair + qrSecret + pairing doc {ownerPub}; shows QR.
///  2. Monitor scans QR, makes its keypair + deviceId, derives masterKey,
///     writes {monitorPub, deviceId, confirmTag} + the device document.
///  3. Owner derives the same masterKey, verifies confirmTag, stores the
///     key, marks the pairing confirmed.
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

  // -------------------------------------------------------------------
  // Owner side
  // -------------------------------------------------------------------

  /// Creates a pairing session; returns the QR payload to render and a
  /// future resolving to the new deviceId once the monitor confirms.
  Future<OwnerPairingSession> startOwnerPairing(String ownerUid) async {
    final pairingId = CryptoEngine.randomId();
    final keyPair = await CryptoEngine.generateKeyPair();
    final ownerPub = base64Encode(await CryptoEngine.publicKeyBytes(keyPair));
    final qrSecret = CryptoEngine.randomBytes(16);

    await firestore.doc(FirestorePaths.pairing(pairingId)).set({
      'ownerUid': ownerUid,
      'ownerPub': ownerPub,
      'status': 'waiting',
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(pairingTtl)),
    });

    final qrPayload = jsonEncode({
      'v': 1,
      'pid': pairingId,
      'uid': ownerUid,
      'opk': ownerPub,
      'sec': base64Encode(qrSecret), // NEVER written to Firestore
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
        final masterKey = await CryptoEngine.derivePairingMasterKey(
          ecdhSecret: secret,
          qrSecret: qrSecret,
        );
        final expectedTag = await CryptoEngine.hmac(
          masterKey,
          _confirmMessage(pairingId, monitorPub, deviceId),
        );
        if (!CryptoEngine.constantTimeEquals(expectedTag, confirmTag)) {
          _log.warn('pairing confirm tag mismatch — rejecting');
          await snap.reference.update({'status': 'failed'});
          if (!completer.isCompleted) {
            completer.completeError(const PairingException('tag mismatch'));
          }
          return;
        }
        await keyStore.saveMasterKey(deviceId, masterKey);
        await snap.reference.update({'status': 'confirmed'});
        if (!completer.isCompleted) completer.complete(deviceId);
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(PairingException('$e'));
        }
      } finally {
        if (completer.isCompleted) await sub.cancel();
      }
    });

    return OwnerPairingSession(
      pairingId: pairingId,
      qrPayload: qrPayload,
      pairedDeviceId: completer.future.timeout(pairingTtl),
      cancel: () async {
        await sub.cancel();
        await firestore.doc(FirestorePaths.pairing(pairingId)).delete();
      },
    );
  }

  // -------------------------------------------------------------------
  // Monitor side
  // -------------------------------------------------------------------

  /// Completes pairing from a scanned QR payload. Returns the permanent
  /// device id. The signed-in uid must match the QR's owner uid.
  Future<String> completeMonitorPairing({
    required String scannedQr,
    required String signedInUid,
    required String deviceName,
    String? fcmToken,
  }) async {
    final Map<String, dynamic> qr;
    try {
      qr = jsonDecode(scannedQr) as Map<String, dynamic>;
      if (qr['v'] != 1) throw const FormatException('unsupported version');
    } catch (_) {
      throw const PairingException('Not a valid PetMonitor pairing code');
    }

    final pairingId = qr['pid'] as String;
    final ownerUid = qr['uid'] as String;
    final ownerPub = base64Decode(qr['opk'] as String);
    final qrSecret = base64Decode(qr['sec'] as String);

    if (ownerUid != signedInUid) {
      throw const PairingException(
        'Sign in with the same account on both devices before pairing',
      );
    }

    final keyPair = await CryptoEngine.generateKeyPair();
    final monitorPub = base64Encode(await CryptoEngine.publicKeyBytes(keyPair));
    final deviceId = CryptoEngine.randomId();

    final secret = await CryptoEngine.sharedSecret(keyPair, ownerPub);
    final masterKey = await CryptoEngine.derivePairingMasterKey(
      ecdhSecret: secret,
      qrSecret: qrSecret,
    );
    final confirmTag = await CryptoEngine.hmac(
      masterKey,
      _confirmMessage(pairingId, monitorPub, deviceId),
    );

    // Register the device, then claim the pairing.
    final batch = firestore.batch()
      ..set(firestore.doc(FirestorePaths.device(deviceId)), {
        'ownerUid': ownerUid,
        'name': deviceName,
        'publicKey': monitorPub,
        if (fcmToken != null) 'fcmToken': fcmToken,
        'status': {'online': true},
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..update(firestore.doc(FirestorePaths.pairing(pairingId)), {
        'status': 'claimed',
        'monitorPub': monitorPub,
        'deviceId': deviceId,
        'confirmTag': confirmTag,
      });
    await batch.commit();

    // Wait for the owner to verify our tag and confirm.
    final confirmed = await firestore
        .doc(FirestorePaths.pairing(pairingId))
        .snapshots()
        .map((s) => s.data()?['status'] as String?)
        .firstWhere((s) => s == 'confirmed' || s == 'failed')
        .timeout(pairingTtl);

    if (confirmed != 'confirmed') {
      await firestore.doc(FirestorePaths.device(deviceId)).delete();
      throw const PairingException('Owner rejected the pairing');
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
    required this.qrPayload,
    required this.pairedDeviceId,
    required this.cancel,
  });

  final String pairingId;
  final String qrPayload;
  final Future<String> pairedDeviceId;
  final Future<void> Function() cancel;
}

class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
  @override
  String toString() => 'PairingException: $message';
}
