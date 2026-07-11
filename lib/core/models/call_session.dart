import 'package:cloud_firestore/cloud_firestore.dart';

/// Lifecycle of a call session document.
enum CallSessionState {
  ringing, // owner created session, monitor not yet authenticated it
  answered, // monitor validated auth, posted its ephemeral key
  connected, // ICE completed (informational)
  ended,
  rejected, // authentication failed
}

/// Firestore representation of a call session
/// (devices/{deviceId}/sessions/{sessionId}).
///
/// Everything security-relevant is opaque ciphertext: `sealedAuth` is the
/// AES-256-GCM encrypted CallAuthPayload; the monitor's answer signature
/// authenticates its ephemeral key with the pairing master key. Firestore
/// (and Google) can never read or forge either.
class CallSession {
  const CallSession({
    required this.id,
    required this.deviceId,
    required this.ownerUid,
    required this.state,
    required this.sealedAuth,
    this.answerEphemeralKey,
    this.answerSignature,
    this.endReason,
    this.createdAt,
  });

  final String id;
  final String deviceId;
  final String ownerUid;
  final CallSessionState state;
  final String sealedAuth;
  final String? answerEphemeralKey;
  final String? answerSignature;
  final String? endReason;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'ownerUid': ownerUid,
        'state': state.name,
        'sealedAuth': sealedAuth,
        if (answerEphemeralKey != null) 'answerEpk': answerEphemeralKey,
        if (answerSignature != null) 'answerSig': answerSignature,
        if (endReason != null) 'endReason': endReason,
        'createdAt': FieldValue.serverTimestamp(),
      };

  factory CallSession.fromDoc(
    String deviceId,
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return CallSession(
      id: doc.id,
      deviceId: deviceId,
      ownerUid: data['ownerUid'] as String? ?? '',
      state: CallSessionState.values.asNameMap()[data['state'] as String?] ??
          CallSessionState.ended,
      sealedAuth: data['sealedAuth'] as String? ?? '',
      answerEphemeralKey: data['answerEpk'] as String?,
      answerSignature: data['answerSig'] as String?,
      endReason: data['endReason'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
