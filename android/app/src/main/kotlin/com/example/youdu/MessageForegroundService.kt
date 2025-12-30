package com.example.youdu

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 消息前台服务
 * 用于在应用后台时显示新消息弹窗
 */
class MessageForegroundService : Service() {
    
    companion object {
        const val CHANNEL_ID = "message_service_channel"
        const val MESSAGE_CHANNEL_ID = "new_message_channel"
        const val NOTIFICATION_ID = 2001
        const val MESSAGE_NOTIFICATION_ID = 2002
        
        // Intent 额外数据键
        const val EXTRA_SENDER_NAME = "sender_name"
        const val EXTRA_SENDER_ID = "sender_id"
        const val EXTRA_CONTENT = "content"
        const val EXTRA_MESSAGE_TYPE = "message_type"
        const val EXTRA_IS_GROUP_MESSAGE = "is_group_message"
        const val EXTRA_GROUP_ID = "group_id"
        const val EXTRA_GROUP_NAME = "group_name"
        const val EXTRA_SENDER_AVATAR = "sender_avatar"
        
        // 动作
        const val ACTION_START_SERVICE = "START_MESSAGE_SERVICE"
        const val ACTION_SHOW_MESSAGE_OVERLAY = "SHOW_MESSAGE_OVERLAY"
        const val ACTION_DISMISS_MESSAGE_OVERLAY = "DISMISS_MESSAGE_OVERLAY"
        const val ACTION_STOP_SERVICE = "STOP_MESSAGE_SERVICE"
        
        // 用于跟踪当前的 MessageOverlayActivity 实例
        var currentMessageOverlayActivity: MessageOverlayActivity? = null
        
        // 服务运行状态
        @Volatile
        var isRunning = false
            private set
    }
    
    private val TAG = "MessageForegroundService"
    private val handler = Handler(Looper.getMainLooper())
    private var autoDismissRunnable: Runnable? = null
    
