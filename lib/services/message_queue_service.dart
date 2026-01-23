import 'dart:async';
import 'dart:collection';
import 'package:uuid/uuid.dart';
import 'local_database_service.dart';
import 'websocket_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import '../utils/timezone_helper.dart';
import 'api_service.dart';

/// 消息发送状态枚举
enum MessageSendStatus {
  pending,    // 待发送（本地创建，未发送）
  sending,    // 发送中（已发送到服务器，等待ACK）
  sent,       // 已发送（服务器已确认收到）
  delivered,  // 已送达（接收端已确认收到）
  read,       // 已读（接收端已读）
  failed,     // 发送失败（重试次数用尽）
}

/// 待发送消息模型
class PendingMessage {
  final String clientMessageId;
  final int? senderId;
  final int receiverId;
  final String content;
  final String messageType;
  final bool isGroupMessage;
  final int? groupId;
  final String? fileName;
  final int? quotedMessageId;
  final String? quotedMessageContent;
  final int? voiceDuration;
  final String? callType;
  
  // 发送者信息
  final String? senderName;
  final String? senderAvatar;
  final String? receiverName;
  final String? receiverAvatar;
  
  MessageSendStatus status;
  int retryCount;
  DateTime? nextRetryTime;
  int? serverMessageId;
  int? localDbId; // 本地数据库中的ID
  final DateTime createdAt;

