import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/firebase/firestore_paths.dart';
import '../../core/models/call_session.dart';
import '../../core/providers.dart';
import '../../core/utils/backoff.dart';
import '../../core/utils/secure_logger.dart';
import 'monitor_call_controller.dart';

final monitorServiceProvider = Provider<MonitorService>((ref) {
  final service = MonitorService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Standby-mode plumbing for the monitor:
///
///  * registers/refreshes the FCM token (survives reboots, reinstalls,
///    token rotation — the recovery requirement),
///  * routes incoming FCM data messages to the call controller,
///  * keeps a low-cost Firestore listener for ringing sessions while the
///    app happens to be in the foreground (FCM is the wake path when not),
///  * does NOTHING else while idle: no camera, no mic, no WebRTC, no
///    wake locks.
class MonitorService {
  MonitorService(this._ref);

  final Ref _ref;
  final _log = SecureLogger('monitor');
  final _backoff = ExponentialBackoff();

  StreamSubscription<RemoteMessage>? _fcmSub;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sessionSub;

  Future<void> start(String deviceId) async {
    final messaging = _ref.read(messagingProvider);

    await messaging.requestPermission();
    await _registerToken(deviceId);

    // Token rotation (also fires after app data restore / reinstall).
    _tokenSub = messaging.onTokenRefresh.listen(
      (_) => _registerToken(deviceId),
    );

    // Foreground FCM messages.
    _fcmSub = FirebaseMessaging.onMessage.listen(_onPush);

    // A cold start triggered by a high-priority data push.
    final initial = await messaging.getInitialMessage();
    if (initial != null) _onPush(initial);

    // Belt-and-braces: watch for ringing sessions while foregrounded.
    _sessionSub = _ref
        .read(firestoreProvider)
        .collection(
          '${FirestorePaths.device(deviceId)}/${FirestorePaths.sessions}',
        )
        .where('state', isEqualTo: CallSessionState.ringing.name)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        // Ignore stale ring documents from before this listener attached.
        final created =
            (change.doc.data()?['createdAt'] as Timestamp?)?.toDate();
        if (created != null &&
            DateTime.now().difference(created) > const Duration(minutes: 2)) {
          continue;
        }
        _dispatch(deviceId, change.doc.id);
      }
    });
  }

  Future<void> _registerToken(String deviceId) async {
    try {
      await _backoff.retry(() async {
        final token = await _ref.read(messagingProvider).getToken();
        if (token == null) throw StateError('no FCM token yet');
        await _ref
            .read(firestoreProvider)
            .doc(FirestorePaths.device(deviceId))
            .update({'fcmToken': token});
      });
      _log.info('FCM token registered');
    } catch (e) {
      _log.error('FCM token registration failed', e);
    }
  }

  void _onPush(RemoteMessage message) {
    final data = message.data;
    if (data['type'] != 'incoming_call') return;
    final deviceId = data['deviceId'];
    final sessionId = data['sessionId'];
    if (deviceId is String && sessionId is String) {
      _dispatch(deviceId, sessionId);
    }
  }

  void _dispatch(String deviceId, String sessionId) {
    // Full cryptographic validation happens inside the controller; the
    // push itself is only a wake signal and is never trusted.
    unawaited(
      _ref.read(monitorCallControllerProvider.notifier).handleIncomingSession(
            deviceId: deviceId,
            sessionId: sessionId,
          ),
    );
  }

  void dispose() {
    _fcmSub?.cancel();
    _tokenSub?.cancel();
    _sessionSub?.cancel();
  }
}