    override fun onCreate() {
        super.onCreate()
        isRunning = true
        Log.d(TAG, "🟢 [MessageForegroundService] ========== onCreate 服务已创建 ==========")
        createNotificationChannels()
    }
    
    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        autoDismissRunnable?.let { handler.removeCallbacks(it) }
        Log.d(TAG, "🔴 [MessageForegroundService] ========== onDestroy 服务已销毁 ==========")
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "📥 [MessageForegroundService] ========== onStartCommand ==========")
        Log.d(TAG, "📥 [MessageForegroundService] action: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START_SERVICE -> {
                Log.d(TAG, "🚀 [MessageForegroundService] 启动前台服务...")
                createNotificationChannels()
                val notification = createServiceNotification()
                
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID, 
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                Log.d(TAG, "✅ [MessageForegroundService] 前台服务已启动")
            }
            ACTION_SHOW_MESSAGE_OVERLAY -> {
                Log.d(TAG, "📨 [MessageForegroundService] 收到显示消息弹窗命令")
                val senderName = intent.getStringExtra(EXTRA_SENDER_NAME) ?: "未知用户"
                val senderId = intent.getIntExtra(EXTRA_SENDER_ID, 0)
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: ""
                val messageType = intent.getStringExtra(EXTRA_MESSAGE_TYPE) ?: "text"
                val isGroupMessage = intent.getBooleanExtra(EXTRA_IS_GROUP_MESSAGE, false)
                val groupId = if (intent.hasExtra(EXTRA_GROUP_ID)) intent.getIntExtra(EXTRA_GROUP_ID, 0) else null
                val groupName = intent.getStringExtra(EXTRA_GROUP_NAME)
                val senderAvatar = intent.getStringExtra(EXTRA_SENDER_AVATAR)
                
                showMessageOverlay(senderName, senderId, content, messageType, isGroupMessage, groupId, groupName, senderAvatar)
            }
            ACTION_DISMISS_MESSAGE_OVERLAY -> {
                Log.d(TAG, "❌ [MessageForegroundService] 收到关闭弹窗命令")
                dismissMessageOverlay()
            }
            ACTION_STOP_SERVICE -> {
                Log.d(TAG, "🛑 [MessageForegroundService] 停止前台服务")
                stopForeground(true)
                stopSelf()
            }
        }
        
        return START_NOT_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
    
    /**
     * 创建通知渠道
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)
            
            // 前台服务通知渠道 - 最小优先级
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "消息服务",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "保持消息服务运行"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            notificationManager.createNotificationChannel(serviceChannel)
            
            // 新消息通知渠道 - 高优先级
            val messageChannel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "新消息通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "显示新消息通知"
                setShowBadge(true)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 200, 100, 200)
                enableLights(true)
                lightColor = android.graphics.Color.BLUE
            }
            notificationManager.createNotificationChannel(messageChannel)
        }
    }
    
    /**
     * 创建前台服务通知（不可见）
     */
    private fun createServiceNotification(): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        )
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("")
            .setContentText("")
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setShowWhen(false)
            .setOngoing(true)
            .build()
    }
    
    /**
     * 显示消息弹窗
     */
    private fun showMessageOverlay(
        senderName: String,
        senderId: Int,
        content: String,
        messageType: String,
        isGroupMessage: Boolean,
        groupId: Int?,
        groupName: String?,
        senderAvatar: String?
    ) {
        Log.d(TAG, "🎯 [MessageForegroundService] 准备启动 MessageOverlayActivity...")
        Log.d(TAG, "   - senderName: $senderName")
        Log.d(TAG, "   - senderId: $senderId")
        Log.d(TAG, "   - content: $content")
        Log.d(TAG, "   - isGroupMessage: $isGroupMessage")
        
        // 取消之前的自动关闭任务
        autoDismissRunnable?.let { handler.removeCallbacks(it) }
        
        val overlayIntent = Intent(this, MessageOverlayActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_SENDER_NAME, senderName)
            putExtra(EXTRA_SENDER_ID, senderId)
            putExtra(EXTRA_CONTENT, content)
            putExtra(EXTRA_MESSAGE_TYPE, messageType)
            putExtra(EXTRA_IS_GROUP_MESSAGE, isGroupMessage)
            if (isGroupMessage && groupId != null) {
                putExtra(EXTRA_GROUP_ID, groupId)
                if (groupName != null) {
                    putExtra(EXTRA_GROUP_NAME, groupName)
                }
            }
            if (senderAvatar != null) {
                putExtra(EXTRA_SENDER_AVATAR, senderAvatar)
            }
        }
        
        try {
            // 🔴 只启动 Activity 弹窗，不发送通知（避免同时显示两个弹窗）
            try {
                startActivity(overlayIntent)
                Log.d(TAG, "✅ [MessageForegroundService] Activity 直接启动成功")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ [MessageForegroundService] Activity 直接启动被阻止，回退到通知: ${e.message}")
                
                // 只有在 Activity 启动失败时才发送通知作为回退方案
                val fullScreenIntent = PendingIntent.getActivity(
                    this,
                    System.currentTimeMillis().toInt(),
                    overlayIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                
                val displayContent = formatMessageContent(messageType, content)
                val title = if (isGroupMessage && groupName != null) {
                    "$senderName ($groupName)"
                } else {
                    senderName
                }
                
                val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(displayContent)
                    .setSmallIcon(android.R.drawable.ic_dialog_email)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                    .setFullScreenIntent(fullScreenIntent, true)
                    .setAutoCancel(true)
                    .build()
                
                val notificationManager = getSystemService(NotificationManager::class.java)
                notificationManager.notify(MESSAGE_NOTIFICATION_ID, notification)
                Log.d(TAG, "✅ [MessageForegroundService] 回退通知已发送")
            }
            
            // 设置自动关闭（5秒后）
            autoDismissRunnable = Runnable {
                dismissMessageOverlay()
            }
            handler.postDelayed(autoDismissRunnable!!, 5000)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageForegroundService] 显示消息弹窗失败: ${e.message}", e)
        }
    }
    
    /**
     * 格式化消息内容
     */
    private fun formatMessageContent(messageType: String, content: String): String {
        return when (messageType) {
            "image" -> "[图片]"
            "file" -> "[文件]"
            "voice" -> "[语音]"
            "video" -> "[视频]"
            "location" -> "[位置]"
            else -> content
        }
    }
    
    /**
     * 关闭消息弹窗
     */
    private fun dismissMessageOverlay() {
        try {
            Log.d(TAG, "❌ [MessageForegroundService] 开始关闭消息弹窗...")
            
            // 取消自动关闭任务
            autoDismissRunnable?.let { handler.removeCallbacks(it) }
            
            // 关闭当前的 MessageOverlayActivity
            currentMessageOverlayActivity?.let { activity ->
                Log.d(TAG, "✅ [MessageForegroundService] 找到活动的弹窗 Activity，正在关闭...")
                activity.finish()
                currentMessageOverlayActivity = null
            }
            
            // 取消消息通知
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.cancel(MESSAGE_NOTIFICATION_ID)
            Log.d(TAG, "✅ [MessageForegroundService] 消息通知已取消")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageForegroundService] 关闭消息弹窗失败: ${e.message}", e)
        }
    }
}
