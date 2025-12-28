package com.example.youdu

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)

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

            // 来电通知渠道（如果还没有的话）
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
