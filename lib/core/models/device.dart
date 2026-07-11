import 'package:cloud_firestore/cloud_firestore.dart';

/// Live status the monitor reports periodically (and on change) while in
/// standby. Contains no secrets — safe to store in Firestore.
class DeviceStatus {
  const DeviceStatus({
    this.online = false,
    this.batteryPercent = -1,
    this.charging = false,
    this.networkType = 'unknown',
    this.wifiSignalLevel = -1,
    this.latencyMs = -1,
    this.freeStorageMb = -1,
    this.cameraOk = true,
    this.microphoneOk = true,
    this.appVersion = '',
    this.lastOnline,
  });

  final bool online;
  final int batteryPercent;
  final bool charging;
  final String networkType; // wifi | mobile | none
  final int wifiSignalLevel; // 0..4, -1 unknown
  final int latencyMs;
  final int freeStorageMb;
  final bool cameraOk;
  final bool microphoneOk;
  final String appVersion;
  final DateTime? lastOnline;

  Map<String, dynamic> toJson() => {
        'online': online,
        'battery': batteryPercent,
        'charging': charging,
        'network': networkType,
        'wifiLevel': wifiSignalLevel,
        'latencyMs': latencyMs,
        'freeStorageMb': freeStorageMb,
        'cameraOk': cameraOk,
        'micOk': microphoneOk,
        'appVersion': appVersion,
        'lastOnline': FieldValue.serverTimestamp(),
      };

  factory DeviceStatus.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DeviceStatus();
    return DeviceStatus(
      online: json['online'] as bool? ?? false,
      batteryPercent: json['battery'] as int? ?? -1,
      charging: json['charging'] as bool? ?? false,
      networkType: json['network'] as String? ?? 'unknown',
      wifiSignalLevel: json['wifiLevel'] as int? ?? -1,
      latencyMs: json['latencyMs'] as int? ?? -1,
      freeStorageMb: json['freeStorageMb'] as int? ?? -1,
      cameraOk: json['cameraOk'] as bool? ?? true,
      microphoneOk: json['micOk'] as bool? ?? true,
      appVersion: json['appVersion'] as String? ?? '',
      lastOnline: (json['lastOnline'] as Timestamp?)?.toDate(),
    );
  }
}

/// A paired monitor device. The pairing master key is NOT here — it lives
/// only in each device's secure storage.
class MonitorDevice {
  const MonitorDevice({
    required this.id,
    required this.ownerUid,
    required this.name,
    required this.publicKey,
    this.fcmToken,
    this.status = const DeviceStatus(),
    this.createdAt,
  });

  final String id;
  final String ownerUid;
  final String name;

  /// Monitor's long-term X25519 public key (base64) recorded at pairing.
  final String publicKey;

  /// Current FCM registration token for wake-up pushes.
  final String? fcmToken;

  final DeviceStatus status;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'ownerUid': ownerUid,
        'name': name,
        'publicKey': publicKey,
        if (fcmToken != null) 'fcmToken': fcmToken,
        'status': status.toJson(),
        'createdAt': FieldValue.serverTimestamp(),
      };

  factory MonitorDevice.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return MonitorDevice(
      id: doc.id,
      ownerUid: data['ownerUid'] as String? ?? '',
      name: data['name'] as String? ?? 'Pet Monitor',
      publicKey: data['publicKey'] as String? ?? '',
      fcmToken: data['fcmToken'] as String?,
      status: DeviceStatus.fromJson(data['status'] as Map<String, dynamic>?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  /// Online means a fresh heartbeat within the presence window.
  bool get isOnline {
    final last = status.lastOnline;
    if (last == null || !status.online) return false;
    return DateTime.now().difference(last) < const Duration(minutes: 3);
  }
}
