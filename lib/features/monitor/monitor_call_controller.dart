import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/crypto/call_authenticator.dart';
import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/key_store.dart';
import '../../core/crypto/session_crypto.dart';
import '../../core/firebase/firestore_paths.dart';
import '../../core/models/call_session.dart';
import '../../core/platform/wake_channel.dart';
import '../../core/providers.dart';
import '../../core/signaling/signaling_channel.dart';
import '../../core/utils/secure_logger.dart';
import '../../core/webrtc/rtc_engine.dart';

/// Monitor-side call state machine.
enum MonitorCallPhase { standby, authenticating, connecting, inCall, ending }

class MonitorCallState {
  const MonitorCallState({
    this.phase = MonitorCallPhase.standby,
    this.engine,
    this.quality = NetworkQuality.unknown,
    this.rtcState = RtcConnectionState.idle,
  });

  final MonitorCallPhase phase;
  final RtcEngine? engine;
  final NetworkQuality quality;
  final RtcConnectionState rtcState;

  MonitorCallState copyWith({
    MonitorCallPhase? phase,
    RtcEngine? engine,
    NetworkQuality? quality,
    RtcConnectionState? rtcState,
    bool clearEngine = false,
  }) =>
      MonitorCallState(
        phase: phase ?? this.phase,
        engine: clearEngine ? null : (engine ?? this.engine),
        quality: quality ?? this.quality,
        rtcState: rtcState ?? this.rtcState,
      );
}

final monitorCallControllerProvider =
    StateNotifierProvider<MonitorCallController, MonitorCallState>(
  (ref) => MonitorCallController(ref),
);

/// Implements the full authenticated auto-answer sequence:
///
///   FCM/Firestore wake -> decrypt + validate CallAuthPayload
///   -> post authenticated answer (ephemeral key) -> wake screen
///   -> WebRTC callee flow -> in-call remote commands
///   -> teardown: release EVERYTHING and return to dormant standby.
class MonitorCallController extends StateNotifier<MonitorCallState> {
  MonitorCallController(this._ref) : super(const MonitorCallState());

  final Ref _ref;
  final _log = SecureLogger('monitor-call');

  SessionCrypto? _sessionCrypto;
  SignalingChannel? _channel;
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _activeSessionId;

  FirebaseFirestore get _firestore => _ref.read(firestoreProvider);
  KeyStore get _keyStore => _ref.read(keyStoreProvider);
  CallAuthenticator get _authenticator => _ref.read(callAuthenticatorProvider);

  /// Entry point — called from the FCM handler or the foreground session
  /// listener with a candidate incoming session.
  Future<void> handleIncomingSession({
    required String deviceId,
    required String sessionId,
  }) async {
    if (state.phase != MonitorCallPhase.standby) {
      _log.warn('busy — ignoring session');
      return;
    }
    _activeSessionId = sessionId;
    state = state.copyWith(phase: MonitorCallPhase.authenticating);

    try {
      // ---- 1. Load identity & keys -----------------------------------
      final localDeviceId = await _keyStore.readLocalDeviceId();
      final masterKey = await _keyStore.readMasterKey(deviceId);
      if (localDeviceId != deviceId || masterKey == null) {
        _log.warn('session for unknown/unpaired device — rejected');
        return _abort();
      }
      final ownerUid = _ref.read(firebaseAuthProvider).currentUser?.uid ?? '';

      final sessionRef =
          _firestore.doc(FirestorePaths.session(deviceId, sessionId));
      final snap = await sessionRef.get();
      if (!snap.exists) return _abort();
      final session = CallSession.fromDoc(deviceId, snap);
      if (session.state != CallSessionState.ringing) return _abort();

      // ---- 2. Authenticate the caller (the security gate) ------------
      final (result, payload) = await _authenticator.verify(
        masterKey: masterKey,
        sealedPayload: session.sealedAuth,
        sessionId: sessionId,
        expectedDeviceId: deviceId,
        expectedOwnerUid: ownerUid,
      );
      if (result != CallAuthResult.accepted || payload == null) {
        _log.warn('call auth rejected: ${result.name}');
        await sessionRef.update({
          'state': CallSessionState.rejected.name,
          'endReason': result.name,
        });
        return _abort();
      }

      // ---- 3. Authenticated answer: our ephemeral key (PFS) ----------
      final ephemeral = await CryptoEngine.generateKeyPair();
      final ephemeralPub =
          base64Encode(await CryptoEngine.publicKeyBytes(ephemeral));
      final answerSig = await CryptoEngine.hmac(
        masterKey,
        '$sessionId|answer|$ephemeralPub',
      );

      _sessionCrypto = await SessionCrypto.establish(
        ourEphemeral: ephemeral,
        theirEphemeralPublicKey: base64Decode(payload.ephemeralPublicKey),
        sessionId: sessionId,
        isCaller: false,
      );

      // ---- 4. Wake the device ----------------------------------------
      await WakeChannel.acquireForCall();
      await WakelockPlus.enable();
      state = state.copyWith(phase: MonitorCallPhase.connecting);

      // ---- 5. WebRTC callee setup ------------------------------------
      final iceConfig = await _ref.read(iceConfigStoreProvider).load();
      final engine = RtcEngine(iceConfig: iceConfig, isCaller: false);
      await engine.initialize(withLocalMedia: true);
      await engine.setSpeakerphone(true); // loudspeaker by default
      state = state.copyWith(engine: engine);

      _channel = SignalingChannel(
        firestore: _firestore,
        deviceId: deviceId,
        sessionId: sessionId,
        crypto: _sessionCrypto!,
        isOwner: false,
      )..listen();

      _wireEngine(engine);
      _wireSignals(engine);

      // Publish the answer AFTER listeners are live so no offer is missed.
      await sessionRef.update({
        'state': CallSessionState.answered.name,
        'answerEpk': ephemeralPub,
        'answerSig': answerSig,
      });

      // Watch for the owner ending the call via session doc as a fallback.
      _subs.add(
        sessionRef.snapshots().listen((s) {
          final st = s.data()?['state'] as String?;
          if (st == CallSessionState.ended.name) endCall(remote: true);
        }),
      );
    } catch (e) {
      _log.error('incoming session failed', e);
      await endCall();
    }
  }

