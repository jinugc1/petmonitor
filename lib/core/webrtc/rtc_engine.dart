import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/backoff.dart';
import '../utils/secure_logger.dart';
import 'ice_config.dart';

/// Video quality presets selectable by the owner.
enum VideoQuality { p1080, p720, p480 }

extension VideoQualityConstraints on VideoQuality {
  Map<String, dynamic> get constraints => switch (this) {
        VideoQuality.p1080 => {
            'width': {'ideal': 1920},
            'height': {'ideal': 1080},
            'frameRate': {'ideal': 30, 'min': 15},
          },
        VideoQuality.p720 => {
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'frameRate': {'ideal': 30, 'min': 15},
          },
        VideoQuality.p480 => {
            'width': {'ideal': 854},
            'height': {'ideal': 480},
            'frameRate': {'ideal': 24, 'min': 10},
          },
      };

  int get maxBitrateBps => switch (this) {
        VideoQuality.p1080 => 2_500_000,
        VideoQuality.p720 => 1_500_000,
        VideoQuality.p480 => 700_000,
      };
}

/// High-level connection state surfaced to the UI.
enum RtcConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
  closed,
}

/// Coarse network quality derived from RTT/loss for the status HUD.
enum NetworkQuality { unknown, good, fair, poor }

/// Media/transport engine shared by both apps.
///
/// Owns the RTCPeerConnection and local media; is transport-agnostic —
/// the call controllers feed it remote SDP/ICE from the encrypted
/// signaling channel and forward its outbound events back through it.
///
/// Security note: DTLS-SRTP is mandatory in WebRTC, so media is encrypted
/// end-to-end between the two peers. Because SDP (which carries the DTLS
/// certificate fingerprints) travels only inside the AES-256-GCM signaling
/// channel, a man-in-the-middle cannot substitute certificates: media E2EE
/// is anchored to the pairing master key.
class RtcEngine {
  RtcEngine({required this.iceConfig, required this.isCaller});

  final IceConfig iceConfig;

  /// Caller (owner) sends offer; callee (monitor) answers.
  final bool isCaller;

  final _log = SecureLogger('rtc');

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  final _stateController = StreamController<RtcConnectionState>.broadcast();
  final _qualityController = StreamController<NetworkQuality>.broadcast();
  final _iceCandidateController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _renegotiateController = StreamController<void>.broadcast();

  Stream<RtcConnectionState> get connectionState => _stateController.stream;
  Stream<NetworkQuality> get networkQuality => _qualityController.stream;

  /// Local ICE candidates to be sent through encrypted signaling.
  Stream<Map<String, dynamic>> get localIceCandidates =>
      _iceCandidateController.stream;

  /// Fired when an ICE restart produced a new offer that must be signaled.
  Stream<void> get needsRenegotiation => _renegotiateController.stream;

  Timer? _statsTimer;
  final _restartBackoff = ExponentialBackoff(
    initial: const Duration(seconds: 1),
    max: const Duration(seconds: 20),
  );
  bool _closed = false;
  bool _usingFrontCamera = true;
  VideoQuality _quality = VideoQuality.p720;

  // -------------------------------------------------------------------
  // Setup
  // -------------------------------------------------------------------

  Future<void> initialize({required bool withLocalMedia}) async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    _pc = await createPeerConnection(iceConfig.toRtcConfiguration());
    _pc!
      ..onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        _iceCandidateController.add({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
      ..onConnectionState = _onConnectionState
      ..onTrack = (event) {
        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams.first;
        }
      };

    if (withLocalMedia) {
      await _openLocalMedia();
    }
    _emit(RtcConnectionState.connecting);
    _startStatsLoop();
  }

