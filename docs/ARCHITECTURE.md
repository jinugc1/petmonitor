# Architecture

## System overview

```
┌───────────────────┐                                   ┌────────────────────┐
│  Owner App (iOS)  │                                   │ Monitor (Android)  │
│  main_owner.dart  │                                   │ main_monitor.dart  │
└─────────┬─────────┘                                   └─────────┬──────────┘
          │                 Firebase (managed, zero-admin)        │
          │  ┌──────────────────────────────────────────────────┐ │
          ├──┤ Auth (email / Google / Apple)                    ├─┤
          ├──┤ Firestore: devices, sessions, ENCRYPTED signals  ├─┤
          │  │ Cloud Function: FCM fan-out only                 │ │
          │  └──────────────────────┬───────────────────────────┘ │
          │                         │ high-priority data push      │
          │                         └──────────────────────────────┤
          │                                                        │
          │            WebRTC  (DTLS-SRTP, end-to-end)             │
          └────────────────────────────────────────────────────────┘
                     direct P2P via STUN; optional TURN relay
```

Media never touches Firebase. Firestore carries only ciphertext envelopes
(signaling) and non-sensitive device status.

## Layers (Clean Architecture / MVVM)

| Layer | Location | Contents |
|---|---|---|
| Presentation | `features/*/*_screen.dart` | Widgets only; render state, dispatch intents |
| ViewModel | `*_controller.dart` (Riverpod `StateNotifier`) | Call state machines |
| Domain / services | `pairing_service`, `monitor_service`, `status_reporter` | Use-case orchestration |
| Repository / data source | Firestore access behind services, `KeyStore`, `IceConfigStore` | Persistence |
| Crypto | `core/crypto/` | Pure, unit-tested primitives & protocols |
| Media | `core/webrtc/RtcEngine` | Transport-agnostic WebRTC wrapper |
| Networking | `core/signaling/SignalingChannel` | Encrypted mailbox over Firestore |

Dependency rule: presentation → controllers → services → core. `core/`
never imports `features/`. All wiring is via Riverpod providers
(`core/providers.dart`), so every service can be replaced by a fake in
tests.

## Firestore schema

```
users/{uid}
  fcmTokens: { <token>: lastSeenMs }        # owner phones, for alerts

pairings/{pairingId}                         # TTL ~5 min
  ownerUid, ownerPub, status: waiting|claimed|confirmed|failed
  monitorPub?, deviceId?, confirmTag?        # written by the monitor

devices/{deviceId}
  ownerUid, name, publicKey, fcmToken
  status: { online, battery, charging, network, wifiLevel, latencyMs,
            freeStorageMb, cameraOk, micOk, appVersion, lastOnline }

  sessions/{sessionId}
    ownerUid, state: ringing|answered|connected|ended|rejected
    sealedAuth                               # AES-256-GCM ciphertext
    answerEpk, answerSig                     # monitor ephemeral key + HMAC
    endReason, createdAt

    signals/{autoId}                         # append-only encrypted mailbox
      from: owner|monitor, c: counter, d: ciphertext, createdAt

  events/{eventId}                           # battery_low, device_offline...
```

## Sequence: secure pairing

```
Owner iPhone                Firestore                 Monitor Android
    │ keypair + qrSecret         │                            │
    ├─ pairings/{id}{ownerPub} ─▶│                            │
    │        QR{id, ownerPub, qrSecret}  ──(screen→camera)──▶ │
    │                            │      keypair + deviceId    │
    │                            │      masterKey = HKDF(     │
    │                            │        X25519, qrSecret)   │
    │                            │◀─ devices/{deviceId} ──────┤
    │                            │◀─ claim{monitorPub,tag} ───┤
    │ masterKey = HKDF(...)      │                            │
    │ verify tag ─ confirmed ───▶│───────────────────────────▶│
    │ store key (Keychain)       │        store key (Keystore)│
```

The `qrSecret` never touches Firestore — a server-side attacker cannot
derive the master key or forge the confirmation tag.

## Sequence: authenticated call with auto-answer

```
Owner                       Firestore + CF              Monitor (dormant)
  │ ephKey_o, nonce, ts          │                           │
  │ sealedAuth = AESGCM(         │                           │
  │   payload+HMAC, wakeKey)     │                           │
  ├── sessions/{sid}{ringing} ──▶│── FCM high-priority ─────▶│ wake isolate
  │                              │                           │ full-screen intent
  │                              │                           │ app launches
  │                              │                           │ decrypt+verify:
  │                              │                           │  ts window, nonce,
  │                              │                           │  HMAC, owner, device
  │                              │◀── {answered, ephKey_m,───┤ screen on,
  │ verify answerSig             │      HMAC(sid|answer|k)}  │ camera+mic up
  │ sessionKeys = HKDF(X25519(ephKeys), sid)   [both sides]  │
  ├── ENCRYPTED offer ──────────▶│──────────────────────────▶│
  │◀───────────────────────────── ENCRYPTED answer ──────────┤
  │◀───────────── ENCRYPTED ICE candidates (both ways) ─────▶│
  │═══════════ DTLS-SRTP media, direct P2P (or TURN) ═══════▶│
  │ bye ────────────────────────▶│──────────────────────────▶│ teardown:
  │                              │                           │ keys zeroed,
  │                              │                           │ wake released,
  │                              │                           │ back to standby
```

## Power model (monitor)

| State | Camera | Mic | WebRTC | Wake locks | Network |
|---|---|---|---|---|---|
| Standby | off | off | none | none | FCM socket (OS-managed) + 2-min heartbeat |
| Ringing→auth | off | off | none | none | one Firestore read |
| In call | on | on | active | screen+cpu | P2P media |
| After call | off | off | destroyed | released | back to standby |

The only recurring standby cost is the `StatusReporter` heartbeat (one
small Firestore write every 2 minutes, batched by the OS with other
traffic). Everything else is push-driven.

## Reliability

- **Exponential backoff with full jitter** (`core/utils/backoff.dart`)
  wraps FCM token registration and other retry loops.
- **ICE restart**: the caller watches `RTCPeerConnectionState`; on
  `disconnected`/`failed` it re-offers with `iceRestart: true` on a
  backoff schedule (`RtcEngine.needsRenegotiation`).
- **Reboot/update recovery**: `BootReceiver` revives the process after
  `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`, letting FCM re-register; the
  standby screen re-registers the token on every launch and on
  `onTokenRefresh`.
- **Presence**: heartbeat writes `status.lastOnline`; the scheduled
  `presenceSweep` function flips stale devices to offline and raises a
  `device_offline` event exactly once per transition.
- **Ring timeout**: the owner gives the monitor 45 s to wake and answer,
  then closes the session.
