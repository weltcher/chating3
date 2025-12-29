package com.example.youdu

import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.cardview.widget.CardView

/**
 * 消息弹窗 Activity
 * 用于在锁屏和其他应用上方显示新消息弹窗
 */
class MessageOverlayActivity : AppCompatActivity() {
    
    companion object {
        private const val TAG = "MessageOverlayActivity"
        private const val AUTO_DISMISS_DELAY = 5000L // 5秒后自动关闭
    }
    
    private var senderName: String = ""
    private var senderId: Int = 0
    private var content: String = ""
    private var messageType: String = "text"
    private var isGroupMessage: Boolean = false
    private var groupId: Int? = null
    private var groupName: String? = null
    private var senderAvatar: String? = null
    
    private val handler = Handler(Looper.getMainLooper())
    private var autoDismissRunnable: Runnable? = null
    
    override fun onCreate(savedInstanceState: Bundle?) {
        Log.d(TAG, "🎯 [MessageOverlayActivity] onCreate 开始")
        try {
            super.onCreate(savedInstanceState)
            
            // 注册当前 Activity 实例到服务
            MessageForegroundService.currentMessageOverlayActivity = this
            Log.d(TAG, "📝 [MessageOverlayActivity] 已注册到服务")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageOverlayActivity] super.onCreate 失败: ${e.message}", e)
            return
        }
        
        // 设置为透明窗口，显示在顶部
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        window.addFlags(WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH)
        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN)
        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        
        // 设置窗口位置为顶部
        val layoutParams = window.attributes
        layoutParams.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        layoutParams.y = 50
        layoutParams.width = WindowManager.LayoutParams.MATCH_PARENT
        layoutParams.height = WindowManager.LayoutParams.WRAP_CONTENT
        window.attributes = layoutParams
        
        // 显示在锁屏上方
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
        
        // 获取消息信息
        senderName = intent.getStringExtra(MessageForegroundService.EXTRA_SENDER_NAME) ?: "未知用户"
        senderId = intent.getIntExtra(MessageForegroundService.EXTRA_SENDER_ID, 0)
        content = intent.getStringExtra(MessageForegroundService.EXTRA_CONTENT) ?: ""
        messageType = intent.getStringExtra(MessageForegroundService.EXTRA_MESSAGE_TYPE) ?: "text"
        isGroupMessage = intent.getBooleanExtra(MessageForegroundService.EXTRA_IS_GROUP_MESSAGE, false)
        groupId = if (intent.hasExtra(MessageForegroundService.EXTRA_GROUP_ID)) {
            intent.getIntExtra(MessageForegroundService.EXTRA_GROUP_ID, 0)
        } else null
        groupName = intent.getStringExtra(MessageForegroundService.EXTRA_GROUP_NAME)
        senderAvatar = intent.getStringExtra(MessageForegroundService.EXTRA_SENDER_AVATAR)
        
        Log.d(TAG, "📋 [MessageOverlayActivity] 消息信息:")
        Log.d(TAG, "   - senderName: $senderName")
        Log.d(TAG, "   - senderId: $senderId")
        Log.d(TAG, "   - content: $content")
        Log.d(TAG, "   - isGroupMessage: $isGroupMessage")
        
        // 设置布局
        try {
            setContentView(R.layout.activity_message_overlay)
            Log.d(TAG, "✅ [MessageOverlayActivity] 布局设置完成")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageOverlayActivity] 布局设置失败: ${e.message}", e)
            return
        }
        
        // 初始化视图
        setupViews()
        
        // 设置自动关闭
        autoDismissRunnable = Runnable {
            Log.d(TAG, "⏰ [MessageOverlayActivity] 自动关闭弹窗")
            finish()
        }
        handler.postDelayed(autoDismissRunnable!!, AUTO_DISMISS_DELAY)
        
        Log.d(TAG, "🎉 [MessageOverlayActivity] onCreate 完成")
    }
    
    /**
     * 初始化视图
     */
    private fun setupViews() {
        try {
            val cardView = findViewById<CardView>(R.id.message_card)
            val titleText = findViewById<TextView>(R.id.message_title)
            val contentText = findViewById<TextView>(R.id.message_content)
            val closeButton = findViewById<ImageView>(R.id.close_button)
            
            // 设置标题
            val title = if (isGroupMessage && groupName != null) {
                "$senderName ($groupName)"
            } else {
                senderName
            }
            titleText.text = title
            
            // 设置内容
            val displayContent = formatMessageContent(messageType, content)
            contentText.text = displayContent
            
            // 点击卡片打开应用
            cardView.setOnClickListener {
                Log.d(TAG, "👆 [MessageOverlayActivity] 用户点击消息卡片")
                openMainApp()
            }
            
            // 点击关闭按钮
            closeButton.setOnClickListener {
                Log.d(TAG, "❌ [MessageOverlayActivity] 用户点击关闭按钮")
                finish()
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageOverlayActivity] 初始化视图失败: ${e.message}", e)
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
     * 打开主应用
     */
    private fun openMainApp() {
        Log.d(TAG, "📱 [MessageOverlayActivity] 打开主应用")
        
        // 取消自动关闭
        autoDismissRunnable?.let { handler.removeCallbacks(it) }
        
        // 关闭通知
        dismissNotification()
        
        val mainIntent = Intent(this, MainActivity::class.java).apply {
            action = "open_chat"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            
            // 传递消息信息
            putExtra(MessageForegroundService.EXTRA_SENDER_ID, senderId)
            putExtra(MessageForegroundService.EXTRA_SENDER_NAME, senderName)
            putExtra(MessageForegroundService.EXTRA_IS_GROUP_MESSAGE, isGroupMessage)
            if (isGroupMessage && groupId != null) {
                putExtra(MessageForegroundService.EXTRA_GROUP_ID, groupId)
                putExtra(MessageForegroundService.EXTRA_GROUP_NAME, groupName)
            }
        }
        
        startActivity(mainIntent)
        finish()
    }
    
    /**
     * 关闭通知
     */
    private fun dismissNotification() {
        try {
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.cancel(MessageForegroundService.MESSAGE_NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MessageOverlayActivity] 关闭通知失败: ${e.message}", e)
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        
        // 取消自动关闭任务
        autoDismissRunnable?.let { handler.removeCallbacks(it) }
        
        // 注销当前 Activity 实例
        if (MessageForegroundService.currentMessageOverlayActivity == this) {
            MessageForegroundService.currentMessageOverlayActivity = null
            Log.d(TAG, "📝 [MessageOverlayActivity] 已从服务注销")
        }
        
        Log.d(TAG, "🗑️ [MessageOverlayActivity] onDestroy 完成")
    }
    
    override fun onBackPressed() {
        // 允许返回键关闭
        super.onBackPressed()
    }
}