  PendingMessage({
    required this.clientMessageId,
    this.senderId,
    required this.receiverId,
    required this.content,
    required this.messageType,
    this.isGroupMessage = false,
    this.groupId,
    this.fileName,
    this.quotedMessageId,
    this.quotedMessageContent,
    this.voiceDuration,
    this.callType,
    this.senderName,
    this.senderAvatar,
    this.receiverName,
    this.receiverAvatar,
    required this.status,
    required this.retryCount,
    this.nextRetryTime,
    this.serverMessageId,
    this.localDbId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'client_message_id': clientMessageId,
    'sender_id': senderId,
    'receiver_id': receiverId,
    'content': content,
    'message_type': messageType,
    'is_group_message': isGroupMessage ? 1 : 0,
    'group_id': groupId,
    'file_name': fileName,
    'quoted_message_id': quotedMessageId,
    'quoted_message_content': quotedMessageContent,
    'voice_duration': voiceDuration,
    'call_type': callType,
    'sender_name': senderName,
    'sender_avatar': senderAvatar,
    'receiver_name': receiverName,
    'receiver_avatar': receiverAvatar,
    'status': status.name,
    'retry_count': retryCount,
    'next_retry_time': nextRetryTime?.toIso8601String(),
    'server_message_id': serverMessageId,
    'local_db_id': localDbId,
    'created_at': createdAt.toIso8601String(),
  };

  factory PendingMessage.fromJson(Map<String, dynamic> json) => PendingMessage(
    clientMessageId: json['client_message_id'] as String,
    senderId: json['sender_id'] as int?,
    receiverId: json['receiver_id'] as int,
    content: json['content'] as String,
    messageType: json['message_type'] as String,
    isGroupMessage: json['is_group_message'] == 1,
    groupId: json['group_id'] as int?,
    fileName: json['file_name'] as String?,
    quotedMessageId: json['quoted_message_id'] as int?,
    quotedMessageContent: json['quoted_message_content'] as String?,
    voiceDuration: json['voice_duration'] as int?,
    callType: json['call_type'] as String?,
    senderName: json['sender_name'] as String?,
    senderAvatar: json['sender_avatar'] as String?,
    receiverName: json['receiver_name'] as String?,
    receiverAvatar: json['receiver_avatar'] as String?,
    status: MessageSendStatus.values.byName(json['status'] as String? ?? 'pending'),
    retryCount: json['retry_count'] as int? ?? 0,
    nextRetryTime: json['next_retry_time'] != null 
        ? DateTime.tryParse(json['next_retry_time'] as String) 
        : null,
    serverMessageId: json['server_message_id'] as int?,
    localDbId: json['local_db_id'] as int?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
  
  /// 转换为消息表格式（用于插入messages表）
  Map<String, dynamic> toMessageTableJson() {
    return {
      'client_message_id': clientMessageId,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'content': content,
      'message_type': messageType,
      'is_read': 0,
      'created_at': createdAt.toIso8601String(),
      'status': status.name,
      'sender_name': senderName,
      'sender_avatar': senderAvatar,
      'receiver_name': receiverName,
      'receiver_avatar': receiverAvatar,
      if (fileName != null) 'file_name': fileName,
      if (quotedMessageId != null) 'quoted_message_id': quotedMessageId,
      if (quotedMessageContent != null) 'quoted_message_content': quotedMessageContent,
      if (voiceDuration != null) 'voice_duration': voiceDuration,
      if (callType != null) 'call_type': callType,
    };
  }
}

/// 消息队列服务 - 保证消息100%发送
/// 
/// 核心功能：
/// 1. 消息持久化 - 发送前先存本地数据库
/// 2. 自动重试 - 发送失败自动重试（指数退避）
/// 3. ACK确认 - 等待服务器确认
/// 4. 状态追踪 - 完整的消息状态管理
class MessageQueueService {
  static final MessageQueueService _instance = MessageQueueService._internal();
  factory MessageQueueService() => _instance;
  MessageQueueService._internal();

  final _localDb = LocalDatabaseService();
  final _websocket = WebSocketService();
  
  // 待发送消息队列（内存中）
  final Queue<PendingMessage> _pendingQueue = Queue();
  
  // 正在发送的消息（等待ACK）- key: clientMessageId
  final Map<String, PendingMessage> _sendingMessages = {};
  
  // ACK超时定时器 - key: clientMessageId
  final Map<String, Timer> _ackTimeoutTimers = {};
  
  // 重试配置
  static const int maxRetries = 5;
  static const Duration baseRetryDelay = Duration(seconds: 2);
  static const Duration ackTimeout = Duration(seconds: 15);
  
  Timer? _processTimer;
  bool _isProcessing = false;
  bool _isInitialized = false;
  
  // 消息发送状态变化回调
  Function(String clientMessageId, MessageSendStatus status, int? serverMessageId)? onMessageStatusChanged;
  
  // 消息发送失败回调
  Function(String clientMessageId, String error)? onMessageFailed;
  
  static const _uuid = Uuid();

  /// 初始化 - 加载未发送的消息
  Future<void> initialize() async {
    if (_isInitialized) {
      logger.debug('📤 [MessageQueue] 已初始化，跳过');
      return;
    }
    
    try {
      // 从数据库加载状态为 pending 或 sending 的消息
      final pendingMessages = await _loadPendingMessages();
      for (final msg in pendingMessages) {
        _pendingQueue.add(msg);
      }
      
      // 启动消息处理循环
      _startProcessing();
      
      _isInitialized = true;
      logger.debug('📤 [MessageQueue] 初始化完成，待发送消息: ${_pendingQueue.length}');
    } catch (e) {
      logger.error('❌ [MessageQueue] 初始化失败: $e');
    }
  }

  /// 发送消息（入队）
  /// 
  /// 返回客户端消息ID，可用于追踪消息状态
  Future<String> enqueueMessage({
    required int receiverId,
    required String content,
    required String messageType,
    bool isGroupMessage = false,
    int? groupId,
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    int? voiceDuration,
    String? callType,
  }) async {
    // 生成客户端消息ID（UUID）
    final clientMessageId = _generateClientMessageId();
    
    // 获取发送者信息
    final senderId = await Storage.getUserId();
    final senderFullName = await Storage.getFullName();
    final senderUsername = await Storage.getUsername();
    final senderAvatar = await Storage.getAvatar();
    final senderName = (senderFullName != null && senderFullName.isNotEmpty) 
        ? senderFullName 
        : (senderUsername ?? 'Unknown');
    
    // 获取接收者信息
    String receiverName = receiverId.toString();
    String? receiverAvatar;
    
    if (!isGroupMessage) {
      try {
        final token = await Storage.getToken();
        if (token != null) {
          final userInfo = await ApiService.getUserInfo(receiverId, token: token);
          if (userInfo['code'] == 0 && userInfo['data'] != null) {
            final userData = userInfo['data'];
            receiverName = userData['full_name']?.toString().isNotEmpty == true 
                ? userData['full_name'].toString()
                : (userData['username']?.toString() ?? receiverId.toString());
            receiverAvatar = userData['avatar']?.toString();
          }
        }
      } catch (e) {
        logger.debug('⚠️ [MessageQueue] 获取接收者信息失败: $e');
      }
    }
    
    // 使用上海时区时间
    final shanghaiTime = TimezoneHelper.nowInShanghai();
    
    final message = PendingMessage(
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      messageType: messageType,
      isGroupMessage: isGroupMessage,
      groupId: groupId,
      fileName: fileName,
      quotedMessageId: quotedMessageId,
      quotedMessageContent: quotedMessageContent,
      voiceDuration: voiceDuration,
      callType: callType,
      senderName: senderName,
      senderAvatar: senderAvatar,
      receiverName: receiverName,
      receiverAvatar: receiverAvatar,
      status: MessageSendStatus.pending,
      retryCount: 0,
      createdAt: shanghaiTime,
    );
    
    // 1. 先持久化到本地数据库（消息表）
    final localDbId = await _persistMessageToDb(message);
    message.localDbId = localDbId;
    
    // 2. 持久化到待发送队列表
    await _persistToPendingQueue(message);
    
    // 3. 加入内存队列
    _pendingQueue.add(message);
    
    // 4. 触发发送
    _triggerProcessing();
    
    logger.debug('📤 [MessageQueue] 消息入队: $clientMessageId, localDbId: $localDbId');
    
    return clientMessageId;
  }

  /// 处理服务器ACK（消息已收到）
  void handleServerAck(String clientMessageId, int serverMessageId) {
    // 取消ACK超时定时器
    _ackTimeoutTimers[clientMessageId]?.cancel();
    _ackTimeoutTimers.remove(clientMessageId);
    
    final message = _sendingMessages.remove(clientMessageId);
    if (message != null) {
      message.serverMessageId = serverMessageId;
      message.status = MessageSendStatus.sent;
      
      // 更新数据库状态
      _updateMessageStatus(message, MessageSendStatus.sent, serverMessageId);
      
      // 从待发送队列表中删除
      _removeFromPendingQueue(clientMessageId);
      
      // 通知状态变化
      onMessageStatusChanged?.call(clientMessageId, MessageSendStatus.sent, serverMessageId);
      
      logger.debug('✅ [MessageQueue] 消息发送成功: $clientMessageId -> serverId: $serverMessageId');
    } else {
      logger.debug('⚠️ [MessageQueue] 收到ACK但未找到消息: $clientMessageId');
    }
  }

  /// 处理送达确认（接收端已收到）
  void handleDeliveryAck(String clientMessageId, int? serverMessageId) {
    // 查找消息（可能在内存中或数据库中）
    _updateMessageStatusByClientId(clientMessageId, MessageSendStatus.delivered);
    
    // 通知状态变化
    onMessageStatusChanged?.call(clientMessageId, MessageSendStatus.delivered, serverMessageId);
    
    logger.debug('📬 [MessageQueue] 消息已送达: $clientMessageId');
  }

  /// 处理已读确认
  void handleReadAck(String clientMessageId, int? serverMessageId) {
    _updateMessageStatusByClientId(clientMessageId, MessageSendStatus.read);
    
    // 通知状态变化
    onMessageStatusChanged?.call(clientMessageId, MessageSendStatus.read, serverMessageId);
    
    logger.debug('👁️ [MessageQueue] 消息已读: $clientMessageId');
  }

  /// 启动消息处理
  void _startProcessing() {
    _processTimer?.cancel();
    _processTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _processQueue();
    });
  }

