import '../utils/logger.dart';
import '../utils/storage.dart';
import 'database_repair_service.dart';
import 'favorite_service.dart';
import 'api_service.dart';
import 'local_database_service.dart';

/// 同步状态回调类型
typedef SyncStatusCallback = void Function(bool isSyncing, String? message);

/// 应用初始化服务
/// 负责应用启动时的各种初始化和修复工作
class AppInitializationService {
  static final AppInitializationService _instance = AppInitializationService._internal();
  factory AppInitializationService() => _instance;
  AppInitializationService._internal();

  final _repairService = DatabaseRepairService();
  final _favoriteService = FavoriteService();
  final _localDb = LocalDatabaseService();

  /// 执行应用初始化
  /// [onSyncStatusChanged] 同步状态变化回调，用于UI显示加载状态
  Future<void> initialize({SyncStatusCallback? onSyncStatusChanged}) async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('🚀 [应用初始化] 开始应用初始化...');
      logger.debug('═══════════════════════════════════════════════════════════');
      
      // 检查用户是否已登录
      final isLoggedIn = await Storage.isLoggedIn();
      logger.debug('🔍 [应用初始化] 用户登录状态: ${isLoggedIn ? "已登录" : "未登录"}');
      if (!isLoggedIn) {
        logger.debug('⚠️ [应用初始化] 用户未登录，跳过数据库修复和同步');
        return;
      }

      // 检查是否需要进行数据库修复
      logger.debug('🔧 [应用初始化] 检查数据库修复需求...');
      await _checkAndRepairDatabase();
      
      // 检查是否是首次安装（本地数据库为空）
      logger.debug('🔍 [应用初始化] 检查是否首次安装...');
      final isFirstInstall = await _checkIsFirstInstall();
      logger.debug('🔍 [应用初始化] 首次安装检查结果: ${isFirstInstall ? "是" : "否"}');
      
