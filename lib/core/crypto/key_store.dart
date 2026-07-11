import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists long-term secrets in platform-secure storage:
/// Android Keystore-backed EncryptedSharedPreferences and the iOS Keychain.
///
/// Nothing stored here ever leaves the device. Session/ephemeral keys are
/// intentionally NOT persisted — they live only in memory (PFS).
class KeyStore {
  KeyStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  static String _masterKeyId(String deviceId) => 'pm.master.$deviceId';
  static const String _localDeviceId = 'pm.local.deviceId';

  /// Pairing master key for a paired device (one per pairing).
  Future<void> saveMasterKey(String deviceId, Uint8List key) =>
      _storage.write(key: _masterKeyId(deviceId), value: base64Encode(key));

  Future<Uint8List?> readMasterKey(String deviceId) async {
    final value = await _storage.read(key: _masterKeyId(deviceId));
    return value == null ? null : base64Decode(value);
  }

  Future<void> deleteMasterKey(String deviceId) =>
      _storage.delete(key: _masterKeyId(deviceId));

  /// The monitor's own permanent device identity.
  Future<void> saveLocalDeviceId(String deviceId) =>
      _storage.write(key: _localDeviceId, value: deviceId);

  Future<String?> readLocalDeviceId() => _storage.read(key: _localDeviceId);

  /// Full wipe (unpair / sign-out).
  Future<void> wipe() => _storage.deleteAll();
}
