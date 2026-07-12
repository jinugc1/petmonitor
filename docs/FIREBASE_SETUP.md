# Firebase setup — step by step

Complete walkthrough for wiring PetMonitor to Firebase on the **Blaze
plan** (Cloud Functions send the wake-up push). A free Spark-plan
fallback also exists — the Owner App can send pushes directly with a
service-account key (Step 5, optional on Blaze).

Commands are for **Windows PowerShell**, run from the project root
(`C:\Users\pace\Petmonitor`) unless a step says otherwise.

---

## Prerequisites (once per machine)

| Tool | Check | Install if missing |
|---|---|---|
| Flutter | `flutter --version` | already installed (3.44.6) |
| Node.js 20+ | `node --version` | `winget install OpenJS.NodeJS.LTS` |
| Firebase CLI | `firebase --version` | `npm install -g firebase-tools` |
| FlutterFire CLI | `flutterfire --version` | `dart pub global activate flutterfire_cli` |

> If `flutterfire` is not recognized after activation, add
> `%LOCALAPPDATA%\Pub\Cache\bin` to your PATH and restart the terminal.

Platform scaffolding (once), so the apps have an Android package name and
iOS bundle id for Firebase to register:

```powershell
flutter create . --platforms=android,ios --org com.petmonitor
git checkout -- android/ pubspec.yaml   # restore our custom files
flutter pub get
```

## Step 1 — Create the Firebase project  ✅ (you did this)

<https://console.firebase.google.com> → **Add project** → name it
(e.g. `petmonitor`) → disable Google Analytics → Create. Note the
**project id** (Project settings → General, e.g. `petmonitor-4f2a1`).

## Step 2 — Enable Authentication providers

1. Sidebar → **Build → Authentication** → **Get started**.
2. **Sign-in method** tab, enable:
   - **Email/Password** → Enable → Save.
   - **Google** → Enable → pick a support email → Save.
   - **Apple** → Enable → Save *(finish the Apple Developer side before
     shipping; not needed for testing with email/Google)*.

## Step 3 — Firestore database  ✅ (you did this)

Build → Firestore Database → Create → pick a region → **production
mode**. (Rules are deployed in Step 6.)

## Step 4 — Register the apps with FlutterFire

```powershell
firebase login          # opens a browser — sign in with the same Google account
flutterfire configure --project <YOUR-PROJECT-ID> --platforms=android,ios
```

- Accept the Android application id `com.petmonitor.app`.
- This writes `lib\firebase_options.dart` (replacing our placeholder —
  expected), `android\app\google-services.json`, and
  `ios\Runner\GoogleService-Info.plist`.

## Step 5 — (Optional on Blaze) Create a direct wake-push key

On Blaze the `onCallSessionCreated` Cloud Function sends the wake push —
you can skip this step. Configure it anyway if you want a redundant wake
path that works even when Functions are down:

1. Firebase console → gear icon → **Project settings** → **Service
   accounts** tab.
2. Click **Generate new private key** → **Generate key** — a JSON file
   downloads.
3. Later, after you install the Owner App: open **Settings (gear icon) →
   Wake-up push key**, paste the entire contents of that JSON file, and
   tap **Save key**. It is stored only in the phone's Keychain/Keystore.
4. Then **delete the downloaded JSON file** from your computer
   (Downloads folder) — the phone keeps the only copy you need.

> Security note: this key can send pushes and access your project, which
> is why it goes into device secure storage and must never be committed,
> emailed, or shared. For a personal deployment (your own key, your own
> phone) this is an accepted trade-off — see SECURITY.md.

## Step 6 — Deploy Firestore rules, indexes, and functions

```powershell
cd firebase
npm --prefix functions install
firebase use <YOUR-PROJECT-ID>
firebase deploy --only firestore:rules,firestore:indexes,functions
cd ..
```

Expected: rules released, 2 composite indexes building (a minute or
two), and three functions deployed: `onCallSessionCreated` (wake push),
`onDeviceEventCreated` (owner alerts), `presenceSweep` (offline
detection). First-time deploy may ask to enable Cloud Build / Artifact
Registry APIs — answer yes; if it then fails with a permissions error,
wait two minutes and rerun.

## Step 7 — iOS push (APNs) — only when you build the iPhone app

1. [Apple Developer console](https://developer.apple.com/account) →
   Certificates, Identifiers & Profiles → **Keys** → **+** → tick
   **APNs** → register → download the `.p8` (one-time), note **Key ID**
   and **Team ID**.
2. Firebase console → Project settings → **Cloud Messaging** → Apple app
   configuration → upload the `.p8` with Key ID + Team ID.
3. Xcode → Runner target → Signing & Capabilities → add **Push
   Notifications**, **Background Modes** (Audio + Remote notifications),
   **Sign in with Apple**.

## Step 8 — Verify end to end

1. Monitor (Android phone): `flutter run -t lib/main_monitor.dart` →
   sign in → scanner opens.
2. Owner app: `flutter run -t lib/main_owner.dart` → sign in with the
   **same account** → **Settings** → paste the wake-push key (Step 5) →
   back → **Add monitor** → QR appears.
3. Scan with the monitor → pairing completes in seconds. Check Firestore
   in the console: `devices/{id}` exists with a `status` map.
4. Put the monitor to sleep (screen off) → tap **Call** on the owner app
   → the monitor lights up and auto-answers.

## Step 9 — Production hardening (before real use)

- **App Check** (console → Build → App Check): register both apps and
  enforce for Firestore.
- **MFA** on the owner account (Authentication → Settings).
- **Firestore TTL**: add a policy on `pairings` (field `expiresAt`).
- Full checklist: [SECURITY.md](SECURITY.md#production-hardening-checklist).

---

## Blaze vs. Spark fallback (both supported)

| Concern | Blaze (default, this setup) | Spark fallback |
|---|---|---|
| Wake push | `onCallSessionCreated` function | Owner app sends FCM v1 directly (`FcmDirectSender`, Step 5 key) |
| Presence | `presenceSweep` scheduled function | Computed client-side from `status.lastOnline` (built in) |
| Offline/battery alerts | Push via `onDeviceEventCreated` | Shown on the dashboard (no push) |

Both wake paths can coexist — the monitor ignores duplicate wake signals
for the same session (it only acts on `ringing` sessions and is
idempotent per session id).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `flutterfire configure` says "no Android app found" | Run the `flutter create` command from Prerequisites first |
| `PERMISSION_DENIED` in the app | Rules not deployed (Step 6), or the two devices use different accounts |
| Call never wakes the sleeping monitor | Owner app Settings → key configured? Monitor battery optimization set to Unrestricted? Check `devices/{id}.fcmToken` exists in Firestore |
| "Not a Firebase service-account key" when pasting | Paste the *whole* file including `{ }`; make sure it's the key from Service accounts, not `google-services.json` |
| Google sign-in fails on Android | Add your debug SHA-1 (`cd android; .\gradlew signingReport`) under Project settings → your Android app → Add fingerprint, then re-run `flutterfire configure` |
| iOS build fails on `GoogleService-Info.plist` | Open Xcode once and confirm the plist is in the Runner target |
