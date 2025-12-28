package com.example.youdu

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import cn.jpush.android.api.CmdMessage
import cn.jpush.android.api.CustomMessage
import cn.jpush.android.api.JPushMessage
import cn.jpush.android.api.NotificationMessage
import cn.jpush.android.service.JPushMessageReceiver

/**
 * 极光推送消息接收器
 * 用于接收推送消息、通知点击等事件
 */
class JPushReceiver : JPushMessageReceiver() {
    
    companion object {
        private const val TAG = "JPushReceiver"
        private const val CHANNEL_ID = "message_channel_v3"
        private const val NOTIFICATION_ID_BASE = 10000
    }

    /**
     * 收到通知时回调
     * 🔴 JPush SDK 会自动显示通知，这里只做日志记录
     * 🔴 不要在这里创建额外的通知，否则会导致重复和系统节流
     */
    override fun onNotifyMessageArrived(context: Context?, message: NotificationMessage?) {
        Log.d(TAG, "📱 ========== 收到推送通知 ==========")
        Log.d(TAG, "📱 标题: ${message?.notificationTitle}")
        Log.d(TAG, "📱 内容: ${message?.notificationContent}")
        Log.d(TAG, "📱 附加数据: ${message?.notificationExtras}")
        Log.d(TAG, "📱 消息ID: ${message?.msgId}")
        Log.d(TAG, "📱 通知ID: ${message?.notificationId}")
        Log.d(TAG, "📱 ================================")
        
        // 🔴 只做日志记录，让 JPush SDK 自己处理通知显示
        // JPush SDK 会根据服务端配置的 channel_id 和 priority 自动显示通知
        
        if (context != null) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            
            // 检查通知权限状态（仅用于日志）
            val areNotificationsEnabled = notificationManager.areNotificationsEnabled()
            Log.d(TAG, "📱 通知权限状态: ${if (areNotificationsEnabled) "✅ 已开启" else "❌ 已关闭"}")
            
            // 检查通知渠道状态 (Android 8.0+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = notificationManager.getNotificationChannel(CHANNEL_ID)
                if (channel != null) {
                    val importance = channel.importance
                    val importanceStr = when (importance) {
                        NotificationManager.IMPORTANCE_NONE -> "NONE (已禁用)"
                        NotificationManager.IMPORTANCE_MIN -> "MIN (静默)"
                        NotificationManager.IMPORTANCE_LOW -> "LOW (无声音)"
                        NotificationManager.IMPORTANCE_DEFAULT -> "DEFAULT (有声音)"
                        NotificationManager.IMPORTANCE_HIGH -> "HIGH (悬浮通知)"
                        else -> "UNKNOWN ($importance)"
                    }
                    Log.d(TAG, "📱 通知渠道 $CHANNEL_ID 重要性: $importanceStr")
                    Log.d(TAG, "📱 通知渠道是否可以悬浮: ${importance >= NotificationManager.IMPORTANCE_HIGH}")
                } else {
                    Log.w(TAG, "📱 ⚠️ 通知渠道 $CHANNEL_ID 不存在!")
                }
            }
        }
        
        // 🔴 不创建额外通知，完全依赖 JPush SDK 的默认通知
        Log.d(TAG, "📱 ✅ JPush SDK 将自动显示通知")
    }
    
    /**
     * 🔴 显示悬浮通知（Heads-up Notification）
     * 使用固定通知ID更新通知，避免系统节流
     */
    private fun showHeadsUpNotification(
        context: Context,
        title: String,
        content: String,
        extras: String?
    ) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            
            // 确保通知渠道存在（Android 8.0+）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                var channel = notificationManager.getNotificationChannel(CHANNEL_ID)
                if (channel == null) {
                    channel = NotificationChannel(
                        CHANNEL_ID,
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
                    }
                    notificationManager.createNotificationChannel(channel)
                    Log.d(TAG, "📱 [通知渠道] $CHANNEL_ID 已创建 (IMPORTANCE_HIGH)")
                }
            }
            
            // 创建点击通知时打开应用的 Intent
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("from_notification", true)
                putExtra("notification_extras", extras)
            }
            
            val pendingIntent = PendingIntent.getActivity(
                context,
                System.currentTimeMillis().toInt(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            
            // 🔴 构建高优先级通知
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(content)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                // 🔴 使用 setFullScreenIntent 强制触发悬浮通知
                .setFullScreenIntent(pendingIntent, true)
                // 🔴 设置 when 为当前时间，确保系统认为这是新通知
                .setWhen(System.currentTimeMillis())
                .setShowWhen(true)
                .build()
            
            // 🔴 使用基于内容哈希的通知ID，相同发送者的消息会更新而不是创建新通知
            // 这样可以减少系统节流的影响
            val notificationId = NOTIFICATION_ID_BASE + (title.hashCode() and 0xFFFF)
            notificationManager.notify(notificationId, notification)
            
            Log.d(TAG, "📱 ✅ 悬浮通知已显示: $title - $content (ID: $notificationId)")
            
        } catch (e: Exception) {
            Log.e(TAG, "📱 ❌ 显示悬浮通知失败: ${e.message}", e)
        }
    }

    /**
     * 用户点击通知时回调
     */
    override fun onNotifyMessageOpened(context: Context?, message: NotificationMessage?) {
        Log.d(TAG, "📱 用户点击通知: ${message?.notificationTitle}")
        // TODO: 可以在这里处理点击通知后的跳转逻辑
    }

    /**
     * 收到自定义消息（透传消息）时回调
     */
    override fun onMessage(context: Context?, customMessage: CustomMessage?) {
        Log.d(TAG, "📱 收到自定义消息: ${customMessage?.message}")
    }

    /**
     * 注册成功后回调，返回 Registration ID
     */
    override fun onRegister(context: Context?, registrationId: String?) {
        Log.d(TAG, "📱 ========== JPush 注册成功 ==========")
        Log.d(TAG, "📱 Registration ID: $registrationId")
        Log.d(TAG, "📱 ===================================")
    }

    /**
     * 连接状态变化回调
     */
    override fun onConnected(context: Context?, isConnected: Boolean) {
        Log.d(TAG, "📱 JPush 连接状态变化: ${if (isConnected) "✅ 已连接" else "❌ 已断开"}")
    }

    /**
     * 命令消息回调（包含错误码）
     */
    override fun onCommandResult(context: Context?, cmdMessage: CmdMessage?) {
        val errorCode = cmdMessage?.errorCode ?: -1
        val cmd = cmdMessage?.cmd ?: -1
        Log.d(TAG, "📱 命令结果: cmd=$cmd, errorCode=$errorCode")
        
        // 解析常见错误码
        when (errorCode) {
            0 -> Log.d(TAG, "📱 命令执行成功")
            2004 -> Log.e(TAG, "📱 ❌ 错误 2004: 网络不可用")
            2005 -> Log.e(TAG, "📱 ❌ 错误 2005: 网络连接超时")
            6002 -> Log.e(TAG, "📱 ❌ 错误 6002: 设置超时，请重试")
            6011 -> Log.e(TAG, "📱 ❌ 错误 6011: 别名/标签操作正在进行中")
            6012 -> Log.e(TAG, "📱 ❌ 错误 6012: 别名/标签操作失败")
            6013 -> Log.e(TAG, "📱 ❌ 错误 6013: 别名字符串不合法")
            6014 -> Log.e(TAG, "📱 ❌ 错误 6014: 标签数量超出限制")
            6015 -> Log.e(TAG, "📱 ❌ 错误 6015: 别名操作过于频繁")
            6016 -> Log.e(TAG, "📱 ❌ 错误 6016: 标签操作过于频繁")
            6017 -> Log.e(TAG, "📱 ❌ 错误 6017: 别名/标签操作失败，未知错误")
            6018 -> Log.e(TAG, "📱 ❌ 错误 6018: 标签字符串不合法")
            6019 -> Log.e(TAG, "📱 ❌ 错误 6019: 标签/别名操作失败，服务器繁忙")
            6020 -> Log.e(TAG, "📱 ❌ 错误 6020: 标签/别名操作失败，服务器内部错误")
            6021 -> Log.e(TAG, "📱 ❌ 错误 6021: 标签/别名操作失败，AppKey 不存在")
            6022 -> Log.e(TAG, "📱 ❌ 错误 6022: 标签/别名操作失败，Registration ID 不存在")
            else -> Log.w(TAG, "📱 ⚠️ 未知错误码: $errorCode")
        }
    }

    /**
     * 标签操作回调
     */
    override fun onTagOperatorResult(context: Context?, jPushMessage: JPushMessage?) {
        Log.d(TAG, "📱 标签操作结果: tags=${jPushMessage?.tags}, errorCode=${jPushMessage?.errorCode}")
    }

    /**
     * 别名操作回调
     */
    override fun onAliasOperatorResult(context: Context?, jPushMessage: JPushMessage?) {
        val errorCode = jPushMessage?.errorCode ?: -1
        val alias = jPushMessage?.alias ?: ""
        
        Log.d(TAG, "📱 ========== 别名操作结果 ==========")
        Log.d(TAG, "📱 别名: $alias")
        Log.d(TAG, "📱 错误码: $errorCode")
        
        if (errorCode == 0) {
            Log.d(TAG, "📱 ✅ 别名设置成功!")
        } else {
            Log.e(TAG, "📱 ❌ 别名设置失败，错误码: $errorCode")
        }
        Log.d(TAG, "📱 ==================================")
    }

    /**
     * 通知设置回调
     */
    override fun onNotificationSettingsCheck(context: Context?, isOn: Boolean, source: Int) {
        Log.d(TAG, "📱 通知权限状态: ${if (isOn) "✅ 已开启" else "❌ 已关闭"}")
    }
}
