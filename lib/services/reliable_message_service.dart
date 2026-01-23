import 'message_queue_service.dart';
import 'message_dedup_service.dart';
import 'offline_sync_service.dart';
import 'websocket_service.dart';
import '../utils/logger.dart';

/// 可靠消息服务
/// 
/// 统一管理消息的发送和接收，确保100%可靠性
/// 
/// 核心功能：
/// 1. 消息发送：通过消息队列确保100%发送成功
/// 2. 消息接收：通过去重服务确保不重复处理
/// 3. 离线同步：重连后自动同步离线消息
/// 4. 状态追踪：实时追踪消息状态变化
/// 
/// 适用于所有客户端组合：
/// - PC ↔ PC
/// - Mobile ↔ Mobile
/// - PC ↔ Mobile
class ReliableMessageService {
  static final ReliableMessageService _instance = ReliableMessageService._internal();
  factory ReliableMessageService() => _instance;
  ReliableMessageService._internal();

  final _messageQueue = MessageQueueService();
  final _dedup = MessageDedupService();
  final _offlineSync = OfflineSyncService();
  final _websocket = WebSocketService();

  bool _initialized = false;

  // 消息状态变化回调
  Function(String clientMessageId, MessageSendStatus status, {int? serverId})? onMessageStatusChanged;
  
  // 新消息接收回调
  Function(Map<String, dynamic> message, bool isGroup)? onNewMessageReceived;
  
  // 消息发送失败回调
  Function(String clientMessageId, String error)? onMessageSendFailed;

  /// 初始化服务
  Future<void> initialize() async {
    if (_initialized) {
      logger.debug('⚠️ [ReliableMessage] 服务已初始化，跳过');
      return;
    }

    logger.debug('🚀 [ReliableMessage] 开始初始化服务...');

    try {
      // 1. 初始化离线同步服务（会初始化消息队列）
      await _offlineSync.initialize();

      // 2. 设置消息队列回调
      _messageQueue.onMessageStatusChanged = _handleMessageStatusChanged;
      _messageQueue.onMessageFailed = _handleMessageSendFailed;

      // 3. 设置 WebSocket ACK 回调
      _websocket.onMessageSentAck = _handleMessageSentAck;
      _websocket.onMessageDeliveredAck = _handleMessageDeliveredAck;
      _websocket.onMessageReadAck = _handleMessageReadAck;

      _initialized = true;
      logger.debug('✅ [ReliableMessage] 服务初始化完成');
    } catch (e) {
      logger.error('❌ [ReliableMessage] 初始化失败: $e');
      rethrow;
    }
  }

  /// 发送私聊消息（可靠发送）
  /// 
  /// 返回 clientMessageId，用于追踪消息状态
  Future<String> sendPrivateMessage({
    required int receiverId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
    String? callType,
    int? voiceDuration,
  }) async {
    logger.debug('📤 [ReliableMessage] 发送私聊消息');
    logger.debug('   - receiverId: $receiverId');
    logger.debug('   - messageType: $messageType');

    // 使用消息队列发送，返回 clientMessageId
    final clientMessageId = await _messageQueue.enqueueMessage(
      receiverId: receiverId,
      content: content,
      messageType: messageType,
      isGroupMessage: false,
      fileName: fileName,
      quotedMessageId: quotedMessageId,
      quotedMessageContent: quotedMessageContent,
      callType: callType,
      voiceDuration: voiceDuration,
    );

    logger.debug('✅ [ReliableMessage] 私聊消息已加入队列: $clientMessageId');
    return clientMessageId;
  }

