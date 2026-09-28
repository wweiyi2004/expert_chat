package com.wweiyi.expert_chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Keeps the existing Flutter stream's process active; never replays a request. */
class GenerationService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "正在生成", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "接收回复期间保持后台任务运行，完成后自动关闭"
                        setShowBadge(false)
                    },
                )
            }
            val openApp = PendingIntent.getActivity(
                this, 0,
                Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle("正在接收回复")
                .setContentText("可切换应用，生成完成后自动结束后台任务")
                .setContentIntent(openApp)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else 0,
            )
            if (wakeLock?.isHeld != true) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:generation")
                    .apply {
                        setReferenceCounted(false)
                        // Safety cap matching Android's maximum dataSync window.
                        // Normal completion/cancellation releases immediately.
                        acquire(6 * 60 * 60 * 1000L)
                    }
            }
        } catch (error: Exception) {
            Log.w("GenerationService", "Unable to protect background generation", error)
            stopProtection()
        }
        // The live socket belongs to Flutter. Restarting a killed process would
        // strand a notification without a stream, or risk a duplicate request.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15+ requires prompt shutdown when the dataSync budget expires.
        stopProtection()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopProtection()
        super.onTaskRemoved(rootIntent)
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun stopProtection() {
        releaseWakeLock()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "generation_active"
        // Separate from completion notifications (ids below 100000).
        private const val NOTIFICATION_ID = 200001
    }
}
