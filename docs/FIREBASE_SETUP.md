# Firebase setup — step by step

Complete walkthrough for creating and wiring the Firebase project that
powers PetMonitor. Time: ~30 minutes. When you finish, the entire backend
exists — there is nothing else to host.

Commands are for **Windows PowerShell**. Run them from the project root
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

Also required once: platform scaffolding, so the apps have an Android
package name and iOS bundle id for Firebase to register:

```powershell
flutter create . --platforms=android,ios --org com.petmonitor
git checkout -- android/   # restore our custom manifest/Kotlin/gradle files
```

*(If the project isn't in git yet: back up the `android\` folder before
`flutter create` and copy our four files back afterwards:
`AndroidManifest.xml`, `MainActivity.kt`, `BootReceiver.kt`,
`app\build.gradle`.)*

---

## Step 1 — Create the Firebase project

1. Open <https://console.firebase.google.com> and sign in with your
   Google account (paceai.studio@gmail.com).
2. Click **Add project** (or "Create a project").
3. Project name: `petmonitor` (Firebase will suggest a unique id like
   `petmonitor-4f2a1` — note this **project id**, you'll use it below).
4. **Google Analytics**: disable it (not needed) → **Create project**.
5. Wait for provisioning, then **Continue**.

## Step 2 — Upgrade to the Blaze plan

Cloud Functions require the pay-as-you-go plan.

1. In the left sidebar, bottom: click the plan name (**Spark**) →
   **Upgrade** → **Blaze**.
2. Link or create a billing account.
3. Recommended: set a **budget alert** (e.g. $5/month). A single-family
   PetMonitor deployment normally stays inside the free tier — the
   functions run for milliseconds per call and Firestore traffic is tiny.

## Step 3 — Enable Authentication providers

1. Sidebar → **Build → Authentication** → **Get started**.
2. **Sign-in method** tab, enable:
   - **Email/Password** → Enable → Save.
   - **Google** → Enable → pick a support email → Save.
   - **Apple** → Enable → Save. *(You can leave the Services ID fields
     empty for now; native Sign in with Apple on iOS only needs the
     provider enabled here plus the capability in Xcode. Finish the Apple
     Developer configuration before shipping — see the note at the end.)*

## Step 4 — Create the Firestore database

1. Sidebar → **Build → Firestore Database** → **Create database**.
2. Location: pick the region closest to your home (e.g. `europe-west3`
   or `us-central1`). **This cannot be changed later.**
3. Start in **production mode** (locked). Our own rules are deployed in
   Step 7 → **Create**.

## Step 5 — Register the apps with FlutterFire

Log the CLIs in, then let `flutterfire` register both apps and generate
the config files:

```powershell
firebase login
flutterfire configure --project <YOUR-PROJECT-ID> --platforms=android,ios
```

- When asked which Android application id to use, accept
  `com.petmonitor.app`.
- The command writes:
  - `lib\firebase_options.dart` (replaces our placeholder — this is
    expected and correct),
  - `android\app\google-services.json`,
  - `ios\Runner\GoogleService-Info.plist`.
- These files are already in `.gitignore` (except `firebase_options.dart`,
  which is safe to commit — it contains public identifiers, not secrets).

Verify: `lib\firebase_options.dart` should now contain real API keys, not
the `UnsupportedError` stub.

## Step 6 — Cloud Messaging / APNs key (for the iPhone owner app)

Android push works out of the box. For iOS notifications:

1. In the [Apple Developer console](https://developer.apple.com/account)
   → **Certificates, Identifiers & Profiles → Keys** → **+**.
2. Name it `PetMonitor APNs`, tick **Apple Push Notifications service
   (APNs)** → Continue → Register → **Download** the `.p8` file (one-time
   download — keep it safe). Note the **Key ID** and your **Team ID**
   (top right of the page).
3. Firebase console → gear icon → **Project settings → Cloud Messaging**
   tab → under **Apple app configuration** → **Upload** the `.p8`, enter
   Key ID and Team ID.
4. In Xcode (`ios\Runner.xcworkspace`), select the Runner target →
   **Signing & Capabilities** → add capabilities:
   - **Push Notifications**
   - **Background Modes** → check *Audio* and *Remote notifications*
   - **Sign in with Apple**

## Step 7 — Deploy rules, indexes, and the functions

```powershell
cd firebase
npm --prefix functions install
firebase use <YOUR-PROJECT-ID>
firebase deploy --only firestore:rules,firestore:indexes,functions
cd ..
```

Expected result: `firestore.rules` released, 2 composite indexes
building, and three functions deployed:

- `onCallSessionCreated` — sends the high-priority FCM wake push,
- `onDeviceEventCreated` — fans out battery/offline alerts to the owner,
- `presenceSweep` — marks stale monitors offline every 5 minutes.

> First-time deploy may ask to enable the Artifact Registry / Cloud Build
> APIs — answer yes. If deploy fails with a permissions error, wait two
> minutes (API enablement propagating) and rerun the same command.

## Step 8 — Verify end to end

1. Build & run the monitor on an Android phone:
   ```powershell
   flutter run -t lib/main_monitor.dart
   ```
   Sign in → the pairing scanner opens (camera permission prompt).
2. Run the owner app (on an iPhone from a Mac, or temporarily on a second
   Android device/emulator for a smoke test):
   ```powershell
   flutter run -t lib/main_owner.dart
   ```
   Sign in with the **same account** → *Add monitor* → QR appears.
3. Scan the QR with the monitor → both screens advance within seconds.
   In the Firebase console → Firestore you should see `devices/{id}` with
   a `status` map, and the `pairings` doc marked `confirmed`.
4. Tap **Call** on the owner app → monitor wakes and auto-answers.
   Console → **Functions → Logs** should show one `onCallSessionCreated`
   invocation per call.

## Step 9 — Production hardening (before real use)

- **App Check**: console → Build → App Check → register both apps
  (Play Integrity for Android, App Attest for iOS) and enforce for
  Firestore + Functions.
- **MFA**: Authentication → Settings → enable multi-factor auth.
- **Firestore TTL**: console → Firestore → TTL → add policies:
  `pairings` on field `expiresAt`, and (optionally) `sessions` on
  `createdAt` + 30 days.
- **Budget alert** if you skipped it in Step 2.
- Full checklist: [SECURITY.md](SECURITY.md#production-hardening-checklist).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `flutterfire configure` says "no Android app found" | Run the `flutter create` command from Prerequisites first |
| Functions deploy: "must be on the Blaze plan" | Step 2 not finished; refresh the console and retry |
| Deploy: `EBUSY`/lock errors on Windows | Delete `firebase\functions\node_modules`, rerun `npm --prefix functions install` |
| Monitor never receives the call push | Check Functions logs for `onCallSessionCreated`; confirm `devices/{id}.fcmToken` exists in Firestore; on the phone disable battery optimization for PetMonitor |
| iOS build fails on `GoogleService-Info.plist` | Open Xcode once and confirm the plist is a member of the Runner target |
| `PERMISSION_DENIED` in the app | Rules not deployed (Step 7) or the two devices are signed into different accounts |
| Google sign-in fails on Android | Add your debug SHA-1 (`cd android; .\gradlew signingReport`) in console → Project settings → your Android app → *Add fingerprint*, then re-download `google-services.json` |

### Note on Sign in with Apple (ship-time requirement)

Apple requires "Sign in with Apple" for App Store apps that offer Google
sign-in. Before submitting the owner app: in the Apple Developer console,
add the *Sign in with Apple* capability to the app's identifier; nothing
extra is needed in Firebase beyond enabling the provider (Step 3).
