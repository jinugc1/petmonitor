package com.petmonitor.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the monitor reachable in standby:
 *
 *  * pins the process (battery managers stop killing the app),
 *  * holds a PARTIAL wake lock — on old SoCs the CPU otherwise enters
 *    deep sleep when idle/unplugged and the Dart heartbeat freezes,
 *    which is exactly the "monitor goes offline after a while" failure,
 *  * holds a Wi-Fi lock so the radio stays associated.
 *
 * This deliberately trades idle battery for reachability: a dedicated
 * pet monitor is expected to live on a charger. The screen still
 * sleeps; only the CPU/network stay minimally awake. Everything is
 * released the moment the monitor is unpaired or signed out.
 */
class StandbyService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        acquireLocks()
        if (intent == null) {
            // STICKY restart after a process death (e.g. a crash): the
            // Flutter side is gone, so heartbeats are frozen. Bring the
            // activity back via a full-screen intent so standby resumes
            // without anyone touching the phone.
            postRecoveryNotification()
        }
        // If the OS ever reclaims us, come back automatically.
        return START_STICKY
    }

    private fun postRecoveryNotification() {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    RECOVERY_CHANNEL_ID,
                    "Standby recovery",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val fullScreen = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, RECOVERY_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MAX)
        }
        manager.notify(
            RECOVERY_NOTIFICATION_ID,
            builder
                .setContentTitle("PetMonitor restarting")
                .setContentText("Recovering standby after an interruption")
                .setSmallIcon(android.R.drawable.presence_video_online)
                .setFullScreenIntent(fullScreen, true)
                .setAutoCancel(true)
                .build()
        )
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "petmonitor:standby"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "petmonitor:standby"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            wifiLock?.release()
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Standby",
                    NotificationManager.IMPORTANCE_MIN
                ).apply {
                    description = "Keeps the monitor reachable for calls"
                    setShowBadge(false)
                }
            )
        }

        val tapIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("PetMonitor standing by")
            .setContentText("Ready to receive calls from the owner")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .setContentIntent(tapIntent)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "standby"
        private const val NOTIFICATION_ID = 2001
        private const val RECOVERY_CHANNEL_ID = "standby_recovery"
        private const val RECOVERY_NOTIFICATION_ID = 2002

        fun start(context: Context) {
            val intent = Intent(context, StandbyService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StandbyService::class.java))
        }
    }
}
