import 'dart:async';
import 'local_database_service.dart';
import 'websocket_service.dart';
import 'message_queue_service.dart';
import 'message_dedup_service.dart';
import 'message_sync_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';

/// 离线消息同步服务
/// 
/// 负责在重连后同步离线消息，确保消息不丢失
/// 
/// 核心功能：
/// 1. 重连后通过服务器B的 check-sync API 同步离线消息
/// 2. 恢复待发送的消息队列
/// 3. 清理过期的去重记录
/// 
/// 🔴 注意：统一使用服务器B的 check-sync API 方式同步离线消息
/// 不再使用 WebSocket 直接请求 sync_offline_messages 的方式
/// 这样可以避免两种方式的竞争条件导致同步不稳定
class OfflineSyncService {
  static final OfflineSyncService _instance = OfflineSyncService._internal();
  factory OfflineSyncService() => _instance;
  OfflineSyncService._internal();

  final _localDb = LocalDatabaseService();
  final _websocket = WebSocketService();
  final _messageQueue = MessageQueueService();
  final _dedup = MessageDedupService();
  final _messageSync = MessageSyncService();
  
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
  /// 
  /// 🔴 统一使用服务器B的 check-sync API 方式同步离线消息
  /// 不再使用 WebSocket 直接请求 sync_offline_messages 的方式
  /// 这样可以避免两种方式的竞争条件导致同步不稳定
  Future<void> _onWebSocketReconnected() async {
    final reconnectTime = DateTime.now();
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('🔄 [OfflineSync] ========== WebSocket重连成功 ==========');
    logger.debug('🔄 [OfflineSync] 重连时间: ${reconnectTime.toIso8601String()}');
    logger.debug('🔄 [OfflineSync] WebSocket连接状态: ${_websocket.isConnected}');
    logger.debug('🔄 [OfflineSync] 开始同步离线消息...');
    logger.debug('═══════════════════════════════════════════════════════════');
    await syncOnReconnect();
  }

  /// 重连后同步离线消息
  /// 
  /// 🔴 只使用服务器B的 check-sync API 方式
  /// 服务器B会比较客户端和服务器的消息ID，找出未同步的消息
  /// 然后通过 WebSocket 通知服务器A推送这些消息给客户端
  Future<void> syncOnReconnect() async {
    if (_isSyncing) {
      logger.debug('⚠️ [OfflineSync] 正在同步中，跳过');
      return;
    }
    
    _isSyncing = true;
    
    try {
      logger.debug('🔄 [OfflineSync] 开始同步离线消息...');
      
      // 1. 恢复待发送的消息队列
      await _messageQueue.resumeOnReconnect();
      logger.debug('📤 [OfflineSync] 待发送消息队列已恢复');
      
      // 2. 清理过期的去重记录
      await _dedup.cleanupExpiredRecords();
      
      // 3. 🔴 统一使用服务器B的 check-sync API 同步离线消息
      // 不再使用 _websocket.requestOfflineMessages() 方式
      final userId = await Storage.getUserId();
      if (userId != null) {
        await triggerServerBSync(userId);
      } else {
        logger.debug('⚠️ [OfflineSync] 无法获取用户ID，跳过服务器B同步检查');
      }
      
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

  /// 触发服务器B的消息同步检查
  /// 在WebSocket重连后立即调用，确保客户端能收到未同步的消息
  Future<void> triggerServerBSync(int userId) async {
    final syncStartTime = DateTime.now();
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('🔄 [OfflineSync] ========== 触发服务器B消息同步检查 ==========');
    logger.debug('🔄 [OfflineSync] 开始时间: ${syncStartTime.toIso8601String()}');
    logger.debug('🔄 [OfflineSync] 用户ID: $userId');
    logger.debug('🔄 [OfflineSync] MessageSyncService状态: isRunning=${_messageSync.isRunning}');
    logger.debug('═══════════════════════════════════════════════════════════');
    
    try {
      final result = await _messageSync.checkSyncImmediately(userId);
      
      final syncEndTime = DateTime.now();
      final syncDuration = syncEndTime.difference(syncStartTime);
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('✅ [OfflineSync] ========== 服务器B消息同步检查完成 ==========');
      logger.debug('✅ [OfflineSync] 完成时间: ${syncEndTime.toIso8601String()}');
      logger.debug('✅ [OfflineSync] 总耗时: ${syncDuration.inMilliseconds}ms');
      logger.debug('✅ [OfflineSync] 检查结果: needSync=${result.needSync}');
      logger.debug('✅ [OfflineSync] 缺失私聊消息数: ${result.missingPrivateIDs.length}');
      logger.debug('✅ [OfflineSync] 缺失群组消息数: ${result.missingGroupIDs.length}');
      if (result.missingGroupIDs.isNotEmpty) {
        logger.debug('✅ [OfflineSync] 缺失群组消息ID: ${result.missingGroupIDs}');
      }
      
      // 🔴 关键修复：如果检测到缺失消息，记录日志
      // 注意：服务器B返回的missingGroupIDs只是消息ID列表，没有群组ID信息
      // 需要服务器B在响应中提供群组ID和消息ID的映射关系，或者客户端需要从其他地方获取
      if (result.needSync && (result.missingPrivateIDs.isNotEmpty || result.missingGroupIDs.isNotEmpty)) {
        logger.debug('🔄 [OfflineSync] 检测到缺失消息，但需要服务器B提供群组ID映射才能拉取');
        logger.debug('🔄 [OfflineSync] 缺失私聊消息ID: ${result.missingPrivateIDs}');
        logger.debug('🔄 [OfflineSync] 缺失群组消息ID: ${result.missingGroupIDs}');
        logger.debug('🔄 [OfflineSync] 注意：服务器B应该返回群组ID和消息ID的映射关系');
      }
      
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e, stackTrace) {
      final syncEndTime = DateTime.now();
      final syncDuration = syncEndTime.difference(syncStartTime);
      logger.error('═══════════════════════════════════════════════════════════');
      logger.error('❌ [OfflineSync] ========== 服务器B消息同步检查失败 ==========');
      logger.error('❌ [OfflineSync] 失败时间: ${syncEndTime.toIso8601String()}');
      logger.error('❌ [OfflineSync] 总耗时: ${syncDuration.inMilliseconds}ms');
      logger.error('❌ [OfflineSync] 异常类型: ${e.runtimeType}');
      logger.error('❌ [OfflineSync] 异常信息: $e');
      logger.error('❌ [OfflineSync] 堆栈跟踪:');
      logger.error('$stackTrace');
      logger.error('═══════════════════════════════════════════════════════════');
    }
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
