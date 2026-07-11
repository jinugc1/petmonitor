# Deployment

Standard installation requires **no servers**: a Firebase project + two
app builds. Optional: a TURN service for hostile NATs.

## 1. Prerequisites

- Flutter (latest stable) + platform toolchains (Xcode for iOS, Android SDK)
- Firebase CLI (`npm i -g firebase-tools`), Node 20 (for the one function)
- A Firebase project on the **Blaze** plan (Cloud Functions requirement;
  idle cost is effectively $0 for a personal deployment)

## 2. Platform scaffolding (one time)

This repo ships the app source, Android manifest/Kotlin, and Firebase
config. Generate the remaining boilerplate:

```bash
flutter create . --platforms=android,ios --org com.petmonitor
flutter pub get
```

`flutter create` will not overwrite the provided `AndroidManifest.xml`,
`MainActivity.kt`, or `build.gradle` if you keep our versions when
prompted / restore them from git afterwards (`git checkout -- android/`).

### iOS Info.plist additions (`ios/Runner/Info.plist`)

```xml
<key>NSCameraUsageDescription</key>
<string>Video calls with your pet monitor</string>
<key>NSMicrophoneUsageDescription</key>
<string>Talk to your pet during calls</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>remote-notification</string>
</array>
```

Enable capabilities in Xcode: Push Notifications, Sign in with Apple,
Background Modes (Audio, Remote notifications).

## 3. Firebase

> Detailed click-by-click walkthrough: [FIREBASE_SETUP.md](FIREBASE_SETUP.md).

```bash
firebase login
firebase projects:create petmonitor-yourname   # or use the console

# Wire the apps (writes lib/firebase_options.dart + platform files)
dart pub global activate flutterfire_cli
flutterfire configure --project petmonitor-yourname \
  --platforms=android,ios
```

In the Firebase console:

1. **Authentication** → enable Email/Password, Google, Apple.
2. **Firestore** → create database (production mode).
3. **Cloud Messaging** → upload your APNs key for iOS.

Deploy rules, indexes, and the functions:

```bash
cd firebase
npm --prefix functions install
firebase deploy --only firestore:rules,firestore:indexes,functions \
  --project petmonitor-yourname
```

That is the entire backend. The three functions
(`onCallSessionCreated`, `onDeviceEventCreated`, `presenceSweep`) are pure
FCM fan-out/presence glue and hold no secrets or state.

## 4. TURN (optional)

STUN-only works for most home-Wi-Fi ↔ LTE pairs. If calls fail to connect
on symmetric/carrier-grade NAT, configure TURN in both apps' secure
settings (`IceConfigStore`), using either:

- **Managed (no servers, recommended):** Twilio Network Traversal,
  Metered.ca, or Cloudflare Calls TURN — paste URL/username/credential.
- **Self-hosted coturn (optional, for those who want it):**

```yaml
# docker-compose.yml
services:
  coturn:
    image: coturn/coturn:4.6
    network_mode: host
    command: >
      -n --log-file=stdout
      --lt-cred-mech --fingerprint
      --user=petmonitor:CHANGE_ME_LONG_RANDOM
      --realm=turn.example.com
      --listening-port=3478
      --min-port=49160 --max-port=49200
```

```bash
docker compose up -d
# open UDP 3478 + 49160-49200 on the firewall
```

TURN credentials live only in on-device secure storage — never in
Firestore, never in the repo.

## 5. Android monitor release

```bash
# one-time signing setup
keytool -genkey -v -keystore android/app/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cat > android/key.properties <<EOF
storePassword=***
keyPassword=***
keyAlias=upload
storeFile=upload-keystore.jks
EOF

flutter build apk --release -t lib/main_monitor.dart \
  --obfuscate --split-debug-info=build/symbols
# side-load onto the spare phone, or:
flutter build appbundle --release -t lib/main_monitor.dart   # Play Store
```

On the monitor phone: settings → battery → **unrestricted** for
PetMonitor; allow camera/mic/notifications; disable screen lock or use
swipe-only (auto-answer never bypasses PIN/biometric locks).

## 6. iOS owner release

```bash
flutter build ipa --release -t lib/main_owner.dart \
  --obfuscate --split-debug-info=build/symbols
# then upload via Xcode Organizer or `xcrun altool` / Transporter
```

App Store review notes: declare camera/microphone usage (pet video
calls); no background location; push = call wake-ups.

## 7. CI/CD

`.github/workflows/ci.yml` — format, analyze, tests, functions build on
every PR. `.github/workflows/release.yml` — tag `v*` builds a signed
Android bundle + unsigned iOS archive; add the secrets listed at the top
of the file.

## 8. Smoke test

1. Sign in on both devices with the same account.
2. Owner: *Add monitor* → QR appears. Monitor: scan → both land on their
   home screens (pairing < 10 s).
3. Lock the monitor phone, wait for Doze (or `adb shell dumpsys deviceidle
   force-idle`).
4. Owner: *Call* → the monitor screen lights up and auto-answers full
   screen (~2–5 s).
5. Hang up → monitor returns to the black standby screen; verify zero
   wake locks: `adb shell dumpsys power | grep -i wake`.
