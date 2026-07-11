import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers.dart';
import 'owner_pairing_screen.dart' show pairingServiceProvider;
import 'pairing_service.dart';

/// Monitor: scans the owner's QR code and completes the key exchange.
class MonitorPairingScreen extends ConsumerStatefulWidget {
  const MonitorPairingScreen({super.key});

  @override
  ConsumerState<MonitorPairingScreen> createState() =>
      _MonitorPairingScreenState();
}

class _MonitorPairingScreenState extends ConsumerState<MonitorPairingScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _processing = false;
  String? _status;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    setState(() {
      _processing = true;
      _status = 'Verifying and exchanging keys…';
    });
    await _controller.stop();

    try {
      final auth = ref.read(firebaseAuthProvider);
      final uid = auth.currentUser?.uid;
      if (uid == null) throw const PairingException('Not signed in');

      final fcmToken = await ref.read(messagingProvider).getToken();
      await ref.read(pairingServiceProvider).completeMonitorPairing(
            scannedQr: raw,
            signedInUid: uid,
            deviceName: 'Pet Monitor',
            fcmToken: fcmToken,
          );
      if (mounted) context.go('/standby');
    } on PairingException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Pairing failed. Please try again.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _processing = false;
      _status = message;
    });
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with owner')),
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
                    'Scan the QR code shown in the owner app.\n'
                        'Keys are exchanged directly between your devices.',
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
