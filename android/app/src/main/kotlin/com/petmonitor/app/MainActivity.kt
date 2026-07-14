package com.petmonitor.app

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of the `petmonitor/wake` MethodChannel.
 *
 * Handles the platform capabilities Flutter cannot reach: turning the
 * screen on for an authenticated incoming call, showing over the lock
 * screen, dismissing a non-credential keyguard, and releasing everything
 * afterwards so the device returns to normal sleep behaviour (the
 * low-power standby contract).
 */
class MainActivity : FlutterActivity() {

    private var keepScreenOnWhileCharging = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "petmonitor/wake"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireForCall" -> {
                    acquireForCall()
                    result.success(null)
                }
                "releaseAfterCall" -> {
                    releaseAfterCall()
                    result.success(null)
                }
                "keepScreenOnWhileCharging" -> {
                    keepScreenOnWhileCharging =
                        call.argument<Boolean>("enabled") == true
                    applyChargingScreenPolicy()
                    result.success(null)
                }
                "startStandbyService" -> {
                    StandbyService.start(this)
                    result.success(null)
                }
                "stopStandbyService" -> {
                    StandbyService.stop(this)
                    result.success(null)
                }
                "requestBatteryExemption" -> {
                    requestBatteryExemption()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun acquireForCall() {
        runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

            // Dismiss a swipe-keyguard (never bypasses PIN/biometrics —
            // "unlock screen if permitted").
            val keyguard =
                getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                keyguard.requestDismissKeyguard(this, null)
            }
        }
    }

    private fun releaseAfterCall() {
        runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            applyChargingScreenPolicy()
        }
    }

    /** Pet Mode: keep the screen on only while on the charger. */
    private fun applyChargingScreenPolicy() {
        val charging = isCharging()
        runOnUiThread {
            if (keepScreenOnWhileCharging && charging) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    /** Ask the user to exempt the app from Doze/battery optimization so
     *  standby heartbeats and FCM wake-ups are never throttled. Shows the
     *  system dialog only if not already exempted. */
    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val pm = getSystemService(Context.POWER_SERVICE)
                as android.os.PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        try {
            startActivity(
                Intent(
                    android.provider.Settings
                        .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    android.net.Uri.parse("package:$packageName")
                )
            )
        } catch (_: Exception) {
            // Some OEMs hide this screen; the foreground service still helps.
        }
    }

    private fun isCharging(): Boolean {
        val intent = registerReceiver(
            null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        ) ?: return false
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }
}
