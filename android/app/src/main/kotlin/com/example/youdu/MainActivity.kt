package com.example.youdu

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import cn.jpush.android.api.JPushInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity
 * 处理 Flutter 与原生 Android 的通信
 */
class MainActivity : FlutterActivity() {
    
    companion object {
        private const val CALL_CHANNEL = "com.example.youdu/call"
        private const val NOTIFICATION_CHANNEL = "com.example.youdu/notification"
        private const val JPUSH_CHANNEL = "com.example.youdu/jpush"
        private const val MESSAGE_CHANNEL = "com.example.youdu/message"
        private const val TAG = "MainActivity"
    }
    
    private var methodChannel: MethodChannel? = null
    private var notificationChannel: MethodChannel? = null
    private var jpushChannel: MethodChannel? = null
    private var messageChannel: MethodChannel? = null
    private var pendingCallData: Map<String, Any?>? = null
    private var pendingMessageData: Map<String, Any?>? = null
    private var stopAudioReceiver: BroadcastReceiver? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        Log.d(TAG, "🔧 [configureFlutterEngine] 开始配置 Flutter 引擎")
        
        // 创建 MethodChannel
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_CHANNEL
        )
        
        Log.d(TAG, "✅ [configureFlutterEngine] MethodChannel 已创建")
        
        // 设置方法调用处理器
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 启动来电前台服务
                "startCallService" -> {
                    startCallService()
                    result.success(true)
                }
                
                // 显示来电弹窗
                "showCallOverlay" -> {
                    Log.d(TAG, "📲 [MethodChannel] 收到 showCallOverlay 请求")
                    Log.d(TAG, "📲 [MethodChannel] 原始参数: ${call.arguments}")
                    
                    val callerName = call.argument<String>("callerName") ?: "未知来电"
                    val callerId = call.argument<Int>("callerId") ?: 0
                    val callType = call.argument<String>("callType") ?: "voice"
                    val channelName = call.argument<String>("channelName") ?: ""
                    val isGroupCall = call.argument<Boolean>("isGroupCall") ?: false
                    val groupId = call.argument<Int>("groupId")
                    val members = call.argument<List<Map<String, Any>>>("members")
                    
                    Log.d(TAG, "📲 [MethodChannel] 解析后的参数:")
                    Log.d(TAG, "   - callerName: $callerName")
                    Log.d(TAG, "   - callerId: $callerId")
                    Log.d(TAG, "   - callType: $callType")
                    Log.d(TAG, "   - channelName: $channelName")
                    Log.d(TAG, "   - isGroupCall: $isGroupCall")
                    Log.d(TAG, "   - groupId: $groupId")
                    Log.d(TAG, "   - members: ${members?.size ?: 0} 个")
                    if (members != null) {
                        Log.d(TAG, "   - members 详情: $members")
                    }
                    
                    showCallOverlay(callerName, callerId, callType, channelName, isGroupCall, groupId, members)
                    result.success(true)
                }
                
                // 关闭来电弹窗
                "dismissCallOverlay" -> {
                    dismissCallOverlay()
                    result.success(true)
                }
                
                // 停止来电前台服务
                "stopCallService" -> {
                    stopCallService()
                    result.success(true)
                }
                
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // 检查是否有待处理的来电数据
        if (pendingCallData != null) {
            Log.d(TAG, "📲 [configureFlutterEngine] 发现待处理的来电数据，立即发送")
            Log.d(TAG, "📲 待处理的数据: $pendingCallData")
            
            // 🔴 关键：延迟更长时间，确保 Flutter 端完全准备好并且 mobile_home_page 已加载
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (methodChannel != null) {
                    Log.d(TAG, "📤 [configureFlutterEngine] 发送待处理的来电数据到 Flutter")
                    methodChannel?.invokeMethod("onIncomingCall", pendingCallData)
                    pendingCallData = null
                    Log.d(TAG, "✅ [configureFlutterEngine] 待处理的来电数据已发送")
                } else {
                    Log.e(TAG, "❌ [configureFlutterEngine] MethodChannel 仍未准备，无法发送数据")
                }
            }, 1000) // 增加延迟到 1 秒
        }
        
        // 检查是否有待处理的消息数据
        if (pendingMessageData != null) {
            Log.d(TAG, "📨 [configureFlutterEngine] 发现待处理的消息数据，立即发送")
            Log.d(TAG, "📨 待处理的数据: $pendingMessageData")
            
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (messageChannel != null) {
                    Log.d(TAG, "📤 [configureFlutterEngine] 发送待处理的消息数据到 Flutter")
                    messageChannel?.invokeMethod("onMessageTapped", pendingMessageData)
                    pendingMessageData = null
                    Log.d(TAG, "✅ [configureFlutterEngine] 待处理的消息数据已发送")
                } else {
                    Log.e(TAG, "❌ [configureFlutterEngine] MessageChannel 仍未准备，无法发送数据")
                }
            }, 1000)
        }
        
        // 🔴 创建通知设置 MethodChannel
        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_CHANNEL
        )
        
        notificationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 打开应用通知设置页面
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(true)
                }
                // 打开通知渠道设置页面
                "openChannelSettings" -> {
                    val channelId = call.argument<String>("channelId") ?: "message_channel_v3"
                    openChannelSettings(channelId)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        Log.d(TAG, "✅ [configureFlutterEngine] 通知设置 MethodChannel 已创建")
        
        // 🔴 创建极光推送 MethodChannel
        jpushChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            JPUSH_CHANNEL
        )
        
        jpushChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 初始化 JPush
                "init" -> {
                    JPushInterface.setDebugMode(true)
                    JPushInterface.init(applicationContext)
                    Log.d(TAG, "📱 [JPush] 初始化完成")
                    result.success(true)
                }
                // 获取 Registration ID
                "getRegistrationId" -> {
                    val rid = JPushInterface.getRegistrationID(applicationContext)
                    Log.d(TAG, "📱 [JPush] Registration ID: $rid")
                    result.success(rid)
                }
                // 设置别名
                "setAlias" -> {
                    val alias = call.argument<String>("alias") ?: ""
                    val sequence = System.currentTimeMillis().toInt()
                    JPushInterface.setAlias(applicationContext, sequence, alias)
                    Log.d(TAG, "📱 [JPush] 设置别名: $alias")
                    result.success(true)
                }
                // 删除别名
                "deleteAlias" -> {
                    val sequence = System.currentTimeMillis().toInt()
                    JPushInterface.deleteAlias(applicationContext, sequence)
                    Log.d(TAG, "📱 [JPush] 删除别名")
                    result.success(true)
                }
                // 设置标签
                "setTags" -> {
                    val tags = call.argument<List<String>>("tags") ?: emptyList()
                    val sequence = System.currentTimeMillis().toInt()
                    JPushInterface.setTags(applicationContext, sequence, tags.toSet())
                    Log.d(TAG, "📱 [JPush] 设置标签: $tags")
                    result.success(true)
                }
                // 清除所有通知
                "clearAllNotifications" -> {
                    JPushInterface.clearAllNotifications(applicationContext)
                    Log.d(TAG, "📱 [JPush] 清除所有通知")
                    result.success(true)
                }
                // 停止推送
                "stopPush" -> {
                    JPushInterface.stopPush(applicationContext)
                    Log.d(TAG, "📱 [JPush] 停止推送")
                    result.success(true)
                }
                // 恢复推送
                "resumePush" -> {
                    JPushInterface.resumePush(applicationContext)
                    Log.d(TAG, "📱 [JPush] 恢复推送")
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        Log.d(TAG, "✅ [configureFlutterEngine] 极光推送 MethodChannel 已创建")
        
        // 🔴 创建消息弹窗 MethodChannel
        messageChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MESSAGE_CHANNEL
        )
        
        messageChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 显示消息弹窗
                "showMessageOverlay" -> {
                    Log.d(TAG, "📨 [MethodChannel] 收到 showMessageOverlay 请求")
                    
                    val senderName = call.argument<String>("senderName") ?: "未知用户"
                    val senderId = call.argument<Int>("senderId") ?: 0
                    val content = call.argument<String>("content") ?: ""
                    val messageType = call.argument<String>("messageType") ?: "text"
                    val isGroupMessage = call.argument<Boolean>("isGroupMessage") ?: false
                    val groupId = call.argument<Int>("groupId")
                    val groupName = call.argument<String>("groupName")
                    val senderAvatar = call.argument<String>("senderAvatar")
                    
                    Log.d(TAG, "📨 [MethodChannel] 解析后的参数:")
                    Log.d(TAG, "   - senderName: $senderName")
                    Log.d(TAG, "   - senderId: $senderId")
                    Log.d(TAG, "   - content: $content")
                    Log.d(TAG, "   - isGroupMessage: $isGroupMessage")
                    
                    showMessageOverlay(senderName, senderId, content, messageType, isGroupMessage, groupId, groupName, senderAvatar)
                    result.success(true)
                }
                
                // 关闭消息弹窗
                "dismissMessageOverlay" -> {
                    dismissMessageOverlay()
                    result.success(true)
                }
                
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        Log.d(TAG, "✅ [configureFlutterEngine] 消息弹窗 MethodChannel 已创建")
    }
    
    /**
     * 打开应用通知设置页面
     */
    private fun openNotificationSettings() {
        Log.d(TAG, "🔔 打开应用通知设置页面")
        try {
            val intent = Intent().apply {
                when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                        action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    }
                    else -> {
                        action = "android.settings.APP_NOTIFICATION_SETTINGS"
                        putExtra("app_package", packageName)
                        putExtra("app_uid", applicationInfo.uid)
                    }
                }
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "❌ 打开通知设置失败: ${e.message}")
            // 备用方案：打开应用详情页
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = android.net.Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "❌ 打开应用详情页也失败: ${e2.message}")
            }
        }
    }
    
    /**
     * 打开特定通知渠道的设置页面
     */
    private fun openChannelSettings(channelId: String) {
        Log.d(TAG, "🔔 打开通知渠道设置页面: $channelId")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
                }
                startActivity(intent)
            } else {
                // Android 8.0 以下没有通知渠道，打开应用通知设置
                openNotificationSettings()
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ 打开通知渠道设置失败: ${e.message}")
            openNotificationSettings()
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // 🔴 如果是来电相关的 Intent，设置锁屏显示标志，确保直接打开应用
        if (intent?.action == "incoming_call") {
            Log.d(TAG, "🔒 检测到来电 Intent，设置锁屏显示标志，直接打开应用")
            
            // 🔴 关键：设置锁屏显示标志，确保应用直接显示在锁屏上方，不显示系统提醒窗口
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                // Android 8.1+ 使用新 API
                setShowWhenLocked(true)
                setTurnScreenOn(true)
                
                // 🔴 主动请求解锁（Android 8.1+）
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                keyguardManager.requestDismissKeyguard(this, null)
                Log.d(TAG, "🔓 已请求解锁屏幕")
            } else {
                // 旧版本使用窗口标志
                @Suppress("DEPRECATION")
                window.addFlags(
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    android.view.WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                )
            }
            
            Log.d(TAG, "✅ 锁屏显示标志已设置，应用将直接显示")
        }
        
        // 🔴 关键修复：在 onCreate 中就注册广播接收器，确保后台也能收到广播
        registerStopAudioReceiver()
        
        // 检查是否是从来电弹窗打开的
        handleIncomingCallIntent(intent)
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        
        // 🔴 如果是来电相关的 Intent，设置锁屏显示标志
        if (intent?.action == "incoming_call") {
            Log.d(TAG, "🔒 检测到来电 Intent (onNewIntent)，设置锁屏显示标志")
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
                
                // 🔴 主动请求解锁（Android 8.1+）
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                keyguardManager.requestDismissKeyguard(this, null)
                Log.d(TAG, "🔓 已请求解锁屏幕 (onNewIntent)")
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    android.view.WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                )
            }
            
            Log.d(TAG, "✅ 锁屏显示标志已设置 (onNewIntent)")
        }
        
        // 处理新的 Intent
        handleIncomingCallIntent(intent)
    }
    
    /**
     * 处理来电 Intent
     */
    private fun handleIncomingCallIntent(intent: Intent?) {
        Log.d(TAG, "🔍 [handleIncomingCallIntent] 检查 Intent")
        Log.d(TAG, "   - Intent action: ${intent?.action}")
        
        // 处理打开聊天（从消息弹窗点击）
        if (intent?.action == "open_chat") {
            val senderId = intent.getIntExtra(MessageForegroundService.EXTRA_SENDER_ID, 0)
            val senderName = intent.getStringExtra(MessageForegroundService.EXTRA_SENDER_NAME)
            val isGroupMessage = intent.getBooleanExtra(MessageForegroundService.EXTRA_IS_GROUP_MESSAGE, false)
            val groupId = if (intent.hasExtra(MessageForegroundService.EXTRA_GROUP_ID)) {
                intent.getIntExtra(MessageForegroundService.EXTRA_GROUP_ID, 0)
            } else null
            val groupName = intent.getStringExtra(MessageForegroundService.EXTRA_GROUP_NAME)
            
            Log.d(TAG, "📨 [handleIncomingCallIntent] 收到打开聊天请求")
            Log.d(TAG, "   - senderId: $senderId")
            Log.d(TAG, "   - senderName: $senderName")
            Log.d(TAG, "   - isGroupMessage: $isGroupMessage")
            Log.d(TAG, "   - groupId: $groupId")
            
            val messageData = mutableMapOf<String, Any?>(
                "senderId" to senderId,
                "senderName" to senderName,
                "isGroupMessage" to isGroupMessage
            )
            
            if (isGroupMessage && groupId != null) {
                messageData["groupId"] = groupId
                messageData["groupName"] = groupName
            }
            
            // 通知 Flutter 打开聊天页面
            if (messageChannel != null) {
                messageChannel?.invokeMethod("onMessageTapped", messageData)
                Log.d(TAG, "✅ [handleIncomingCallIntent] 已通知 Flutter 打开聊天页面")
            } else {
                // 缓存数据，等待 Flutter 引擎准备好
                Log.d(TAG, "⏳ [handleIncomingCallIntent] MessageChannel 未准备，缓存数据")
                pendingMessageData = messageData
            }
            return
        }
        
        // 处理拒绝通话
        if (intent?.action == "call_rejected") {
            val callerId = intent.getIntExtra(CallForegroundService.EXTRA_CALLER_ID, 0)
            val callType = intent.getStringExtra(CallForegroundService.EXTRA_CALL_TYPE)
            
            Log.d(TAG, "❌ [handleIncomingCallIntent] 收到拒绝通话请求")
            Log.d(TAG, "   - callerId: $callerId")
            Log.d(TAG, "   - callType: $callType")
            
            // 通知 Flutter 发送拒绝消息
            if (methodChannel != null) {
                methodChannel?.invokeMethod("onCallRejected", mapOf(
                    "callerId" to callerId,
                    "callType" to callType
                ))
                Log.d(TAG, "✅ [handleIncomingCallIntent] 已通知 Flutter 发送拒绝消息")
            } else {
                Log.d(TAG, "⚠️ [handleIncomingCallIntent] MethodChannel 未准备")
            }
            return
        }
        
        // 处理来电
        if (intent?.action == "incoming_call") {
            val callerName = intent.getStringExtra(CallForegroundService.EXTRA_CALLER_NAME)
            val callerId = intent.getIntExtra(CallForegroundService.EXTRA_CALLER_ID, 0)
            val callType = intent.getStringExtra(CallForegroundService.EXTRA_CALL_TYPE)
            val channelName = intent.getStringExtra(CallForegroundService.EXTRA_CHANNEL_NAME)
            val isGroupCall = intent.getBooleanExtra(CallForegroundService.EXTRA_IS_GROUP_CALL, false)
            val isAnswered = intent.getBooleanExtra("isAnswered", false) // 🔴 新增：是否已接听
            val groupId = if (intent.hasExtra(CallForegroundService.EXTRA_GROUP_ID)) {
                intent.getIntExtra(CallForegroundService.EXTRA_GROUP_ID, 0)
            } else null
            val members = intent.getStringExtra(CallForegroundService.EXTRA_MEMBERS)
            
            val callTypeStr = if (isGroupCall) "群组通话" else "单人通话"
            Log.d(TAG, "📲 [handleIncomingCallIntent] 收到来电信息:")
            Log.d(TAG, "   - 来电者: $callerName")
            Log.d(TAG, "   - 来电者ID: $callerId")
            Log.d(TAG, "   - 通话类型: $callType ($callTypeStr)")
            Log.d(TAG, "   - 频道名称: $channelName")
            Log.d(TAG, "   - 已接听: $isAnswered") // 🔴 新增日志
            if (isGroupCall) {
                Log.d(TAG, "   - 群组ID: $groupId")
                Log.d(TAG, "   - 成员信息: $members")
            }
            
            val callData = mutableMapOf<String, Any?>(
                "callerName" to callerName,
                "callerId" to callerId,
                "callType" to callType,
                "channelName" to channelName,
                "isGroupCall" to isGroupCall,
                "isAnswered" to isAnswered // 🔴 新增：传递已接听标志
            )
            
            if (isGroupCall && groupId != null) {
                callData["groupId"] = groupId
                if (members != null) {
                    callData["members"] = members
                }
            }
            
            // 如果 methodChannel 已经准备好，直接发送
            if (methodChannel != null) {
                Log.d(TAG, "✅ [handleIncomingCallIntent] MethodChannel 已准备，直接发送")
                methodChannel?.invokeMethod("onIncomingCall", callData)
            } else {
                // 否则缓存数据，等待 Flutter 引擎准备好
                Log.d(TAG, "⏳ [handleIncomingCallIntent] MethodChannel 未准备，缓存数据")
                pendingCallData = callData
            }
        } else {
            Log.d(TAG, "ℹ️ [handleIncomingCallIntent] Intent action 不是 incoming_call")
        }
    }
    
    /**
     * 启动来电前台服务
     */
    private fun startCallService() {
        Log.d(TAG, "🚀 [MainActivity] 启动来电前台服务...")
        
        val serviceIntent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_START_SERVICE
        }
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Log.d(TAG, "📱 [MainActivity] Android 8.0+，使用 startForegroundService")
                startForegroundService(serviceIntent)
            } else {
                Log.d(TAG, "📱 [MainActivity] Android 8.0以下，使用 startService")
                startService(serviceIntent)
            }
            Log.d(TAG, "✅ [MainActivity] 前台服务启动命令已发送")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MainActivity] 启动前台服务失败: ${e.message}", e)
        }
    }
    
    /**
     * 显示来电弹窗
     */
    private fun showCallOverlay(
        callerName: String,
        callerId: Int,
        callType: String,
        channelName: String,
        isGroupCall: Boolean = false,
        groupId: Int? = null,
        members: List<Map<String, Any>>? = null
    ) {
        val callTypeStr = if (isGroupCall) "群组通话" else "单人通话"
        Log.d(TAG, "📲 [MainActivity] 显示来电弹窗: $callerName, 类型: $callType ($callTypeStr)")
        if (isGroupCall) {
            Log.d(TAG, "   - 群组ID: $groupId")
            Log.d(TAG, "   - 成员数: ${members?.size ?: 0}")
        }
        
        val serviceIntent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_SHOW_CALL_OVERLAY
            putExtra(CallForegroundService.EXTRA_CALLER_NAME, callerName)
            putExtra(CallForegroundService.EXTRA_CALLER_ID, callerId)
            putExtra(CallForegroundService.EXTRA_CALL_TYPE, callType)
            putExtra(CallForegroundService.EXTRA_CHANNEL_NAME, channelName)
            putExtra(CallForegroundService.EXTRA_IS_GROUP_CALL, isGroupCall)
            if (isGroupCall && groupId != null) {
                putExtra(CallForegroundService.EXTRA_GROUP_ID, groupId)
                // 将成员列表序列化为 JSON 字符串
                if (members != null) {
                    val membersJson = android.text.TextUtils.join(",", members.map { member ->
                        "{\"user_id\":${member["user_id"]},\"display_name\":\"${member["display_name"]}\"}"
                    })
                    putExtra(CallForegroundService.EXTRA_MEMBERS, "[$membersJson]")
                }
            }
        }
        
        Log.d(TAG, "📤 [MainActivity] 发送显示弹窗命令到服务...")
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }
    
    /**
     * 关闭来电弹窗
     */
    private fun dismissCallOverlay() {
        Log.d(TAG, "❌ [MainActivity] 关闭来电弹窗")
        
        val serviceIntent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_DISMISS_CALL_OVERLAY
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }
    
    /**
     * 停止来电前台服务
     */
    private fun stopCallService() {
        val serviceIntent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_STOP_SERVICE
        }
        startService(serviceIntent)
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
        Log.d(TAG, "📨 [MainActivity] 显示消息弹窗: $senderName")
        Log.d(TAG, "   - content: $content")
        Log.d(TAG, "   - isGroupMessage: $isGroupMessage")
        
        val serviceIntent = Intent(this, MessageForegroundService::class.java).apply {
            action = MessageForegroundService.ACTION_START_SERVICE
        }
        
        // 先启动服务
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MainActivity] 启动消息服务失败: ${e.message}", e)
        }
        
        // 延迟发送显示弹窗命令
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val overlayIntent = Intent(this, MessageForegroundService::class.java).apply {
                action = MessageForegroundService.ACTION_SHOW_MESSAGE_OVERLAY
                putExtra(MessageForegroundService.EXTRA_SENDER_NAME, senderName)
                putExtra(MessageForegroundService.EXTRA_SENDER_ID, senderId)
                putExtra(MessageForegroundService.EXTRA_CONTENT, content)
                putExtra(MessageForegroundService.EXTRA_MESSAGE_TYPE, messageType)
                putExtra(MessageForegroundService.EXTRA_IS_GROUP_MESSAGE, isGroupMessage)
                if (isGroupMessage && groupId != null) {
                    putExtra(MessageForegroundService.EXTRA_GROUP_ID, groupId)
                    if (groupName != null) {
                        putExtra(MessageForegroundService.EXTRA_GROUP_NAME, groupName)
                    }
                }
                if (senderAvatar != null) {
                    putExtra(MessageForegroundService.EXTRA_SENDER_AVATAR, senderAvatar)
                }
            }
            
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(overlayIntent)
                } else {
                    startService(overlayIntent)
                }
                Log.d(TAG, "✅ [MainActivity] 消息弹窗命令已发送")
            } catch (e: Exception) {
                Log.e(TAG, "❌ [MainActivity] 发送消息弹窗命令失败: ${e.message}", e)
            }
        }, 200)
    }
    
    /**
     * 关闭消息弹窗
     */
    private fun dismissMessageOverlay() {
        Log.d(TAG, "❌ [MainActivity] 关闭消息弹窗")
        
        val serviceIntent = Intent(this, MessageForegroundService::class.java).apply {
            action = MessageForegroundService.ACTION_DISMISS_MESSAGE_OVERLAY
        }
        
        try {
            startService(serviceIntent)
        } catch (e: Exception) {
            Log.e(TAG, "❌ [MainActivity] 关闭消息弹窗失败: ${e.message}", e)
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        // 🔴 只在销毁时取消注册广播接收器
        unregisterStopAudioReceiver()
        methodChannel?.setMethodCallHandler(null)
        notificationChannel?.setMethodCallHandler(null)
        jpushChannel?.setMethodCallHandler(null)
        messageChannel?.setMethodCallHandler(null)
    }
    
    /**
     * 注册停止音频广播接收器
     */
    private fun registerStopAudioReceiver() {
        if (stopAudioReceiver != null) {
            Log.d(TAG, "⚠️ 广播接收器已注册，跳过")
            return
        }
        
        stopAudioReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                Log.d(TAG, "📡 收到停止音频广播")
                
                // 通知 Flutter 停止音频
                if (methodChannel != null) {
                    Log.d(TAG, "🔇 通知 Flutter 停止播放音频")
                    methodChannel?.invokeMethod("stopCallAudio", null)
                } else {
                    Log.d(TAG, "⚠️ MethodChannel 未准备，无法停止音频")
                }
            }
        }
        
        val filter = IntentFilter("com.example.youdu.STOP_CALL_AUDIO")
        
        // 🔴 Android 13+ 需要明确指定接收器导出标志
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stopAudioReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(stopAudioReceiver, filter)
        }
        
        Log.d(TAG, "✅ 广播接收器已注册")
    }
    
    /**
     * 取消注册停止音频广播接收器
     */
    private fun unregisterStopAudioReceiver() {
        if (stopAudioReceiver != null) {
            try {
                unregisterReceiver(stopAudioReceiver)
                stopAudioReceiver = null
                Log.d(TAG, "✅ 停止音频广播接收器已取消注册")
            } catch (e: Exception) {
                Log.e(TAG, "❌ 取消注册停止音频广播接收器失败: $e")
            }
        }
    }
}
