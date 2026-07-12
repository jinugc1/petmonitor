import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;

import '../utils/secure_logger.dart';

/// Sends FCM messages directly from the device via the HTTP v1 API —
/// the Spark-plan (no Cloud Functions, no billing) wake-up path.
///
/// The Firebase service-account key is pasted once into the owner app's
/// settings and lives ONLY in platform secure storage (iOS Keychain /
/// Android Keystore-backed). This is a deliberate, documented trade-off
/// for personal deployments: the key is the user's own project credential
/// on the user's own phone. It is never written to Firestore, never
/// bundled into the app binary, and never leaves the device.
class FcmDirectSender {
  FcmDirectSender([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _log = SecureLogger('fcm-direct');

  static const String _key = 'pm.fcm.serviceAccount';
  static const _scopes = ['https://www.googleapis.com/auth/firebase.messaging'];

  gauth.AutoRefreshingAuthClient? _client;
  String? _projectId;

  Future<bool> get isConfigured async =>
      (await _storage.read(key: _key)) != null;

  /// Validates and stores a service-account JSON key.
  /// Throws [FormatException] with a user-readable message if invalid.
  Future<void> saveServiceAccount(String jsonText) async {
    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(jsonText.trim()) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not valid JSON — paste the whole file.');
    }
    if (parsed['type'] != 'service_account' ||
        parsed['project_id'] is! String ||
        parsed['private_key'] is! String ||
        parsed['client_email'] is! String) {
      throw const FormatException(
        'This is not a Firebase service-account key. In the Firebase '
        'console open Project settings → Service accounts → '
        '"Generate new private key".',
      );
    }
    await _storage.write(key: _key, value: jsonEncode(parsed));
    await _resetClient();
  }

  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _resetClient();
  }

  Future<void> _resetClient() async {
    _client?.close();
    _client = null;
    _projectId = null;
  }

  Future<gauth.AutoRefreshingAuthClient> _authClient() async {
    final existing = _client;
    if (existing != null) return existing;
    final raw = await _storage.read(key: _key);
    if (raw == null) {
      throw StateError('FCM service-account key not configured');
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _projectId = json['project_id'] as String;
    final credentials = gauth.ServiceAccountCredentials.fromJson(json);
    final client = await gauth.clientViaServiceAccount(credentials, _scopes);
    _client = client;
    return client;
  }

  /// High-priority data-only push that wakes the dormant monitor.
  /// The push carries no secrets — only routing ids; the monitor still
  /// performs full cryptographic call authentication before answering.
  Future<void> sendCallWake({
    required String fcmToken,
    required String deviceId,
    required String sessionId,
  }) async {
    await _send({
      'message': {
        'token': fcmToken,
        'android': {'priority': 'HIGH', 'ttl': '45s'},
        'data': {
          'type': 'incoming_call',
          'deviceId': deviceId,
          'sessionId': sessionId,
        },
      },
    });
  }

  Future<void> _send(Map<String, dynamic> body) async {
    final client = await _authClient();
    final uri = Uri.parse(
      'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
    );
    final response = await client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      _log.warn('FCM send failed: HTTP ${response.statusCode}');
      throw http.ClientException('FCM v1 send failed', uri);
    }
  }

  void dispose() {
    _client?.close();
  }
}
