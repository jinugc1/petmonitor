import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

import '../../core/webrtc/rtc_engine.dart';
import 'monitor_call_controller.dart';

/// Pet-facing call screen.
///
/// Design rules from the spec: the owner's face fills the entire display
/// (aspect-ratio preserving cover), every control is hidden, a thin HUD
/// (clock, battery, network, connection) fades out after a few seconds,
/// and Pet Mode locks the interface against paws — ending the call
/// requires an intentional long-press that a pet cannot perform.
class MonitorCallScreen extends ConsumerStatefulWidget {
  const MonitorCallScreen({super.key});

  @override
  ConsumerState<MonitorCallScreen> createState() => _MonitorCallScreenState();
}

class _MonitorCallScreenState extends ConsumerState<MonitorCallScreen> {
  bool _hudVisible = true;
  Timer? _hudTimer;
  Timer? _clockTimer;
  int _battery = -1;

  @override
  void initState() {
    super.initState();
    // Immersive: hide status/navigation bars for the pet.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHudHide();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final level = await Battery().batteryLevel;
      if (mounted) setState(() => _battery = level);
    });
    Battery().batteryLevel.then((v) {
      if (mounted) setState(() => _battery = v);
    });
  }

  void _scheduleHudHide() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _clockTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(monitorCallControllerProvider);
    final engine = call.engine;

    ref.listen(monitorCallControllerProvider, (prev, next) {
      if (next.phase == MonitorCallPhase.standby) context.go('/standby');
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // Taps only toggle the HUD — Pet Mode: nothing destructive on tap.
        onTap: () {
          setState(() => _hudVisible = true);
          _scheduleHudHide();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (engine != null)
              RTCVideoView(
                engine.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              const Center(child: CircularProgressIndicator()),
            if (call.phase == MonitorCallPhase.connecting)
              const Center(
                child: Text(
                  'Connecting…',
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),
              ),
            // HUD — auto-hides.
            AnimatedOpacity(
              opacity: _hudVisible ? 1 : 0,
              duration: const Duration(milliseconds: 400),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Clock(),
                        const SizedBox(width: 12),
                        Icon(
                          _battery >= 0 && _battery < 20
                              ? Icons.battery_alert
                              : Icons.battery_full,
                          size: 16,
                          color: Colors.white70,
                        ),
                        Text(
                          _battery < 0 ? '—' : '$_battery%',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          switch (call.quality) {
                            NetworkQuality.good => Icons.network_wifi,
                            NetworkQuality.fair => Icons.network_wifi_3_bar,
                            NetworkQuality.poor => Icons.network_wifi_1_bar,
                            NetworkQuality.unknown =>
                              Icons.signal_wifi_statusbar_null,
                          },
                          size: 16,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          call.rtcState == RtcConnectionState.connected
                              ? 'Live'
                              : call.rtcState == RtcConnectionState.reconnecting
                                  ? 'Reconnecting…'
                                  : 'Connecting…',
                          style: TextStyle(
                            color: call.rtcState == RtcConnectionState.connected
                                ? Colors.greenAccent
                                : Colors.orangeAccent,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Pet-proof exit: 3-second long-press in the corner.
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                onLongPressStart: (_) => _armEnd(),
                onLongPressEnd: (_) => _disarmEnd(),
                child: const SizedBox(width: 96, height: 96),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _endTimer;

  void _armEnd() {
    _endTimer = Timer(const Duration(seconds: 3), () {
      ref.read(monitorCallControllerProvider.notifier).endCall();
    });
  }

  void _disarmEnd() {
    _endTimer?.cancel();
    _endTimer = null;
  }
}

class _Clock extends StatefulWidget {
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    return Text(
      now.format(context),
      style: const TextStyle(color: Colors.white70, fontSize: 13),
    );
  }
}
