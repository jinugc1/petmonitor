# Security design & threat model

## Goals

1. Only the paired owner can view/hear the pet area or make the monitor
   auto-answer — even if Firebase, Google, or a network attacker is fully
   compromised.
2. The servers are zero-knowledge: they never hold session keys, shared
   secrets, media keys, or plaintext signaling.
3. Compromise of any single past artifact (a captured push, a Firestore
   dump, an old session key) must not unlock anything else.

## Key hierarchy

```
qrSecret (16 B, random)  ── visual channel only (owner screen → monitor camera)
X25519 long-term pair keys ── generated on-device at pairing
        │
        ▼
masterKey = HKDF-SHA256(ikm = X25519(privA, pubB), salt = qrSecret,
                        info = "petmonitor/pairing/v1")        [32 B]
        ├── stored ONLY in Android Keystore-backed storage / iOS Keychain
        ├── wakeKey  = HKDF(masterKey, "petmonitor/wake/v1")   → seals CallAuthPayload
        └── authenticates per-call ephemeral X25519 keys (HMAC)
per call:
  ephemeral X25519 both sides (memory only, zeroed at hangup)   → PFS
  sessionKeys = HKDF(X25519(eph), salt = sessionId)  [2 × 32 B, per direction]
        └── forward-ratcheted every 50 messages: k' = HKDF(k, "ratchet/v1")
```

## Mechanisms

| Requirement | Implementation |
|---|---|
| E2E signaling encryption | AES-256-GCM, random 96-bit IV, counter bound as AAD (`SessionCrypto`) |
| Call authentication | `HMAC-SHA256(sessionId\|timestamp\|nonce\|ephPub, masterKey)`, sealed with the wakeKey (`CallAuthenticator`) |
| Timestamp validation | ±90 s window, UTC |
| Replay protection | persistent nonce cache (survives app restarts) checked **after** all other validations; signaling counters strictly increasing |
| Perfect Forward Secrecy | fresh ephemeral X25519 per call; keys only in memory; zeroed on hangup; intra-session ratchet |
| Media E2EE | DTLS-SRTP (mandatory in WebRTC). SDP fingerprints travel only inside AES-GCM signaling ⇒ a signaling MITM cannot swap certificates. TURN relays see only SRTP ciphertext |
| Secure randomness | `SecretKeyData.random` (platform CSPRNG) |
| Secure key storage | `flutter_secure_storage`: Android Keystore-backed EncryptedSharedPreferences, iOS Keychain (`first_unlock_this_device`) |
| Transport pinning | Firebase SDKs use certificate-pinned Google TLS stacks; app adds no custom endpoints. If you add one, pin its certificate |
| Secure logging | `SecureLogger`: silent in release, redacts base64-like blobs in debug |
| Constant-time comparisons | all MAC verifications |

## Threat model

| Adversary | Capability | Outcome |
|---|---|---|
| Network attacker (Wi-Fi, ISP) | observe/modify traffic | TLS to Firebase; DTLS-SRTP for media; all signaling content is AES-GCM ciphertext. Can only deny service |
| Compromised Firestore / insider at cloud provider | read & write every document | Sees ciphertext + metadata. Cannot derive masterKey (never left devices; qrSecret was visual-only), cannot forge call auth or pairing tags, cannot swap DTLS certs. Can delete data (DoS) |
| Stolen owner **account** (password phished) | full Firestore access as owner | Cannot decrypt or place authenticated calls — no masterKey on the attacker's device. Could attempt a *re-pairing*, which requires physical access to the monitor (camera scan + same signed-in account). Mitigation: enable MFA on the Firebase project |
| Captured FCM push / Firestore dump replay | resend old sealedAuth | Rejected: nonce cache (persisted) + timestamp window |
| Stolen monitor phone | physical access | Keys are hardware-backed and non-exportable; a device PIN/biometric protects the OS. Owner should unpair (delete device doc) to revoke |
| Malicious "monitor" claiming a pairing | writes to pairing doc | Confirmation tag requires masterKey ⇒ requires qrSecret ⇒ requires seeing the owner's screen |
| Replay/reorder of signaling | re-post envelopes | Counter-as-AAD: stale counters dropped, mismatched counters fail authentication |

### Known residual risks

- **Metadata**: Firebase sees *that* calls happen, when, and between which
  account/device ids (not content). Unavoidable with managed signaling.
- **Account = pairing gate**: both devices deliberately share the owner
  account; Firestore rules scope everything to that uid. Turn on MFA.
- **Doze delays**: on aggressive OEM battery managers the first push after
  days of idle can be delayed seconds. Exempt the app from battery
  optimization (see USER_GUIDE).
- **TURN relay** (if configured) learns call IP/timing — never content.

## Production hardening checklist

- [ ] Enforce MFA on owner accounts (Firebase Identity Platform).
- [ ] Enable Firebase App Check (Play Integrity / App Attest) so only your
      app binaries can reach Firestore/Functions.
- [ ] Rotate FCM/APNs credentials on team changes.
- [ ] `flutter build --obfuscate --split-debug-info=...` for releases.
- [ ] Review Firestore rules on every schema change (`firebase/firestore.rules`).
- [ ] Keep `flutter_webrtc` / `cryptography` pinned & patched (Dependabot).
- [ ] Pen-test the pairing flow with a hostile Firestore emulator.
- [ ] Set Firestore TTL policy on `pairings` (expiresAt) and old `sessions`.
- [ ] Confirm no `debugPrint` of sensitive data sneaks in (SecureLogger only).
- [ ] Device PIN + disabled ADB on the deployed monitor phone.
