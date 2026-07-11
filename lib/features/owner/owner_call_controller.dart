import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/crypto_engine.dart';
import '../../core/crypto/session_crypto.dart';
import '../../core/firebase/firestore_paths.dart';
import '../../core/models/call_session.dart';
import '../../core/providers.dart';
import '../../core/signaling/signaling_channel.dart';
import '../../core/utils/secure_logger.dart';
import '../../core/webrtc/rtc_engine.dart';

enum OwnerCallPhase { idle, ringing, connecting, inCall, ending, failed }

class OwnerCallState {
  const OwnerCallState({
    this.phase = OwnerCallPhase.idle,
    this.engine,
    this.deviceId,
    this.quality = NetworkQuality.unknown,
    this.rtcState = RtcConnectionState.idle,
    this.micMuted = false,
    this.speakerOn = true,
    this.videoQuality = VideoQuality.p720,
    this.error,
  });

  final OwnerCallPhase phase;
  final RtcEngine? engine;
  final String? deviceId;
  final NetworkQuality quality;
  final RtcConnectionState rtcState;
  final bool micMuted;
  final bool speakerOn;
  final VideoQuality videoQuality;
  final String? error;

  OwnerCallState copyWith({
    OwnerCallPhase? phase,
    RtcEngine? engine,
    String? deviceId,
    NetworkQuality? quality,
    RtcConnectionState? rtcState,
    bool? micMuted,
    bool? speakerOn,
    VideoQuality? videoQuality,
    String? error,
  }) =>
      OwnerCallState(
        phase: phase ?? this.phase,
        engine: engine ?? this.engine,
        deviceId: deviceId ?? this.deviceId,
        quality: quality ?? this.quality,
        rtcState: rtcState ?? this.rtcState,
        micMuted: micMuted ?? this.micMuted,
        speakerOn: speakerOn ?? this.speakerOn,
        videoQuality: videoQuality ?? this.videoQuality,
        error: error,
      );
}

final ownerCallControllerProvider =
    StateNotifierProvider<OwnerCallController, OwnerCallState>(
  (ref) => OwnerCallController(ref),
);

/// Owner-side (caller) state machine.
///
/// startCall: ephemeral X25519 keypair -> sealed CallAuthPayload ->
/// session doc (Cloud Function fans it out as a high-priority FCM wake) ->
/// verify the monitor's HMAC-authenticated ephemeral key -> derive PFS
/// session keys -> encrypted SDP/ICE exchange -> media.
class OwnerCallController extends StateNotifier<OwnerCallState> {
  OwnerCallController(this._ref) : super(const OwnerCallState());

  final Ref _ref;
  final _log = SecureLogger('owner-call');

  SessionCrypto? _sessionCrypto;
  SignalingChannel? _channel;
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _sessionId;
  Timer? _ringTimeout;

  FirebaseFirestore get _firestore => _ref.read(firestoreProvider);

  Future<void> startCall(String deviceId) async {
    if (state.phase != OwnerCallPhase.idle &&
        state.phase != OwnerCallPhase.failed) {
      return;
    }
    state = OwnerCallState(
      phase: OwnerCallPhase.ringing,
      deviceId: deviceId,
    );

    try {
      final ownerUid = _ref.read(firebaseAuthProvider).currentUser!.uid;
      final masterKey =
          await _ref.read(keyStoreProvider).readMasterKey(deviceId);
      if (masterKey == null) {
        throw StateError('device not paired on this phone');
      }

      final sessionId = CryptoEngine.randomId();
      _sessionId = sessionId;
      final ephemeral = await CryptoEngine.generateKeyPair();
      final ephemeralPub =
          base64Encode(await CryptoEngine.publicKeyBytes(ephemeral));

      final (sealed, _) = await _ref.read(callAuthenticatorProvider).seal(
            masterKey: masterKey,
            sessionId: sessionId,
            deviceId: deviceId,
            ownerUid: ownerUid,
            ephemeralPublicKey: ephemeralPub,
          );

      final sessionRef =
          _firestore.doc(FirestorePaths.session(deviceId, sessionId));
      await sessionRef.set({
        'ownerUid': ownerUid,
        'state': CallSessionState.ringing.name,
        'sealedAuth': sealed,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Give the monitor 45s to wake, authenticate, and answer.
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (state.phase == OwnerCallPhase.ringing) {
          endCall(reason: 'no_answer');
        }
      });

      _subs.add(
        sessionRef.snapshots().listen((snap) async {
          final data = snap.data();
          if (data == null) return;
          final st = data['state'] as String?;
          if (st == CallSessionState.answered.name &&
              state.phase == OwnerCallPhase.ringing) {
            await _onAnswered(
              deviceId: deviceId,
              sessionId: sessionId,
              masterKey: masterKey,
              ourEphemeral: ephemeral,
              answerEpk: data['answerEpk'] as String?,
              answerSig: data['answerSig'] as String?,
            );
          } else if (st == CallSessionState.rejected.name) {
            _log.warn('monitor rejected call: ${data['endReason']}');
            await endCall(reason: 'rejected', notifyPeer: false);
          } else if (st == CallSessionState.ended.name &&
              state.phase != OwnerCallPhase.idle) {
            await endCall(reason: 'remote_ended', notifyPeer: false);
          }
        }),
      );
    } catch (e) {
      _log.error('startCall failed', e);
      state = state.copyWith(
        phase: OwnerCallPhase.failed,
        error: 'Could not start the call',
      );
      await _teardown();
    }
  }

