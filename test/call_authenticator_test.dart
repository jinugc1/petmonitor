import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:petmonitor/core/crypto/call_authenticator.dart';
import 'package:petmonitor/core/crypto/crypto_engine.dart';
import 'package:petmonitor/core/crypto/nonce_cache.dart';
import 'package:petmonitor/core/crypto/secure_kv.dart';

void main() {
  late CallAuthenticator auth;
  final masterKey = CryptoEngine.randomBytes(32);
  const sessionId = 'session-1';
  const deviceId = 'device-1';
  const ownerUid = 'owner-1';
  const epk = 'ZXBoZW1lcmFsLWtleQ==';

  setUp(() {
    auth = CallAuthenticator(nonceCache: NonceCache(storage: InMemoryKv()));
  });

  Future<String> sealValid({DateTime? now}) async {
    final (sealed, _) = await auth.seal(
      masterKey: masterKey,
      sessionId: sessionId,
      deviceId: deviceId,
      ownerUid: ownerUid,
      ephemeralPublicKey: epk,
      now: now,
    );
    return sealed;
  }

  test('valid payload is accepted and carries the ephemeral key', () async {
    final sealed = await sealValid();
    final (result, payload) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.accepted);
    expect(payload!.ephemeralPublicKey, epk);
  });

  test('replayed nonce is rejected the second time', () async {
    final sealed = await sealValid();
    final (first, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    final (second, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(first, CallAuthResult.accepted);
    expect(second, CallAuthResult.replayedNonce);
  });

  test('replay survives an app restart (persistent nonce cache)', () async {
    final kv = InMemoryKv();
    final auth1 = CallAuthenticator(nonceCache: NonceCache(storage: kv));
    final sealed = await sealValid();
    await auth1.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    // "Restart": a fresh authenticator sharing the persisted store.
    final auth2 = CallAuthenticator(nonceCache: NonceCache(storage: kv));
    final (result, _) = await auth2.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.replayedNonce);
  });

  test('expired timestamp is rejected', () async {
    final old = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final sealed = await sealValid(now: old);
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.expiredTimestamp);
  });

  test('future-dated timestamp beyond skew is rejected', () async {
    final future = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final sealed = await sealValid(now: future);
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.expiredTimestamp);
  });

  test('payload sealed with a different key is rejected as malformed',
      () async {
    final otherAuth =
        CallAuthenticator(nonceCache: NonceCache(storage: InMemoryKv()));
    final (sealed, _) = await otherAuth.seal(
      masterKey: CryptoEngine.randomBytes(32), // attacker's key
      sessionId: sessionId,
      deviceId: deviceId,
      ownerUid: ownerUid,
      ephemeralPublicKey: epk,
    );
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.malformed);
  });

  test('payload bound to another session cannot be transplanted', () async {
    final sealed = await sealValid();
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: 'other-session', // AAD mismatch -> decrypt fails
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.malformed);
  });

  test('wrong device id is rejected', () async {
    final sealed = await sealValid();
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: 'other-device',
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.wrongDevice);
  });

  test('unknown owner is rejected', () async {
    final sealed = await sealValid();
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: sealed,
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: 'someone-else',
    );
    expect(result, CallAuthResult.unknownOwner);
  });

  test('garbage payload is rejected without throwing', () async {
    final (result, _) = await auth.verify(
      masterKey: masterKey,
      sealedPayload: base64Encode(List.filled(64, 7)),
      sessionId: sessionId,
      expectedDeviceId: deviceId,
      expectedOwnerUid: ownerUid,
    );
    expect(result, CallAuthResult.malformed);
  });
}
