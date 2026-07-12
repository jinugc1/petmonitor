import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers.dart';
import 'devices_screen.dart' show deviceKeyPresentProvider;

/// Scans a "Share call access" QR from another of the owner's devices
/// and stores the monitor's pairing key locally, making this device able
/// to call without a fresh pairing. Mobile only (needs a camera).
class ReceiveAccessScreen extends ConsumerStatefulWidget {
  const ReceiveAccessScreen({super.key});

  @override
  ConsumerState<ReceiveAccessScreen> createState() =>
      _ReceiveAccessScreenState();
}

class _ReceiveAccessScreenState extends ConsumerState<ReceiveAccessScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _processing = false;
  String? _status;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    setState(() => _processing = true);
    await _controller.stop();

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['t'] != 'pm-access' || json['v'] != 2) {
        throw const FormatException('not an access code');
      }
      final deviceId = json['did'] as String;
      final key = base64Decode(json['key'] as String);
      if (key.length != 32) throw const FormatException('bad key length');

      await ref.read(keyStoreProvider).saveMasterKey(deviceId, key);
      ref.invalidate(deviceKeyPresentProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This device can now call.')),
        );
        context.pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _processing = false;
          _status = 'That is not a PetMonitor access code — use '
              '"Share call access" on the device that can call.';
        });
        await _controller.start();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan call access')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          if (_processing) const Center(child: CircularProgressIndicator()),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              color: Colors.black54,
              child: Text(
                _status ??
                    'Scan the access QR shown on the device that can '
                        'already call the monitor.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
