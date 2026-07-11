import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../crypto/session_crypto.dart';
import '../firebase/firestore_paths.dart';
import '../utils/secure_logger.dart';

/// Types of end-to-end encrypted signaling messages.
class SignalType {
  SignalType._();
  static const String offer = 'offer';
  static const String answer = 'answer';
  static const String ice = 'ice';
  static const String bye = 'bye';
  static const String command = 'cmd'; // remote controls (owner -> monitor)
  static const String stats = 'stats'; // in-call telemetry (monitor -> owner)
}

/// A decrypted signaling message.
class SignalMessage {
  const SignalMessage(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// Firestore-backed signaling with zero readable content.
///
/// Every message is AES-256-GCM sealed by [SessionCrypto] before it is
/// written; documents contain only `{from, c (counter), d (ciphertext)}`.
/// Firestore is a dumb, blind mailbox: it orders and delivers envelopes it
/// cannot open. Replay/reorder is rejected by the counter-as-AAD scheme in
/// SessionCrypto.
class SignalingChannel {
  SignalingChannel({
    required FirebaseFirestore firestore,
    required this.deviceId,
    required this.sessionId,
    required SessionCrypto crypto,
    required this.isOwner,
  })  : _firestore = firestore,
        _crypto = crypto;

  final FirebaseFirestore _firestore;
  final String deviceId;
  final String sessionId;
  final SessionCrypto _crypto;
  final bool isOwner;

  final _log = SecureLogger('signaling');
  final _controller = StreamController<SignalMessage>.broadcast();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  String get _self => isOwner ? 'owner' : 'monitor';

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(
        FirestorePaths.signalCollection(deviceId, sessionId),
      );

  /// Decrypted messages from the remote peer, in counter order.
  Stream<SignalMessage> get messages => _controller.stream;

  void listen() {
    _sub = _collection
        .where('from', isNotEqualTo: _self)
        .orderBy('from')
        .orderBy('c')
        .snapshots()
        .listen(
      _onSnapshot,
      onError: (Object e) {
        _log.error('signal listener error', e);
      },
    );
  }

  Future<void> _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) async {
    for (final change in snap.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final data = change.doc.data();
      if (data == null) continue;
      try {
        final clear = await _crypto.decryptMessage(data);
        if (clear == null) continue; // stale replay — dropped
        _controller.add(
          SignalMessage(
            clear['t'] as String,
            (clear['p'] as Map<String, dynamic>?) ?? const {},
          ),
        );
      } catch (e) {
        // Undecryptable envelope: tampering or corruption. Never crash the
        // call for it; log (redacted) and continue.
        _log.warn('dropping undecryptable signal envelope');
      }
    }
  }

  Future<void> send(String type, Map<String, dynamic> payload) async {
    final envelope = await _crypto.encryptMessage({'t': type, 'p': payload});
    await _collection.add({
      ...envelope,
      'from': _self,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
