import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:petmonitor/core/crypto/crypto_engine.dart';

/// Protocol-level pairing tests (no Firestore): verifies that the
/// confirmation tag binds the monitor's key + device id to the QR secret,
/// so a signaling-channel MITM cannot complete a pairing.
void main() {
  test('honest pairing verifies; MITM without the QR secret fails', () async {
    // Owner side.
    final ownerKp = await CryptoEngine.generateKeyPair();
    final ownerPub = await CryptoEngine.publicKeyBytes(ownerKp);
    final qrSecret = CryptoEngine.randomBytes(16);
    const pairingId = 'p1';

    // Honest monitor (has the QR secret via the camera).
    final monitorKp = await CryptoEngine.generateKeyPair();
    final monitorPub =
        base64Encode(await CryptoEngine.publicKeyBytes(monitorKp));
    const deviceId = 'd1';
    final monitorMaster = await CryptoEngine.derivePairingMasterKey(
      ecdhSecret: await CryptoEngine.sharedSecret(monitorKp, ownerPub),
      qrSecret: qrSecret,
    );
    final tag = await CryptoEngine.hmac(
      monitorMaster,
      'confirm|$pairingId|$monitorPub|$deviceId',
    );

    // Owner verifies.
    final ownerMaster = await CryptoEngine.derivePairingMasterKey(
      ecdhSecret: await CryptoEngine.sharedSecret(
        ownerKp,
        base64Decode(monitorPub),
      ),
      qrSecret: qrSecret,
    );
    final expected = await CryptoEngine.hmac(
      ownerMaster,
      'confirm|$pairingId|$monitorPub|$deviceId',
    );
    expect(CryptoEngine.constantTimeEquals(expected, tag), isTrue);

    // MITM: controls Firestore (saw ownerPub), substitutes its own key,
    // but never saw the QR secret.
    final mitmKp = await CryptoEngine.generateKeyPair();
    final mitmPub = base64Encode(await CryptoEngine.publicKeyBytes(mitmKp));
    final mitmGuessMaster = await CryptoEngine.derivePairingMasterKey(
      ecdhSecret: await CryptoEngine.sharedSecret(mitmKp, ownerPub),
      qrSecret: CryptoEngine.randomBytes(16), // must guess — cannot
    );
    final mitmTag = await CryptoEngine.hmac(
      mitmGuessMaster,
      'confirm|$pairingId|$mitmPub|$deviceId',
    );

    final ownerMasterVsMitm = await CryptoEngine.derivePairingMasterKey(
      ecdhSecret: await CryptoEngine.sharedSecret(
        ownerKp,
        base64Decode(mitmPub),
      ),
      qrSecret: qrSecret,
    );
    final ownerExpectedVsMitm = await CryptoEngine.hmac(
      ownerMasterVsMitm,
      'confirm|$pairingId|$mitmPub|$deviceId',
    );
    expect(
      CryptoEngine.constantTimeEquals(ownerExpectedVsMitm, mitmTag),
      isFalse,
    );
  });
}
