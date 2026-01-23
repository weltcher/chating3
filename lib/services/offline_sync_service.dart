import 'dart:async';
import 'local_database_service.dart';
import 'websocket_service.dart';
import 'message_queue_service.dart';
import 'message_dedup_service.dart';
import '../utils/logger.dart';

/// 离线消息同步服务
/// 
/// 负责在重连后同步离线消息，确保消息不丢失
/// 
/// 核心功能：
/// 1. 重连后请求服务器发送离线消息
/// 2. 恢复待发送的消息队列
/// 3. 清理过期的去重记录
class OfflineSyncService {
  static final OfflineSyncService _instance = OfflineSyncService._internal();
  factory OfflineSyncService() => _instance;
  OfflineSyncService._internal();

  final _localDb = LocalDatabaseService();
  final _websocket = WebSocketService();
  final _messageQueue = MessageQueueService();
  final _dedup = MessageDedupService();
  
  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  
  // 同步完成回调
  Function()? onSyncCompleted;
  
  // 同步进度回调
  Function(int current, int total)? onSyncProgress;

  /// 初始化服务
  /// 
  /// 设置 WebSocket 重连回调
  Future<void> initialize() async {
    // 确保数据库表存在
    await _localDb.ensurePendingMessagesTable();
    await _localDb.ensureMessageDedupTable();
    await _localDb.ensureClientMessageIdColumn();
    
    // 设置 WebSocket 重连回调
    _websocket.onReconnected = _onWebSocketReconnected;
    
    // 初始化消息队列
    await _messageQueue.initialize();
    
    logger.debug('✅ [OfflineSync] 服务初始化完成');
  }

  /// WebSocket 重连后的处理
  Future<void> _onWebSocketReconnected() async {
    logger.debug('🔄 [OfflineSync] WebSocket 重连成功，开始同步...');
    await syncOnReconnect();
  }

  /// 重连后同步离线消息
  Future<void> syncOnReconnect() async {
    if (_isSyncing) {
      logger.debug('⚠️ [OfflineSync] 正在同步中，跳过');
      return;
    }
    
    _isSyncing = true;
    
    try {
      logger.debug('🔄 [OfflineSync] 开始同步离线消息...');
      
      // 1. 获取本地最后一条消息的时间戳
      final lastMessageTime = await _localDb.getLastMessageTimestamp();
      logger.debug('📅 [OfflineSync] 本地最后消息时间: $lastMessageTime');
      
      // 2. 请求服务器发送离线消息
      _websocket.requestOfflineMessages(lastMessageTime: lastMessageTime);
      
      // 3. 恢复待发送的消息队列
      await _messageQueue.resumeOnReconnect();
      logger.debug('📤 [OfflineSync] 待发送消息队列已恢复');
      
      // 4. 清理过期的去重记录
      await _dedup.cleanupExpiredRecords();
      
      _lastSyncTime = DateTime.now();
      
      logger.debug('✅ [OfflineSync] 离线消息同步完成');
      
      // 通知同步完成
      onSyncCompleted?.call();
    } catch (e) {
      logger.error('❌ [OfflineSync] 同步失败: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// 手动触发同步
  Future<void> manualSync() async {
    if (!_websocket.isConnected) {
      logger.debug('⚠️ [OfflineSync] WebSocket 未连接，无法同步');
      return;
    }
    
    await syncOnReconnect();
  }

  /// 获取同步状态
  bool get isSyncing => _isSyncing;
  
  /// 获取上次同步时间
  DateTime? get lastSyncTime => _lastSyncTime;

  /// 获取待发送消息数量
  int get pendingMessageCount => _messageQueue.pendingCount;

  /// 获取正在发送的消息数量
  int get sendingMessageCount => _messageQueue.sendingCount;

  /// 获取去重缓存统计
  Map<String, int> get dedupCacheStats => _dedup.getCacheStats();

  /// 清理资源
  void dispose() {
    _messageQueue.dispose();
    _dedup.clearCache();
    _websocket.onReconnected = null;
  }
}
