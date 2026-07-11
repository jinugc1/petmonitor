import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

import '../../core/webrtc/rtc_engine.dart';
import 'owner_call_controller.dart';

/// Owner's in-call screen: the pet-area video full screen, the owner's
/// own preview as a small PiP, and the full remote-control tray.
class OwnerCallScreen extends ConsumerWidget {
  const OwnerCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(ownerCallControllerProvider);
    final controller = ref.read(ownerCallControllerProvider.notifier);

    ref.listen(ownerCallControllerProvider, (prev, next) {
      if (next.phase == OwnerCallPhase.idle ||
          next.phase == OwnerCallPhase.failed) {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/devices');
        }
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (call.engine != null && call.phase == OwnerCallPhase.inCall)
              RTCVideoView(
                call.engine!.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white70),
                    const SizedBox(height: 16),
                    Text(
                      switch (call.phase) {
                        OwnerCallPhase.ringing => 'Waking the monitor…',
                        OwnerCallPhase.connecting =>
                          'Authenticated — connecting…',
                        _ => 'Please wait…',
                      },
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),

            // Own camera preview (the pet sees this feed).
            if (call.engine != null)
              Positioned(
                top: 12,
                right: 12,
                width: 96,
                height: 144,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(
                    call.engine!.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),

            // Status chip.
            Positioned(
              top: 16,
              left: 16,
              child: Chip(
                avatar: Icon(
                  switch (call.quality) {
                    NetworkQuality.good => Icons.network_wifi,
                    NetworkQuality.fair => Icons.network_wifi_3_bar,
                    NetworkQuality.poor => Icons.network_wifi_1_bar,
                    NetworkQuality.unknown => Icons.wifi_find,
                  },
                  size: 16,
                ),
                label: Text(
                  call.rtcState == RtcConnectionState.reconnecting
                      ? 'Reconnecting…'
                      : call.quality.name,
                ),
              ),
            ),

            // Control tray.
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: call.micMuted ? 'Unmute' : 'Mute',
                      color: Colors.white,
                      icon: Icon(call.micMuted ? Icons.mic_off : Icons.mic),
                      onPressed: controller.toggleOwnMic,
                    ),
                    IconButton(
                      tooltip: 'Switch monitor camera',
                      color: Colors.white,
                      icon: const Icon(Icons.cameraswitch),
                      onPressed: controller.switchMonitorCamera,
                    ),
                    IconButton(
                      tooltip: 'More controls',
                      color: Colors.white,
                      icon: const Icon(Icons.tune),
                      onPressed: () => _showControls(context, ref),
                    ),
                    const SizedBox(width: 4),
                    FloatingActionButton(
                      backgroundColor: Colors.red,
                      onPressed: () => controller.endCall(),
                      child: const Icon(Icons.call_end, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showControls(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final call = ref.watch(ownerCallControllerProvider);
          final c = ref.read(ownerCallControllerProvider.notifier);
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                leading: const Icon(Icons.flashlight_on),
                title: const Text('Flashlight'),
                trailing: _TorchSwitch(onChanged: c.setTorch),
              ),
              ListTile(
                leading: const Icon(Icons.high_quality),
                title: const Text('Video quality'),
                trailing: SegmentedButton<VideoQuality>(
                  segments: const [
                    ButtonSegment(value: VideoQuality.p480, label: Text('480')),
                    ButtonSegment(value: VideoQuality.p720, label: Text('720')),
                    ButtonSegment(
                      value: VideoQuality.p1080,
                      label: Text('1080'),
                    ),
                  ],
                  selected: {call.videoQuality},
                  onSelectionChanged: (v) => c.setMonitorQuality(v.first),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.volume_up),
                title: const Text('Monitor speaker volume'),
                subtitle: _VolumeSlider(onChanged: c.setMonitorVolume),
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Restart monitor camera'),
                onTap: () {
                  c.restartMonitorCamera();
                  Navigator.pop(sheetContext);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TorchSwitch extends StatefulWidget {
  const _TorchSwitch({required this.onChanged});
  final Future<void> Function(bool) onChanged;

  @override
  State<_TorchSwitch> createState() => _TorchSwitchState();
}

class _TorchSwitchState extends State<_TorchSwitch> {
  bool _on = false;

  @override
  Widget build(BuildContext context) => Switch(
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          widget.onChanged(v);
        },
      );
}

class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({required this.onChanged});
  final Future<void> Function(double) onChanged;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  double _value = 0.8;

  @override
  Widget build(BuildContext context) => Slider(
        value: _value,
        // Safe upper bound: the monitor additionally clamps volume.
        onChanged: (v) => setState(() => _value = v),
        onChangeEnd: widget.onChanged,
      );
}