  Future<void> _openLocalMedia() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': {
        'facingMode': _usingFrontCamera ? 'user' : 'environment',
        ..._quality.constraints,
      },
    });
    _localStream = stream;
    localRenderer.srcObject = stream;
    for (final track in stream.getTracks()) {
      await _pc!.addTrack(track, stream);
    }
    await _applyMaxBitrate();
  }

  // -------------------------------------------------------------------
  // SDP negotiation (driven by call controllers)
  // -------------------------------------------------------------------

  Future<Map<String, dynamic>> createOffer({bool iceRestart = false}) async {
    final offer = await _pc!.createOffer({
      if (iceRestart) 'iceRestart': true,
    });
    await _pc!.setLocalDescription(offer);
    return {'sdp': offer.sdp, 'type': offer.type};
  }

  Future<Map<String, dynamic>> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return {'sdp': answer.sdp, 'type': answer.type};
  }

  Future<void> setRemoteDescription(Map<String, dynamic> sdp) async {
    await _pc!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );
  }

  Future<void> addRemoteIceCandidate(Map<String, dynamic> c) async {
    await _pc!.addCandidate(
      RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      ),
    );
  }

  // -------------------------------------------------------------------
  // Resilience: connection monitoring + ICE restart
  // -------------------------------------------------------------------

  void _onConnectionState(RTCPeerConnectionState state) {
    _log.info('pc state: $state');
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _restartBackoff.reset();
        _emit(RtcConnectionState.connected);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _emit(RtcConnectionState.reconnecting);
        _scheduleIceRestart();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _emit(RtcConnectionState.reconnecting);
        _scheduleIceRestart();
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _emit(RtcConnectionState.closed);
      default:
        break;
    }
  }

  Future<void> _scheduleIceRestart() async {
    if (_closed || !isCaller) return; // only the caller restarts ICE
    final delay = _restartBackoff.next();
    _log.info('scheduling ICE restart in ${delay.inMilliseconds}ms');
    await Future<void>.delayed(delay);
    if (_closed) return;
    final state = _pc?.connectionState;
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return; // recovered on its own
    }
    _renegotiateController.add(null);
  }

  // -------------------------------------------------------------------
  // Adaptive quality + stats
  // -------------------------------------------------------------------

  void _startStatsLoop() {
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final pc = _pc;
      if (pc == null || _closed) return;
      try {
        final reports = await pc.getStats();
        double? rttMs;
        for (final r in reports) {
          if (r.type == 'candidate-pair' &&
              r.values['state'] == 'succeeded' &&
              r.values['currentRoundTripTime'] != null) {
            rttMs = (r.values['currentRoundTripTime'] as num) * 1000;
          }
        }
        if (rttMs != null) {
          _qualityController.add(
            rttMs < 150
                ? NetworkQuality.good
                : rttMs < 400
                    ? NetworkQuality.fair
                    : NetworkQuality.poor,
          );
        }
      } catch (_) {/* stats are best-effort */}
    });
  }

  Future<void> _applyMaxBitrate() async {
    final pc = _pc;
    if (pc == null) return;
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final params = sender.parameters;
      final encodings = params.encodings ?? [RTCRtpEncoding()];
      for (final e in encodings) {
        e.maxBitrate = _quality.maxBitrateBps;
      }
      params.encodings = encodings;
      // Prefer resolution drops over frame-rate drops for a pet camera.
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_FRAMERATE;
      await sender.setParameters(params);
    }
  }

  // -------------------------------------------------------------------
  // Remote-controllable features
  // -------------------------------------------------------------------

  Future<void> setQuality(VideoQuality quality) async {
    _quality = quality;
    final videoTrack = _videoTrack;
    if (videoTrack != null) {
      await videoTrack.applyConstraints(quality.constraints);
    }
    await _applyMaxBitrate();
  }

  Future<void> switchCamera() async {
    final track = _videoTrack;
    if (track == null) return;
    await Helper.switchCamera(track);
    _usingFrontCamera = !_usingFrontCamera;
  }

  Future<void> setTorch(bool on) async {
    final track = _videoTrack;
    if (track == null) return;
    try {
      // Torch is a native extension on mobile tracks; not part of the
      // cross-platform MediaStreamTrack interface.
      // ignore: avoid_dynamic_calls
      await (track as dynamic).setTorch(on);
    } catch (e) {
      _log.warn('torch unsupported on this camera');
    }
  }

  void setMicrophoneMuted(bool muted) {
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  Future<void> setSpeakerphone(bool on) => Helper.setSpeakerphoneOn(on);

  Future<void> setVolume(double volume) async {
    // Applied to the remote (incoming) audio: 0.0 .. 1.0.
    final remote = remoteRenderer.srcObject;
    for (final t in remote?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      await Helper.setVolume(volume.clamp(0.0, 1.0), t);
    }
  }

  Future<void> restartCamera() async {
    final stream = _localStream;
    if (stream == null) return;
    for (final t in stream.getVideoTracks()) {
      t.enabled = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      t.enabled = true;
    }
  }

  MediaStreamTrack? get _videoTrack {
    final tracks = _localStream?.getVideoTracks();
    return (tracks == null || tracks.isEmpty) ? null : tracks.first;
  }

  void _emit(RtcConnectionState s) {
    if (!_stateController.isClosed) _stateController.add(s);
  }

  // -------------------------------------------------------------------
  // Teardown — releases every media resource (battery requirement)
  // -------------------------------------------------------------------

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _statsTimer?.cancel();
    try {
      for (final t in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _localStream?.dispose();
      await _pc?.close();
    } finally {
      _localStream = null;
      _pc = null;
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
      _emit(RtcConnectionState.closed);
      await _stateController.close();
      await _qualityController.close();
      await _iceCandidateController.close();
      await _renegotiateController.close();
    }
  }
}
