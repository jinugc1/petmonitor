# PetMonitor — User guide

## What you need

- Your iPhone (Owner App)
- A spare Android phone (Pet Monitor App) + a charger near your pet's
  favourite spot

## Set up the monitor (once, ~5 minutes)

1. Install **PetMonitor** on both phones.
2. Sign in on **both** phones with the **same account** (email, Google, or
   Apple).
3. iPhone: tap **Add monitor** — a QR code appears.
4. Android: the app opens the camera — **scan the QR code**. The phones
   exchange encryption keys directly; when the QR screen closes on the
   iPhone, pairing is done.
5. Android setup for reliable wake-up:
   - Settings → Apps → PetMonitor → Battery → **Unrestricted**.
   - Allow **Camera**, **Microphone**, **Notifications** (incl. full-screen).
   - Use **swipe** screen lock (or none). Auto-answer will never bypass a
     PIN or fingerprint lock.
6. Plug the Android phone into its charger, screen facing the pet area.
   The screen goes almost black — that's standby. Done.

## Calling your pet

- On the iPhone, your monitor card shows **Online** with battery, network,
  and signal details. Tap **Call**.
- The monitor wakes by itself, shows **your face full screen**, and turns
  on its loudspeaker — no one needs to touch it.
- Talk normally; you'll hear the room in return.

### In-call controls (iPhone)

| Control | What it does |
|---|---|
| Mic button | mute/unmute your voice |
| Camera-switch | flip the monitor between front/rear camera |
| ⚙ More | flashlight, video quality (480/720/1080), monitor volume, restart camera |
| Red button | end the call — the monitor instantly returns to standby |

### On the monitor during a call

The pet sees only your video. A small strip (clock, battery, signal)
appears briefly and hides itself. Taps do nothing (paw-proof); a human
can end the call by **holding a finger in the bottom-right corner for
3 seconds**.

## Notifications you'll receive

- Monitor went **offline** / back online
- Monitor **battery low**
- Monitor **restarted**

## Troubleshooting

| Problem | Fix |
|---|---|
| Monitor shows Offline | Check its Wi-Fi and charger; reopen the app once — it re-registers automatically |
| Call rings but never connects | Both networks may block direct video (rare). Add a TURN relay in settings — see docs/DEPLOYMENT.md §4 |
| Wake-up is slow | Ensure Battery → Unrestricted on the monitor; some brands (Xiaomi/Huawei) need "Autostart" enabled too |
| Screen won't light while locked | Allow "Show on lock screen" / full-screen notifications for PetMonitor |

## Privacy

Everything between your phones is end-to-end encrypted. The video and
audio go **directly** between your iPhone and the monitor; our cloud
components only pass sealed envelopes they cannot open. Nobody — including
the cloud provider — can watch your home.
