import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/providers.dart';

/// Shows a QR that grants another of the OWNER'S OWN devices the ability
/// to call a monitor. The QR carries the pairing master key over the
/// visual channel (screen -> camera) — exactly the trust model of the
/// original pairing: Firestore never sees it, and whoever can photograph
/// your unlocked screen could already do the same with a fresh pairing.
class ShareAccessScreen extends ConsumerStatefulWidget {
  const ShareAccessScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<ShareAccessScreen> createState() => _ShareAccessScreenState();
}

class _ShareAccessScreenState extends ConsumerState<ShareAccessScreen> {
  String? _payload;
  bool _missingKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key =
        await ref.read(keyStoreProvider).readMasterKey(widget.deviceId);
    if (!mounted) return;
    if (key == null) {
      setState(() => _missingKey = true);
      return;
    }
    setState(() {
      _payload = jsonEncode({
        'v': 2,
        't': 'pm-access',
        'did': widget.deviceId,
        'key': base64Encode(key),
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share call access')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _missingKey
              ? const Text(
                  'This device does not hold the key for that monitor — '
                  'share from the device that can call it.',
                  textAlign: TextAlign.center,
                )
              : _payload == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(data: _payload!, size: 260),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'On your other phone, open PetMonitor →\n'
                          'menu on the monitor card → "Scan call access",\n'
                          'and scan this code.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'This code contains the encryption key for this '
                          'monitor. Show it only to your own devices.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
