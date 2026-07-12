/**
 * PetMonitor Cloud Functions — deliberately minimal.
 *
 * FCM's HTTP v1 API requires service-account OAuth credentials, which can
 * never ship inside a client app, so push fan-out is the ONE thing that
 * must run in Firebase's managed environment. These functions:
 *
 *   - never see plaintext: `sealedAuth` and signaling envelopes are
 *     AES-256-GCM ciphertext only the paired devices can open;
 *   - hold no configuration or secrets of their own;
 *   - are pure fire-and-forget fan-out + a presence sweep.
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions/v2";

initializeApp();
const db = getFirestore();

/**
 * Wake the monitor when the owner starts a call.
 *
 * High-priority DATA-ONLY message: it must reach the Doze-idle device
 * immediately and must not show a system notification by itself — the
 * app's background handler posts the full-screen incoming-call intent.
 */
export const onCallSessionCreated = onDocumentCreated(
  "devices/{deviceId}/sessions/{sessionId}",
  async (event) => {
    const session = event.data?.data();
    if (!session || session.state !== "ringing") return;

    const { deviceId, sessionId } = event.params;
    const deviceSnap = await db.doc(`devices/${deviceId}`).get();
    const device = deviceSnap.data();

    // Defence in depth (rules already guarantee this).
    if (!device || device.ownerUid !== session.ownerUid) {
      logger.warn("session/device owner mismatch — not forwarding push");
      return;
    }
    const token = device.fcmToken as string | undefined;
    if (!token) {
      logger.warn("monitor has no FCM token registered");
      return;
    }

    await getMessaging().send({
      token,
      android: { priority: "high", ttl: 45_000 },
      data: { type: "incoming_call", deviceId, sessionId },
    });
  }
);

/** Fan device events (battery low, reboot, offline) out to owner phones. */
export const onDeviceEventCreated = onDocumentCreated(
  "devices/{deviceId}/events/{eventId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const { deviceId } = event.params;
    const device = (await db.doc(`devices/${deviceId}`).get()).data();
    if (!device) return;

    const owner = (await db.doc(`users/${device.ownerUid}`).get()).data();
    const tokens: string[] = Object.keys(owner?.fcmTokens ?? {});
    if (tokens.length === 0) return;

    const bodies: Record<string, string> = {
      battery_low: `Monitor battery is low (${data.battery ?? "?"}%)`,
      device_offline: "Your pet monitor went offline",
      device_online: "Your pet monitor is back online",
      device_rebooted: "Your pet monitor restarted",
      connection_lost: "A call lost its connection",
      app_crashed: "The monitor app recovered from a crash",
    };

    await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: device.name ?? "Pet Monitor",
        body: bodies[data.type as string] ?? `Event: ${data.type}`,
      },
      apns: { payload: { aps: { sound: "default" } } },
    });
  }
);

/**
 * Presence sweep: every 5 minutes, mark devices offline whose heartbeat
 * is stale, and raise a device_offline event exactly once per transition.
 */
export const presenceSweep = onSchedule("every 5 minutes", async () => {
  // Monitor heartbeats every 60s; 3 minutes of silence = offline.
  const staleBefore = Timestamp.fromMillis(Date.now() - 3 * 60 * 1000);
  const snap = await db
    .collection("devices")
    .where("status.online", "==", true)
    .where("status.lastOnline", "<", staleBefore)
    .get();

  for (const doc of snap.docs) {
    await doc.ref.set(
      { status: { online: false } },
      { mergeFields: ["status.online"] }
    );
    await doc.ref.collection("events").add({
      type: "device_offline",
      createdAt: Timestamp.now(),
    });
    logger.info(`marked ${doc.id} offline`);
  }
});
