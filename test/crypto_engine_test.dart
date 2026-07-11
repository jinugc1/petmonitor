import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petmonitor/core/crypto/crypto_engine.dart';

void main() {
  group('random', () {
    test('randomBytes returns requested length and varies', () {
      final a = CryptoEngine.randomBytes(32);
      final b = CryptoEngine.randomBytes(32);
      expect(a.length, 32);
      expect(a, isNot(equals(b)));
    });

    test('randomId is url-safe', () {
      final id = CryptoEngine.randomId();
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
    });
  });

  group('X25519 + HKDF', () {
    test('both sides derive the same pairing master key', () async {
      final owner = await CryptoEngine.generateKeyPair();
      final monitor = await CryptoEngine.generateKeyPair();
      final qrSecret = CryptoEngine.randomBytes(16);

      final ownerSecret = await CryptoEngine.sharedSecret(
        owner,
        await CryptoEngine.publicKeyBytes(monitor),
      );
      final monitorSecret = await CryptoEngine.sharedSecret(
        monitor,
        await CryptoEngine.publicKeyBytes(owner),
      );
      expect(ownerSecret, equals(monitorSecret));

      final k1 = await CryptoEngine.derivePairingMasterKey(
        ecdhSecret: ownerSecret,
        qrSecret: qrSecret,
      );
      final k2 = await CryptoEngine.derivePairingMasterKey(
        ecdhSecret: monitorSecret,
        qrSecret: qrSecret,
      );
      expect(k1, equals(k2));
      expect(k1.length, 32);
    });

    test('different QR secret yields a different master key (anti-MITM)',
        () async {
      final ecdh = CryptoEngine.randomBytes(32);
      final k1 = await CryptoEngine.derivePairingMasterKey(
        ecdhSecret: ecdh,
        qrSecret: Uint8List.fromList(List.filled(16, 1)),
      );
      final k2 = await CryptoEngine.derivePairingMasterKey(
        ecdhSecret: ecdh,
        qrSecret: Uint8List.fromList(List.filled(16, 2)),
      );
      expect(k1, isNot(equals(k2)));
    });

    test('ratchet produces a new key and is deterministic', () async {
      final k = CryptoEngine.randomBytes(32);
      final r1 = await CryptoEngine.ratchetKey(k);
      final r2 = await CryptoEngine.ratchetKey(k);
      expect(r1, equals(r2));
      expect(r1, isNot(equals(k)));
    });
  });

  group('AES-256-GCM', () {
    test('roundtrip with AAD', () async {
      final key = CryptoEngine.randomBytes(32);
      final sealed = await CryptoEngine.encrypt(
        key: key,
        plaintext: utf8.encode('hello pet'),
        aad: utf8.encode('session-1'),
      );
      final clear = await CryptoEngine.decrypt(
        key: key,
        packedBase64: sealed,
        aad: utf8.encode('session-1'),
      );
      expect(utf8.decode(clear), 'hello pet');
    });

    test('random IV: same plaintext encrypts differently', () async {
      final key = CryptoEngine.randomBytes(32);
      final a = await CryptoEngine.encrypt(key: key, plaintext: [1, 2, 3]);
      final b = await CryptoEngine.encrypt(key: key, plaintext: [1, 2, 3]);
      expect(a, isNot(equals(b)));
    });

    test('tampered ciphertext is rejected', () async {
      final key = CryptoEngine.randomBytes(32);
      final sealed = await CryptoEngine.encrypt(key: key, plaintext: [9, 9, 9]);
      final bytes = base64Decode(sealed);
      bytes[14] ^= 0xFF; // flip a ciphertext bit
      expect(
        () => CryptoEngine.decrypt(key: key, packedBase64: base64Encode(bytes)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('wrong AAD is rejected', () async {
      final key = CryptoEngine.randomBytes(32);
      final sealed = await CryptoEngine.encrypt(
        key: key,
        plaintext: [1],
        aad: utf8.encode('a'),
      );
      expect(
        () => CryptoEngine.decrypt(
          key: key,
          packedBase64: sealed,
          aad: utf8.encode('b'),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('wrong key is rejected', () async {
      final sealed = await CryptoEngine.encrypt(
        key: CryptoEngine.randomBytes(32),
        plaintext: [1],
      );
      expect(
        () => CryptoEngine.decrypt(
          key: CryptoEngine.randomBytes(32),
          packedBase64: sealed,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('HMAC / constant-time compare', () {
    test('hmac is deterministic per key+message', () async {
      final key = CryptoEngine.randomBytes(32);
      expect(
        await CryptoEngine.hmac(key, 'm'),
        equals(await CryptoEngine.hmac(key, 'm')),
      );
      expect(
        await CryptoEngine.hmac(key, 'm'),
        isNot(equals(await CryptoEngine.hmac(key, 'n'))),
      );
    });

    test('constantTimeEquals', () {
      expect(CryptoEngine.constantTimeEquals('abc', 'abc'), isTrue);
      expect(CryptoEngine.constantTimeEquals('abc', 'abd'), isFalse);
      expect(CryptoEngine.constantTimeEquals('abc', 'ab'), isFalse);
    });
  });
}
