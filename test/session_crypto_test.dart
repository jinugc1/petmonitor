import 'package:flutter_test/flutter_test.dart';
import 'package:petmonitor/core/crypto/crypto_engine.dart';
import 'package:petmonitor/core/crypto/session_crypto.dart';

void main() {
  Future<(SessionCrypto owner, SessionCrypto monitor)> establishPair() async {
    final ownerEph = await CryptoEngine.generateKeyPair();
    final monitorEph = await CryptoEngine.generateKeyPair();
    const sessionId = 's1';

    final owner = await SessionCrypto.establish(
      ourEphemeral: ownerEph,
      theirEphemeralPublicKey: await CryptoEngine.publicKeyBytes(monitorEph),
      sessionId: sessionId,
      isCaller: true,
    );
    final monitor = await SessionCrypto.establish(
      ourEphemeral: monitorEph,
      theirEphemeralPublicKey: await CryptoEngine.publicKeyBytes(ownerEph),
      sessionId: sessionId,
      isCaller: false,
    );
    return (owner, monitor);
  }

  test('full-duplex encrypted exchange', () async {
    final (owner, monitor) = await establishPair();

    final env1 = await owner.encryptMessage({'t': 'offer', 'sdp': 'x'});
    final got1 = await monitor.decryptMessage(env1);
    expect(got1!['t'], 'offer');

    final env2 = await monitor.encryptMessage({'t': 'answer', 'sdp': 'y'});
    final got2 = await owner.decryptMessage(env2);
    expect(got2!['t'], 'answer');

    owner.destroy();
    monitor.destroy();
  });

  test('key ratchet: long exchanges keep decrypting across rotations',
      () async {
    final (owner, monitor) = await establishPair();
    // Cross several ratchet boundaries (interval = 50).
    for (var i = 0; i < 130; i++) {
      final env = await owner.encryptMessage({'i': i});
      final got = await monitor.decryptMessage(env);
      expect(got!['i'], i);
    }
    owner.destroy();
    monitor.destroy();
  });

  test('replayed envelope is dropped (returns null)', () async {
    final (owner, monitor) = await establishPair();
    final env = await owner.encryptMessage({'n': 1});
    expect(await monitor.decryptMessage(env), isNotNull);
    expect(await monitor.decryptMessage(env), isNull); // replay
    owner.destroy();
    monitor.destroy();
  });

  test('envelope from a foreign session cannot be decrypted', () async {
    final (owner, _) = await establishPair();
    final (_, otherMonitor) = await establishPair(); // different keys
    final env = await owner.encryptMessage({'secret': true});
    expect(
      () => otherMonitor.decryptMessage(env),
      throwsA(anything),
    );
  });

  test('use after destroy() throws (keys are gone — PFS)', () async {
    final (owner, monitor) = await establishPair();
    owner.destroy();
    expect(
      () => owner.encryptMessage({'x': 1}),
      throwsA(isA<StateError>()),
    );
    monitor.destroy();
  });
}
