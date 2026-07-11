import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ICE server configuration.
///
/// Serverless by default: public STUN only, which succeeds for the large
/// majority of home Wi-Fi <-> LTE pairs. For symmetric/carrier-grade NAT
/// the user may configure a managed TURN service (e.g. Twilio NTS, Metered,
/// or a self-hosted coturn — see docs/DEPLOYMENT.md). TURN credentials are
/// kept in platform secure storage and are never written to Firestore.
class IceConfig {
  const IceConfig({this.turnUrl, this.turnUsername, this.turnPassword});

  final String? turnUrl;
  final String? turnUsername;
  final String? turnPassword;

  static const List<String> _stunServers = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
  ];

  bool get hasTurn =>
      turnUrl != null && turnUrl!.isNotEmpty && turnUsername != null;

  Map<String, dynamic> toRtcConfiguration() => {
        'iceServers': [
          {'urls': _stunServers},
          if (hasTurn)
            {
              'urls': [turnUrl],
              'username': turnUsername,
              'credential': turnPassword,
            },
        ],
        'sdpSemantics': 'unified-plan',
        // Both IP families; WebRTC prefers host/srflx pairs automatically.
        'iceCandidatePoolSize': 2,
      };
}

/// Loads/saves the optional TURN configuration from secure storage.
class IceConfigStore {
  IceConfigStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _key = 'pm.ice.turn';

  Future<IceConfig> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const IceConfig();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return IceConfig(
      turnUrl: json['url'] as String?,
      turnUsername: json['user'] as String?,
      turnPassword: json['pass'] as String?,
    );
  }

  Future<void> save(IceConfig config) => _storage.write(
        key: _key,
        value: jsonEncode({
          'url': config.turnUrl,
          'user': config.turnUsername,
          'pass': config.turnPassword,
        }),
      );

  Future<void> clear() => _storage.delete(key: _key);
}
