import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';
import '../config/api_config.dart';
import '../utils/storage.dart';
import 'local_database_service.dart';

/// 消息同步服务
/// 负责与服务器B通信，实现消息同步功能
class MessageSyncService {
  static final MessageSyncService _instance = MessageSyncService._internal();
  factory MessageSyncService() => _instance;
  MessageSyncService._internal();

  final _localDb = LocalDatabaseService();
  Timer? _syncTimer;
  bool _isRunning = false;
  int? _currentUserId;

  /// 获取服务器B的基础URL
  String get _serverBBaseUrl {
    return 'http://${ApiConfig.syncHost}:${ApiConfig.syncPort}';
  }

  /// 启动定时同步任务
  /// 每隔5秒调用服务器B的check-sync接口
  Future<void> startPeriodicSync(int userId) async {
    if (_isRunning) {
      logger.debug('[MessageSync] 定时同步任务已在运行中');
      return;
    }

    _currentUserId = userId;
    _isRunning = true;

    logger.debug('[MessageSync] 启动定时同步任务，用户ID: $userId');

    // 立即执行一次同步检查
    await _checkSync();

    // 每5秒执行一次同步检查
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _checkSync();
    });
  }

  /// 停止定时同步任务
  void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _isRunning = false;
    _currentUserId = null;
    logger.debug('[MessageSync] 停止定时同步任务');
  }

  /// 检查是否有未同步的消息
  /// 调用服务器B的 POST /api/check-sync 接口
  Future<void> _checkSync() async {
    if (_currentUserId == null) {
      return;
    }

    try {
      // 获取本地所有会话的最新消息ID
      final messageIds = await _getLocalPrivateMessageIds();
      final groupMessageIds = await _getLocalGroupMessageIds();

      // 如果没有任何会话，跳过同步
      if (messageIds.isEmpty && groupMessageIds.isEmpty) {
        return;
      }

      final requestBody = {
        'receiver_id': _currentUserId,
        'message_ids': messageIds,
        'group_message_ids': groupMessageIds,
      };

      logger.debug('[MessageSync] 发送同步检查请求: $requestBody');

      final response = await http.post(
        Uri.parse('$_serverBBaseUrl/api/check-sync'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final needSync = data['need_sync'] as bool? ?? false;
        if (needSync) {
          logger.debug('[MessageSync] 服务器B检测到有未同步的消息，已触发同步');
        }
      } else {
        logger.debug('[MessageSync] 同步检查请求失败: ${response.statusCode}');
      }
    } catch (e) {
      logger.debug('[MessageSync] 同步检查异常: $e');
    }
  }

  /// 立即执行一次同步检查（供外部调用）
  /// 在WebSocket重连后立即调用，确保客户端能收到未同步的消息
  Future<void> checkSyncImmediately(int userId) async {
    _currentUserId = userId;
    await _checkSync();
  }

  /// 同步新消息到服务器B
  /// 在收到 message_sent 确认后调用
  /// 
  /// [receiverId] 接收者ID
  /// [senderId] 发送者ID
  /// [serverId] 服务器返回的消息ID
  Future<void> syncPrivateMessage({
    required int receiverId,
    required int senderId,
    required int serverId,
  }) async {
    try {
      // 生成私聊消息的key: 0-{接收者ID}-{发送者ID}
      final key = '0-$receiverId-$senderId';
      final requestBody = {key: serverId};

      logger.debug('[MessageSync] 同步私聊消息到服务器B: $requestBody');

      final response = await http.post(
        Uri.parse('$_serverBBaseUrl/api/sync-message'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        logger.debug('[MessageSync] 私聊消息同步成功');
      } else {
        logger.debug('[MessageSync] 私聊消息同步失败: ${response.statusCode}');
      }
    } catch (e) {
      logger.debug('[MessageSync] 私聊消息同步异常: $e');
    }
  }

  /// 同步群组消息到服务器B
  /// 在收到 message_sent 确认后调用
  ///
  /// 🔴 关键修复：群组消息的 key 格式改为 1-{群组ID}
  /// 不再包含用户ID，这样所有群组成员都使用相同的 key
  ///
  /// [receiverId] 接收者ID（当前用户）- 保留参数但不再使用
  /// [groupId] 群组ID
  /// [serverId] 服务器返回的消息ID
  Future<void> syncGroupMessage({
    required int receiverId,
    required int groupId,
    required int serverId,
  }) async {
    try {
      // 🔴 关键修复：群组消息的key格式改为 1-{群组ID}
      // 不再包含用户ID，这样所有群组成员都使用相同的 key
      // 这样当任何成员发送消息时，其他成员都能通过 check-sync 检测到未同步的消息
      final key = '1-$groupId';
      final requestBody = {key: serverId};

      logger.debug('[MessageSync] 同步群组消息到服务器B: $requestBody');

      final response = await http.post(
        Uri.parse('$_serverBBaseUrl/api/sync-message'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        logger.debug('[MessageSync] 群组消息同步成功');
      } else {
        logger.debug('[MessageSync] 群组消息同步失败: ${response.statusCode}');
      }
    } catch (e) {
      logger.debug('[MessageSync] 群组消息同步异常: $e');
    }
  }

  /// 获取本地私聊会话的最新消息ID
  /// 返回格式: {"0-100-101": [31, 32], "0-100-102": [41]}
  Future<Map<String, List<int>>> _getLocalPrivateMessageIds() async {
    final result = <String, List<int>>{};

    if (_currentUserId == null) {
      return result;
    }

    try {
      // 获取所有私聊会话的最新消息
      final conversations = await _localDb.getRecentPrivateConversations(_currentUserId!);
      
      for (final conv in conversations) {
        final otherUserId = conv['other_user_id'] as int?;
        final serverId = conv['server_id'] as int?;
        
        if (otherUserId != null && serverId != null && serverId > 0) {
          // key格式: 0-{接收者ID}-{发送者ID}
          final key = '0-$_currentUserId-$otherUserId';
          result[key] = [serverId];
        }
      }
    } catch (e) {
      logger.debug('[MessageSync] 获取本地私聊消息ID失败: $e');
    }

    return result;
  }

  /// 获取本地群组会话的最新消息ID
  /// 返回格式: {"1-901": [1001], "1-902": [2001]}
  ///
  /// 🔴 关键修复：
  /// 1. key 格式改为 1-{群组ID}，不再包含用户ID
  /// 2. 即使群组没有本地消息（server_id=0），也要包含在结果中
  /// 这样服务器B才能检测到该群组是否有未同步的消息
  Future<Map<String, List<int>>> _getLocalGroupMessageIds() async {
    final result = <String, List<int>>{};

    if (_currentUserId == null) {
      return result;
    }

    try {
      // 获取用户所属的所有群组及其最新消息
      // 🔴 现在 getRecentGroupConversations 会返回所有群组，包括没有消息的群组（server_id=0）
      final conversations = await _localDb.getRecentGroupConversations(_currentUserId!);
      
      for (final conv in conversations) {
        final groupId = conv['group_id'] as int?;
        final serverId = conv['server_id'] as int?;
        
        if (groupId != null) {
          // 🔴 关键修复：key格式改为 1-{群组ID}，不再包含用户ID
          // 这样所有群组成员都使用相同的 key
          final key = '1-$groupId';
          // 🔴 即使 serverId 为 0 或 null，也要包含这个群组
          // 这样服务器B才能检测到该群组是否有未同步的消息
          final effectiveServerId = (serverId != null && serverId > 0) ? serverId : 0;
          result[key] = [effectiveServerId];
        }
      }
      
      logger.debug('[MessageSync] 获取本地群组消息ID: ${result.length}个群组');
    } catch (e) {
      logger.debug('[MessageSync] 获取本地群组消息ID失败: $e');
    }

    return result;
  }

  /// 检查服务是否正在运行
  bool get isRunning => _isRunning;
}
