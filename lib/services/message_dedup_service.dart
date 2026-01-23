import 'dart:collection';
import 'local_database_service.dart';
import '../utils/logger.dart';

/// 消息去重服务
/// 
/// 用于防止重复接收消息，保证消息只处理一次
/// 
/// 核心功能：
/// 1. 内存LRU缓存 - 快速检查最近的消息
/// 2. 数据库持久化 - 持久化去重记录
/// 3. 支持服务器消息ID和客户端消息ID双重去重
class MessageDedupService {
  static final MessageDedupService _instance = MessageDedupService._internal();
  factory MessageDedupService() => _instance;
  MessageDedupService._internal();

  final _localDb = LocalDatabaseService();
  
  // 内存缓存（LRU）- 使用LinkedHashMap实现
  final LinkedHashMap<String, DateTime> _recentMessageIds = LinkedHashMap();
  static const int _maxCacheSize = 2000;
  
  // 私聊消息去重缓存
  final LinkedHashMap<String, DateTime> _privateMessageIds = LinkedHashMap();
  
  // 群聊消息去重缓存
  final LinkedHashMap<String, DateTime> _groupMessageIds = LinkedHashMap();

  /// 检查私聊消息是否重复
  /// 
  /// [messageId] 服务器消息ID
  /// [clientMessageId] 客户端消息ID（可选）
  /// 
  /// 返回 true 表示消息重复，应该跳过处理
  Future<bool> isPrivateMessageDuplicate(int messageId, {String? clientMessageId}) async {
    final key = _generateKey(messageId, clientMessageId);
    
    // 1. 先检查内存缓存
    if (_privateMessageIds.containsKey(key)) {
      logger.debug('🔄 [Dedup] 私聊消息重复（内存缓存）: $key');
      return true;
    }
    
    // 2. 检查数据库
    final exists = await _localDb.messageExists(messageId);
    if (exists) {
      _addToCache(_privateMessageIds, key);
      logger.debug('🔄 [Dedup] 私聊消息重复（数据库）: $key');
      return true;
    }
    
    // 3. 如果有clientMessageId，也检查
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      final existsByClientId = await _localDb.messageExistsByClientId(clientMessageId);
      if (existsByClientId) {
        _addToCache(_privateMessageIds, key);
        logger.debug('🔄 [Dedup] 私聊消息重复（clientMessageId）: $clientMessageId');
        return true;
      }
    }
    
    return false;
  }

  /// 检查群聊消息是否重复
  /// 
  /// [messageId] 服务器消息ID
  /// [groupId] 群组ID
  /// [clientMessageId] 客户端消息ID（可选）
  Future<bool> isGroupMessageDuplicate(int messageId, int groupId, {String? clientMessageId}) async {
    final key = 'g${groupId}_${_generateKey(messageId, clientMessageId)}';
    
    // 1. 先检查内存缓存
    if (_groupMessageIds.containsKey(key)) {
      logger.debug('🔄 [Dedup] 群聊消息重复（内存缓存）: $key');
      return true;
    }
    
    // 2. 检查数据库
    final exists = await _localDb.groupMessageExists(messageId, groupId);
    if (exists) {
      _addToCache(_groupMessageIds, key);
      logger.debug('🔄 [Dedup] 群聊消息重复（数据库）: $key');
      return true;
    }
    
    // 3. 如果有clientMessageId，也检查
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      final existsByClientId = await _localDb.groupMessageExistsByClientId(clientMessageId, groupId);
      if (existsByClientId) {
        _addToCache(_groupMessageIds, key);
        logger.debug('🔄 [Dedup] 群聊消息重复（clientMessageId）: $clientMessageId');
        return true;
      }
    }
    
    return false;
  }

  /// 标记私聊消息已处理
  void markPrivateMessageProcessed(int messageId, {String? clientMessageId}) {
    final key = _generateKey(messageId, clientMessageId);
    _addToCache(_privateMessageIds, key);
    
    // 同时添加到去重表（异步，不阻塞）
    _persistDedup(messageId, clientMessageId, isGroup: false);
  }

  /// 标记群聊消息已处理
  void markGroupMessageProcessed(int messageId, int groupId, {String? clientMessageId}) {
    final key = 'g${groupId}_${_generateKey(messageId, clientMessageId)}';
    _addToCache(_groupMessageIds, key);
    
    // 同时添加到去重表（异步，不阻塞）
    _persistDedup(messageId, clientMessageId, isGroup: true, groupId: groupId);
  }

  /// 批量检查消息是否重复
  /// 
  /// 返回不重复的消息ID列表
  Future<List<int>> filterDuplicateMessages(List<int> messageIds, {bool isGroup = false, int? groupId}) async {
    final nonDuplicates = <int>[];
    
    for (final id in messageIds) {
      bool isDuplicate;
      if (isGroup && groupId != null) {
        isDuplicate = await isGroupMessageDuplicate(id, groupId);
      } else {
        isDuplicate = await isPrivateMessageDuplicate(id);
      }
      
      if (!isDuplicate) {
        nonDuplicates.add(id);
      }
    }
    
    return nonDuplicates;
  }

  /// 生成去重key
  String _generateKey(int messageId, String? clientMessageId) {
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      return '${messageId}_$clientMessageId';
    }
    return messageId.toString();
  }

  /// 添加到LRU缓存
  void _addToCache(LinkedHashMap<String, DateTime> cache, String key) {
    // 如果已存在，先删除再添加（移到末尾）
    cache.remove(key);
    
    // 如果超过最大容量，删除最旧的
    while (cache.length >= _maxCacheSize) {
      cache.remove(cache.keys.first);
    }
    
    cache[key] = DateTime.now();
  }

  /// 持久化去重记录到数据库
  Future<void> _persistDedup(int messageId, String? clientMessageId, {required bool isGroup, int? groupId}) async {
    try {
      await _localDb.insertMessageDedup(
        messageId: messageId,
        clientMessageId: clientMessageId,
        isGroup: isGroup,
        groupId: groupId,
      );
    } catch (e) {
      // 去重记录插入失败不影响主流程
      logger.debug('⚠️ [Dedup] 持久化去重记录失败: $e');
    }
  }

  /// 清理过期的去重记录（保留7天）
  Future<void> cleanupExpiredRecords() async {
    try {
      final deletedCount = await _localDb.cleanupExpiredDedup(days: 7);
      if (deletedCount > 0) {
        logger.debug('🧹 [Dedup] 清理过期去重记录: $deletedCount 条');
      }
    } catch (e) {
      logger.debug('⚠️ [Dedup] 清理过期记录失败: $e');
    }
  }

  /// 清空内存缓存
  void clearCache() {
    _recentMessageIds.clear();
    _privateMessageIds.clear();
    _groupMessageIds.clear();
    logger.debug('🧹 [Dedup] 内存缓存已清空');
  }

  /// 获取缓存统计信息
  Map<String, int> getCacheStats() {
    return {
      'privateMessageCache': _privateMessageIds.length,
      'groupMessageCache': _groupMessageIds.length,
      'totalCache': _privateMessageIds.length + _groupMessageIds.length,
    };
  }
}
