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

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      firestore.collection('users/$uid/keysync');

  /// Sync is active on this device (wrap key cached locally).
  Future<bool> get isEnabledHere async =>
      (await _storage.read(key: _wrapKeyKey)) != null;

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

    var count = 0;
    for (final deviceId in deviceIds) {
      if (await _backup(ownerUid, deviceId, wrapKey)) count++;
    }
    return count;
  }

  /// Backs up one device's key if sync is enabled here (used after a
  /// pairing or a PIN redeem). Silently does nothing otherwise.
  Future<void> backupDevice(String ownerUid, String deviceId) async {
    final wrapKey = await _localWrapKey();
    if (wrapKey == null) return;
    await _backup(ownerUid, deviceId, wrapKey);
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

  /// Restores every backed-up key onto THIS device using the passphrase.
  /// Also caches the wrap key so this device keeps future backups fresh.
  /// Returns the number of keys restored.
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
    final wrapKey = await CryptoEngine.deriveSyncWrapKey(
      passphrase: passphrase,
      ownerUid: ownerUid,
    );
    var restored = 0;
    for (final doc in snap.docs) {
      try {
        final masterKey = await CryptoEngine.decrypt(
          key: wrapKey,
          packedBase64: doc.data()['ct'] as String,
          aad: utf8.encode(doc.id),
        );
        await keyStore.saveMasterKey(doc.id, masterKey);
        restored++;
      } catch (_) {
        // Wrong passphrase fails GCM authentication on every entry.
      }
    }
    if (restored == 0) {
      throw const KeySyncException('Wrong passphrase — try again.');
    }
    await _storage.write(key: _wrapKeyKey, value: base64Encode(wrapKey));
    return restored;
  }

  /// Removes all cloud backups and forgets the wrap key on this device.
  Future<void> disable(String ownerUid) async {
    final snap = await _col(ownerUid).get();
    for (final doc in snap.docs) {
      await doc.reference.delete();
    }
    await _storage.delete(key: _wrapKeyKey);
  }
}

class KeySyncException implements Exception {
  const KeySyncException(this.message);
  final String message;
  @override
  String toString() => message;
}