  void _wireEngine(RtcEngine engine) {
    _subs
      ..add(
        engine.localIceCandidates.listen(
          (c) => _channel?.send(SignalType.ice, c),
        ),
      )
      ..add(
        engine.connectionState.listen((s) {
          state = state.copyWith(
            rtcState: s,
            phase: s == RtcConnectionState.connected
                ? MonitorCallPhase.inCall
                : state.phase,
          );
        }),
      )
      ..add(
        engine.networkQuality.listen(
          (q) => state = state.copyWith(quality: q),
        ),
      );
  }

  void _wireSignals(RtcEngine engine) {
    _subs.add(
      _channel!.messages.listen((msg) async {
        switch (msg.type) {
          case SignalType.offer:
            await engine.setRemoteDescription(msg.data);
            final answer = await engine.createAnswer();
            await _channel?.send(SignalType.answer, answer);
          case SignalType.ice:
            await engine.addRemoteIceCandidate(msg.data);
          case SignalType.command:
            await _handleCommand(engine, msg.data);
          case SignalType.bye:
            await endCall(remote: true);
        }
      }),
    );
  }

  /// Remote controls from the owner — already authenticated by virtue of
  /// arriving on the E2E-encrypted channel only the owner can key.
  Future<void> _handleCommand(
    RtcEngine engine,
    Map<String, dynamic> cmd,
  ) async {
    switch (cmd['op'] as String?) {
      case 'switchCamera':
        await engine.switchCamera();
      case 'restartCamera':
        await engine.restartCamera();
      case 'torch':
        await engine.setTorch(cmd['on'] as bool? ?? false);
      case 'quality':
        final q =
            VideoQuality.values.asNameMap()[cmd['value'] as String? ?? 'p720'];
        if (q != null) await engine.setQuality(q);
      case 'mute':
        engine.setMicrophoneMuted(cmd['on'] as bool? ?? false);
      case 'speaker':
        await engine.setSpeakerphone(cmd['on'] as bool? ?? true);
      case 'volume':
        await engine.setVolume((cmd['value'] as num? ?? 1.0).toDouble());
    }
  }

  Future<void> _abort() async {
    _activeSessionId = null;
    state = const MonitorCallState();
  }

  /// Full teardown back to dormant standby — releases every resource so
  /// the phone can sleep (the battery-life contract).
  Future<void> endCall({bool remote = false}) async {
    if (state.phase == MonitorCallPhase.standby) return;
    state = state.copyWith(phase: MonitorCallPhase.ending);
    final sessionId = _activeSessionId;
    _activeSessionId = null;

    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    if (!remote && sessionId != null) {
      try {
        await _channel?.send(SignalType.bye, const {});
      } catch (_) {}
    }
    try {
      final deviceId = await _keyStore.readLocalDeviceId();
      if (sessionId != null && deviceId != null) {
        await _firestore
            .doc(FirestorePaths.session(deviceId, sessionId))
            .update({'state': CallSessionState.ended.name});
      }
    } catch (_) {}

    await _channel?.close();
    _channel = null;
    await state.engine?.close();
    _sessionCrypto?.destroy(); // zeroes session keys — PFS
    _sessionCrypto = null;

    await WakelockPlus.disable();
    await WakeChannel.releaseAfterCall();
    state = const MonitorCallState(); // back to standby
  }
}