  /// 发送群聊消息（可靠发送）
  /// 
  /// 返回 clientMessageId，用于追踪消息状态
  Future<String> sendGroupMessage({
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
    logger.debug('📤 [ReliableMessage] 发送群聊消息');
    logger.debug('   - groupId: $groupId');
    logger.debug('   - messageType: $messageType');

    // 使用消息队列发送，返回 clientMessageId
    final clientMessageId = await _messageQueue.enqueueMessage(
      receiverId: groupId, // 群聊时 receiverId 是 groupId
      content: content,
      messageType: messageType,
      isGroupMessage: true,
      groupId: groupId,
      fileName: fileName,
      quotedMessageId: quotedMessageId,
      quotedMessageContent: quotedMessageContent,
      callType: callType,
      voiceDuration: voiceDuration,
    );

    logger.debug('✅ [ReliableMessage] 群聊消息已加入队列: $clientMessageId');
    return clientMessageId;
  }

  /// 处理接收到的私聊消息（带去重）
  /// 
  /// 返回 true 表示是新消息，false 表示是重复消息
  Future<bool> handleReceivedPrivateMessage(Map<String, dynamic> message) async {
    final messageId = message['id'] as int?;
    final clientMessageId = message['client_message_id'] as String?;

    logger.debug('📥 [ReliableMessage] 处理接收到的私聊消息');
    logger.debug('   - messageId: $messageId');
    logger.debug('   - clientMessageId: $clientMessageId');

    if (messageId == null) {
      logger.debug('⚠️ [ReliableMessage] 消息ID为空，跳过去重检查');
      onNewMessageReceived?.call(message, false);
      return true;
    }

    // 检查是否重复
    final isDuplicate = await _dedup.isPrivateMessageDuplicate(
      messageId,
      clientMessageId: clientMessageId,
    );

    if (isDuplicate) {
      logger.debug('⚠️ [ReliableMessage] 检测到重复私聊消息，跳过处理');
      return false;
    }

    // 标记为已处理
    _dedup.markPrivateMessageProcessed(messageId, clientMessageId: clientMessageId);

    // 发送送达确认
    _websocket.sendDeliveryAck(messageId, clientMessageId: clientMessageId, isGroup: false);

    // 通知新消息
    onNewMessageReceived?.call(message, false);

    logger.debug('✅ [ReliableMessage] 私聊消息处理完成');
    return true;
  }

  /// 处理接收到的群聊消息（带去重）
  /// 
  /// 返回 true 表示是新消息，false 表示是重复消息
  Future<bool> handleReceivedGroupMessage(Map<String, dynamic> message) async {
    final messageId = message['id'] as int?;
    final clientMessageId = message['client_message_id'] as String?;
    final groupId = message['group_id'] as int?;

    logger.debug('📥 [ReliableMessage] 处理接收到的群聊消息');
    logger.debug('   - messageId: $messageId');
    logger.debug('   - clientMessageId: $clientMessageId');
    logger.debug('   - groupId: $groupId');

    if (messageId == null || groupId == null) {
      logger.debug('⚠️ [ReliableMessage] 消息ID或群组ID为空，跳过去重检查');
      onNewMessageReceived?.call(message, true);
      return true;
    }

    // 检查是否重复
    final isDuplicate = await _dedup.isGroupMessageDuplicate(
      messageId,
      groupId,
      clientMessageId: clientMessageId,
    );

    if (isDuplicate) {
      logger.debug('⚠️ [ReliableMessage] 检测到重复群聊消息，跳过处理');
      return false;
    }

    // 标记为已处理
    _dedup.markGroupMessageProcessed(messageId, groupId, clientMessageId: clientMessageId);

    // 发送送达确认
    _websocket.sendDeliveryAck(messageId, clientMessageId: clientMessageId, isGroup: true);

    // 通知新消息
    onNewMessageReceived?.call(message, true);

    logger.debug('✅ [ReliableMessage] 群聊消息处理完成');
    return true;
  }

  /// 重试发送失败的消息
  Future<void> retryFailedMessage(String clientMessageId) async {
    // 从数据库重新加载消息并加入队列
    logger.debug('🔄 [ReliableMessage] 重试发送消息: $clientMessageId');
    // TODO: 实现从数据库加载并重新入队
  }

  /// 获取待发送消息数量
  int get pendingMessageCount => _messageQueue.pendingCount;

  /// 获取正在发送的消息数量
  int get sendingMessageCount => _messageQueue.sendingCount;

  /// 手动触发离线同步
  Future<void> syncOfflineMessages() async {
    await _offlineSync.manualSync();
  }

  /// 获取同步状态
  bool get isSyncing => _offlineSync.isSyncing;

  // ==================== 内部回调处理 ====================

  void _handleMessageStatusChanged(String clientMessageId, MessageSendStatus status, int? serverMessageId) {
    logger.debug('📊 [ReliableMessage] 消息状态变化: $clientMessageId -> $status');
    onMessageStatusChanged?.call(clientMessageId, status, serverId: serverMessageId);
  }

  void _handleMessageSendFailed(String clientMessageId, String error) {
    logger.error('❌ [ReliableMessage] 消息发送失败: $clientMessageId - $error');
    onMessageSendFailed?.call(clientMessageId, error);
  }

  void _handleMessageSentAck(String clientMessageId, int serverId) {
    logger.debug('✅ [ReliableMessage] 收到服务器确认: $clientMessageId -> serverId: $serverId');
    _messageQueue.handleServerAck(clientMessageId, serverId);
  }

  void _handleMessageDeliveredAck(String clientMessageId, int messageId) {
    logger.debug('📬 [ReliableMessage] 收到送达确认: $clientMessageId');
    _messageQueue.handleDeliveryAck(clientMessageId, messageId);
  }

  void _handleMessageReadAck(String clientMessageId, int messageId) {
    logger.debug('👁️ [ReliableMessage] 收到已读确认: $clientMessageId');
    _messageQueue.handleReadAck(clientMessageId, messageId);
  }

  /// 清理资源
  void dispose() {
    _offlineSync.dispose();
    _initialized = false;
  }
}
