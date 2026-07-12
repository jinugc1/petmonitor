import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/key_store.dart';
import '../../core/providers.dart';

final keySyncServiceProvider = Provider<KeySyncService>(
  (ref) => KeySyncService(
    firestore: ref.watch(firestoreProvider),
    keyStore: ref.watch(keyStoreProvider),
  ),
);

/// End-to-end encrypted cloud backup of monitor pairing keys, so signing
/// in on ANY device (new browser, new phone) + one sync passphrase makes
/// it call-capable — no other device needed at that moment.
///
/// users/{uid}/keysync/{deviceId} holds AES-256-GCM(masterKey) under a
/// key derived from the passphrase with PBKDF2 (200k rounds, per-account
/// salt). The server never sees the passphrase or a decryptable key; an
/// attacker with full Firestore access must brute-force the passphrase.
/// Devices that enabled sync keep the derived wrap key in secure
/// storage so newly paired monitors are backed up automatically.
class KeySyncService {
  KeySyncService({
    required this.firestore,
    required this.keyStore,
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FirebaseFirestore firestore;
  final KeyStore keyStore;
  final FlutterSecureStorage _storage;

  static const String _wrapKeyKey = 'pm.sync.wrapKey';
  static const String _wrapUidKey = 'pm.sync.uid';

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      firestore.collection('users/$uid/keysync');

  /// Sync is active on this device (wrap key cached locally).
  Future<bool> get isEnabledHere async =>
      (await _storage.read(key: _wrapKeyKey)) != null;

  /// Forgets the cached wrap key (call on sign-out — the key derivation
  /// is salted per account, so it must never leak across accounts).
  Future<void> forgetLocal() async {
    await _storage.delete(key: _wrapKeyKey);
    await _storage.delete(key: _wrapUidKey);
  }

  /// Any backups exist in the cloud for this account.
  Future<bool> hasCloudBackups(String uid) async =>
      (await _col(uid).limit(1).get()).docs.isNotEmpty;

  Future<Uint8List?> _localWrapKey() async {
    final raw = await _storage.read(key: _wrapKeyKey);
    return raw == null ? null : base64Decode(raw);
  }

  /// Turns sync on from a device that holds keys: derives the wrap key,
  /// caches it, and backs up every locally held monitor key.
  /// Returns the number of keys backed up.
  Future<int> enable({
    required String ownerUid,
    required String passphrase,
    required List<String> deviceIds,
  }) async {
    if (passphrase.trim().length < 8) {
      throw const KeySyncException(
        'Use a sync passphrase of at least 8 characters.',
      );
    }
    final wrapKey = await CryptoEngine.deriveSyncWrapKey(
      passphrase: passphrase,
      ownerUid: ownerUid,
    );
    await _storage.write(key: _wrapKeyKey, value: base64Encode(wrapKey));
    await _storage.write(key: _wrapUidKey, value: ownerUid);

    var count = 0;
    for (final deviceId in deviceIds) {
      if (await _backup(ownerUid, deviceId, wrapKey)) count++;
    }
    return count;
  }

  /// Backs up one device's key if sync is enabled here (used after a
  /// pairing or a PIN redeem). Silently does nothing otherwise, and
  /// refuses to use a wrap key cached under a different account.
  Future<void> backupDevice(String ownerUid, String deviceId) async {
    if (await _storage.read(key: _wrapUidKey) != ownerUid) return;
    final wrapKey = await _localWrapKey();
    if (wrapKey == null) return;
    await _backup(ownerUid, deviceId, wrapKey);
  }

  /// Deletes one device's backup (call on unpair / remove monitor).
  Future<void> deleteBackup(String ownerUid, String deviceId) async {
    try {
      await _col(ownerUid).doc(deviceId).delete();
    } catch (_) {}
  }

  Future<bool> _backup(
    String ownerUid,
    String deviceId,
    Uint8List wrapKey,
  ) async {
    final masterKey = await keyStore.readMasterKey(deviceId);
    if (masterKey == null) return false;
    final sealed = await CryptoEngine.encrypt(
      key: wrapKey,
      plaintext: masterKey,
      aad: utf8.encode(deviceId),
    );
    await _col(ownerUid).doc(deviceId).set({
      'v': 1,
      'ct': sealed,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return true;
  }

  /// Restores backed-up keys onto THIS device using the passphrase.
  /// Only keys for monitors that still exist count (stale entries from
  /// old pairings are purged), so the reported number always reflects
  /// monitors that genuinely became callable. Also caches the wrap key
  /// so this device keeps future backups fresh.
  Future<int> restore({
    required String ownerUid,
    required String passphrase,
  }) async {
    final snap = await _col(ownerUid).get();
    if (snap.docs.isEmpty) {
      throw const KeySyncException(
        'No cloud backups yet. On a device that can call, open '
        'Settings and enable key sync first.',
      );
    }

    // Backups are keyed by deviceId; every unpair/re-pair mints a new
    // id, so entries for vanished devices are useless — drop them.
    final devices = await firestore
        .collection('devices')
        .where('ownerUid', isEqualTo: ownerUid)
        .get();
    final liveDeviceIds = devices.docs.map((d) => d.id).toSet();

    final wrapKey = await CryptoEngine.deriveSyncWrapKey(
      passphrase: passphrase,
      ownerUid: ownerUid,
    );
    var restored = 0;
    var attempted = 0;
    for (final doc in snap.docs) {
      if (!liveDeviceIds.contains(doc.id)) {
        try {
          await doc.reference.delete(); // stale — purge
        } catch (_) {}
        continue;
      }
      attempted++;
      try {
        final masterKey = await CryptoEngine.decrypt(
          key: wrapKey,
          packedBase64: doc.data()['ct'] as String,
          aad: utf8.encode(doc.id),
        );
        await keyStore.saveMasterKey(doc.id, masterKey);
        restored++;
      } catch (_) {
        // Wrong passphrase fails GCM authentication.
      }
    }

    if (attempted == 0) {
      throw const KeySyncException(
        'The backups were for old pairings and have been cleaned up. '
        'On the device that can currently call, open Settings and tap '
        'Enable / back up again.',
      );
    }
    if (restored == 0) {
      throw const KeySyncException('Wrong passphrase — try again.');
    }
    await _storage.write(key: _wrapKeyKey, value: base64Encode(wrapKey));
    await _storage.write(key: _wrapUidKey, value: ownerUid);
    return restored;
  }

  /// Removes all cloud backups and forgets the wrap key on this device.
  Future<void> disable(String ownerUid) async {
    final snap = await _col(ownerUid).get();
    for (final doc in snap.docs) {
      await doc.reference.delete();
    }
    await forgetLocal();
  }
}

class KeySyncException implements Exception {
  const KeySyncException(this.message);
  final String message;
  @override
  String toString() => message;
}
