# PetMonitor

A serverless, end-to-end encrypted pet monitoring system built from one
Flutter codebase:

| App | Platform | Entry point | Role |
|---|---|---|---|
| **Owner App** | iOS (iPhone) | `lib/main_owner.dart` | See & talk to your pet, manage monitors, remote controls |
| **Pet Monitor App** | Android (spare phone) | `lib/main_monitor.dart` | Dormant terminal near the pet; wakes instantly for authenticated calls and auto-answers full screen |

## Highlights

- **Zero servers to run.** Firebase Auth + Firestore + FCM + one tiny Cloud
  Function (FCM fan-out only). Deploy = create a Firebase project, run
  `flutterfire configure`, build the apps.
- **True end-to-end encryption.** X25519 pairing anchored to an
  out-of-band QR secret, AES-256-GCM signaling, HMAC-SHA256 call
  authentication, per-call ephemeral keys (Perfect Forward Secrecy),
  persistent replay protection, DTLS-SRTP media whose certificate
  fingerprints travel only inside the encrypted channel. Firebase stores
  ciphertext it can never read.
- **Near-zero idle battery.** In standby the monitor holds no wake locks,
  no camera, no mic, no WebRTC, no background loops — just a dormant app
  that a high-priority FCM push wakes via a full-screen intent.
- **Authenticated auto-answer.** The monitor answers only after
  decrypting and verifying `HMAC-SHA256(sessionId|timestamp|nonce|ephKey,
  masterKey)` with fresh timestamp and unseen nonce.
- **Pet-friendly.** The owner's face fills the whole screen; controls
  auto-hide; the interface is locked against paws (3-second corner
  long-press to exit).

## Repository layout

```
lib/
  main_owner.dart            iOS owner app entry
  main_monitor.dart          Android monitor entry (+ FCM background handler)
  app/                       theme
  core/
    crypto/                  X25519 / AES-GCM / HMAC / PFS / replay protection
    signaling/               encrypted Firestore signaling channel
    webrtc/                  RtcEngine: adaptive bitrate, ICE restart, controls
    models/  firebase/  platform/  utils/
  features/
    auth/  pairing/  owner/  monitor/
android/                     manifest + MainActivity wake/lock + BootReceiver
firebase/                    firestore.rules, indexes, minimal Cloud Functions
test/                        crypto / call-auth / replay / protocol tests
docs/                        architecture, security, deployment, user guide
.github/workflows/           CI + release pipelines
```

## Quick start

```bash
# 1. Platform scaffolding (generates ios/, completes android/)
flutter create . --platforms=android,ios --org com.petmonitor

# 2. Firebase
firebase login
dart pub global activate flutterfire_cli
flutterfire configure            # writes lib/firebase_options.dart
cd firebase && firebase deploy --only firestore:rules,firestore:indexes,functions

# 3. Run
flutter run -t lib/main_monitor.dart   # on the Android phone
flutter run -t lib/main_owner.dart     # on the iPhone
```

Full instructions: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Documentation

- [Firebase setup, step by step](docs/FIREBASE_SETUP.md)
- [Architecture & sequence diagrams](docs/ARCHITECTURE.md)
- [Security design & threat model](docs/SECURITY.md)
- [Deployment (Firebase, TURN, store releases)](docs/DEPLOYMENT.md)
- [User guide](docs/USER_GUIDE.md)

## Testing

```bash
flutter test          # crypto, call-auth, replay, session, backoff suites
flutter analyze
```