  Future<void> _onAnswered({
    required String deviceId,
    required String sessionId,
    required Uint8List masterKey,
    required SimpleKeyPair ourEphemeral,
    required String? answerEpk,
    required String? answerSig,
  }) async {
    _ringTimeout?.cancel();
    if (answerEpk == null || answerSig == null) return;

    // Authenticate the monitor's ephemeral key before trusting it.
    final expected = await CryptoEngine.hmac(
      masterKey,
      '$sessionId|answer|$answerEpk',
    );
    if (!CryptoEngine.constantTimeEquals(expected, answerSig)) {
      _log.warn('answer signature invalid — aborting (possible MITM)');
      await endCall(reason: 'bad_answer_sig');
      return;
    }

    state = state.copyWith(phase: OwnerCallPhase.connecting);

    _sessionCrypto = await SessionCrypto.establish(
      ourEphemeral: ourEphemeral,
      theirEphemeralPublicKey: base64Decode(answerEpk),
      sessionId: sessionId,
      isCaller: true,
    );

    final iceConfig = await _ref.read(iceConfigStoreProvider).load();
    final engine = RtcEngine(iceConfig: iceConfig, isCaller: true);
    await engine.initialize(withLocalMedia: true);
    state = state.copyWith(engine: engine);

    _channel = SignalingChannel(
      firestore: _firestore,
      deviceId: deviceId,
      sessionId: sessionId,
      crypto: _sessionCrypto!,
      isOwner: true,
    )..listen();

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
                ? OwnerCallPhase.inCall
                : state.phase,
          );
        }),
      )
      ..add(
        engine.networkQuality.listen(
          (q) => state = state.copyWith(quality: q),
        ),
      )
      ..add(
        engine.needsRenegotiation.listen((_) async {
          // ICE restart after network change / failure.
          final offer = await engine.createOffer(iceRestart: true);
          await _channel?.send(SignalType.offer, offer);
        }),
      )
      ..add(
        _channel!.messages.listen((msg) async {
          switch (msg.type) {
            case SignalType.answer:
              await engine.setRemoteDescription(msg.data);
            case SignalType.ice:
              await engine.addRemoteIceCandidate(msg.data);
            case SignalType.bye:
              await endCall(reason: 'remote_ended', notifyPeer: false);
          }
        }),
      );

    final offer = await engine.createOffer();
    await _channel!.send(SignalType.offer, offer);
  }

  // -------------------------------------------------------------------
  // Remote controls (sent over the E2E-encrypted channel)
  // -------------------------------------------------------------------

  Future<void> _command(Map<String, dynamic> cmd) async {
    await _channel?.send(SignalType.command, cmd);
  }

  Future<void> switchMonitorCamera() => _command({'op': 'switchCamera'});
  Future<void> restartMonitorCamera() => _command({'op': 'restartCamera'});
  Future<void> setTorch(bool on) => _command({'op': 'torch', 'on': on});

  Future<void> setMonitorQuality(VideoQuality q) async {
    state = state.copyWith(videoQuality: q);
    await _command({'op': 'quality', 'value': q.name});
  }

  Future<void> setMonitorMuted(bool muted) =>
      _command({'op': 'mute', 'on': muted});

  Future<void> setMonitorSpeaker(bool on) =>
      _command({'op': 'speaker', 'on': on});

  Future<void> setMonitorVolume(double v) =>
      _command({'op': 'volume', 'value': v});

  /// Owner's local microphone (talk to the pet).
  void toggleOwnMic() {
    final muted = !state.micMuted;
    state.engine?.setMicrophoneMuted(muted);
    state = state.copyWith(micMuted: muted);
  }

  Future<void> toggleOwnSpeaker() async {
    final on = !state.speakerOn;
    await state.engine?.setSpeakerphone(on);
    state = state.copyWith(speakerOn: on);
  }

  // -------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------

  Future<void> endCall({
    String reason = 'hangup',
    bool notifyPeer = true,
  }) async {
    if (state.phase == OwnerCallPhase.idle) return;
    state = state.copyWith(phase: OwnerCallPhase.ending);

    if (notifyPeer) {
      try {
        await _channel?.send(SignalType.bye, const {});
      } catch (_) {}
    }
    final sessionId = _sessionId;
    final deviceId = state.deviceId;
    if (sessionId != null && deviceId != null) {
      try {
        await _firestore
            .doc(FirestorePaths.session(deviceId, sessionId))
            .update({
          'state': CallSessionState.ended.name,
          'endReason': reason,
        });
      } catch (_) {}
    }
    await _teardown();
    state = const OwnerCallState();
  }

  Future<void> _teardown() async {
    _ringTimeout?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _channel?.close();
    _channel = null;
    await state.engine?.close();
    _sessionCrypto?.destroy();
    _sessionCrypto = null;
    _sessionId = null;
  }
}