      if (isFirstInstall) {
        logger.debug('═══════════════════════════════════════════════════════════');
        logger.debug('📱 [应用初始化] 检测到首次安装/数据库迁移，开始从服务器同步数据...');
        logger.debug('═══════════════════════════════════════════════════════════');
        
        // 通知UI开始同步
        onSyncStatusChanged?.call(true, '同步数据中...');
        
        // 同步历史聊天消息，返回同步的消息数量
        logger.debug('📥 [应用初始化] 开始同步历史聊天消息...');
        final syncedCount = await _syncHistoryMessages();
        logger.debug('📥 [应用初始化] 历史消息同步完成，共 $syncedCount 条');
        
        // 同步收藏数据
        logger.debug('📥 [应用初始化] 开始同步收藏数据...');
        await _syncFavorites();
        
        // 通知UI同步完成
        onSyncStatusChanged?.call(false, null);
        
        // 只有在成功同步了消息后才标记为完成
        if (syncedCount > 0) {
          await Storage.saveFirstSyncCompleted(true);
          logger.debug('✅ [应用初始化] 首次安装数据同步完成，共同步 $syncedCount 条消息');
        } else {
          logger.debug('⚠️ [应用初始化] 首次同步未获取到消息，不标记为完成，下次启动会重试');
        }
      } else {
        // 非首次安装，只同步收藏数据（增量同步）
        logger.debug('📥 [应用初始化] 非首次安装，只同步收藏数据...');
        await _syncFavorites();
      }
      
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('✅ [应用初始化] 应用初始化完成');
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e) {
      // 发生错误时也要通知UI停止显示加载状态
      onSyncStatusChanged?.call(false, null);
      logger.debug('❌ [应用初始化] 应用初始化失败: $e');
    }
  }
  
  /// 检查是否是首次安装（本地数据库为空）
  Future<bool> _checkIsFirstInstall() async {
    try {
      logger.debug('───────────────────────────────────────────────────────────');
      logger.debug('📱 [首次安装检查] 开始检查...');
      
      // 检查本地消息表是否为空
      final userId = await Storage.getUserId();
      logger.debug('📱 [首次安装检查] 当前用户ID: $userId');
      if (userId == null) {
        logger.debug('📱 [首次安装检查] 用户ID为空，返回false');
        return false;
      }
      
      logger.debug('📱 [首次安装检查] 查询本地数据库是否有消息...');
      final hasMessages = await _localDb.hasAnyMessages(userId);
      logger.debug('📱 [首次安装检查] 本地消息数据: ${hasMessages ? "✅ 有数据" : "❌ 为空"}');
      
      // 检查是否已完成首次同步
      final firstSyncCompleted = await Storage.getFirstSyncCompleted();
      logger.debug('📱 [首次安装检查] 首次同步标记(first_sync_completed): ${firstSyncCompleted ? "✅ 已完成" : "❌ 未完成"}');
      
      // 如果标记为已完成但本地数据库为空，说明之前同步失败了，需要重新同步
      if (firstSyncCompleted && !hasMessages) {
        logger.debug('⚠️ [首次安装检查] 异常状态：同步标记为完成但本地数据库为空');
        logger.debug('⚠️ [首次安装检查] 清除标记并重新同步...');
        await Storage.clearFirstSyncCompleted();
        logger.debug('📱 [首次安装检查] 结果: 需要重新同步');
        logger.debug('───────────────────────────────────────────────────────────');
        return true;
      }
      
      if (firstSyncCompleted) {
        logger.debug('📱 [首次安装检查] 已完成首次同步，跳过历史数据同步');
        logger.debug('───────────────────────────────────────────────────────────');
        return false;
      }
      
      final isFirstInstall = !hasMessages;
      logger.debug('📱 [首次安装检查] 最终结果: ${isFirstInstall ? "✅ 是首次安装/需要同步" : "❌ 不是首次安装"}');
      logger.debug('───────────────────────────────────────────────────────────');
      return isFirstInstall;
    } catch (e) {
      logger.debug('❌ [首次安装检查] 检查失败: $e');
      logger.debug('───────────────────────────────────────────────────────────');
      return false;
    }
  }
  
  /// 从服务器同步历史聊天消息
  /// 返回同步的消息总数
  Future<int> _syncHistoryMessages() async {
    try {
      final token = await Storage.getToken();
      final userId = await Storage.getUserId();
      logger.debug('───────────────────────────────────────────────────────────');
      logger.debug('📥 [历史消息同步] 开始同步...');
      logger.debug('📥 [历史消息同步] Token: ${token != null ? "✅ 已获取 (${token.length}字符)" : "❌ 为空"}');
      logger.debug('📥 [历史消息同步] 用户ID: $userId');
      
      if (token == null || userId == null) {
        logger.debug('⚠️ [历史消息同步] 未登录，跳过历史消息同步');
        return 0;
      }
      
      // 1. 同步私聊历史消息
      logger.debug('📥 [历史消息同步] 步骤1: 同步私聊消息...');
      final privateCount = await _syncPrivateMessages(token, userId);
      logger.debug('📥 [历史消息同步] 私聊消息同步完成: $privateCount 条');
      
      // 2. 同步群聊历史消息
      logger.debug('📥 [历史消息同步] 步骤2: 同步群聊消息...');
      final groupCount = await _syncGroupMessages(token, userId);
      logger.debug('📥 [历史消息同步] 群聊消息同步完成: $groupCount 条');
      
      final totalCount = privateCount + groupCount;
      logger.debug('───────────────────────────────────────────────────────────');
      logger.debug('✅ [历史消息同步] 同步完成! 私聊: $privateCount 条, 群聊: $groupCount 条, 总计: $totalCount 条');
      logger.debug('───────────────────────────────────────────────────────────');
      return totalCount;
    } catch (e) {
      logger.debug('❌ [历史消息同步] 同步失败: $e');
      return 0;
    }
  }
  
  /// 同步私聊历史消息
  /// 返回同步的消息数量
  Future<int> _syncPrivateMessages(String token, int userId) async {
    try {
      logger.debug('  ┌─────────────────────────────────────────────────────────');
      logger.debug('  │ 📥 [私聊同步] 开始同步私聊历史消息...');
      
      // 先获取联系人列表
      logger.debug('  │ 📥 [私聊同步] 获取联系人列表...');
      final contactsResponse = await ApiService.getContacts(token: token);
      logger.debug('  │ 📥 [私聊同步] API响应: code=${contactsResponse['code']}');
      
      if (contactsResponse['code'] != 0) {
        logger.debug('  │ ⚠️ [私聊同步] 获取联系人列表失败: ${contactsResponse['message']}');
        logger.debug('  └─────────────────────────────────────────────────────────');
        return 0;
      }
      
      final contacts = contactsResponse['data']?['contacts'] as List<dynamic>? ?? [];
      logger.debug('  │ 📥 [私聊同步] 联系人数量: ${contacts.length}');
      
      int totalSavedCount = 0;
      int contactIndex = 0;
      for (var contact in contacts) {
        contactIndex++;
        final contactId = contact['friend_id'] as int? ?? contact['id'] as int?;
        final contactName = contact['full_name'] ?? contact['username'] ?? '未知';
        if (contactId == null) continue;
        
        // 获取与该联系人的消息历史
        logger.debug('  │ 📥 [私聊同步] [$contactIndex/${contacts.length}] 同步联系人: $contactName (ID: $contactId)');
        final response = await ApiService.getMessageHistoryFromServer(
          token: token,
          contactId: contactId,
          page: 1,
          pageSize: 100, // 每个联系人获取最近100条消息
        );
        
        if (response['code'] != 0) {
          logger.debug('  │ ⚠️ [私聊同步] 获取消息失败: ${response['message']}');
          continue;
        }
        
        final messages = response['data']?['messages'] as List<dynamic>? ?? [];
        logger.debug('  │ 📥 [私聊同步] 服务器返回 ${messages.length} 条消息');
        
        int savedCount = 0;
        for (var msg in messages) {
          try {
            final messageMap = _convertServerMessageToLocal(msg as Map<String, dynamic>, isGroup: false);
            final id = await _localDb.insertMessage(messageMap, orIgnore: true);
            if (id > 0) {
              savedCount++;
            }
          } catch (e) {
            logger.debug('  │ ⚠️ [私聊同步] 保存消息失败: $e');
          }
        }
        
        totalSavedCount += savedCount;
        if (savedCount > 0) {
          logger.debug('  │ ✅ [私聊同步] 联系人 $contactName 保存了 $savedCount 条消息');
        }
      }
      
      logger.debug('  │ ✅ [私聊同步] 完成! 共保存 $totalSavedCount 条私聊消息');
      logger.debug('  └─────────────────────────────────────────────────────────');
      return totalSavedCount;
    } catch (e) {
      logger.debug('  │ ❌ [私聊同步] 同步失败: $e');
      logger.debug('  └─────────────────────────────────────────────────────────');
      return 0;
    }
  }
  
  /// 同步群聊历史消息
  /// 返回同步的消息数量
  Future<int> _syncGroupMessages(String token, int userId) async {
    try {
      logger.debug('  ┌─────────────────────────────────────────────────────────');
      logger.debug('  │ 📥 [群聊同步] 开始同步群聊历史消息...');
      
      // 先获取用户所属的群组列表
      logger.debug('  │ 📥 [群聊同步] 获取用户所属群组列表...');
      final groupsResponse = await ApiService.getUserGroups(token: token);
      logger.debug('  │ 📥 [群聊同步] API响应: code=${groupsResponse['code']}');
      
      if (groupsResponse['code'] != 0) {
        logger.debug('  │ ⚠️ [群聊同步] 获取群组列表失败: ${groupsResponse['message']}');
        logger.debug('  └─────────────────────────────────────────────────────────');
        return 0;
      }
      
      final groups = groupsResponse['data']?['groups'] as List<dynamic>? ?? [];
      logger.debug('  │ 📥 [群聊同步] 群组数量: ${groups.length}');
      
      int totalSavedCount = 0;
      int groupIndex = 0;
      for (var group in groups) {
        groupIndex++;
        final groupId = group['id'] as int?;
        final groupName = group['name'] ?? '未知群组';
        if (groupId == null) continue;
        
        // 获取该群组的历史消息
        logger.debug('  │ 📥 [群聊同步] [$groupIndex/${groups.length}] 同步群组: $groupName (ID: $groupId)');
        final response = await ApiService.getGroupMessagesFromServer(
          token: token,
          groupId: groupId,
          page: 1,
          pageSize: 200, // 每个群组获取最近200条消息
        );
        
        if (response['code'] != 0) {
          logger.debug('  │ ⚠️ [群聊同步] 获取消息失败: ${response['message']}');
          continue;
        }
        
        final messages = response['data']?['messages'] as List<dynamic>? ?? [];
        logger.debug('  │ 📥 [群聊同步] 服务器返回 ${messages.length} 条消息');
        
        int savedCount = 0;
        for (var msg in messages) {
          try {
            final messageMap = _convertServerMessageToLocal(msg as Map<String, dynamic>, isGroup: true);
            final id = await _localDb.insertGroupMessage(messageMap, orIgnore: true);
            if (id > 0) savedCount++;
          } catch (e) {
            logger.debug('  │ ⚠️ [群聊同步] 保存消息失败: $e');
          }
        }
        
        totalSavedCount += savedCount;
        if (savedCount > 0) {
          logger.debug('  │ ✅ [群聊同步] 群组 $groupName 保存了 $savedCount 条消息');
        }
      }
      
      logger.debug('  │ ✅ [群聊同步] 完成! 共保存 $totalSavedCount 条群聊消息');
      logger.debug('  └─────────────────────────────────────────────────────────');
      return totalSavedCount;
    } catch (e) {
      logger.debug('  │ ❌ [群聊同步] 同步失败: $e');
      logger.debug('  └─────────────────────────────────────────────────────────');
      return 0;
    }
  }
  
  /// 将服务器消息格式转换为本地数据库格式
  /// 私聊消息表(messages)和群聊消息表(group_messages)的字段不同，需要分别处理
  Map<String, dynamic> _convertServerMessageToLocal(Map<String, dynamic> serverMsg, {required bool isGroup}) {
    if (isGroup) {
      // 群聊消息表字段：server_id, group_id, sender_id, sender_name, sender_nickname, 
      // sender_full_name, group_name, group_avatar, content, message_type, file_name,
      // file_size, is_read, is_recalled, quoted_message_id, quoted_message_content, 
      // status, created_at, sender_avatar, mentioned_user_ids, mentions, deleted_by_users, 
      // call_type, channel_name, voice_duration
      return {
        'server_id': serverMsg['id'],
        'group_id': serverMsg['group_id'],
        'sender_id': serverMsg['sender_id'],
        'sender_name': serverMsg['sender_name'] ?? '未知用户',
        'sender_nickname': serverMsg['sender_nickname'],
        'sender_full_name': serverMsg['sender_full_name'],
        'group_name': serverMsg['group_name'],
        'group_avatar': serverMsg['group_avatar'],
        'content': serverMsg['content'] ?? '',
        'message_type': serverMsg['message_type'] ?? 'text',
        'file_name': serverMsg['file_name'],
        'file_size': serverMsg['file_size'],
        'is_read': (serverMsg['is_read'] == true || serverMsg['is_read'] == 1) ? 1 : 0,
        'is_recalled': (serverMsg['is_recalled'] == true || serverMsg['is_recalled'] == 1) ? 1 : 0,
        'quoted_message_id': serverMsg['quoted_message_id'],
        'quoted_message_content': serverMsg['quoted_content'] ?? serverMsg['quoted_message_content'],
        'status': 'sent',
        'created_at': serverMsg['created_at'] ?? DateTime.now().toIso8601String(),
        'sender_avatar': serverMsg['sender_avatar'],
        'mentioned_user_ids': serverMsg['mentioned_user_ids'],
        'mentions': serverMsg['mentions'],
        'call_type': serverMsg['call_type'],
        'channel_name': serverMsg['channel_name'],
        'voice_duration': serverMsg['voice_duration'],
      };
    } else {
      // 私聊消息表字段：server_id, sender_id, receiver_id, content, message_type,
      // is_read, created_at, read_at, sender_name, receiver_name, file_name,
      // quoted_message_id, quoted_message_content, status, deleted_by_users,
      // sender_avatar, receiver_avatar, call_type, voice_duration
      return {
        'server_id': serverMsg['id'],
        'sender_id': serverMsg['sender_id'],
        'receiver_id': serverMsg['receiver_id'],
        'content': serverMsg['content'] ?? '',
        'message_type': serverMsg['message_type'] ?? 'text',
        'is_read': (serverMsg['is_read'] == true || serverMsg['is_read'] == 1) ? 1 : 0,
        'created_at': serverMsg['created_at'] ?? DateTime.now().toIso8601String(),
        'sender_name': serverMsg['sender_name'],
        'receiver_name': serverMsg['receiver_name'],
        'file_name': serverMsg['file_name'],
        'quoted_message_id': serverMsg['quoted_message_id'],
        'quoted_message_content': serverMsg['quoted_content'] ?? serverMsg['quoted_message_content'],
        'status': 'sent',
        'sender_avatar': serverMsg['sender_avatar'],
        'receiver_avatar': serverMsg['receiver_avatar'],
        'call_type': serverMsg['call_type'],
        'voice_duration': serverMsg['voice_duration'],
      };
    }
  }

  /// 同步收藏数据
  Future<void> _syncFavorites() async {
    try {
      logger.debug('📥 开始同步收藏数据...');
      await _favoriteService.syncFromServer();
      logger.debug('✅ 收藏数据同步完成');
    } catch (e) {
      logger.debug('❌ 收藏数据同步失败: $e');
      // 同步失败不影响应用启动
    }
  }

  /// 检查并修复数据库
  Future<void> _checkAndRepairDatabase() async {
    try {
      // 检查是否已经执行过修复
      final lastRepairTime = await Storage.getLastDatabaseRepairTime();
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      
      // 如果距离上次修复超过7天，或者从未修复过，则执行修复
      if (lastRepairTime == null || (currentTime - lastRepairTime) > 7 * 24 * 60 * 60 * 1000) {
        logger.debug('🔧 检查数据库修复需求...');
        
        final needRepairCount = await _repairService.checkRepairNeeded();
        if (needRepairCount > 0) {
          logger.debug('🔧 发现 $needRepairCount 条记录需要修复用户昵称，开始修复...');
          await _repairService.repairMissingUserNames();
          
          // 记录修复时间
          await Storage.saveLastDatabaseRepairTime(currentTime);
          logger.debug('✅ 数据库修复完成，已记录修复时间');
        } else {
          logger.debug('✅ 数据库无需修复');
          // 即使无需修复，也更新修复时间，避免频繁检查
          await Storage.saveLastDatabaseRepairTime(currentTime);
        }
      } else {
        logger.debug('⏭️ 距离上次数据库修复时间较短，跳过检查');
      }
    } catch (e) {
      logger.debug('❌ 数据库修复检查失败: $e');
    }
  }

  /// 手动触发数据库修复（用于调试或用户手动触发）
  Future<bool> manualRepairDatabase() async {
    try {
      logger.debug('🔧 手动触发数据库修复...');
      
      final needRepairCount = await _repairService.checkRepairNeeded();
      if (needRepairCount > 0) {
        logger.debug('🔧 发现 $needRepairCount 条记录需要修复，开始修复...');
        await _repairService.repairMissingUserNames();
        
        // 记录修复时间
        final currentTime = DateTime.now().millisecondsSinceEpoch;
        await Storage.saveLastDatabaseRepairTime(currentTime);
        
        logger.debug('✅ 手动数据库修复完成');
        return true;
      } else {
        logger.debug('✅ 数据库无需修复');
        return false;
      }
    } catch (e) {
      logger.debug('❌ 手动数据库修复失败: $e');
      return false;
    }
  }
}
