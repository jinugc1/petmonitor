package com.petmonitor.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires on BOOT_COMPLETED and after app updates (MY_PACKAGE_REPLACED).
 *
 * It intentionally does almost nothing: merely receiving the broadcast
 * starts the app process, which lets the Firebase Messaging SDK refresh
 * its registration immediately. High-priority FCM pushes then reach the
 * device again without anyone touching the monitor — the automatic
 * recovery requirement, at zero standby cost (no service stays running).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                // Process is now alive; FCM auto-initialization handles the
                // rest. No wake locks, no foreground service.
            }
        }
    }
}
