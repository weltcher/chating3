import '../models/message_model.dart';
import '../models/favorite_model.dart';
import 'local_database_service.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';
import 'api_service.dart';

/// 收藏服务
/// 管理收藏消息、常用联系人和常用群组
/// 支持本地存储和服务器同步
class FavoriteService {
  final _localDb = LocalDatabaseService();

  // ============ 收藏消息 ============

  /// 添加收藏消息（同时同步到服务器）
  /// [messageId] 本地消息ID（用于本地存储）
  /// [serverMessageId] 服务器消息ID（用于同步到服务器）
  Future<int> addFavorite({
    int? messageId,
    int? serverMessageId,
    required String content,
    required String messageType,
    String? fileName,
    required int senderId,
    required String senderName,
  }) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) throw Exception('用户未登录');

      // 检查是否已收藏
      final existing = await _localDb.checkFavoriteExists(
        userId: userId,
        messageId: messageId,
        content: content,
        senderId: senderId,
      );

      if (existing != null) {
        final existingId = existing['id'] as int;
        final existingServerId = existing['server_id'] as int?;
        final existingSyncStatus = existing['sync_status'] as String?;
        
        logger.debug('消息已存在于收藏中: localId=$existingId, serverId=$existingServerId, syncStatus=$existingSyncStatus');
        
        // 如果已存在但未同步到服务器（pending状态或没有server_id），尝试同步
        if (existingServerId == null || existingSyncStatus == SyncStatus.pending.name) {
          logger.debug('已存在的收藏未同步到服务器，尝试同步...');
          _syncFavoriteToServer(
            localId: existingId,
            serverMessageId: serverMessageId,
            content: content,
            messageType: messageType,
            fileName: fileName,
            senderId: senderId,
            senderName: senderName,
          );
        }
        
        return existingId;
      }

      // 先保存到本地（状态为pending）
      final favorite = {
        'user_id': userId,
        'content': content,
        'message_type': messageType,
        'sender_id': senderId,
        'sender_name': senderName,
        'created_at': DateTime.now().toIso8601String(),
        'sync_status': SyncStatus.pending.name,
      };

      if (messageId != null) favorite['message_id'] = messageId;
      if (fileName != null) favorite['file_name'] = fileName;

      final localId = await _localDb.insertFavorite(favorite);
      logger.debug('添加收藏到本地成功: ID=$localId');

      // 异步同步到服务器（使用服务器消息ID）
      _syncFavoriteToServer(
        localId: localId,
        serverMessageId: serverMessageId,
        content: content,
        messageType: messageType,
        fileName: fileName,
        senderId: senderId,
        senderName: senderName,
      );

      return localId;
    } catch (e) {
      logger.debug('添加收藏失败: $e');
      rethrow;
    }
  }

  /// 同步单个收藏到服务器
  Future<void> _syncFavoriteToServer({
    required int localId,
    int? serverMessageId,
    required String content,
    required String messageType,
    String? fileName,
    required int senderId,
    required String senderName,
  }) async {
    try {
      final token = await Storage.getToken();
      if (token == null) {
        logger.debug('未登录，跳过服务器同步');
        return;
      }

      logger.debug('📤 [收藏同步] 开始同步到服务器');
      logger.debug('   - localId: $localId');
      logger.debug('   - serverMessageId: $serverMessageId');
      logger.debug('   - messageType: $messageType');
      logger.debug('   - senderId: $senderId');
      logger.debug('   - content: ${content.substring(0, content.length > 50 ? 50 : content.length)}...');

      // 如果serverMessageId为null，说明这是本地消息或者消息没有server_id
      // 这种情况下使用direct API，不设置message_id
      if (serverMessageId == null) {
        logger.debug('⚠️ [收藏同步] serverMessageId为null，使用direct API创建收藏（message_id将为空）');
        logger.debug('⚠️ [收藏同步] 可能原因：');
        logger.debug('   1. 消息是本地发送的，尚未收到服务器确认');
        logger.debug('   2. 消息从数据库加载时server_id字段为null');
        logger.debug('   3. MessageModel.fromJson()未正确映射server_id字段');
      }

      // 调用服务器API创建收藏（使用服务器消息ID）
      final response = await ApiService.createFavoriteOnServer(
        token: token,
        messageId: serverMessageId,
        content: content,
        messageType: messageType,
        fileName: fileName,
        senderId: senderId,
        senderName: senderName,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final serverId = response['data']['id'] as int?;
        if (serverId != null) {
          // 更新本地记录的server_id和sync_status
          await _localDb.updateFavoriteServerInfo(
            localId: localId,
            serverId: serverId,
            syncStatus: SyncStatus.synced.name,
          );
          logger.debug('收藏同步到服务器成功: localId=$localId, serverId=$serverId');
        }
      } else {
        logger.debug('收藏同步到服务器失败: ${response['message']}');
      }
    } catch (e) {
      logger.debug('收藏同步到服务器异常: $e');
      // 同步失败不影响本地操作，保持pending状态，下次同步时重试
    }
  }

  /// 获取收藏列表
  Future<List<FavoriteModel>> getFavorites({
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) {
        logger.debug('获取收藏列表失败: 用户未登录');
        return [];
      }

      final offset = (page - 1) * pageSize;
      logger.debug('获取收藏列表: userId=$userId, page=$page, pageSize=$pageSize, offset=$offset');
      
      final results = await _localDb.getFavorites(
        userId: userId,
        limit: pageSize,
        offset: offset,
      );

      logger.debug('从数据库获取到 ${results.length} 条收藏记录');
      
      // 过滤掉已删除的记录
      final filteredResults = results.where((data) {
        final syncStatus = data['sync_status'] as String?;
        final contentStr = data['content']?.toString() ?? '';
        final contentPreview = contentStr.length > 20 ? contentStr.substring(0, 20) : contentStr;
        logger.debug('收藏记录: id=${data['id']}, sync_status=$syncStatus, content=$contentPreview...');
        return syncStatus != SyncStatus.deleted.name;
      }).toList();

      // 🔄 对于image、video、file类型，替换content中的OSS域名前缀
      final favoritesList = <FavoriteModel>[];
      for (final data in filteredResults) {
        final messageType = data['message_type'] as String?;
        final favoriteId = data['id'];
        
        // 创建可修改的副本
        final mutableData = Map<String, dynamic>.from(data);
        
        if (messageType == 'image' || messageType == 'video' || messageType == 'file') {
          final content = mutableData['content'] as String?;
          logger.debug('🔄 [Favorite] ID=$favoriteId, 类型=$messageType, 原始content: $content');
          
          if (content != null && content.isNotEmpty) {
            final replacedContent = await Storage.replaceOSSPrefixInUrl(content);
            if (replacedContent != content) {
              logger.debug('🔄 [Favorite] ID=$favoriteId, 替换后content: $replacedContent');
              mutableData['content'] = replacedContent;
            } else {
              logger.debug('🔄 [Favorite] ID=$favoriteId, content未改变');
            }
          }
        }
        favoritesList.add(FavoriteModel.fromJson(mutableData));
      }

      logger.debug('过滤后返回 ${favoritesList.length} 条收藏');
      return favoritesList;
    } catch (e) {
      logger.debug('获取收藏列表失败: $e');
      return [];
    }
  }

  /// 删除收藏（同时同步到服务器）
  Future<bool> deleteFavorite(int favoriteId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      // 获取收藏信息以获取server_id
      final favoriteInfo = await _localDb.getFavoriteById(favoriteId, userId);
      final serverId = favoriteInfo?['server_id'] as int?;

      // 如果有server_id，先同步删除到服务器
      if (serverId != null) {
        _syncDeleteFavoriteToServer(serverId);
      }

      // 删除本地记录
      await _localDb.deleteFavorite(favoriteId, userId);
      logger.debug('删除收藏成功: ID=$favoriteId');
      return true;
    } catch (e) {
      logger.debug('删除收藏失败: $e');
      return false;
    }
  }

  /// 同步删除收藏到服务器
  Future<void> _syncDeleteFavoriteToServer(int serverId) async {
    try {
      final token = await Storage.getToken();
      if (token == null) return;

      final response = await ApiService.deleteFavoriteOnServer(
        token: token,
        favoriteId: serverId,
      );

      if (response['code'] == 0) {
        logger.debug('收藏删除同步到服务器成功: serverId=$serverId');
      } else {
        logger.debug('收藏删除同步到服务器失败: ${response['message']}');
      }
    } catch (e) {
      logger.debug('收藏删除同步到服务器异常: $e');
    }
  }

  /// 检查消息是否已收藏
  Future<bool> isFavorited({
    int? messageId,
    String? content,
    int? senderId,
  }) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      final result = await _localDb.checkFavoriteExists(
        userId: userId,
        messageId: messageId,
        content: content,
        senderId: senderId,
      );

      return result != null;
    } catch (e) {
      logger.debug('检查收藏状态失败: $e');
      return false;
    }
  }

  // ============ 服务器同步 ============

  /// 从服务器同步收藏数据到本地（初次安装或登录时调用）
  Future<void> syncFromServer() async {
    try {
      final token = await Storage.getToken();
      final userId = await Storage.getUserId();
      if (token == null || userId == null) {
        logger.debug('未登录，跳过收藏同步');
        return;
      }

      logger.debug('开始从服务器同步收藏数据...');

      // 获取服务器上的所有收藏
      int page = 1;
      const pageSize = 100;
      List<Map<String, dynamic>> allServerFavorites = [];

      while (true) {
        final response = await ApiService.getFavoritesFromServer(
          token: token,
          page: page,
          pageSize: pageSize,
        );

        if (response['code'] != 0) {
          logger.debug('获取服务器收藏失败: ${response['message']}');
          break;
        }

        final data = response['data'];
        final favorites = data['favorites'] as List<dynamic>? ?? [];
        
        if (favorites.isEmpty) break;

        for (var fav in favorites) {
          allServerFavorites.add(fav as Map<String, dynamic>);
        }

        final total = data['total'] as int? ?? 0;
        if (page * pageSize >= total) break;
        page++;
      }

      logger.debug('从服务器获取到 ${allServerFavorites.length} 条收藏');

      // 获取本地所有收藏的server_id
      final localFavorites = await _localDb.getFavorites(
        userId: userId,
        limit: 10000,
        offset: 0,
      );
      final localServerIds = <int>{};
      for (var local in localFavorites) {
        final serverId = local['server_id'] as int?;
        if (serverId != null) {
          localServerIds.add(serverId);
        }
      }

      // 将服务器上有但本地没有的收藏添加到本地
      int addedCount = 0;
      for (var serverFav in allServerFavorites) {
        final serverId = serverFav['id'] as int?;
        if (serverId != null && !localServerIds.contains(serverId)) {
          await _localDb.insertFavorite({
            'server_id': serverId,
            'user_id': userId,
            'message_id': serverFav['message_id'],
            'content': serverFav['content'] ?? '',
            'message_type': serverFav['message_type'] ?? 'text',
            'file_name': serverFav['file_name'],
            'sender_id': serverFav['sender_id'] ?? 0,
            'sender_name': serverFav['sender_name'] ?? '',
            'created_at': serverFav['created_at'] ?? DateTime.now().toIso8601String(),
            'sync_status': SyncStatus.synced.name,
          });
          addedCount++;
        }
      }

      logger.debug('从服务器同步完成，新增 $addedCount 条收藏');

      // 同步本地pending状态的收藏到服务器
      await _syncPendingFavoritesToServer();
    } catch (e) {
      logger.debug('从服务器同步收藏失败: $e');
    }
  }

  /// 同步本地pending状态的收藏到服务器
  Future<void> _syncPendingFavoritesToServer() async {
    try {
      final token = await Storage.getToken();
      final userId = await Storage.getUserId();
      if (token == null || userId == null) return;

      final pendingFavorites = await _localDb.getPendingFavorites(userId);
      logger.debug('发现 ${pendingFavorites.length} 条待同步的收藏');

      for (var fav in pendingFavorites) {
        final localId = fav['id'] as int;
        // 注意：pending收藏没有serverMessageId，使用direct API创建
        await _syncFavoriteToServer(
          localId: localId,
          serverMessageId: null,
          content: fav['content'] as String? ?? '',
          messageType: fav['message_type'] as String? ?? 'text',
          fileName: fav['file_name'] as String?,
          senderId: fav['sender_id'] as int? ?? 0,
          senderName: fav['sender_name'] as String? ?? '',
        );
      }
    } catch (e) {
      logger.debug('同步pending收藏失败: $e');
    }
  }

  // ============ 常用联系人 ============

  /// 添加常用联系人
  Future<bool> addFavoriteContact(int contactId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      await _localDb.addFavoriteContact(userId, contactId);
      logger.debug('添加常用联系人成功: ContactID=$contactId');
      return true;
    } catch (e) {
      logger.debug('添加常用联系人失败: $e');
      return false;
    }
  }

  /// 移除常用联系人
  Future<bool> removeFavoriteContact(int contactId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      await _localDb.removeFavoriteContact(userId, contactId);
      logger.debug('移除常用联系人成功: ContactID=$contactId');
      return true;
    } catch (e) {
      logger.debug('移除常用联系人失败: $e');
      return false;
    }
  }

  /// 获取常用联系人ID列表
  Future<List<int>> getFavoriteContactIds() async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return [];

      final results = await _localDb.getFavoriteContacts(userId);
      return results.map((data) => (data['contact_id'] as int?) ?? 0).where((id) => id != 0).toList();
    } catch (e) {
      logger.debug('获取常用联系人列表失败: $e');
      return [];
    }
  }

  /// 获取常用联系人详细信息列表
  Future<List<Map<String, dynamic>>> getFavoriteContactsWithDetails() async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return [];

      // 获取常用联系人ID列表
      final favoriteResults = await _localDb.getFavoriteContacts(userId);
      final contactIds = favoriteResults
          .map((data) => (data['contact_id'] as int?) ?? 0)
          .where((id) => id != 0)
          .toList();

      if (contactIds.isEmpty) return [];

      // 批量查询联系人详细信息
      final List<Map<String, dynamic>> contactDetails = [];
      for (final contactId in contactIds) {
        final contactInfo = await _localDb.getContactSnapshot(
          ownerId: userId,
          contactId: contactId,
          contactType: 'user',
        );
        if (contactInfo != null) {
          contactDetails.add({
            'contact_id': contactId,
            'user_id': contactId, // contact_id 就是用户ID
            'username': contactInfo['username'],
            'full_name': contactInfo['full_name'],
            'avatar': contactInfo['avatar'],
            'status': 'offline', // 默认为离线，稍后会通过状态同步更新
          });
        }
      }

      logger.debug('获取常用联系人详细信息成功: ${contactDetails.length}个');
      return contactDetails;
    } catch (e) {
      logger.debug('获取常用联系人详细信息失败: $e');
      return [];
    }
  }

  /// 检查是否为常用联系人
  Future<bool> isFavoriteContact(int contactId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      return await _localDb.isFavoriteContact(userId, contactId);
    } catch (e) {
      logger.debug('检查常用联系人失败: $e');
      return false;
    }
  }

  // ============ 常用群组 ============

  /// 添加常用群组
  Future<bool> addFavoriteGroup(int groupId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      await _localDb.addFavoriteGroup(userId, groupId);
      logger.debug('添加常用群组成功: GroupID=$groupId');
      return true;
    } catch (e) {
      logger.debug('添加常用群组失败: $e');
      return false;
    }
  }

  /// 移除常用群组
  Future<bool> removeFavoriteGroup(int groupId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      await _localDb.removeFavoriteGroup(userId, groupId);
      logger.debug('移除常用群组成功: GroupID=$groupId');
      return true;
    } catch (e) {
      logger.debug('移除常用群组失败: $e');
      return false;
    }
  }

  /// 获取常用群组ID列表
  Future<List<int>> getFavoriteGroupIds() async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return [];

      final results = await _localDb.getFavoriteGroups(userId);
      return results.map((data) => (data['group_id'] as int?) ?? 0).where((id) => id != 0).toList();
    } catch (e) {
      logger.debug('获取常用群组列表失败: $e');
      return [];
    }
  }

  /// 检查是否为常用群组
  Future<bool> isFavoriteGroup(int groupId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return false;

      return await _localDb.isFavoriteGroup(userId, groupId);
    } catch (e) {
      logger.debug('检查常用群组失败: $e');
      return false;
    }
  }
}
