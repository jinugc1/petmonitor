import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key-value abstraction over platform secure storage so crypto
/// components stay unit-testable without platform channels.
abstract class SecureKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureStorageKv implements SecureKv {
  SecureStorageKv([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Test double.
class InMemoryKv implements SecureKv {
  final Map<String, String> _map = {};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}