  /// 停止消息处理
  void stopProcessing() {
    _processTimer?.cancel();
    _processTimer = null;
    
    // 取消所有ACK超时定时器
    for (final timer in _ackTimeoutTimers.values) {
      timer.cancel();
    }
    _ackTimeoutTimers.clear();
  }

  /// 处理消息队列
  Future<void> _processQueue() async {
    if (_isProcessing || _pendingQueue.isEmpty) return;
    if (!_websocket.isConnected) {
      // WebSocket未连接，等待连接
      return;
    }
    
    _isProcessing = true;
    
    try {
      while (_pendingQueue.isNotEmpty) {
        final message = _pendingQueue.first;
        
        // 检查是否超过最大重试次数
        if (message.retryCount >= maxRetries) {
          _pendingQueue.removeFirst();
          message.status = MessageSendStatus.failed;
          await _updateMessageStatus(message, MessageSendStatus.failed, null);
          await _removeFromPendingQueue(message.clientMessageId);
          
          // 通知发送失败
          onMessageFailed?.call(message.clientMessageId, '发送失败，已重试${maxRetries}次');
          
          logger.error('❌ [MessageQueue] 消息发送失败（重试次数用尽）: ${message.clientMessageId}');
          continue;
        }
        
        // 检查重试延迟
        if (message.nextRetryTime != null && DateTime.now().isBefore(message.nextRetryTime!)) {
          break; // 等待重试时间
        }
        
        // 发送消息
        final success = await _sendMessage(message);
        
        if (success) {
          _pendingQueue.removeFirst();
          message.status = MessageSendStatus.sending;
          _sendingMessages[message.clientMessageId] = message;
          
          // 更新数据库状态为sending
          await _updateMessageStatus(message, MessageSendStatus.sending, null);
          
          // 设置ACK超时
          _scheduleAckTimeout(message);
          
          logger.debug('📤 [MessageQueue] 消息已发送，等待ACK: ${message.clientMessageId}');
        } else {
          // 发送失败，计算下次重试时间（指数退避）
          message.retryCount++;
          final delay = baseRetryDelay * (1 << message.retryCount);
          message.nextRetryTime = DateTime.now().add(delay);
          
          // 更新待发送队列表中的重试信息
          await _updatePendingQueueRetry(message);
          
          logger.debug('🔄 [MessageQueue] 消息发送失败，将在 ${delay.inSeconds}s 后重试 (第${message.retryCount}次): ${message.clientMessageId}');
          break;
        }
      }
    } catch (e) {
      logger.error('❌ [MessageQueue] 处理队列异常: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// 发送单条消息
  Future<bool> _sendMessage(PendingMessage message) async {
    try {
      if (!_websocket.isConnected) {
        logger.debug('⚠️ [MessageQueue] WebSocket未连接，无法发送');
        return false;
      }
      
      final data = <String, dynamic>{
        'client_message_id': message.clientMessageId, // 🔴 关键：携带客户端消息ID
        'receiver_id': message.receiverId,
        'content': message.content,
        'message_type': message.messageType,
      };
      
      if (message.fileName != null) data['file_name'] = message.fileName;
      if (message.quotedMessageId != null) data['quoted_message_id'] = message.quotedMessageId;
      if (message.quotedMessageContent != null) data['quoted_message_content'] = message.quotedMessageContent;
      if (message.voiceDuration != null) data['voice_duration'] = message.voiceDuration;
      if (message.callType != null) data['call_type'] = message.callType;
      
      final type = message.isGroupMessage ? 'group_message' : 'message';
      if (message.isGroupMessage && message.groupId != null) {
        data['group_id'] = message.groupId;
      }
      
      _websocket.sendRaw({'type': type, 'data': data});
      return true;
    } catch (e) {
      logger.error('❌ [MessageQueue] 发送消息异常: $e');
      return false;
    }
  }

  /// 设置ACK超时
  void _scheduleAckTimeout(PendingMessage message) {
    _ackTimeoutTimers[message.clientMessageId]?.cancel();
    
    _ackTimeoutTimers[message.clientMessageId] = Timer(ackTimeout, () {
      if (_sendingMessages.containsKey(message.clientMessageId)) {
        // ACK超时，重新入队
        final msg = _sendingMessages.remove(message.clientMessageId);
        if (msg != null) {
          msg.retryCount++;
          msg.nextRetryTime = DateTime.now().add(baseRetryDelay * (1 << msg.retryCount));
          msg.status = MessageSendStatus.pending;
          _pendingQueue.addFirst(msg);
          
          // 更新待发送队列表
          _updatePendingQueueRetry(msg);
          
          logger.debug('⏰ [MessageQueue] ACK超时，重新入队 (第${msg.retryCount}次重试): ${msg.clientMessageId}');
        }
      }
      _ackTimeoutTimers.remove(message.clientMessageId);
    });
  }

  void _triggerProcessing() {
    if (!_isProcessing) {
      _processQueue();
    }
  }

  String _generateClientMessageId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}';
  }

  /// 从数据库加载未完成的消息
  Future<List<PendingMessage>> _loadPendingMessages() async {
    try {
      final results = await _localDb.queryPendingMessages();
      return results.map((row) => PendingMessage.fromJson(row)).toList();
    } catch (e) {
      logger.error('❌ [MessageQueue] 加载待发送消息失败: $e');
      return [];
    }
  }

  /// 持久化消息到消息表
  Future<int> _persistMessageToDb(PendingMessage message) async {
    try {
      final messageData = message.toMessageTableJson();
      return await _localDb.insertMessage(messageData);
    } catch (e) {
      logger.error('❌ [MessageQueue] 持久化消息失败: $e');
      return -1;
    }
  }

  /// 持久化到待发送队列表
  Future<void> _persistToPendingQueue(PendingMessage message) async {
    try {
      await _localDb.insertPendingMessage(message.toJson());
    } catch (e) {
      logger.error('❌ [MessageQueue] 持久化到待发送队列失败: $e');
    }
  }

  /// 更新消息状态
  Future<void> _updateMessageStatus(PendingMessage message, MessageSendStatus status, int? serverMessageId) async {
    try {
      // 更新消息表中的状态
      if (message.localDbId != null) {
        await _localDb.updateMessageStatusById(
          localId: message.localDbId!,
          status: status.name,
          serverId: serverMessageId,
        );
      }
      
      // 更新待发送队列表中的状态
      await _localDb.updatePendingMessageStatus(
        message.clientMessageId, 
        status.name, 
        serverMessageId,
      );
    } catch (e) {
      logger.error('❌ [MessageQueue] 更新消息状态失败: $e');
    }
  }

  /// 通过clientMessageId更新消息状态
  Future<void> _updateMessageStatusByClientId(String clientMessageId, MessageSendStatus status) async {
    try {
      await _localDb.updateMessageStatusByClientId(clientMessageId, status.name);
    } catch (e) {
      logger.error('❌ [MessageQueue] 更新消息状态失败: $e');
    }
  }

  /// 更新待发送队列中的重试信息
  Future<void> _updatePendingQueueRetry(PendingMessage message) async {
    try {
      await _localDb.updatePendingMessageRetry(
        message.clientMessageId,
        message.retryCount,
        message.nextRetryTime?.toIso8601String(),
      );
    } catch (e) {
      logger.error('❌ [MessageQueue] 更新重试信息失败: $e');
    }
  }

  /// 从待发送队列表中删除
  Future<void> _removeFromPendingQueue(String clientMessageId) async {
    try {
      await _localDb.deletePendingMessage(clientMessageId);
    } catch (e) {
      logger.error('❌ [MessageQueue] 删除待发送消息失败: $e');
    }
  }

  /// 获取待发送消息数量
  int get pendingCount => _pendingQueue.length;

  /// 获取正在发送的消息数量
  int get sendingCount => _sendingMessages.length;

  /// 重新连接后恢复发送
  Future<void> resumeOnReconnect() async {
    logger.debug('🔄 [MessageQueue] WebSocket重连，恢复消息发送...');
    
    // 将所有sending状态的消息重新入队
    for (final message in _sendingMessages.values.toList()) {
      _sendingMessages.remove(message.clientMessageId);
      message.status = MessageSendStatus.pending;
      _pendingQueue.addFirst(message);
    }
    
    // 取消所有ACK超时定时器
    for (final timer in _ackTimeoutTimers.values) {
      timer.cancel();
    }
    _ackTimeoutTimers.clear();
    
    // 触发处理
    _triggerProcessing();
  }

  /// 清理资源
  void dispose() {
    stopProcessing();
    _pendingQueue.clear();
    _sendingMessages.clear();
    _isInitialized = false;
  }
}
