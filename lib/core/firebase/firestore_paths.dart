/// Single source of truth for the Firestore schema.
///
/// ```text
/// users/{uid}                                  owner profile (no secrets)
/// pairings/{pairingId}                         short-lived pairing handshake
/// devices/{deviceId}                           monitor device + status
/// devices/{deviceId}/sessions/{sessionId}      call sessions (ciphertext)
/// devices/{deviceId}/sessions/{sid}/signals/*  encrypted signaling envelopes
/// devices/{deviceId}/events/{eventId}          notifications timeline
/// ```
class FirestorePaths {
  FirestorePaths._();

  static const String users = 'users';
  static const String pairings = 'pairings';
  static const String devices = 'devices';
  static const String sessions = 'sessions';
  static const String signals = 'signals';
  static const String events = 'events';

  static String user(String uid) => '$users/$uid';
  static String pairing(String pairingId) => '$pairings/$pairingId';
  static String device(String deviceId) => '$devices/$deviceId';
  static String session(String deviceId, String sessionId) =>
      '$devices/$deviceId/$sessions/$sessionId';
  static String signalCollection(String deviceId, String sessionId) =>
      '${session(deviceId, sessionId)}/$signals';
}
