import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import '../utils/storage.dart';
import '../config/api_config.dart';
import '../utils/logger.dart';
import '../utils/timezone_helper.dart';
import 'local_database_service.dart';
import 'notification_service.dart';
import 'api_service.dart';
import 'native_message_service.dart';
import 'auth_state_service.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  bool _isConnected = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;  // 🔴 重连尝试次数计数器（仅用于计算延迟时间，不限制重连次数）
  String? _token;
  
  // 🔴 静默重连模式：从后台恢复时使用，不触发UI显示"正在连接..."
  bool _isSilentReconnect = false;
  bool get isSilentReconnect => _isSilentReconnect;
  
  // 🔴 记录上次成功连接的时间，用于判断是否需要显示连接状态
  DateTime? _lastConnectedTime;
  static const Duration _silentReconnectThreshold = Duration(minutes: 5); // 5分钟内静默重连
  
  // 🔴 临时存储最近发送的消息信息（用于错误处理）
  // key: receiverId_content的hash, value: {localId, receiverId, content, etc.}
  final Map<String, Map<String, dynamic>> _pendingPrivateMessages = {};
  final Map<String, Map<String, dynamic>> _pendingGroupMessages = {};
  
  // 🔴 心跳检测相关变量
  Timer? _heartbeatTimer;  // 心跳定时器
  int _missedHeartbeats = 0;  // 连续未收到pong响应次数
  static const int _maxMissedHeartbeats = 3;  // 最大允许未响应次数
  bool _waitingForPong = false;  // 是否正在等待pong响应
  bool _intentionalDisconnect = false;  // 🔴 是否是主动断开连接（主动断开不重连）
  bool _isReconnecting = false;  // 🔴 是否正在重连中（防止并发重连）
  bool _isForcedLogout = false;  // 🔴 是否被强制登出（被踢下线后永久禁止重连）
  
  // 🔴 离线消息同步状态
  bool _offlineMessagesSynced = false;  // 私聊离线消息是否已同步
  bool _offlineGroupMessagesSynced = false;  // 群组离线消息是否已同步
  bool get offlineMessagesSynced => _offlineMessagesSynced;
  bool get offlineGroupMessagesSynced => _offlineGroupMessagesSynced;
  
  // 🔴 登录保护期：新登录后短时间内忽略 forced_logout 消息
  DateTime? _loginTime;  // 登录/连接成功的时间
  static const Duration _loginGracePeriod = Duration(seconds: 10);  // 登录保护期10秒
  final _localDb = LocalDatabaseService();
  final _notificationService = NotificationService.instance;

  // 消息流，供外部监听
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  bool get isConnected => _isConnected;
  bool get isForcedLogout => _isForcedLogout;  // 🔴 是否被强制登出

  // WebRTC信令回调
  Function(Map<String, dynamic>)? onWebRTCSignal;

  // 被踢下线回调
  Function(String message)? onForcedLogout;

  // 🔴 重连成功回调：用于通知UI层同步数据
  Function()? onReconnected;
  
  /// 🔴 重置强制登出状态（用户重新登录时调用）
  /// 这会清除被踢下线的标记，允许重新建立 WebSocket 连接
  void resetForcedLogoutState() {
    logger.debug('🔄 [WebSocket] 重置强制登出状态');
    _isForcedLogout = false;
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    _loginTime = null;
  }
  
  /// 🔴 重置离线消息同步状态（重连前调用）
  void _resetOfflineSyncState() {
    _offlineMessagesSynced = false;
    _offlineGroupMessagesSynced = false;
  }

  // 连接到WebSocket服务
  Future<bool> connect({String? token}) async {
    // 🔴 如果被强制登出，禁止重连
    if (_isForcedLogout) {
      logger.debug('🚫 [WebSocket] 已被强制登出，禁止重连');
      return false;
    }
    
    // 🔴 如果已连接，直接返回
    if (_isConnected) {
      return true;
    }
    
    // 🔴 如果正在重连中，等待重连完成
    if (_isReconnecting) {
      logger.debug('🔄 [WebSocket] 正在重连中，跳过本次连接请求');
      return false;
    }

    _isReconnecting = true;  // 🔴 标记开始重连
    _resetOfflineSyncState();  // 🔴 重置离线消息同步状态

    try {
      // 优先使用传入的token，避免从Storage读取被其他窗口覆盖的token
      if (token != null && token.isNotEmpty) {
        _token = token;
      } else {
        // 如果没有传入token，则从Storage获取
        _token = await Storage.getToken();
      }

      if (_token == null || _token!.isEmpty) {
        return false;
      }

      // 使用配置的WebSocket服务器地址和独立端口
      final wsUrl = '${ApiConfig.wsBaseUrl}/ws?token=$_token';
      logger.debug('🔌 [WebSocket] 连接URL: $wsUrl');
      logger.debug('🔌 [WebSocket] wsBaseUrl: ${ApiConfig.wsBaseUrl}');
      logger.debug('🔌 [WebSocket] wsProtocol: ${ApiConfig.wsProtocol}');
      logger.debug('🔌 [WebSocket] useHttps: ${ApiConfig.useHttps}');
      logger.debug('🔌 [WebSocket] kDebugMode: $kDebugMode');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      // 🔴 修复：等待连接就绪，添加超时处理
      try {
        await _channel!.ready.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw TimeoutException('WebSocket连接超时');
          },
        );
      } catch (e) {
        logger.error('❌ [WebSocket] 连接失败: $e');
        _channel?.sink.close();
        _channel = null;
        _isReconnecting = false;  // 🔴 重置重连标志
        _scheduleReconnect();
        return false;
      }

      // 监听消息
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      _isConnected = true;
      _reconnectAttempts = 0;  // 🔴 连接成功，重置重试计数器
      _missedHeartbeats = 0;  // 🔴 重置心跳计数器
      _intentionalDisconnect = false;  // 🔴 连接成功后重置主动断开标志
      _isReconnecting = false;  // 🔴 重置重连标志
      _loginTime = DateTime.now();  // 🔴 记录登录时间，用于登录保护期
      
      // 🔴 启动心跳检测
      _startHeartbeat();
      
      return true;
    } catch (e) {
      logger.error('❌ [WebSocket] connect异常: $e');
      _channel?.sink.close();
      _channel = null;
      _isReconnecting = false;  // 🔴 重置重连标志
      _scheduleReconnect();
      return false;
    }
  }

  // 上线通知回调
  Function(Map<String, dynamic>)? onOnlineNotification;

  // 离线通知回调
  Function(Map<String, dynamic>)? onOfflineNotification;

  // 消息发送错误回调
  Function(String errorType, String errorMessage)? onMessageError;

  // 处理接收到的消息
  Future<void> _onMessage(dynamic data) async {
    try {
      // 处理可能包含多个JSON对象的数据（用换行符分隔）
      final dataString = data as String;
      final lines = dataString.trim().split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;

        try {
          final message = jsonDecode(trimmedLine) as Map<String, dynamic>;
          // 🔴 处理心跳响应
          if (message['type'] == 'pong') {
            _waitingForPong = false;
            _missedHeartbeats = 0;  // 收到响应，重置计数器
            continue;
          }

          // 🚫 处理被踢下线通知
          if (message['type'] == 'forced_logout') {
            final logoutMessage = message['message'] as String? ?? '您的账号已在其他设备登录';
            
            // 🔴 登录保护期检查：新登录后10秒内忽略 forced_logout 消息
            // 这是为了防止服务器错误地将 forced_logout 发送给新登录的设备
            if (_loginTime != null) {
              final timeSinceLogin = DateTime.now().difference(_loginTime!);
              if (timeSinceLogin < _loginGracePeriod) {
                logger.debug('🛡️ [WebSocket] 登录保护期内收到 forced_logout，忽略此消息 (已登录 ${timeSinceLogin.inSeconds} 秒)');
                continue;  // 忽略此消息，继续处理其他消息
              }
            }
            
            logger.debug('🚫 [WebSocket] 收到 forced_logout 消息: $logoutMessage');
            
            // 🔴 关键修复：标记为被强制登出，永久禁止自动重连
            _isForcedLogout = true;
            _intentionalDisconnect = true;
            
            // 🔴 立即停止心跳和重连定时器
            _stopHeartbeat();
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            
            // 🔴 清除登录时间，防止后续消息被保护期过滤
            _loginTime = null;
            
            // 🔴 立即关闭 WebSocket 连接（同步执行，不要异步）
            _isConnected = false;
            _isReconnecting = false;
            if (_channel != null) {
              try {
                _channel!.sink.close(status.goingAway);
              } catch (e) {
                logger.debug('⚠️ [WebSocket] 关闭连接时出错: $e');
              }
              _channel = null;
            }
            
            // 先调用回调通知上层（在断开连接之后）
            if (onForcedLogout != null) {
              onForcedLogout!(logoutMessage);
            }
            
            // 不继续处理其他消息
            return;
          }

          // 🚫 处理私聊消息发送错误通知
          if (message['type'] == 'message_error') {
            final errorData = message['data'] as Map<String, dynamic>? ?? {};
            final errorType = errorData['error'] as String? ?? '发送失败';
            final errorMessage = errorData['message'] as String? ?? '消息发送失败';
            
            // 🔴 从临时存储中获取最后一条私聊消息，插入status为forbidden的消息
            await _handlePrivateMessageError(errorType, errorMessage);
            
            // 调用错误回调通知上层
            if (onMessageError != null) {
              onMessageError!(errorType, errorMessage);
            }
            
            // 将错误消息添加到消息流，以便UI可以显示错误提示
            _messageController.add(message);
            continue;
          }
          
          // 🚫 处理群组消息发送错误通知
          if (message['type'] == 'group_message_error') {
            final errorData = message['data'] as Map<String, dynamic>? ?? {};
            final errorType = errorData['error'] as String? ?? '发送失败';
            
            // 🔴 从临时存储中获取最后一条群组消息，插入status为forbidden的消息
            await _handleGroupMessageError(errorType);
            
            // 将错误消息添加到消息流，以便UI可以显示错误提示  
            _messageController.add(message);
            continue;
          }

          // 处理WebRTC信令消息
          if (message['type'] != null && _isWebRTCSignal(message['type'])) {
            onWebRTCSignal?.call(message['data'] ?? message);
            continue;
          }

          // 处理上线通知消息
          if (message['type'] == 'online_notification') {
            onOnlineNotification?.call(message['data'] ?? {});
            // 上线通知也添加到消息流，以便HomePage可以监听
            _messageController.add(message);
            continue;
          }

          // 处理离线通知消息
          if (message['type'] == 'offline_notification') {
            onOfflineNotification?.call(message['data'] ?? {});
            // 离线通知也添加到消息流，以便HomePage可以监听
            _messageController.add(message);
            continue;
          }

          // 处理群组昵称更新通知
          if (message['type'] == 'group_nickname_updated') {
            await _handleGroupNicknameUpdated(message['data']);
            // 将消息添加到流中，供HomePage处理UI更新
            _messageController.add(message);
            continue;
          }

          // 处理私聊消息 - 保存到本地数据库
          if (message['type'] == 'message' && message['data'] != null) {
            await _savePrivateMessageToLocal(message['data']);
          }

          // 处理群聊消息 - 保存到本地数据库
          if (message['type'] == 'group_message' && message['data'] != null) {
            await _saveGroupMessageToLocal(message['data']);
          }

          // 处理离线私聊消息 - 保存到本地数据库
          if (message['type'] == 'offline_messages' && message['data'] != null) {
            await _handleOfflineMessages(message['data']);
          }

          // 处理离线群组消息 - 保存到本地数据库
          if (message['type'] == 'offline_group_messages' && message['data'] != null) {
            await _handleOfflineGroupMessages(message['data']);
          }
          
          // 🔴 处理服务器发送的离线消息同步完成信号
          if (message['type'] == 'offline_messages_saved') {
            _offlineMessagesSynced = true;
            logger.debug('✅ [WebSocket] 收到服务器私聊离线消息同步完成信号');
          }
          if (message['type'] == 'offline_group_messages_saved') {
            _offlineGroupMessagesSynced = true;
            logger.debug('✅ [WebSocket] 收到服务器群组离线消息同步完成信号');
          }

          // 🔴 调试日志：打印所有收到的消息类型
          final msgType = message['type'] as String?;
          logger.debug('📨 [WebSocket] 收到消息类型: $msgType');
          
          // 🔴 特别关注 update_message_type 消息
          if (msgType == 'update_message_type') {
            logger.debug('📨 [WebSocket] ⭐ 收到 update_message_type 消息!');
            logger.debug('📨 [WebSocket] 消息内容: $message');
            logger.debug('📨 [WebSocket] data字段: ${message['data']}');
          }

          // 通过流发送给监听器
          _messageController.add(message);
          logger.debug('📨 [WebSocket] 已转发消息到监听器: $msgType');
        } catch (e) {
          logger.error('❌ [WebSocket] 解析消息失败: $e');
        }
      }
    } catch (e) {
    }
  }

  // 判断是否是WebRTC信令消息
  bool _isWebRTCSignal(String type) {
    const webrtcTypes = [
      'offer',
      'answer',
      'ice-candidate',
      'call-request',
      'call-accepted',
      'call-rejected',
      'call-ended',
      'incoming_call', // 服务器发送的来电通知
      'incoming_group_call', // 服务器发送的群组来电通知
      'group_call_member_accepted', // 群组通话成员接听通知
      'group_call_member_left', // 群组通话成员离开通知
      'group_call_ended', // 🔴 群组通话结束通知（通知未接听成员关闭来电弹窗）
      'call_rejected', // 服务器发送的拒绝通知
      'call_ended', // 服务器发送的结束通知
    ];
    return webrtcTypes.contains(type);
  }

  // 处理错误
  void _onError(error) {
    final timestamp = DateTime.now().toString();
    _isConnected = false;
    _isReconnecting = false;  // 🔴 关键修复：重置重连标志，确保能触发重连
    _stopHeartbeat();  // 🔴 停止心跳检测
    logger.debug('❌ [WebSocket] 连接错误: $error, 时间: $timestamp');
    
    // 🔴 只有非主动断开时才重连
    if (!_intentionalDisconnect) {
      _scheduleReconnect();
    } else {
      logger.debug('🔄 [WebSocket] 主动断开，不重连');
    }
  }

  // 处理连接关闭
  void _onDone() {
    final timestamp = DateTime.now().toString();
    _isConnected = false;
    _isReconnecting = false;  // 🔴 关键修复：重置重连标志，确保能触发重连
    _stopHeartbeat();  // 🔴 停止心跳检测
    logger.debug('🔌 [WebSocket] 连接关闭, 时间: $timestamp');
    
    // 🔴 只有非主动断开时才重连
    if (!_intentionalDisconnect) {
      _scheduleReconnect();
    } else {
      logger.debug('🔄 [WebSocket] 主动断开，不重连');
    }
  }

  // ==================== 消息重试机制 ====================
  
  /// 带重试机制的消息发送包装器
  /// 
  /// [sendFunction] 实际的发送函数
  /// [messageType] 消息类型描述（用于日志）
  /// [maxRetries] 最大重试次数，默认3次
  /// [retryDelay] 重试间隔，默认3秒
  Future<bool> _sendWithRetry({
    required Future<bool> Function() sendFunction,
    required String messageType,
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 3),
  }) async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      
      try {
        final success = await sendFunction();
        
        if (success) {
          return true;
        }
        
        // 发送失败，判断是否需要重试
        if (attempt < maxRetries) {
          await Future.delayed(retryDelay);
        } else {
          // 已达到最大重试次数
          logger.error(
            '❌ 重复发送失败: [$messageType] 消息发送失败，已重试$maxRetries次，放弃发送',
          );
        }
      } catch (e) {
        logger.error('❌ [$messageType] 发送消息时发生异常: $e');
        
        if (attempt < maxRetries) {
          await Future.delayed(retryDelay);
        } else {
          logger.error(
            '❌ 重复发送失败: [$messageType] 消息发送异常，已重试$maxRetries次，放弃发送',
          );
        }
      }
    }
    
    return false;
  }
  
  // ==================== 私聊消息发送 ====================
  
  /// 获取临时消息列表（供外部访问）
  Map<String, Map<String, dynamic>> getPendingPrivateMessages() {
    return Map.from(_pendingPrivateMessages);
  }

  /// 立即保存最近的临时消息到数据库
  /// 用于在收到 message_sent 确认后立即保存消息
  /// [receiverId] 接收者ID
  /// [serverMessageId] 服务器返回的消息ID（可选，如果提供则直接更新数据库中的消息状态）
  Future<void> saveRecentPendingMessage(int receiverId, {int? serverMessageId}) async {
    try {
      
      // 🔴 修复：如果提供了serverMessageId，直接通过localId查找并更新消息状态
      if (serverMessageId != null) {
        // 查找匹配的临时消息（通过receiverId查找最近的）
        String? targetKey;
        int? targetLocalId;
        DateTime? latestTime;
        
        for (final entry in _pendingPrivateMessages.entries) {
          final msg = entry.value;
          if (msg['receiverId'] == receiverId) {
            final createdAtStr = msg['created_at'] as String?;
            if (createdAtStr != null) {
              try {
                final createdAt = DateTime.parse(createdAtStr);
                if (latestTime == null || createdAt.isAfter(latestTime)) {
                  latestTime = createdAt;
                  targetKey = entry.key;
                  targetLocalId = msg['localId'] as int?;
                }
              } catch (e) {
              }
            }
          }
        }
        
        if (targetLocalId != null) {
          // 直接更新数据库中的消息状态
          final count = await _localDb.updateMessageStatusById(
            localId: targetLocalId,
            status: 'sent',
            serverId: serverMessageId,
          );
          if (count > 0) {
            if (targetKey != null) {
              _pendingPrivateMessages.remove(targetKey);
            }
          } else {
            // 🔴 备用方案：查找数据库中状态为sending的最近消息并更新
            await _updateSendingMessageByReceiverId(receiverId, serverMessageId);
          }
        } else {
          // 🔴 备用方案：查找数据库中状态为sending的最近消息并更新
          await _updateSendingMessageByReceiverId(receiverId, serverMessageId);
        }
        return;
      }
      
      // 原有逻辑：查找最近发送给该接收者的临时消息
      String? targetKey;
      DateTime? latestTime;
      
      for (final entry in _pendingPrivateMessages.entries) {
        final msg = entry.value;
        if (msg['receiverId'] == receiverId) {
          final createdAtStr = msg['created_at'] as String?;
          if (createdAtStr != null) {
            try {
              final createdAt = DateTime.parse(createdAtStr);
              if (latestTime == null || createdAt.isAfter(latestTime)) {
                latestTime = createdAt;
                targetKey = entry.key;
              }
            } catch (e) {
            }
          }
        }
      }
      
      if (targetKey != null && _pendingPrivateMessages.containsKey(targetKey)) {
        final finalMessage = Map<String, dynamic>.from(_pendingPrivateMessages[targetKey]!);
        
        // 🔴 移除不属于数据库表的字段
        finalMessage.remove('localId');
        finalMessage.remove('created_at');
        
        // 🔴 特殊处理：如果是通话拒绝消息，修改内容为"已拒绝"（自己看到的）
        final messageType = finalMessage['message_type'] as String?;
        if (messageType == 'call_rejected' || messageType == 'call_rejected_video') {
          finalMessage['content'] = '已拒绝';
        }
        
        await _localDb.insertMessage(finalMessage);
        _pendingPrivateMessages.remove(targetKey);
      } else {
      }
    } catch (e) {
      logger.error('❌ 保存临时消息失败: $e');
    }
  }
  
  /// 🔴 备用方案：查找数据库中状态为sending的最近消息并更新状态
  /// 当找不到临时消息时使用此方法
  Future<void> _updateSendingMessageByReceiverId(int receiverId, int? serverMessageId) async {
    try {
      final senderId = await Storage.getUserId();
      if (senderId == null) {
        return;
      }
      
      // 🔴 使用LocalDatabaseService的getMessages方法查找消息，然后筛选状态为sending的
      // 注意：getMessages返回的是双向消息，我们需要筛选出sender_id匹配且status为sending的
      final allMessages = await _localDb.getMessages(
        userId1: senderId,
        userId2: receiverId,
        limit: 50, // 只查询最近50条，应该足够找到sending状态的消息
      );
      
      // 筛选出状态为sending且sender_id匹配的消息，按created_at降序排列
      final sendingMessages = allMessages
          .where((msg) => 
              msg['sender_id'] == senderId && 
              msg['receiver_id'] == receiverId &&
              msg['status'] == 'sending')
          .toList();
      
      // 按created_at降序排序，取最近的一条
      sendingMessages.sort((a, b) {
        final aTime = a['created_at'] as String?;
        final bTime = b['created_at'] as String?;
        if (aTime == null || bTime == null) return 0;
        return bTime.compareTo(aTime);
      });
      
      if (sendingMessages.isNotEmpty) {
        final message = sendingMessages.first;
        final localId = message['id'] as int?;
        if (localId != null) {
          final count = await _localDb.updateMessageStatusById(
            localId: localId,
            status: 'sent',
            serverId: serverMessageId,
          );
          if (count > 0) {
          } else {
          }
        }
      } else {
      }
    } catch (e) {
      logger.error('❌ [备用方案] 更新消息状态失败: $e');
    }
  }
  
  /// 发送私聊消息（带自动重试机制）
  /// 
  /// 如果发送失败，会自动重试最多3次，每次间隔3秒
  Future<bool> sendMessage({
    required int receiverId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    String? callType,
    int? voiceDuration, // 语音消息时长（秒）
  }) async {
    return _sendWithRetry(
      sendFunction: () => _executeSendMessage(
        receiverId: receiverId,
        content: content,
        messageType: messageType,
        fileName: fileName,
        quotedMessageId: quotedMessageId,
        quotedMessageContent: quotedMessageContent,
        callType: callType,
        voiceDuration: voiceDuration,
      ),
      messageType: '私聊消息',
    );
  }
  
  /// 执行实际的私聊消息发送（不含重试逻辑）
  Future<bool> _executeSendMessage({
    required int receiverId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    String? callType,
    int? voiceDuration,
  }) async {
    logger.debug('🌐 [WebSocket-私聊] _executeSendMessage被调用');
    logger.debug('   - messageType: $messageType');
    logger.debug('   - voiceDuration参数: $voiceDuration');
    
    if (!_isConnected || _channel == null) {
      final connected = await connect();
      if (!connected) {
        logger.error('❌ [发送消息] 重新连接失败，无法发送消息');
        return false;
      }
    }

    // 🔴 乐观更新：立即插入到本地数据库（状态为sending）
    String? messageKey;
    try {
      final senderId = await Storage.getUserId();
      if (senderId != null) {
        final senderFullName = await Storage.getFullName();
        final senderUsername = await Storage.getUsername();
        final senderAvatar = await Storage.getAvatar();
        
        // 优先使用 fullName，如果为空则使用 username
        final senderName = (senderFullName != null && senderFullName.isNotEmpty) 
            ? senderFullName 
            : (senderUsername ?? 'Unknown');
        
        // 获取接收者信息
        String receiverName = receiverId.toString();
        String? receiverAvatar;
        try {
          final token = await Storage.getToken();
          if (token != null) {
            final userInfo = await ApiService.getUserInfo(receiverId, token: token);
            if (userInfo['code'] == 0 && userInfo['data'] != null) {
              final userData = userInfo['data'];
              receiverName = userData['full_name']?.toString()?.isNotEmpty == true 
                  ? userData['full_name'].toString()
                  : (userData['username']?.toString() ?? receiverId.toString());
              receiverAvatar = userData['avatar']?.toString();
            }
          }
        } catch (e) {
        }
        
        // 创建消息对象（状态为sending）
        // 🔴 时区处理：获取本地时区，转换为上海时区存储
        final shanghaiTimeStr = TimezoneHelper.nowInShanghaiString();
        logger.debug('🕐 [时区-发送私聊] 本地时间转上海时区: $shanghaiTimeStr');
        
        final messageToSave = {
          'sender_id': senderId,
          'receiver_id': receiverId,
          'content': content,
          'message_type': messageType,
          'is_read': 0, // 发送的消息默认为未读状态 (SQLite使用0表示false)
          'created_at': shanghaiTimeStr, // 🔴 使用上海时区时间
          'status': 'sending', // 🔴 关键：设置为sending状态
          'sender_name': senderName,
          'sender_avatar': senderAvatar,
          'receiver_name': receiverName,
          'receiver_avatar': receiverAvatar,
        };
        
        if (fileName != null) messageToSave['file_name'] = fileName;
        if (quotedMessageId != null) messageToSave['quoted_message_id'] = quotedMessageId;
        if (quotedMessageContent != null) messageToSave['quoted_message_content'] = quotedMessageContent;
        if (callType != null) messageToSave['call_type'] = callType;
        if (voiceDuration != null) {
          messageToSave['voice_duration'] = voiceDuration;
          logger.debug('🌐 [WebSocket-私聊] 添加voice_duration到messageToSave: $voiceDuration');
        }
        
        logger.debug('🌐 [WebSocket-私聊] 准备插入本地数据库，messageToSave包含:');
        logger.debug('   - message_type: ${messageToSave['message_type']}');
        logger.debug('   - voice_duration: ${messageToSave['voice_duration']}');
        
        // 🔴 立即插入到本地数据库，获取本地数据库分配的ID
        final localId = await _localDb.insertMessage(messageToSave);
        logger.debug('🌐 [WebSocket-私聊] 本地数据库插入完成，localId=$localId');
        if (localId > 0) {
          
          // 🔴 使用receiverId+content作为key，保存localId到临时存储
          messageKey = '${receiverId}_${content.hashCode}';
          final now = DateTime.now().toUtc().toIso8601String();
          _pendingPrivateMessages[messageKey] = {
            'localId': localId,
            'receiverId': receiverId,
            'content': content,
            'created_at': now, // 🔴 修复：添加created_at字段，用于查找临时消息
          };
        } else {
        }
      }
    } catch (e) {
    }

    final data = <String, dynamic>{
      'receiver_id': receiverId,
      'content': content,
      'message_type': messageType,
    };

    if (fileName != null && fileName.isNotEmpty) {
      data['file_name'] = fileName;
    }

    if (quotedMessageId != null) {
      data['quoted_message_id'] = quotedMessageId;
    }

    if (quotedMessageContent != null && quotedMessageContent.isNotEmpty) {
      data['quoted_message_content'] = quotedMessageContent;
    }

    if (callType != null && callType.isNotEmpty) {
      data['call_type'] = callType;
    }

    if (voiceDuration != null) {
      data['voice_duration'] = voiceDuration;
      logger.debug('🌐 [WebSocket-私聊] 添加voice_duration到WebSocket消息: $voiceDuration');
    }

    final message = {'type': 'message', 'data': data};
    
    logger.debug('🌐 [WebSocket-私聊] 准备发送WebSocket消息:');
    logger.debug('   - data包含: ${data.keys.toList()}');
    logger.debug('   - voice_duration值: ${data['voice_duration']}');

    try {
      final messageJson = jsonEncode(message);
      logger.debug('🌐 [WebSocket-私聊] JSON编码完成，准备发送');
      
      _channel!.sink.add(messageJson);
      
      return true;
    } catch (e) {
      // 发送失败时从待处理列表中移除
      if (messageKey != null) {
        _pendingPrivateMessages.remove(messageKey);
      }
      return false;
    }
  }
  

  // ==================== 群组消息发送 ====================
  
  /// 发送群组消息（带自动重试机制）
  /// 
  /// 如果发送失败，会自动重试最多3次，每次间隔3秒
  Future<bool> sendGroupMessage({
    required int groupId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    List<int>? mentionedUserIds,
    String? mentions,
    String? callType,
    int? voiceDuration, // 语音消息时长（秒）
  }) async {
    return _sendWithRetry(
      sendFunction: () => _executeSendGroupMessage(
        groupId: groupId,
        content: content,
        messageType: messageType,
        fileName: fileName,
        quotedMessageId: quotedMessageId,
        quotedMessageContent: quotedMessageContent,
        mentionedUserIds: mentionedUserIds,
        mentions: mentions,
        callType: callType,
        voiceDuration: voiceDuration,
      ),
      messageType: '群组消息',
    );
  }
  
  /// 执行实际的群组消息发送（不含重试逻辑）
  Future<bool> _executeSendGroupMessage({
    required int groupId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    List<int>? mentionedUserIds,
    String? mentions,
    String? callType,
    int? voiceDuration,
  }) async {
    logger.debug('🌐 [WebSocket-群组] _executeSendGroupMessage被调用');
    logger.debug('   - messageType: $messageType');
    logger.debug('   - voiceDuration参数: $voiceDuration');
    
    if (!_isConnected || _channel == null) {
      final connected = await connect();
      if (!connected) {
        return false;
      }
    }

    // 🔴 乐观更新：立即插入到本地数据库（状态为sending）
    String? messageKey;
    try {
      final senderId = await Storage.getUserId();
      if (senderId != null) {
        final senderFullName = await Storage.getFullName();
        final senderUsername = await Storage.getUsername();
        final senderAvatar = await Storage.getAvatar();
        
        // 优先使用 fullName，如果为空则使用 username
        final senderName = (senderFullName != null && senderFullName.isNotEmpty) 
            ? senderFullName 
            : (senderUsername ?? 'Unknown');
        
        // 获取群组信息
        String? groupName;
        String? groupAvatar;
        try {
          final token = await Storage.getToken();
          if (token != null && token.isNotEmpty) {
            final groupResponse = await ApiService.getGroupDetail(
              token: token,
              groupId: groupId,
            );
            if (groupResponse['code'] == 0 && groupResponse['data'] != null) {
              final groupData = groupResponse['data']['group'] as Map<String, dynamic>;
              groupName = groupData['name'] as String?;
              groupAvatar = groupData['avatar'] as String?;
            }
          }
        } catch (e) {
        }
        
        // 创建消息对象（状态为sending）
        // 🔴 时区处理：获取本地时区，转换为上海时区存储
        final shanghaiTimeStr = TimezoneHelper.nowInShanghaiString();
        logger.debug('🕐 [时区-发送群组] 本地时间转上海时区: $shanghaiTimeStr');
        
        final messageToSave = {
          'group_id': groupId,
          'sender_id': senderId,
          'sender_name': senderName,
          'sender_avatar': senderAvatar,
          'group_name': groupName,
          'group_avatar': groupAvatar,
          'content': content,
          'message_type': messageType,
          'created_at': shanghaiTimeStr, // 🔴 使用上海时区时间
          'status': 'sending',  // 🔴 关键：设置为sending状态
        };
        
        if (fileName != null) messageToSave['file_name'] = fileName;
        if (quotedMessageId != null) messageToSave['quoted_message_id'] = quotedMessageId;
        if (quotedMessageContent != null) messageToSave['quoted_message_content'] = quotedMessageContent;
        if (mentionedUserIds != null && mentionedUserIds.isNotEmpty) {
          messageToSave['mentioned_user_ids'] = mentionedUserIds.join(',');
        }
        if (mentions != null) messageToSave['mentions'] = mentions;
        if (callType != null) messageToSave['call_type'] = callType;
        if (voiceDuration != null) {
          messageToSave['voice_duration'] = voiceDuration;
          logger.debug('🌐 [WebSocket-群组] 添加voice_duration到messageToSave: $voiceDuration');
        }
        
        logger.debug('🌐 [WebSocket-群组] 准备插入本地数据库，messageToSave包含:');
        logger.debug('   - message_type: ${messageToSave['message_type']}');
        logger.debug('   - voice_duration: ${messageToSave['voice_duration']}');
        
        // 🔴 立即插入到本地数据库，获取本地数据库分配的ID
        final localId = await _localDb.insertGroupMessage(messageToSave);
        logger.debug('🌐 [WebSocket-群组] 本地数据库插入完成，localId=$localId');
        if (localId > 0) {
          
          // 🔴 使用groupId+content作为key，保存localId到临时存储
          messageKey = '${groupId}_${content.hashCode}';
          _pendingGroupMessages[messageKey] = {
            'localId': localId,
            'groupId': groupId,
            'content': content,
          };
        } else {
        }
      }
    } catch (e) {
    }

    final data = <String, dynamic>{
      'group_id': groupId,
      'content': content,
      'message_type': messageType,
    };

    if (fileName != null && fileName.isNotEmpty) {
      data['file_name'] = fileName;
    }

    if (quotedMessageId != null) {
      data['quoted_message_id'] = quotedMessageId;
    }

    if (quotedMessageContent != null && quotedMessageContent.isNotEmpty) {
      data['quoted_message_content'] = quotedMessageContent;
    }

    if (mentionedUserIds != null && mentionedUserIds.isNotEmpty) {
      data['mentioned_user_ids'] = mentionedUserIds;
    }

    if (mentions != null && mentions.isNotEmpty) {
      data['mentions'] = mentions;
    }

    if (callType != null && callType.isNotEmpty) {
      data['call_type'] = callType;
    }

    if (voiceDuration != null) {
      data['voice_duration'] = voiceDuration;
      logger.debug('🌐 [WebSocket-群组] 添加voice_duration到WebSocket消息: $voiceDuration');
    }

    final message = {'type': 'group_message_send', 'data': data};
    
    logger.debug('🌐 [WebSocket-群组] 准备发送WebSocket消息:');
    logger.debug('   - data包含: ${data.keys.toList()}');
    logger.debug('   - voice_duration值: ${data['voice_duration']}');

    try {
      _channel!.sink.add(jsonEncode(message));
      logger.debug('🌐 [WebSocket-群组] WebSocket消息已发送');
      
      return true;
    } catch (e) {
      // 发送失败时从待处理列表中移除
      if (messageKey != null) {
        _pendingGroupMessages.remove(messageKey);
      }
      return false;
    }
  }
  

  // 发送已读回执（旧的，单条消息）
  void sendReadReceipt(int messageId) {
    if (!_isConnected || _channel == null) {
      return;
    }

    final message = {
      'type': 'read_receipt',
      'data': {'message_id': messageId},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
    }
  }

  // 🔴 修复：发送已读回执（新的，按联系人批量标记）
  void sendReadReceiptForContact(int senderId) {
    if (!_isConnected || _channel == null) {
      return;
    }

    final message = {
      'type': 'read_receipt',
      'data': {'sender_id': senderId},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
    }
  }

  // 发送状态变更
  Future<bool> sendStatusChange(String status) async {
    if (!_isConnected || _channel == null) {
      final connected = await connect();
      if (!connected) {
        return false;
      }
    }

    // 验证状态
    const validStatuses = ['online', 'busy', 'away', 'offline'];
    if (!validStatuses.contains(status)) {
      return false;
    }

    final message = {
      'type': 'status_change',
      'data': {'status': status},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      return false;
    }
  }

  // 🔴 心跳检测：每5秒发送一次ping消息保持连接
  void _startHeartbeat() {
    _stopHeartbeat();
    
    // 每5秒发送一次ping消息
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_isConnected || _channel == null) {
        timer.cancel();
        return;
      }
      
      try {
        // 发送ping消息
        final pingMessage = {'type': 'ping'};
        _channel!.sink.add(jsonEncode(pingMessage));
        logger.debug('💓 [心跳] 发送ping消息');
      } catch (e) {
        logger.error('❌ [心跳] 发送ping失败: $e');
      }
    });
    
    logger.debug('💓 [心跳] 已启动心跳定时器（5秒间隔）');
  }
  
  // 🔴 停止心跳检测
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _waitingForPong = false;
    _missedHeartbeats = 0;
  }

  // 计划重连（带指数退避）- 🔴 断开后延迟重连，一直尝试直到成功
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    
    // 🔴 如果被强制登出，永久禁止重连
    if (_isForcedLogout) {
      logger.debug('🚫 [WebSocket] 已被强制登出，禁止重连');
      return;
    }
    
    // 🔴 如果是主动断开，不重连
    if (_intentionalDisconnect) {
      logger.debug('🔄 [WebSocket] 主动断开，不重连');
      return;
    }
    
    // 🔴 关键修复：移除 _isReconnecting 检查，因为 Timer 回调中需要能够继续重连
    // _isReconnecting 标志只用于防止 connect() 被并发调用
    
    _reconnectAttempts++;  // 🔴 增加重连计数
    
    // 🔴 PC端连续5次连接失败后自动退登
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (isDesktop && _reconnectAttempts >= 5) {
      logger.debug('🚫 [WebSocket] PC端连续${_reconnectAttempts}次连接失败，触发自动退登');
      _isForcedLogout = true;
      _intentionalDisconnect = true;
      
      // 触发全局登出处理
      AuthStateService().handleTokenInvalid('当前账号已有设备登录，请重新登录');
      return;
    }
    
    // 🔴 使用指数退避策略计算延迟时间
    // 第1次: 2秒, 第2次: 4秒, 第3次: 8秒, 第4次及以后: 15秒
    // 🔴 移除最大重连次数限制，一直尝试直到成功
    int delaySeconds;
    if (_reconnectAttempts <= 3) {
      delaySeconds = 2 * (1 << (_reconnectAttempts - 1)); // 2, 4, 8
    } else {
      delaySeconds = 15; // 超过3次后固定15秒间隔
    }
    
    logger.debug('🔄 [WebSocket] 检测到断开，${delaySeconds}秒后尝试重连（第$_reconnectAttempts次，将持续尝试直到成功）');
    
    // 🔴 延迟重连
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      // 🔴 再次检查是否被强制登出
      if (_isForcedLogout) {
        logger.debug('🚫 [WebSocket] 重连前检测到已被强制登出，取消重连');
        return;
      }
      
      // 🔴 再次检查是否是主动断开
      if (_intentionalDisconnect) {
        logger.debug('🔄 [WebSocket] 重连前检测到主动断开，取消重连');
        return;
      }
      
      // 🔴 关键修复：在调用 connect() 之前重置 _isReconnecting，确保 connect() 能正常执行
      _isReconnecting = false;
      
      final success = await connect();
      
      if (success) {
        // 🔴 重连成功，重置计数器并通知UI层同步数据
        _reconnectAttempts = 0;
        logger.debug('✅ [WebSocket] 重连成功，触发数据同步回调');
        onReconnected?.call();
      } else {
        // 🔴 重连失败，继续尝试（不限制次数）
        logger.debug('🔄 [WebSocket] 重连失败，将继续尝试...');
        // 🔴 关键修复：connect() 失败时会自动调用 _scheduleReconnect()
        // 但如果 connect() 因为 _isReconnecting 检查而提前返回，需要手动调用
        if (!_isReconnecting) {
          _scheduleReconnect();
        }
      }
    });
  }
  
  /// 🔴 新增：强制重连（用于后台服务检测到断开时调用）
  /// 重置所有状态并立即尝试重连
  Future<bool> forceReconnect() async {
    logger.debug('🔄 [WebSocket] 强制重连被调用');
    
    // 重置所有状态
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    
    // 如果已连接，先断开
    if (_channel != null) {
      try {
        _channel!.sink.close(status.goingAway);
      } catch (e) {
        logger.debug('⚠️ [WebSocket] 关闭旧连接时出错: $e');
      }
      _channel = null;
    }
    _isConnected = false;
    _stopHeartbeat();
    
    // 立即尝试连接
    return await connect();
  }

  // 断开连接
  Future<void> disconnect({bool sendOfflineStatus = false}) async {
    // 🔴 标记为主动断开，防止自动重连
    _intentionalDisconnect = true;
    
    // 如果需要发送离线状态，先发送再断开
    if (sendOfflineStatus && _isConnected && _channel != null) {
      try {
        await sendStatusChange('offline');
        // 等待一小段时间确保消息发送
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
      }
    }

    _reconnectTimer?.cancel();
    _stopHeartbeat();  // 🔴 停止心跳检测

    if (_channel != null) {
      _channel!.sink.close(status.goingAway);
      _channel = null;
    }

    _isConnected = false;
  }

  // 发送正在输入指示器
  Future<bool> sendTypingIndicator({
    required int receiverId,
    required bool isTyping,
  }) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    final message = {
      'type': 'typing_indicator',
      'data': {'receiver_id': receiverId, 'is_typing': isTyping},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      return false;
    }
  }

  // 发送WebRTC信令
  Future<bool> sendWebRTCSignal(Map<String, dynamic> data) async {
    if (!_isConnected || _channel == null) {
      final connected = await connect();
      if (!connected) {
        return false;
      }
    }

    final type = data['type'];
    final message = {'type': type, 'data': data};

    try {
      _channel!.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      return false;
    }
  }

  // 发送消息撤回
  Future<bool> sendMessageRecall({
    required int messageId,
    required int userId,
    required bool isGroup,
  }) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    final message = {
      'type': 'message_recall',
      'data': {'messageId': messageId, 'userId': userId, 'isGroup': isGroup},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      return false;
    }
  }

  // 发送消息删除
  Future<bool> sendMessageDelete({
    required int messageId,
    required int userId,
    required bool isGroup,
  }) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    final message = {
      'type': 'message_delete',
      'data': {'messageId': messageId, 'userId': userId, 'isGroup': isGroup},
    };

    try {
      _channel!.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      return false;
    }
  }

  // 保存私聊消息到本地数据库
  Future<void> _savePrivateMessageToLocal(
    Map<String, dynamic> messageData,
  ) async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📨 [_savePrivateMessageToLocal] 收到私聊消息');
      logger.debug('📨 [_savePrivateMessageToLocal] message_type: ${messageData['message_type']}');
      logger.debug('📨 [_savePrivateMessageToLocal] content: ${messageData['content']}');
      logger.debug('📨 [_savePrivateMessageToLocal] sender_id: ${messageData['sender_id']}');
      logger.debug('📨 [_savePrivateMessageToLocal] receiver_id: ${messageData['receiver_id']}');
      
      // 🔴 特殊日志：通话相关消息
      final msgType = messageData['message_type']?.toString() ?? '';
      final content = messageData['content']?.toString() ?? '';
      if (msgType.contains('call_')) {
        logger.debug('📞 [_savePrivateMessageToLocal] ⭐⭐⭐ 检测到通话相关消息!');
        logger.debug('📞 [_savePrivateMessageToLocal] 消息类型: $msgType');
        logger.debug('📞 [_savePrivateMessageToLocal] 消息内容: $content');
      }
      
      // 🔴 乐观更新：检查是否是自己发送的消息回传
      // 服务器会回传消息给发送者（用于多端同步）
      final currentUserId = await Storage.getUserId();
      final senderId = messageData['sender_id'];

      logger.debug('📨 [_savePrivateMessageToLocal] currentUserId: $currentUserId, senderId: $senderId');

      // 🔴 过滤掉自己发送的"对方已取消"和"对方已拒绝"消息
      // 当自己取消或拒绝通话时，会发送这些消息给对方，但自己不应该看到这些消息
      if (currentUserId != null && senderId == currentUserId) {
        if ((msgType == 'call_cancelled' || msgType == 'call_cancelled_video' ||
             msgType == 'call_rejected' || msgType == 'call_rejected_video') &&
            content.contains('对方')) {
          logger.debug('🚫 [_savePrivateMessageToLocal] 过滤掉自己发送的"$content"消息，不保存到数据库');
          return;
        }
      }

      if (currentUserId != null && senderId == currentUserId) {
        logger.debug('📨 [_savePrivateMessageToLocal] 这是自己发送的消息回传');
        
        final receiverId = messageData['receiver_id'];
        final serverId = messageData['id'];
        
        logger.debug('🔴 [_savePrivateMessageToLocal] 检测到自己发送的消息回传 - serverId: $serverId, receiverId: $receiverId, content: $content');
        
        // 🔴 关键：使用receiverId+content查找临时存储中的localId
        final messageKey = '${receiverId}_${content.hashCode}';
        final pendingMsg = _pendingPrivateMessages[messageKey];
        
        logger.debug('🔴 [_savePrivateMessageToLocal] 查找临时消息 - messageKey: $messageKey, 找到: ${pendingMsg != null}');
        
        if (pendingMsg != null) {
          final localId = pendingMsg['localId'] as int;
          
          logger.debug('🔴 [_savePrivateMessageToLocal] 更新消息状态 - localId: $localId, serverId: $serverId');
          
          // 🔴 根据localId更新消息状态和服务器ID
          final count = await _localDb.updateMessageStatusById(
            localId: localId,
            status: 'sent',
            serverId: serverId,
          );
          
          logger.debug('🔴 [_savePrivateMessageToLocal] 更新结果 - count: $count');
          
          if (count > 0) {
            logger.debug('✅ [_savePrivateMessageToLocal] 消息状态和serverId更新成功');
          }
          
          // 从临时存储移除
          _pendingPrivateMessages.remove(messageKey);
        } else {
          // 如果没找到，可能是多端同步的消息，正常插入
          logger.debug('⚠️ [_savePrivateMessageToLocal] 未找到临时消息，作为新消息插入');
          await _insertPrivateMessageToLocal(messageData);
        }
        return;
      }
      
      // 其他人发送的消息，正常插入
      logger.debug('📨 [_savePrivateMessageToLocal] 其他人发送的消息，正常插入 - senderId: $senderId');
      await _insertPrivateMessageToLocal(messageData);
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e) {
      logger.error('❌ [_savePrivateMessageToLocal] 异常: $e');
    }
  }

  // 插入私聊消息到本地数据库（实际插入逻辑）
  Future<void> _insertPrivateMessageToLocal(
    Map<String, dynamic> messageData,
  ) async {
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('📝 [_insertPrivateMessageToLocal] 开始处理消息');
    logger.debug('   - messageData[\'id\']: ${messageData['id']}');
    logger.debug('   - message_type: ${messageData['message_type']}');
    logger.debug('   - voice_duration: ${messageData['voice_duration']}');
    logger.debug('   - sender_id: ${messageData['sender_id']}');
    logger.debug('   - receiver_id: ${messageData['receiver_id']}');
    logger.debug('   - content: ${messageData['content']}');
    
    // 🔴 特殊日志：通话相关消息
    final msgType = messageData['message_type']?.toString() ?? '';
    if (msgType.contains('call_')) {
      logger.debug('📞 [_insertPrivateMessageToLocal] ⭐ 检测到通话相关消息!');
      logger.debug('📞 [_insertPrivateMessageToLocal] 消息类型: $msgType');
      logger.debug('📞 [_insertPrivateMessageToLocal] 消息内容: ${messageData['content']}');
    }
    
    // 🔴 特殊处理：如果是"请求添加好友【已通过】"或"请求添加好友【已驳回】"消息
    // 清空该会话的所有历史消息，只保留最新的这条
    final content = messageData['content']?.toString() ?? '';
    final senderId = messageData['sender_id'] as int?;
    final receiverId = messageData['receiver_id'] as int?;
    
    if ((content == '请求添加好友【已通过】' || content == '请求添加好友【已驳回】') && 
        senderId != null && receiverId != null) {
      logger.debug('🔄 [_insertPrivateMessageToLocal] 检测到好友审核消息，清空会话历史');
      await _localDb.deleteMessagesBetweenUsers(senderId, receiverId);
      logger.debug('✅ [_insertPrivateMessageToLocal] 已清空 $senderId 和 $receiverId 之间的历史消息');
      
      // 🔴 通知 UI 清空聊天界面的消息列表，并传递消息内容用于更新未读数
      _messageController.add({
        'type': 'clear_chat_history',
        'data': {
          'user_id': senderId,
          'contact_id': receiverId,
          'content': content, // 🔴 传递消息内容，用于判断是否需要更新未读数
          'sender_name': messageData['sender_name'],
          'sender_avatar': messageData['sender_avatar'],
          'created_at': messageData['created_at'],
        },
      });
      logger.debug('📢 [_insertPrivateMessageToLocal] 已发送清空聊天历史通知');
    }
    
    // 处理is_read字段：既要兼容旧数据的整数，又要处理新的布尔值
    final isReadValue = messageData['is_read'];
    final isReadInt = isReadValue is bool 
        ? (isReadValue ? 1 : 0) 
        : (isReadValue ?? 0);
    
    // 🔴 时区处理：服务器发送的是 UTC 时间，需要转换为上海时区
    String createdAtStr;
    if (messageData['created_at'] != null) {
      final shanghaiTime = TimezoneHelper.parseToShanghaiTime(
        messageData['created_at'].toString(),
        assumeUtc: true,
      );
      createdAtStr = shanghaiTime.toIso8601String().replaceAll('Z', '');
    } else {
      createdAtStr = TimezoneHelper.nowInShanghaiString();
    }
    
    final message = {
      'server_id': messageData['id'], // 保存服务器返回的消息ID
      'sender_id': messageData['sender_id'],
      'receiver_id': messageData['receiver_id'],
      'content': messageData['content'],
      'message_type': messageData['message_type'] ?? 'text',
      'is_read': isReadInt, // SQLite使用整数0/1而不是布尔值
      'created_at': createdAtStr, // 🔴 使用上海时区时间
      'sender_name': messageData['sender_name'],
      'receiver_name': messageData['receiver_name'],
      'file_name': messageData['file_name'],
      'quoted_message_id': messageData['quoted_message_id'],
      'quoted_message_content': messageData['quoted_message_content'],
      'status': messageData['status'] ?? 'normal',
      'deleted_by_users': messageData['deleted_by_users'] ?? '',
      'sender_avatar': messageData['sender_avatar'],
      'receiver_avatar': messageData['receiver_avatar'],
      'call_type': messageData['call_type'],
      'voice_duration': messageData['voice_duration'], // 🔴 添加语音时长字段
      'read_at': messageData['read_at'],
    };

    // 移除null值
    message.removeWhere((key, value) => value == null);
    
    logger.debug('📝 [_insertPrivateMessageToLocal] 保存消息 - server_id: ${message['server_id']}, voice_duration: ${message['voice_duration']}, content: ${message['content']}');
    
    await _localDb.insertMessage(message);
    
    // 显示通知
    await _showPrivateMessageNotification(messageData);
  }

  // 显示私聊消息通知
  Future<void> _showPrivateMessageNotification(
    Map<String, dynamic> messageData,
  ) async {
    try {
      final senderId = messageData['sender_id'];
      final senderName = messageData['sender_name'] ?? '未知用户';
      final content = messageData['content'] ?? '';
      final messageType = messageData['message_type'] ?? 'text';
      final fileName = messageData['file_name'];
      final senderAvatar = messageData['sender_avatar'];
      
      // 格式化消息内容
      final formattedContent = _notificationService.formatMessageContent(
        messageType,
        content,
        fileName,
      );
      
      // 🔴 检查应用是否在后台，如果在后台则显示原生弹窗（Android/iOS）
      final isAppInBackground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
      
      if ((Platform.isAndroid || Platform.isIOS) && isAppInBackground) {
        // 应用在后台，显示原生消息弹窗
        logger.debug('📱 [WebSocket] 应用在后台，显示原生消息弹窗');
        try {
          await NativeMessageService().showMessageOverlay(
            senderName: senderName,
            senderId: senderId,
            content: formattedContent,
            messageType: messageType,
            isGroupMessage: false,
            senderAvatar: senderAvatar,
          );
        } catch (e) {
          logger.debug('❌ [WebSocket] 显示原生消息弹窗失败: $e');
          // 失败时回退到普通通知
          await _notificationService.showMessageNotification(
            id: senderId,
            title: senderName,
            body: formattedContent,
            payload: 'private:$senderId',
          );
        }
      }
      // 🔴 应用在前台时不显示任何通知，用户可以直接在聊天列表看到新消息
    } catch (e) {
      logger.error('显示私聊消息通知失败: $e');
    }
  }

  // 保存群聊消息到本地数据库
  Future<void> _saveGroupMessageToLocal(
    Map<String, dynamic> messageData,
  ) async {
    try {
      logger.debug('🌐 [WebSocket-接收] _saveGroupMessageToLocal被调用');
      logger.debug('   - messageData: ${messageData.keys.toList()}');
      logger.debug('   - message_type: ${messageData['message_type']}');
      logger.debug('   - voice_duration: ${messageData['voice_duration']}');
      
      // 🔴 乐观更新：检查是否是自己发送的消息回传
      // 服务器会广播消息给群组所有成员（包括发送者）
      final currentUserId = await Storage.getUserId();
      final senderId = messageData['sender_id'];
      final messageType = messageData['message_type'] ?? 'text';
      
      // 🔴 系统消息必须保存，因为它可能是群组的第一条消息
      if (messageType == 'system') {
        await _insertGroupMessageToLocal(messageData);
        return;
      }
      
      if (currentUserId != null && senderId == currentUserId) {
        
        final groupId = messageData['group_id'];
        final content = messageData['content'];
        final serverId = messageData['id'];
        
        // 🔴 关键：使用groupId+content查找临时存储中的localId
        final messageKey = '${groupId}_${content.hashCode}';
        final pendingMsg = _pendingGroupMessages[messageKey];
        
        if (pendingMsg != null) {
          final localId = pendingMsg['localId'] as int;
          
          // 🔴 根据localId更新消息状态和服务器ID
          final count = await _localDb.updateGroupMessageStatusById(
            localId: localId,
            status: 'sent',
            serverId: serverId,
          );
          
          if (count > 0) {
          }
          
          // 从临时存储移除
          _pendingGroupMessages.remove(messageKey);
        } else {
          // 如果没找到，可能是多端同步的消息，正常插入
          await _insertGroupMessageToLocal(messageData);
        }
        return;
      }
      
      // 其他人发送的消息，正常插入
      await _insertGroupMessageToLocal(messageData);
    } catch (e) {
    }
  }

  // 插入群聊消息到本地数据库（实际插入逻辑）
  Future<void> _insertGroupMessageToLocal(
    Map<String, dynamic> messageData,
  ) async {
    logger.debug('🌐 [WebSocket-插入] _insertGroupMessageToLocal被调用');
    logger.debug('   - message_type: ${messageData['message_type']}');
    logger.debug('   - 原始messageData的voice_duration: ${messageData['voice_duration']}');
    logger.debug('   - messageData所有字段: ${messageData.keys.toList()}');
    
    // 处理mentioned_user_ids - 如果是List，转换为逗号分隔的字符串
    String? mentionedUserIdsStr;
    if (messageData['mentioned_user_ids'] != null) {
      if (messageData['mentioned_user_ids'] is List) {
        mentionedUserIdsStr = (messageData['mentioned_user_ids'] as List)
            .map((e) => e.toString())
            .join(',');
      } else {
        mentionedUserIdsStr = messageData['mentioned_user_ids'].toString();
      }
    }

    // 🔴 时区处理：服务器发送的是 UTC 时间，需要转换为上海时区
    String createdAtStr;
    if (messageData['created_at'] != null) {
      final originalTimeStr = messageData['created_at'].toString();
      logger.debug('🕐 [群组消息时区-接收] ========== 时区转换开始 ==========');
      logger.debug('🕐 [群组消息时区-接收] 原始时间字符串: $originalTimeStr');
      logger.debug('🕐 [群组消息时区-接收] 原始字符串是否以Z结尾: ${originalTimeStr.endsWith('Z')}');
      
      final shanghaiTime = TimezoneHelper.parseToShanghaiTime(
        originalTimeStr,
        assumeUtc: true,
      );
      createdAtStr = shanghaiTime.toIso8601String().replaceAll('Z', '');
      
      logger.debug('🕐 [群组消息时区-接收] 转换后shanghaiTime: ${shanghaiTime.toString()}');
      logger.debug('🕐 [群组消息时区-接收] shanghaiTime.isUtc: ${shanghaiTime.isUtc}');
      logger.debug('🕐 [群组消息时区-接收] 最终存储的createdAtStr: $createdAtStr');
      logger.debug('🕐 [群组消息时区-接收] ========== 时区转换结束 ==========');
    } else {
      createdAtStr = TimezoneHelper.nowInShanghaiString();
      logger.debug('🕐 [群组消息时区-接收] 无created_at，使用当前上海时间: $createdAtStr');
    }

    // 构建消息数据
    final message = {
      'server_id': messageData['id'], // 保存服务器返回的消息ID
      'group_id': messageData['group_id'],
      'sender_id': messageData['sender_id'],
      'sender_name': messageData['sender_name'],
      'group_name': messageData['group_name'],
      'group_avatar': messageData['group_avatar'],
      'content': messageData['content'],
      'message_type': messageData['message_type'] ?? 'text',
      'file_name': messageData['file_name'],
      'quoted_message_id': messageData['quoted_message_id'],
      'quoted_message_content': messageData['quoted_message_content'],
      'status': messageData['status'] ?? 'normal',
      'created_at': createdAtStr, // 🔴 使用上海时区时间
      'sender_avatar': messageData['sender_avatar'],
      'mentioned_user_ids': mentionedUserIdsStr,
      'mentions': messageData['mentions'],
      'deleted_by_users': messageData['deleted_by_users'] ?? '',
      'call_type': messageData['call_type'],
      'channel_name': messageData['channel_name'],
      'voice_duration': messageData['voice_duration'], // 🔴 添加voice_duration字段
    };

    logger.debug('🌐 [WebSocket-插入] 构建的message对象:');
    logger.debug('   - message_type: ${message['message_type']}');
    logger.debug('   - voice_duration: ${message['voice_duration']}');

    // 移除null值
    message.removeWhere((key, value) => value == null);
    
    logger.debug('🌐 [WebSocket-插入] 移除null后的voice_duration: ${message['voice_duration']}');

    // 🔍 调试：查看要保存的消息数据（特别是通话按钮消息）
    if (messageData['message_type'] == 'join_voice_button' || messageData['message_type'] == 'join_video_button') {
    }

    await _localDb.insertGroupMessage(message);
    
    // 显示通知
    await _showGroupMessageNotification(messageData);
  }

  // 显示群组消息通知
  Future<void> _showGroupMessageNotification(
    Map<String, dynamic> messageData,
  ) async {
    try {
      final groupId = messageData['group_id'];
      final senderId = messageData['sender_id'];
      final senderName = messageData['sender_name'] ?? '未知用户';
      final content = messageData['content'] ?? '';
      final messageType = messageData['message_type'] ?? 'text';
      final fileName = messageData['file_name'];
      final senderAvatar = messageData['sender_avatar'];
      final groupName = messageData['group_name'] ?? '群聊 $groupId';
      
      // 格式化消息内容
      final formattedContent = _notificationService.formatMessageContent(
        messageType,
        content,
        fileName,
      );
      
      // 🔴 检查应用是否在后台，如果在后台则显示原生弹窗（Android/iOS）
      final isAppInBackground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
      
      if ((Platform.isAndroid || Platform.isIOS) && isAppInBackground) {
        // 应用在后台，显示原生消息弹窗
        logger.debug('📱 [WebSocket] 应用在后台，显示原生群组消息弹窗');
        try {
          await NativeMessageService().showMessageOverlay(
            senderName: senderName,
            senderId: senderId,
            content: formattedContent,
            messageType: messageType,
            isGroupMessage: true,
            groupId: groupId,
            groupName: groupName,
            senderAvatar: senderAvatar,
          );
        } catch (e) {
          logger.debug('❌ [WebSocket] 显示原生群组消息弹窗失败: $e');
          // 失败时回退到普通通知
          await _notificationService.showGroupMessageNotification(
            id: groupId,
            groupName: groupName,
            senderName: senderName,
            message: formattedContent,
            payload: 'group:$groupId',
          );
        }
      }
      // 🔴 应用在前台时不显示任何通知，用户可以直接在聊天列表看到新消息
    } catch (e) {
      logger.error('显示群组消息通知失败: $e');
    }
  }

  // 处理群组昵称更新通知
  Future<void> _handleGroupNicknameUpdated(Map<String, dynamic> data) async {
    try {
      final groupId = data['group_id'] as int?;
      final userId = data['user_id'] as int?;
      final newNickname = data['new_nickname'] as String?;
      
      if (groupId == null || userId == null || newNickname == null) {
        return;
      }
      
      
      // 更新本地数据库中该用户在该群组的所有历史消息的昵称
      final updatedCount = await _localDb.updateGroupMemberNickname(
        groupId,
        userId,
        newNickname,
      );
      
    } catch (e) {
    }
  }

  // 处理离线私聊消息
  Future<void> _handleOfflineMessages(dynamic data) async {
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('📥 [离线私聊消息-WebSocket] 开始处理离线消息');
    logger.debug('📥 [离线私聊消息-WebSocket] data类型: ${data.runtimeType}');
    
    try {
      // data 是一个消息数组
      final messages = data as List?;
      if (messages == null || messages.isEmpty) {
        logger.debug('📥 [离线私聊消息-WebSocket] ⚠️ 没有离线消息需要处理');
        logger.debug('═══════════════════════════════════════════════════════════');
        return;
      }
      
      logger.debug('📥 [离线私聊消息-WebSocket] 收到 ${messages.length} 条离线消息');
      
      int savedCount = 0;
      int skippedCount = 0;
      int updatedCount = 0; // 🔴 新增：更新已读状态的消息数量
      // 🔴 收集有离线消息的发送者ID，用于从已读缓存中移除
      // 🔴 关键修复：无论消息是否被跳过（重复），都要记录发送者ID
      // 因为服务器发送的离线消息都是未读的，即使本地已存在也需要刷新UI
      final Set<int> senderIds = {};
      
      for (var messageData in messages) {
        try {
          final messageMap = Map<String, dynamic>.from(messageData as Map<String, dynamic>);
          
          // 🔴 调试：打印服务器发送的原始is_read值
          final senderId = messageMap['sender_id'] as int?;
          final receiverId = messageMap['receiver_id'] as int?;
          final serverId = messageMap['id'] as int?; // 服务器消息ID
          final content = messageMap['content']?.toString() ?? '';
          final preview = content.length > 20 ? content.substring(0, 20) : content;
          logger.debug('📥 [离线私聊消息-WebSocket] 处理消息 - serverId: $serverId, senderId: $senderId, receiverId: $receiverId, content: "$preview..."');
          
          // 🔴 关键修复：无论消息是否被跳过，都记录发送者ID
          // 因为服务器发送的离线消息都是未读的
          if (senderId != null) {
            senderIds.add(senderId);
          }
          
          // 🔴 关键修复：将服务器的 id 存储到 server_id 字段，移除 id 字段让数据库自动生成
          // 这样可以避免主键冲突导致消息被忽略
          if (serverId != null) {
            messageMap['server_id'] = serverId;
            messageMap.remove('id'); // 移除 id 字段，让数据库自动生成
          }
          
          // 🔴 时区处理：服务器发送的是 UTC 时间，需要转换为上海时区
          if (messageMap['created_at'] != null) {
            final shanghaiTime = TimezoneHelper.parseToShanghaiTime(
              messageMap['created_at'].toString(),
              assumeUtc: true,
            );
            messageMap['created_at'] = shanghaiTime.toIso8601String().replaceAll('Z', '');
            logger.debug('📥 [离线私聊消息-WebSocket] 时区转换后: ${messageMap['created_at']}');
          }
          
          // 🔴 先检查是否已存在相同 server_id 的消息
          if (serverId != null) {
            final existing = await _localDb.getMessageByServerId(serverId);
            if (existing != null) {
              skippedCount++;
              logger.debug('📥 [离线私聊消息-WebSocket] 消息已存在于本地数据库，serverId: $serverId');
              // 消息已存在，更新为未读状态
              final updateCount = await _localDb.updateMessageReadStatusByServerId(serverId, false);
              if (updateCount > 0) {
                updatedCount++;
                logger.debug('📥 [离线私聊消息-WebSocket] 🔄 已更新为未读状态 - serverId: $serverId');
              } else {
                logger.debug('📥 [离线私聊消息-WebSocket] ⏭️ 消息已跳过（已存在），serverId: $serverId');
              }
              continue;
            }
          }
          
          // 保存消息到本地数据库
          logger.debug('📥 [离线私聊消息-WebSocket] 准备插入数据库，messageMap: $messageMap');
          final id = await _localDb.insertMessage(messageMap, orIgnore: false);
          if (id > 0) {
            savedCount++;
            logger.debug('📥 [离线私聊消息-WebSocket] ✅ 消息已保存，本地ID: $id, 服务器ID: $serverId, 发送者ID: $senderId');
          } else {
            skippedCount++;
            logger.debug('📥 [离线私聊消息-WebSocket] ❌ 消息保存失败，serverId: $serverId');
          }
        } catch (e) {
          logger.error('❌ [离线私聊消息-WebSocket] 保存单条离线私聊消息失败: $e');
        }
      }
      
      logger.debug('📥 [离线私聊消息-WebSocket] ═══════════════════════════════════════');
      logger.debug('📥 [离线私聊消息-WebSocket] 处理完成统计:');
      logger.debug('📥 [离线私聊消息-WebSocket]   - 保存: $savedCount 条');
      logger.debug('📥 [离线私聊消息-WebSocket]   - 跳过: $skippedCount 条');
      logger.debug('📥 [离线私聊消息-WebSocket]   - 更新已读状态: $updatedCount 条');
      logger.debug('📥 [离线私聊消息-WebSocket]   - 发送者ID列表: $senderIds');
      logger.debug('📥 [离线私聊消息-WebSocket] ═══════════════════════════════════════');
      
      // 🔴 关键修复：设置同步状态标志，让UI层知道离线消息已处理完成
      _offlineMessagesSynced = true;
      
      // 🔴 关键修复：只要有离线消息（无论是否保存成功），都发送刷新通知
      // 这样可以确保UI正确显示未读状态
      final notificationData = {
        'type': 'offline_messages_saved',
        'data': {
          'count': savedCount + updatedCount, // 🔴 包含更新的消息数量
          'sender_ids': senderIds.toList(), // 🔴 传递发送者ID列表
          'messages': messages, // 🔴 传递原始消息数据，用于直接更新UI
          'from_client': true, // 🔴 标记这是客户端内部发送的信号
        }
      };
      logger.debug('📥 [离线私聊消息-WebSocket] 准备发送内部刷新通知: $notificationData');
      _messageController.add(notificationData);
      logger.debug('📥 [离线私聊消息-WebSocket] ✅ 已发送内部刷新通知到消息流');
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e) {
      logger.error('❌ [离线私聊消息-WebSocket] 处理离线私聊消息失败: $e');
      logger.debug('═══════════════════════════════════════════════════════════');
    }
  }

  // 处理离线群组消息
  Future<void> _handleOfflineGroupMessages(dynamic data) async {
    try {
      // 注意：data 是单个群组对象 {group_id: xx, messages: [...]}, 不是数组！
      final groupData = data as Map<String, dynamic>?;
      if (groupData == null) {
        logger.debug('📥 [离线群组消息] 数据为空');
        return;
      }

      final groupId = groupData['group_id'] as int?;
      final messages = groupData['messages'] as List?;
      
      if (groupId == null || messages == null || messages.isEmpty) {
        logger.debug('📥 [离线群组消息] 群组ID为空或没有消息 - groupId: $groupId, messages: ${messages?.length ?? 0}');
        return;
      }

      logger.debug('📥 [离线群组消息] 收到群组 $groupId 的 ${messages.length} 条离线消息');
      
      int savedCount = 0;
      int skippedCount = 0;
      for (var messageData in messages) {
        try {
          final messageMap = Map<String, dynamic>.from(messageData as Map<String, dynamic>);
          
          // 确保消息包含group_id
          if (!messageMap.containsKey('group_id')) {
            messageMap['group_id'] = groupId;
          }
          
          // 🔴 获取服务器消息ID
          final serverId = messageMap['id'] as int?;
          
          // 🔴 调试：打印消息内容
          final content = messageMap['content']?.toString() ?? '';
          final preview = content.length > 20 ? content.substring(0, 20) : content;
          logger.debug('📥 [离线群组消息] 处理消息 - groupId: $groupId, serverId: $serverId, content: "$preview..."');
          
          // 🔴 关键修复：将服务器的 id 存储到 server_id 字段，移除 id 字段让数据库自动生成
          if (serverId != null) {
            messageMap['server_id'] = serverId;
            messageMap.remove('id');
          }
          
          // 🔴 时区处理：服务器发送的是 UTC 时间，需要转换为上海时区
          if (messageMap['created_at'] != null) {
            final shanghaiTime = TimezoneHelper.parseToShanghaiTime(
              messageMap['created_at'].toString(),
              assumeUtc: true,
            );
            messageMap['created_at'] = shanghaiTime.toIso8601String().replaceAll('Z', '');
          }
          
          // 🔴 先检查是否已存在相同 server_id 的消息
          if (serverId != null) {
            final existing = await _localDb.getGroupMessageByServerId(serverId);
            if (existing != null) {
              skippedCount++;
              logger.debug('📥 [离线群组消息] ⏭️ 消息已跳过（已存在），serverId: $serverId');
              continue;
            }
          }
          
          // 保存消息到本地数据库
          final id = await _localDb.insertGroupMessage(messageMap, orIgnore: false);
          if (id > 0) {
            savedCount++;
            logger.debug('📥 [离线群组消息] ✅ 消息已保存，本地ID: $id, 服务器ID: $serverId');
          } else {
            skippedCount++;
            logger.debug('📥 [离线群组消息] ⏭️ 消息保存失败，serverId: $serverId');
          }
        } catch (e) {
          logger.error('❌ 保存单条离线群聊消息失败: $e');
        }
      }
      
      logger.debug('📥 [离线群组消息] 处理完成: 保存 $savedCount 条, 跳过 $skippedCount 条');
      
      // 🔴 关键修复：设置同步状态标志，让UI层知道离线消息已处理完成
      _offlineGroupMessagesSynced = true;
      
      // 🔴 关键修复：立即发送刷新通知，包含群组ID和消息数据
      // 这个信号会在服务器的 offline_group_messages_saved 信号之前被处理
      _messageController.add({
        'type': 'offline_group_messages_saved',
        'data': {
          'group_id': groupId, 
          'count': savedCount,
          'messages': messages, // 🔴 传递原始消息数据，用于直接更新UI
          'from_client': true, // 🔴 标记这是客户端内部发送的信号
        }
      });
      logger.debug('📥 [离线群组消息] 已发送内部刷新通知，groupId: $groupId, count: $savedCount');
    } catch (e) {
      logger.error('❌ 处理离线群组消息失败: $e');
    }
  }

  // ==================== 消息错误处理 ====================
  
  /// 处理私聊消息发送错误
  Future<void> _handlePrivateMessageError(String errorType, String errorMessage) async {
    try {
      // 获取最后一条待处理的私聊消息
      if (_pendingPrivateMessages.isEmpty) {
        return;
      }
      
      // 获取最后一条消息
      final lastEntry = _pendingPrivateMessages.entries.last;
      final messageKey = lastEntry.key;
      final lastMessage = lastEntry.value;
      final localId = lastMessage['localId'] as int;
      final receiverId = lastMessage['receiverId'] as int;
      
      
      // 🔴 关键：使用localId更新状态
      final count = await _localDb.updateMessageStatusById(
        localId: localId,
        status: 'forbidden',
      );
      
      if (count > 0) {
      } else {
      }
      
      // 从待处理列表中移除
      _pendingPrivateMessages.remove(messageKey);
      
    } catch (e) {
      logger.error('❌ 处理私聊消息错误失败: $e');
    }
  }
  
  /// 处理群组消息发送错误
  Future<void> _handleGroupMessageError(String errorType) async {
    try {
      // 获取最后一条待处理的群组消息
      if (_pendingGroupMessages.isEmpty) {
        return;
      }
      
      // 获取最后一条消息
      final lastEntry = _pendingGroupMessages.entries.last;
      final messageKey = lastEntry.key;
      final lastMessage = lastEntry.value;
      final localId = lastMessage['localId'] as int;
      final groupId = lastMessage['groupId'] as int;
      
      
      // 🔴 关键：使用localId更新状态
      final count = await _localDb.updateGroupMessageStatusById(
        localId: localId,
        status: 'forbidden',
      );
      
      if (count > 0) {
      } else {
      }
      
      // 从待处理列表中移除
      _pendingGroupMessages.remove(messageKey);
      
    } catch (e) {
      logger.error('❌ 处理群组消息错误失败: $e');
    }
  }

  // 释放资源
  void dispose() {
    disconnect();
    _messageController.close();
  }
}
