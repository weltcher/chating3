import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';
import '../config/api_config.dart';
import 'local_database_service.dart';
import 'api_service.dart';

/// 检查同步结果
class CheckSyncResult {
  final bool needSync;
  final List<int> missingPrivateIDs;
  final List<int> missingGroupIDs;

  CheckSyncResult({
    required this.needSync,
    required this.missingPrivateIDs,
    required this.missingGroupIDs,
  });
}

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

    // 立即执行一次同步检查（定时任务不关心返回值）
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
  /// 返回检查结果，包含是否需要同步和缺失的消息ID列表
  Future<CheckSyncResult> _checkSync() async {
    if (_currentUserId == null) {
      logger.debug('🔍 [CheckSync] 当前用户ID为空，跳过同步检查');
      return CheckSyncResult(
        needSync: false,
        missingPrivateIDs: [],
        missingGroupIDs: [],
      );
    }

    final startTime = DateTime.now();
    final requestUrl = '$_serverBBaseUrl/api/check-sync';
    
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('🔍 [CheckSync] ========== 开始调用服务器B的check-sync API ==========');
    logger.debug('🔍 [CheckSync] 时间: ${startTime.toIso8601String()}');
    logger.debug('🔍 [CheckSync] 用户ID: $_currentUserId');
    logger.debug('🔍 [CheckSync] 服务器B URL: $_serverBBaseUrl');
    logger.debug('🔍 [CheckSync] 请求URL: $requestUrl');

    try {
      // 获取本地所有会话的最新消息ID
      logger.debug('🔍 [CheckSync] 正在获取本地私聊消息ID...');
      final messageIds = await _getLocalPrivateMessageIds();
      logger.debug('🔍 [CheckSync] 本地私聊消息ID获取完成: ${messageIds.length}个会话');
      logger.debug('🔍 [CheckSync] 私聊消息ID详情: $messageIds');
      
      logger.debug('🔍 [CheckSync] 正在获取本地群组消息ID...');
      final groupMessageIds = await _getLocalGroupMessageIds();
      logger.debug('🔍 [CheckSync] 本地群组消息ID获取完成: ${groupMessageIds.length}个群组');
      logger.debug('🔍 [CheckSync] 群组消息ID详情: $groupMessageIds');

      // 如果没有任何会话，跳过同步
      if (messageIds.isEmpty && groupMessageIds.isEmpty) {
        logger.debug('🔍 [CheckSync] 本地没有任何会话，跳过同步检查');
        logger.debug('═══════════════════════════════════════════════════════════');
        return CheckSyncResult(
          needSync: false,
          missingPrivateIDs: [],
          missingGroupIDs: [],
        );
      }

      final requestBody = {
        'receiver_id': _currentUserId,
        'message_ids': messageIds,
        'group_message_ids': groupMessageIds,
      };

      final requestBodyJson = jsonEncode(requestBody);
      logger.debug('🔍 [CheckSync] 请求体大小: ${requestBodyJson.length}字节');
      logger.debug('🔍 [CheckSync] 请求体内容: $requestBodyJson');
      logger.debug('🔍 [CheckSync] 请求头: Content-Type: application/json');
      logger.debug('🔍 [CheckSync] 正在发送HTTP POST请求...');

      final response = await http.post(
        Uri.parse(requestUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: requestBodyJson,
      ).timeout(const Duration(seconds: 10));

      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      
      logger.debug('🔍 [CheckSync] HTTP请求完成');
      logger.debug('🔍 [CheckSync] 响应状态码: ${response.statusCode}');
      logger.debug('🔍 [CheckSync] 响应头: ${response.headers}');
      logger.debug('🔍 [CheckSync] 响应体大小: ${response.bodyBytes.length}字节');
      logger.debug('🔍 [CheckSync] 请求耗时: ${duration.inMilliseconds}ms');
      
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          logger.debug('🔍 [CheckSync] 响应体解析成功');
          logger.debug('🔍 [CheckSync] 响应数据: $data');
          
          final needSync = data['need_sync'] as bool? ?? false;
          logger.debug('🔍 [CheckSync] need_sync字段: $needSync');
          
          // 解析缺失的消息ID列表
          List<int> missingPrivateIDs = [];
          List<int> missingGroupIDs = [];
          
          if (data['missing_private_ids'] != null) {
            final ids = data['missing_private_ids'] as List?;
            if (ids != null) {
              missingPrivateIDs = ids.map((e) => (e as num).toInt()).toList();
              logger.debug('🔍 [CheckSync] 缺失的私聊消息ID: $missingPrivateIDs');
            }
          }
          
          if (data['missing_group_ids'] != null) {
            final ids = data['missing_group_ids'] as List?;
            if (ids != null) {
              missingGroupIDs = ids.map((e) => (e as num).toInt()).toList();
              logger.debug('🔍 [CheckSync] 缺失的群组消息ID: $missingGroupIDs');
            }
          }
          
          if (needSync) {
            logger.debug('✅ [CheckSync] 服务器B检测到有未同步的消息，已触发同步');
            logger.debug('✅ [CheckSync] 缺失私聊消息数: ${missingPrivateIDs.length}, 缺失群组消息数: ${missingGroupIDs.length}');
            logger.debug('═══════════════════════════════════════════════════════════');
            return CheckSyncResult(
              needSync: true,
              missingPrivateIDs: missingPrivateIDs,
              missingGroupIDs: missingGroupIDs,
            );
          } else {
            logger.debug('ℹ️ [CheckSync] 服务器B确认没有未同步的消息');
            logger.debug('═══════════════════════════════════════════════════════════');
            return CheckSyncResult(
              needSync: false,
              missingPrivateIDs: [],
              missingGroupIDs: [],
            );
          }
        } catch (e) {
          logger.error('❌ [CheckSync] 响应体JSON解析失败: $e');
          logger.error('❌ [CheckSync] 原始响应体: ${response.body}');
          logger.debug('═══════════════════════════════════════════════════════════');
          return CheckSyncResult(
            needSync: false,
            missingPrivateIDs: [],
            missingGroupIDs: [],
          );
        }
      } else {
        logger.error('❌ [CheckSync] 同步检查请求失败');
        logger.error('❌ [CheckSync] 状态码: ${response.statusCode}');
        logger.error('❌ [CheckSync] 响应体: ${response.body}');
        logger.debug('═══════════════════════════════════════════════════════════');
        return CheckSyncResult(
          needSync: false,
          missingPrivateIDs: [],
          missingGroupIDs: [],
        );
      }
    } catch (e, stackTrace) {
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      
      logger.error('❌ [CheckSync] ========== check-sync API调用异常 ==========');
      logger.error('❌ [CheckSync] 异常类型: ${e.runtimeType}');
      logger.error('❌ [CheckSync] 异常信息: $e');
      logger.error('❌ [CheckSync] 请求耗时: ${duration.inMilliseconds}ms');
      logger.error('❌ [CheckSync] 堆栈跟踪:');
      logger.error('$stackTrace');
      logger.error('❌ [CheckSync] ===============================================');
      logger.error('═══════════════════════════════════════════════════════════');
      return CheckSyncResult(
        needSync: false,
        missingPrivateIDs: [],
        missingGroupIDs: [],
      );
    }
  }

  /// 立即执行一次同步检查（供外部调用）
  /// 在WebSocket重连后立即调用，确保客户端能收到未同步的消息
  /// 返回检查结果，包含是否需要同步和缺失的消息ID列表
  Future<CheckSyncResult> checkSyncImmediately(int userId) async {
    logger.debug('🔍 [CheckSync] checkSyncImmediately被调用');
    logger.debug('🔍 [CheckSync] 传入的用户ID: $userId');
    logger.debug('🔍 [CheckSync] 当前用户ID: $_currentUserId');
    logger.debug('🔍 [CheckSync] 服务运行状态: $_isRunning');
    
    _currentUserId = userId;
    logger.debug('🔍 [CheckSync] 已更新当前用户ID为: $_currentUserId');
    logger.debug('🔍 [CheckSync] 开始执行_checkSync()...');
    
    final result = await _checkSync();
    
    logger.debug('🔍 [CheckSync] checkSyncImmediately执行完成，needSync=${result.needSync}');
    logger.debug('🔍 [CheckSync] 缺失私聊消息数: ${result.missingPrivateIDs.length}, 缺失群组消息数: ${result.missingGroupIDs.length}');
    return result;
  }

  /// 带重试机制的同步检查
  /// [userId] 用户ID
  /// [maxRetries] 最大重试次数，默认3次
  /// [retryDelay] 每次重试之间的延迟，默认2秒
  /// 返回检查结果，包含是否需要同步和缺失的消息ID列表（合并所有重试的结果）
  Future<CheckSyncResult> checkSyncWithRetry(int userId, {int maxRetries = 3, Duration retryDelay = const Duration(seconds: 2)}) async {
    logger.debug('🔄 [CheckSync] 开始带重试机制的同步检查');
    logger.debug('🔄 [CheckSync] 用户ID: $userId, 最大重试次数: $maxRetries, 重试延迟: ${retryDelay.inSeconds}秒');
    
    _currentUserId = userId;
    
    // 合并所有重试的缺失消息ID
    final allMissingPrivateIDs = <int>{};
    final allMissingGroupIDs = <int>{};
    bool finalNeedSync = false;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      logger.debug('🔄 [CheckSync] 第 $attempt 次尝试（共 $maxRetries 次）');
      
      final result = await _checkSync();
      
      // 合并缺失的消息ID
      allMissingPrivateIDs.addAll(result.missingPrivateIDs);
      allMissingGroupIDs.addAll(result.missingGroupIDs);
      
      if (!result.needSync) {
        logger.debug('🔄 [CheckSync] 第 $attempt 次检查：无需同步，结束重试');
        return CheckSyncResult(
          needSync: false,
          missingPrivateIDs: allMissingPrivateIDs.toList()..sort(),
          missingGroupIDs: allMissingGroupIDs.toList()..sort(),
        );
      }
      
      logger.debug('🔄 [CheckSync] 第 $attempt 次检查：需要同步');
      logger.debug('🔄 [CheckSync] 本次缺失私聊消息数: ${result.missingPrivateIDs.length}, 缺失群组消息数: ${result.missingGroupIDs.length}');
      finalNeedSync = true;
      
      // 如果不是最后一次尝试，等待一段时间后重试
      if (attempt < maxRetries) {
        logger.debug('🔄 [CheckSync] 等待 ${retryDelay.inSeconds} 秒后重试...');
        await Future.delayed(retryDelay);
      } else {
        logger.debug('🔄 [CheckSync] 已达到最大重试次数，返回需要同步');
      }
    }
    
    logger.debug('🔄 [CheckSync] 带重试机制的同步检查完成，最终结果：需要同步');
    logger.debug('🔄 [CheckSync] 累计缺失私聊消息数: ${allMissingPrivateIDs.length}, 累计缺失群组消息数: ${allMissingGroupIDs.length}');
    return CheckSyncResult(
      needSync: finalNeedSync,
      missingPrivateIDs: allMissingPrivateIDs.toList()..sort(),
      missingGroupIDs: allMissingGroupIDs.toList()..sort(),
    );
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
      logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 当前用户ID为空');
      return result;
    }

    try {
      logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 开始查询数据库，用户ID=$_currentUserId');
      // 获取所有私聊会话的最新消息
      final conversations = await _localDb.getRecentPrivateConversations(_currentUserId!);
      logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 数据库返回${conversations.length}个会话');
      
      int processedCount = 0;
      int skippedCount = 0;
      
      for (final conv in conversations) {
        final otherUserId = conv['other_user_id'] as int?;
        final serverId = conv['server_id'] as int?;
        
        logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 处理会话 - otherUserId=$otherUserId, serverId=$serverId');
        
        if (otherUserId != null && serverId != null && serverId > 0) {
          // key格式: 0-{接收者ID}-{发送者ID}
          final key = '0-$_currentUserId-$otherUserId';
          result[key] = [serverId];
          processedCount++;
          logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 添加私聊key=$key, serverId=$serverId');
        } else {
          skippedCount++;
          logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 跳过会话 - otherUserId=$otherUserId, serverId=$serverId');
        }
      }
      
      logger.debug('🔍 [CheckSync] _getLocalPrivateMessageIds: 处理完成 - 已处理$processedCount个，跳过$skippedCount个');
    } catch (e, stackTrace) {
      logger.error('❌ [CheckSync] _getLocalPrivateMessageIds: 获取本地私聊消息ID失败: $e');
      logger.error('❌ [CheckSync] _getLocalPrivateMessageIds: 堆栈跟踪: $stackTrace');
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
      logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 当前用户ID为空');
      return result;
    }

    try {
      logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 开始查询数据库，用户ID=$_currentUserId');
      // 获取用户所属的所有群组及其最新消息
      // 🔴 现在 getRecentGroupConversations 会返回所有群组，包括没有消息的群组（server_id=0）
      final conversations = await _localDb.getRecentGroupConversations(_currentUserId!);
      logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 数据库返回${conversations.length}个群组');
      
      int processedCount = 0;
      int skippedCount = 0;
      
      for (final conv in conversations) {
        final groupId = conv['group_id'] as int?;
        final serverId = conv['server_id'] as int?;
        
        logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 处理群组 - groupId=$groupId, serverId=$serverId');
        
        if (groupId != null) {
          // 🔴 关键修复：key格式改为 1-{群组ID}，不再包含用户ID
          // 这样所有群组成员都使用相同的 key
          final key = '1-$groupId';
          // 🔴 即使 serverId 为 0 或 null，也要包含这个群组
          // 这样服务器B才能检测到该群组是否有未同步的消息
          final effectiveServerId = (serverId != null && serverId > 0) ? serverId : 0;
          result[key] = [effectiveServerId];
          processedCount++;
          logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 添加群组key=$key, effectiveServerId=$effectiveServerId');
        } else {
          skippedCount++;
          logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 跳过群组 - groupId=$groupId');
        }
      }
      
      logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 处理完成 - 已处理$processedCount个，跳过$skippedCount个');
      logger.debug('🔍 [CheckSync] _getLocalGroupMessageIds: 最终结果包含${result.length}个群组');
    } catch (e, stackTrace) {
      logger.error('❌ [CheckSync] _getLocalGroupMessageIds: 获取本地群组消息ID失败: $e');
      logger.error('❌ [CheckSync] _getLocalGroupMessageIds: 堆栈跟踪: $stackTrace');
    }

    return result;
  }

  /// 检查服务是否正在运行
  bool get isRunning => _isRunning;

  /// 主动拉取缺失的私聊消息
  /// [token] 用户token
  /// [messageIds] 缺失的消息ID列表
  /// [currentUserId] 当前用户ID（可选，用于筛选属于当前会话的消息）
  /// [otherUserId] 对方用户ID（可选，用于筛选属于当前会话的消息）
  /// 返回成功拉取的消息数量和属于当前会话的消息数量
  Future<Map<String, int>> fetchMissingPrivateMessages({
    required String token,
    required List<int> messageIds,
    int? currentUserId,
    int? otherUserId,
  }) async {
    if (messageIds.isEmpty) {
      logger.debug('🔍 [FetchMessages] 缺失的私聊消息ID列表为空，跳过拉取');
      return {'total': 0, 'currentConversation': 0};
    }

    logger.debug('🔍 [FetchMessages] 开始主动拉取缺失的私聊消息: ${messageIds.length}条');
    if (currentUserId != null && otherUserId != null) {
      logger.debug('🔍 [FetchMessages] 将筛选属于当前会话的消息: currentUserId=$currentUserId, otherUserId=$otherUserId');
    }

    try {
      // 分批拉取，每批最多100条
      const batchSize = 100;
      const retryDelay = Duration(seconds: 2); // 重试延迟
      int totalFetched = 0;
      int currentConversationFetched = 0;

      for (int i = 0; i < messageIds.length; i += batchSize) {
        final batch = messageIds.skip(i).take(batchSize).toList();
        logger.debug('🔍 [FetchMessages] 拉取第 ${i ~/ batchSize + 1} 批: ${batch.length}条消息');

        // 🔴 无限重试：直到成功获取到消息为止
        bool batchSuccess = false;
        int retryCount = 0;
        
        while (!batchSuccess) {
          try {
            if (retryCount > 0) {
              logger.debug('🔄 [FetchMessages] 第 ${i ~/ batchSize + 1} 批重试第 $retryCount 次...');
              await Future.delayed(retryDelay);
            }
            
            final response = await ApiService.getMessagesByIds(
              token: token,
              messageIds: batch,
            );

            // 🔴 增强日志：记录完整的响应信息
            logger.debug('🔍 [FetchMessages] API响应详情: code=${response['code']}, message=${response['message']}, hasData=${response['data'] != null}');
            if (response['data'] != null) {
              logger.debug('🔍 [FetchMessages] response data类型: ${response['data'].runtimeType}');
              if (response['data'] is Map) {
                logger.debug('🔍 [FetchMessages] response data keys: ${(response['data'] as Map).keys}');
              }
            }

            if (response['code'] == 0 && response['data'] != null) {
              final messages = response['data']['messages'] as List?;
              if (messages != null) {
                batchSuccess = true; // 标记成功，退出重试循环
                
                if (messages.isNotEmpty) {
                  totalFetched += messages.length;
                  logger.debug('🔍 [FetchMessages] 成功拉取 ${messages.length} 条私聊消息（请求 ${batch.length} 条）');
                  
                  // 将消息保存到本地数据库
                  for (final msg in messages) {
                    try {
                      final messageData = msg as Map<String, dynamic>;
                      final senderId = messageData['sender_id'] as int?;
                      final receiverId = messageData['receiver_id'] as int?;
                      
                      // 检查是否属于当前会话
                      bool belongsToCurrentConversation = false;
                      if (currentUserId != null && otherUserId != null) {
                        // 消息属于当前会话，如果 (sender_id == currentUserId && receiver_id == otherUserId) 
                        // 或 (sender_id == otherUserId && receiver_id == currentUserId)
                        belongsToCurrentConversation = 
                            (senderId == currentUserId && receiverId == otherUserId) ||
                            (senderId == otherUserId && receiverId == currentUserId);
                        
                        if (belongsToCurrentConversation) {
                          currentConversationFetched++;
                          logger.debug('🔍 [FetchMessages] 消息属于当前会话: serverId=${messageData['id']}, senderId=$senderId, receiverId=$receiverId');
                        }
                      }
                      
                      // 转换服务器消息格式为本地数据库格式
                      final messageToSave = {
                        'server_id': messageData['id'],
                        'sender_id': senderId,
                        'receiver_id': receiverId,
                        'sender_name': messageData['sender_name'],
                        'receiver_name': messageData['receiver_name'],
                        'sender_avatar': messageData['sender_avatar'],
                        'receiver_avatar': messageData['receiver_avatar'],
                        'content': messageData['content'],
                        'message_type': messageData['message_type'],
                        'file_name': messageData['file_name'],
                        'quoted_message_id': messageData['quoted_message_id'],
                        'quoted_message_content': messageData['quoted_message_content'],
                        'call_type': messageData['call_type'],
                        'voice_duration': messageData['voice_duration'],
                        'status': messageData['status'] ?? 'normal',
                        'is_read': messageData['is_read'] ?? false,
                        'created_at': messageData['created_at'],
                        'read_at': messageData['read_at'],
                      };
                      
                      // 移除null值
                      messageToSave.removeWhere((key, value) => value == null);
                      
                      // 检查消息是否已存在（通过server_id）
                      final existingMsg = await _localDb.getMessageByServerId(messageData['id'] as int);
                      if (existingMsg == null) {
                        await _localDb.insertMessage(messageToSave, orIgnore: false);
                        logger.debug('🔍 [FetchMessages] 保存私聊消息: serverId=${messageData['id']}${belongsToCurrentConversation ? " (当前会话)" : ""}');
                      } else {
                        logger.debug('🔍 [FetchMessages] 私聊消息已存在，跳过: serverId=${messageData['id']}');
                      }
                    } catch (e) {
                      logger.error('❌ [FetchMessages] 保存私聊消息失败: $e');
                    }
                  }
                } else {
                  logger.debug('🔍 [FetchMessages] 第 ${i ~/ batchSize + 1} 批：服务器返回空消息列表（可能消息已被删除）');
                  // 🔴 关键修复：即使返回空列表，也视为成功（消息可能已被删除），退出重试循环
                  batchSuccess = true;
                }
              } else {
                logger.debug('⚠️ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取失败: response data为null，将重试...');
                logger.debug('⚠️ [FetchMessages] 完整响应: $response');
                retryCount++;
              }
            } else {
              // 🔴 增强错误日志：记录完整的错误信息
              final errorCode = response['code'];
              final errorMessage = response['message'] ?? '未知错误';
              logger.error('❌ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取失败: code=$errorCode, message=$errorMessage');
              logger.error('❌ [FetchMessages] 完整响应: $response');
              logger.error('❌ [FetchMessages] 请求参数: messageIds=$batch');
              retryCount++;
            }
          } catch (e) {
            logger.error('❌ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取异常: $e，将重试...');
            retryCount++;
            // 继续重试循环
          }
        }
        
        logger.debug('✅ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取完成（重试 $retryCount 次）');
      }

      logger.debug('🔍 [FetchMessages] 私聊消息拉取完成: 成功 $totalFetched 条（请求 ${messageIds.length} 条）');
      if (currentUserId != null && otherUserId != null) {
        logger.debug('🔍 [FetchMessages] 其中属于当前会话的消息: $currentConversationFetched 条');
      }
      return {
        'total': totalFetched,
        'currentConversation': currentConversationFetched,
      };
    } catch (e) {
      logger.error('❌ [FetchMessages] 拉取私聊消息异常: $e');
      return {'total': 0, 'currentConversation': 0};
    }
  }

  /// 主动拉取缺失的群组消息
  /// [token] 用户token
  /// [groupId] 群组ID
  /// [messageIds] 缺失的消息ID列表
  /// 返回成功拉取的消息数量
  Future<int> fetchMissingGroupMessages({
    required String token,
    required int groupId,
    required List<int> messageIds,
  }) async {
    if (messageIds.isEmpty) {
      logger.debug('🔍 [FetchMessages] 缺失的群组消息ID列表为空，跳过拉取');
      return 0;
    }

    logger.debug('🔍 [FetchMessages] 开始主动拉取缺失的群组消息: groupId=$groupId, ${messageIds.length}条');

    try {
      // 分批拉取，每批最多100条
      const batchSize = 100;
      const retryDelay = Duration(seconds: 2); // 重试延迟
      int totalFetched = 0;

      for (int i = 0; i < messageIds.length; i += batchSize) {
        final batch = messageIds.skip(i).take(batchSize).toList();
        logger.debug('🔍 [FetchMessages] 拉取第 ${i ~/ batchSize + 1} 批: ${batch.length}条消息');

        // 🔴 无限重试：直到成功获取到消息为止
        bool batchSuccess = false;
        int retryCount = 0;
        
        while (!batchSuccess) {
          try {
            if (retryCount > 0) {
              logger.debug('🔄 [FetchMessages] 第 ${i ~/ batchSize + 1} 批重试第 $retryCount 次...');
              await Future.delayed(retryDelay);
            }
            
            final response = await ApiService.getGroupMessagesByIds(
              token: token,
              groupId: groupId,
              messageIds: batch,
            );

            // 🔴 增强日志：记录完整的响应信息
            logger.debug('🔍 [FetchMessages] API响应详情: code=${response['code']}, message=${response['message']}, hasData=${response['data'] != null}');
            if (response['data'] != null) {
              logger.debug('🔍 [FetchMessages] response data类型: ${response['data'].runtimeType}');
              if (response['data'] is Map) {
                logger.debug('🔍 [FetchMessages] response data keys: ${(response['data'] as Map).keys}');
              }
            }
            
            if (response['code'] == 0 && response['data'] != null) {
              final messages = response['data']['messages'] as List?;
              if (messages != null) {
                batchSuccess = true; // 标记成功，退出重试循环
                
                if (messages.isNotEmpty) {
                  totalFetched += messages.length;
                  logger.debug('🔍 [FetchMessages] 成功拉取 ${messages.length} 条群组消息（请求 ${batch.length} 条）');
                  
                  // 将消息保存到本地数据库
                  for (final msg in messages) {
                    try {
                      final messageData = msg as Map<String, dynamic>;
                      // 转换服务器消息格式为本地数据库格式
                      final messageToSave = {
                        'server_id': messageData['id'],
                        'group_id': messageData['group_id'],
                        'sender_id': messageData['sender_id'],
                        'sender_name': messageData['sender_name'],
                        'sender_avatar': messageData['sender_avatar'],
                        'sender_nickname': messageData['sender_nickname'],
                        'content': messageData['content'],
                        'message_type': messageData['message_type'],
                        'file_name': messageData['file_name'],
                        'quoted_message_id': messageData['quoted_message_id'],
                        'quoted_message_content': messageData['quoted_message_content'],
                        'mentioned_user_ids': messageData['mentioned_user_ids'],
                        'mentions': messageData['mentions'],
                        'call_type': messageData['call_type'],
                        'channel_name': messageData['channel_name'],
                        'status': messageData['status'] ?? 'normal',
                        'created_at': messageData['created_at'],
                      };
                      
                      // 移除null值
                      messageToSave.removeWhere((key, value) => value == null);
                      
                      // 检查消息是否已存在（通过server_id）
                      final existingMsg = await _localDb.getGroupMessageByServerId(messageData['id'] as int);
                      if (existingMsg == null) {
                        await _localDb.insertGroupMessage(messageToSave, orIgnore: false);
                        logger.debug('🔍 [FetchMessages] 保存群组消息: serverId=${messageData['id']}');
                      } else {
                        logger.debug('🔍 [FetchMessages] 群组消息已存在，跳过: serverId=${messageData['id']}');
                      }
                    } catch (e) {
                      logger.error('❌ [FetchMessages] 保存群组消息失败: $e');
                    }
                  }
                } else {
                  logger.debug('🔍 [FetchMessages] 第 ${i ~/ batchSize + 1} 批：服务器返回空消息列表（可能消息已被删除）');
                  // 🔴 关键修复：即使返回空列表，也视为成功（消息可能已被删除），退出重试循环
                  batchSuccess = true;
                }
              } else {
                logger.debug('⚠️ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取失败: response data为null，将重试...');
                logger.debug('⚠️ [FetchMessages] 完整响应: $response');
                retryCount++;
              }
            } else {
              // 🔴 增强错误日志：记录完整的错误信息
              final errorCode = response['code'];
              final errorMessage = response['message'] ?? '未知错误';
              logger.error('❌ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取失败: code=$errorCode, message=$errorMessage');
              logger.error('❌ [FetchMessages] 完整响应: $response');
              logger.error('❌ [FetchMessages] 请求参数: groupId=$groupId, messageIds=$batch');
              retryCount++;
            }
          } catch (e) {
            logger.error('❌ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取异常: $e，将重试...');
            retryCount++;
            // 继续重试循环
          }
        }
        
        logger.debug('✅ [FetchMessages] 第 ${i ~/ batchSize + 1} 批拉取完成（重试 $retryCount 次）');
      }

      logger.debug('🔍 [FetchMessages] 群组消息拉取完成: 成功 $totalFetched 条（请求 ${messageIds.length} 条）');
      return totalFetched;
    } catch (e) {
      logger.error('❌ [FetchMessages] 拉取群组消息异常: $e');
      return 0;
    }
  }
}
