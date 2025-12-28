package com.example.youdu

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.util.Log
import cn.jpush.android.api.JPushInterface

class MainApplication : Application() {
    
    companion object {
        private const val TAG = "MainApplication"
    }
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        initJPush()
    }
    
    /**
     * 初始化极光推送
     * 🔴 添加延迟获取 Registration ID，因为 JPush 需要时间连接服务器
     */
    private fun initJPush() {
        Log.d(TAG, "📱 [JPush] 开始初始化...")
        JPushInterface.setDebugMode(true)
        JPushInterface.init(this)
        Log.d(TAG, "📱 [JPush] ✅ 初始化完成")
        
        // 🔴 延迟获取 Registration ID（JPush 需要时间连接服务器）
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val rid = JPushInterface.getRegistrationID(this)
            if (rid.isNullOrEmpty()) {
                Log.w(TAG, "📱 [JPush] ⚠️ Registration ID 仍为空，等待 onRegister 回调")
            } else {
                Log.d(TAG, "📱 [JPush] ✅ Registration ID: $rid")
            }
        }, 3000) // 延迟 3 秒
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)

            // 🔴 消息通知渠道（JPush 推送使用，必须与服务端配置的 channel_id 一致）
            val messageChannel = NotificationChannel(
                "message_channel_v3",
                "消息通知",
                NotificationManager.IMPORTANCE_HIGH  // 高优先级，支持悬浮通知
            ).apply {
                description = "新消息提醒通知"
                setShowBadge(true)
                enableLights(true)
                lightColor = android.graphics.Color.BLUE
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 250, 250)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                setBypassDnd(false)  // 不绕过勿扰模式
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
