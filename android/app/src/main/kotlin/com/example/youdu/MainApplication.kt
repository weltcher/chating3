package com.example.youdu

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.util.Log

class MainApplication : Application() {
    
    companion object {
        private const val TAG = "MainApplication"
    }
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)

            // 消息通知渠道
            val messageChannel = NotificationChannel(
                "message_channel_v3",
                "消息通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "新消息提醒通知"
                setShowBadge(true)
                enableLights(true)
                lightColor = android.graphics.Color.BLUE
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 250, 250)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                setBypassDnd(false)
            }
            notificationManager.createNotificationChannel(messageChannel)
            Log.d(TAG, "📱 [通知渠道] message_channel_v3 已创建 (IMPORTANCE_HIGH)")

            // 后台服务通知渠道
            val backgroundChannel = NotificationChannel(
                "youdu_background_service",
                "消息服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持消息连接的后台服务"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(backgroundChannel)

            // 来电通知渠道
            val callChannel = NotificationChannel(
                "youdu_call_channel",
                "来电通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "来电提醒通知"
                setShowBadge(true)
            }
            notificationManager.createNotificationChannel(callChannel)
        }
    }
}
