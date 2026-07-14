package com.petmonitor.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Minimal foreground service that keeps the monitor process alive in
 * standby. It does NO work itself — no wake locks, no timers — it only
 * pins the process so the Dart heartbeat keeps running and FCM wake
 * pushes always find a live app instead of a battery-killed one.
 *
 * Cost: one persistent low-priority notification. For a phone that
 * lives on a charger as a dedicated pet monitor, this is the intended
 * Android mechanism.
 */
class StandbyService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        // If the OS ever reclaims us, come back automatically.
        return START_STICKY
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
