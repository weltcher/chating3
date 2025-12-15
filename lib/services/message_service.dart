import 'dart:convert';

import '../models/message_model.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'local_database_service.dart';
import 'api_service.dart';

/// 消息服务 - 统一管理私聊和群聊消息
/// 所有消息都存储在本地SQLite数据库中
class MessageService {
  static final MessageService _instance = MessageService._internal();
  factory MessageService() => _instance;
  MessageService._internal();

  final _localDb = LocalDatabaseService();

  // ============ 私聊消息 ============

  /// 获取私聊消息历史
  Future<List<MessageModel>> getMessages({
    required int contactId,
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      // 获取当前用户ID
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) {
        logger.debug('未找到当前用户信息');
        return [];
      }

      // 从本地数据库获取消息
      final messages = await _localDb.getMessages(
        userId1: currentUserId,
        userId2: contactId,
        limit: pageSize,
      );

      // 转换为MessageModel
      final messageList = messages
          .map((json) => MessageModel.fromJson(json))
          .toList();

      return messageList;
    } catch (e) {
      logger.debug('获取私聊消息失败: $e');
      return [];
    }
  }

  /// 获取私聊消息历史（兼容旧API）
  Future<Map<String, dynamic>> getMessageHistory({
    required int userId,
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      final messages = await getMessages(
        contactId: userId,
        page: page,
        pageSize: pageSize,
      );

      return {
        'code': 0,
        'message': '成功',
        'data': {
          'messages': messages.map((m) => m.toJson()).toList(),
          'page': page,
          'page_size': pageSize,
          'total': messages.length,
        },
      };
    } catch (e) {
      logger.debug('获取消息历史失败: $e');
      return {'code': -1, 'message': '获取失败: $e', 'data': null};
    }
  }

  /// 保存私聊消息到本地数据库
  Future<int> saveMessage(Map<String, dynamic> messageData) async {
    try {
      return await _localDb.insertMessage(messageData);
    } catch (e) {
      logger.debug('保存私聊消息失败: $e');
      rethrow;
    }
  }

  /// 更新消息已读状态
  Future<void> markMessageAsRead(int messageId) async {
    try {
      await _localDb.updateMessageReadStatus(messageId);
    } catch (e) {
      logger.debug('更新消息已读状态失败: $e');
      rethrow;
    }
  }

  /// 批量标记消息为已读
  Future<void> markMessagesAsRead(int senderId) async {
    try {
      final receiverId = await Storage.getUserId();
      if (receiverId == null) return;

      await _localDb.markMessagesAsRead(senderId, receiverId);
    } catch (e) {
      logger.debug('批量标记消息为已读失败: $e');
      rethrow;
    }
  }

  /// 撤回消息
  Future<void> recallMessage(int messageId) async {
    try {
      await _localDb.recallMessage(messageId);
    } catch (e) {
      logger.debug('撤回消息失败: $e');
      rethrow;
    }
  }

  /// 删除消息
  Future<void> deleteMessage(int messageId, int userId) async {
    try {
      await _localDb.deleteMessage(messageId, userId);
    } catch (e) {
      logger.debug('删除消息失败: $e');
      rethrow;
    }
  }

  /// 获取未读消息数量
  Future<int> getUnreadMessageCount(int receiverId) async {
    try {
      return await _localDb.getUnreadMessageCount(receiverId);
    } catch (e) {
      logger.debug('获取未读消息数量失败: $e');
      return 0;
    }
  }

  /// 格式化消息预览：将特殊类型的消息转换为显示文本
  String _formatMessagePreview(
    String messageType,
    String content,
    String? fileName, {
    int? voiceDuration,
  }) {
    switch (messageType) {
      case 'image':
        return '[图片]';
      case 'file':
        return '[文件]';
      case 'audio':
      case 'voice':
        if (voiceDuration != null && voiceDuration > 0) {
          return '[语音] ${voiceDuration}秒';
        }
        return '[语音]';
      case 'video':
        return '[视频]';
      case 'call_ended':
      case 'call_ended_video':
        return '[通话结束]';
      default:
        // 检测是否为纯表情消息（格式：[emotion:xxx.png]）
        if (content.contains('[emotion:')) {
          final withoutEmotions = content
              .replaceAll(RegExp(r'\[emotion:[^\]]+\.png\]'), '')
              .trim();
          if (withoutEmotions.isEmpty) {
            return '[表情]';
          }
        }
        return content;
    }
  }

  /// 判断字符串是否是纯数字ID
  bool _isNumericId(String value) {
    if (value.isEmpty) return false;
    return int.tryParse(value) != null;
  }

  /// 判断是否为自动生成的群聊名称（例如“群聊123”）
  bool _isGeneratedGroupName(String name, int groupId) {
    final trimmed = name.trim();
    return trimmed == '群聊$groupId' || trimmed == '群聊 $groupId';
  }

  static const Duration _contactSnapshotTtl = Duration(hours: 12);

  bool _isSnapshotExpired(Map<String, dynamic> snapshot) {
    final updatedAt = snapshot['updated_at']?.toString();
    if (updatedAt == null || updatedAt.isEmpty) {
      return true;
    }
    final parsed = DateTime.tryParse(updatedAt);
    if (parsed == null) {
      return true;
    }
    return DateTime.now().difference(parsed) > _contactSnapshotTtl;
  }

  Future<Map<String, dynamic>?> _getOrFetchContactSnapshot({
    required int ownerId,
    required int contactId,
    required String contactType,
    required String? token,
    bool forceRefresh = false,
    String? fallbackName,
    String? fallbackAvatar,
  }) async {
    final normalizedType = contactType == 'group' ? 'group' : 'user';
    Map<String, dynamic>? snapshot;

    try {
      snapshot = await _localDb.getContactSnapshot(
        ownerId: ownerId,
        contactId: contactId,
        contactType: normalizedType,
      );
    } catch (e) {
      logger.debug('❌ 读取联系人快照失败: $e');
    }

    final bool hasToken = token != null && token.isNotEmpty;
    final bool missingName = snapshot == null ||
        ((snapshot['full_name']?.toString().trim().isEmpty ?? true) &&
            (snapshot['username']?.toString().trim().isEmpty ?? true));
    final bool shouldRefresh =
        hasToken && (forceRefresh || missingName || (snapshot != null && _isSnapshotExpired(snapshot)));

    if (shouldRefresh) {
      final remote = await _fetchContactSnapshotFromApi(
        ownerId: ownerId,
        contactId: contactId,
        contactType: normalizedType,
        token: token!,
      );
      if (remote != null) {
        await _localDb.upsertContactSnapshot(
          ownerId: ownerId,
          contactId: contactId,
          contactType: normalizedType,
          username: remote['username'] as String?,
          fullName: remote['full_name'] as String?,
          avatar: remote['avatar'] as String?,
          remark: remote['remark'] as String?,
          metadata: remote['metadata'] as String?,
        );
        snapshot = remote;
      }
    }

    if (snapshot == null &&
        fallbackName != null &&
        fallbackName.trim().isNotEmpty) {
      snapshot = {
        'contact_type': normalizedType,
        'contact_id': contactId,
        'owner_id': ownerId,
        'full_name': fallbackName.trim(),
        'username': fallbackName.trim(),
        'avatar': fallbackAvatar,
        'updated_at': DateTime.now().toIso8601String(),
      };
    } else if (snapshot != null &&
        (snapshot['avatar'] == null ||
            (snapshot['avatar'] as String?)?.isEmpty == true) &&
        fallbackAvatar != null) {
      snapshot = Map<String, dynamic>.from(snapshot);
      snapshot['avatar'] = fallbackAvatar;
    }

    return snapshot;
  }

  Future<Map<String, dynamic>?> _fetchContactSnapshotFromApi({
    required int ownerId,
    required int contactId,
    required String contactType,
    required String token,
  }) async {
    try {
      if (contactType == 'group') {
        final response = await ApiService.getGroupDetail(
          token: token,
          groupId: contactId,
        );
        if (_isApiSuccess(response) && response['data'] != null) {
          final groupData =
              _extractPayloadMap(response['data'], nestedKey: 'group');
          if (groupData != null) {
            final name =
                groupData['name']?.toString().trim().isNotEmpty == true
                    ? groupData['name'].toString().trim()
                    : '群聊$contactId';
            final avatar = (groupData['avatar'] ??
                    groupData['avatar_url'] ??
                    groupData['icon'])
                ?.toString();
            final remark = groupData['remark']?.toString();
            return {
              'owner_id': ownerId,
              'contact_id': contactId,
              'contact_type': 'group',
              'username': name,
              'full_name': name,
              'avatar': avatar,
              'remark': remark,
              'metadata': _safeEncode(groupData),
              'updated_at': DateTime.now().toIso8601String(),
            };
          }
        }
      } else {
        final response = await ApiService.getUserInfo(contactId, token: token);
        if (_isApiSuccess(response) && response['data'] != null) {
          final userData =
              _extractPayloadMap(response['data'], nestedKey: 'user');
          if (userData != null) {
            final username = userData['username']?.toString().trim().isNotEmpty ==
                    true
                ? userData['username'].toString().trim()
                : contactId.toString();
            final fullName =
                userData['full_name']?.toString().trim().isNotEmpty == true
                    ? userData['full_name'].toString().trim()
                    : username;
            final avatar = (userData['avatar'] ??
                    userData['avatar_url'] ??
                    userData['profile_photo'])
                ?.toString();
            final remark = userData['remark']?.toString();
            return {
              'owner_id': ownerId,
              'contact_id': contactId,
              'contact_type': 'user',
              'username': username,
              'full_name': fullName,
              'avatar': avatar,
              'remark': remark,
              'metadata': _safeEncode(userData),
              'updated_at': DateTime.now().toIso8601String(),
            };
          }
        }
      }
    } catch (e) {
      logger.debug(
        '❌ 从接口获取联系人快照失败: $e (type=$contactType, id=$contactId)',
      );
    }
    return null;
  }

  Map<String, dynamic>? _extractPayloadMap(
    dynamic payload, {
    String? nestedKey,
  }) {
    if (payload is Map<String, dynamic>) {
      if (nestedKey != null && payload[nestedKey] is Map<String, dynamic>) {
        return Map<String, dynamic>.from(
          payload[nestedKey] as Map<String, dynamic>,
        );
      }
      return Map<String, dynamic>.from(payload);
    }
    return null;
  }

  bool _isApiSuccess(Map<String, dynamic> response) {
    final code = response['code'];
    if (code is int) {
      return code == 0 || code == 200;
    }
    return false;
  }

  String? _safeEncode(Map<String, dynamic> data) {
    try {
      return jsonEncode(data);
    } catch (e) {
      logger.debug('❌ 编码联系人快照元数据失败: $e');
      return null;
    }
  }

  /// 获取最近联系人列表
  Future<Map<String, dynamic>> getRecentContacts() async {
    try {
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) {
        return {'code': -1, 'message': '未登录', 'data': null};
      }

      final rawContacts = await _localDb.getRecentContacts(currentUserId);
      logger.debug('📊 获取到原始联系人数据: ${rawContacts.length}条');
      if (rawContacts.isNotEmpty) {
        logger.debug('📊 第一条数据示例: ${rawContacts.first}');
      }

      final authToken = await Storage.getToken();
      final pendingContactIds =
          await Storage.getPendingContactsForCurrentUser();
      if (pendingContactIds.isNotEmpty) {
        logger.debug('🚧 待审核联系人: $pendingContactIds');
      }

      // 🔴 修复：从服务器获取用户所属的群组列表，并同步群组成员到本地数据库
      logger.debug('🔍 开始从服务器获取用户所属的群组列表...');
      Set<int> userGroupIds = {};
      if (authToken != null && authToken.isNotEmpty) {
        try {
          final groupsResponse = await ApiService.getUserGroups(token: authToken);
          logger.debug('📡 服务器响应: code=${groupsResponse['code']}, message=${groupsResponse['message']}');
          
          if (groupsResponse['code'] == 0) {
            final groups = groupsResponse['data']?['groups'] as List?;
            if (groups != null && groups.isNotEmpty) {
              userGroupIds = groups
                  .map((g) => g['id'] as int?)
                  .whereType<int>()
                  .toSet();

              // 🆕 同步群组成员到本地数据库（用于SQL过滤）
              for (final group in groups) {
                final groupId = group['id'] as int?;
                if (groupId != null) {
                  // 简化版：只记录当前用户属于这个群组
                  await _localDb.addGroupMember(groupId, currentUserId);
                }
              }
              logger.debug('✅ 群组成员同步完成');
            } else {
              logger.debug('📭 用户当前没有加入任何群组');
            }
          } else {
            logger.debug('⚠️ 获取群组列表失败: ${groupsResponse['message']}');
          }
        } catch (e) {
          logger.debug('❌ 获取用户群组列表异常: $e');
        }
      } else {
        logger.debug('⚠️ Token为空，无法获取用户群组列表');
      }

      // 转换数据格式：将数据库的消息记录转换为RecentContactModel期望的格式
      final contactsFutures =
          rawContacts.map<Future<Map<String, dynamic>?>>((msg) async {
        try {
          // 安全获取字段
          final contactType = msg['contact_type']?.toString() ?? 'user';
          final senderId = msg['sender_id'] is int
              ? msg['sender_id'] as int
              : int.tryParse(msg['sender_id']?.toString() ?? '') ?? 0;
          final receiverId = msg['receiver_id'] is int
              ? msg['receiver_id'] as int
              : int.tryParse(msg['receiver_id']?.toString() ?? '') ?? 0;
          final contactId = msg['contact_id'] is int
              ? msg['contact_id'] as int
              : int.tryParse(msg['contact_id']?.toString() ?? '') ?? 0;

          // 获取消息内容和类型
          final content = msg['content']?.toString() ?? '';
          final messageType = msg['message_type']?.toString() ?? 'text';
          final fileName = msg['file_name']?.toString();

          // 格式化消息预览
          final formattedMessage = _formatMessagePreview(
            messageType,
            content,
            fileName,
          );

          int actualContactId = contactId;

          if (contactType != 'group') {
            actualContactId =
                senderId == currentUserId ? receiverId : senderId;
            if (actualContactId == 0) {
              actualContactId = contactId;
            }

            if (pendingContactIds.contains(actualContactId)) {
              logger.debug(
                '⏭️ 联系人 $actualContactId 仍在待审核，跳过最近联系人列表',
              );
              return null;
            }
          }
          // 🔴 群组过滤已在SQL层面完成（通过INNER JOIN group_members），无需在这里过滤

          // 根据类型确定联系人信息
          String contactUsername;
          String contactFullName;
          String? contactAvatar;
          int unreadCount = 0;

          if (contactType == 'group') {
            final dbGroupName = msg['group_name']?.toString();
            String contactGroupName = (dbGroupName ?? '').trim();
            // 🔴 修复：使用group_avatar而不是sender_avatar
            contactAvatar = msg['group_avatar']?.toString();

            final snapshot = await _getOrFetchContactSnapshot(
              ownerId: currentUserId,
              contactId: contactId,
              contactType: 'group',
              token: authToken,
              forceRefresh: contactGroupName.isEmpty ||
                  _isGeneratedGroupName(contactGroupName, contactId),
              fallbackName:
                  contactGroupName.isNotEmpty ? contactGroupName : null,
              fallbackAvatar: contactAvatar,
            );

            if (snapshot != null) {
              final cachedName =
                  snapshot['full_name']?.toString() ??
                  snapshot['username']?.toString();
              if (cachedName != null && cachedName.trim().isNotEmpty) {
                contactGroupName = cachedName.trim();
              }
              final cachedAvatar = snapshot['avatar']?.toString();
              if (cachedAvatar != null && cachedAvatar.isNotEmpty) {
                contactAvatar = cachedAvatar;
              }
            }

            if (contactGroupName.isEmpty) {
              contactGroupName = '群聊$contactId';
            }

            contactUsername = contactGroupName;
            contactFullName = contactGroupName;
            // 🔴 优化：直接使用SQL查询返回的未读数，避免额外查询
            unreadCount = msg['unread_count'] is int
                ? msg['unread_count'] as int
                : int.tryParse(msg['unread_count']?.toString() ?? '0') ?? 0;
          } else if (contactType == 'file_assistant') {
            // 处理文件传输助手
            contactUsername = '文件传输助手';
            contactFullName = '文件传输助手';
            contactAvatar = null; // 文件传输助手使用默认图标
            actualContactId = 0; // 使用0表示文件传输助手
            unreadCount = 0; // 文件传输助手暂不计算未读数
            logger.debug('📁 文件传输助手已添加到最近联系人列表');
          } else {
            // 获取联系人账号（通常是用户名）
            String? dbContactUsername = senderId == currentUserId
                ? msg['receiver_name']?.toString()
                : msg['sender_name']?.toString();

            contactUsername =
                (dbContactUsername == null || dbContactUsername.isEmpty)
                ? actualContactId.toString()
                : dbContactUsername;
            contactFullName = contactUsername;

            contactAvatar = senderId == currentUserId
                ? msg['receiver_avatar']?.toString()
                : msg['sender_avatar']?.toString();

            final snapshot = await _getOrFetchContactSnapshot(
              ownerId: currentUserId,
              contactId: actualContactId,
              contactType: 'user',
              token: authToken,
              forceRefresh:
                  contactFullName.isEmpty || _isNumericId(contactFullName),
              fallbackName: contactFullName.isNotEmpty
                  ? contactFullName
                  : contactUsername,
              fallbackAvatar: contactAvatar,
            );

            if (snapshot != null) {
              final cachedFullName = snapshot['full_name']?.toString();
              final cachedUsername = snapshot['username']?.toString();
              if (cachedFullName != null && cachedFullName.trim().isNotEmpty) {
                contactFullName = cachedFullName.trim();
              } else if (cachedUsername != null &&
                  cachedUsername.trim().isNotEmpty) {
                contactFullName = cachedUsername.trim();
              }
              if (cachedUsername != null && cachedUsername.trim().isNotEmpty) {
                contactUsername = cachedUsername.trim();
              }
              final cachedAvatar = snapshot['avatar']?.toString();
              if (cachedAvatar != null && cachedAvatar.isNotEmpty) {
                contactAvatar = cachedAvatar;
              }
            } else {
              logger.debug(
                '⚠️ 联系人快照缺失，使用本地字段: contactId=$actualContactId',
              );
            }

            // 🔴 优化：直接使用SQL查询返回的未读数，避免额外查询
            unreadCount = msg['unread_count'] is int
                ? msg['unread_count'] as int
                : int.tryParse(msg['unread_count']?.toString() ?? '0') ?? 0;
          }

          final resolvedFullName = contactFullName.isNotEmpty
              ? contactFullName
              : contactUsername;

          // 🔴 获取免打扰状态（从SharedPreferences查询）
          final contactKey = Storage.generateContactKey(
            isGroup: contactType == 'group',
            id: contactType == 'file_assistant' ? currentUserId : contactId,
          );
          final doNotDisturb = await Storage.getDoNotDisturb(currentUserId, contactKey);
          logger.debug('🔔 联系人 $resolvedFullName 的免打扰状态: $doNotDisturb (key: $contactKey)');

          // 🔴 时区处理：本地数据库存储的时间已经是上海时区，直接使用
          String lastMessageTime = msg['last_message_time']?.toString() ?? DateTime.now().toIso8601String();

          return {
            'type': contactType,
            'user_id': contactType == 'file_assistant' ? actualContactId : contactId,
            'username': contactUsername,
            'full_name': resolvedFullName,
            'avatar': contactAvatar,
            'last_message_time': lastMessageTime,
            'last_message': formattedMessage,
            'unread_count': unreadCount,
            'status': 'offline',
            'do_not_disturb': doNotDisturb, // 🔴 添加免打扰状态
            if (contactType == 'group') 'group_id': contactId,
            if (contactType == 'group') 'group_name': resolvedFullName,
            if (contactType == 'file_assistant') 'is_file_assistant': true,
          };
        } catch (e, stackTrace) {
          logger.debug('❌ 处理联系人数据失败: $e');
          logger.debug('❌ 问题数据: $msg');
          logger.debug('❌ 堆栈: $stackTrace');
          // 返回一个默认的联系人数据，避免整个列表加载失败
          return {
            'type': 'user',
            'user_id': 0,
            'username': 'Unknown',
            'full_name': 'Unknown',
            'avatar': null,
            'last_message_time': DateTime.now().toIso8601String(),
            'last_message': '[加载失败]',
            'unread_count': 0,
            'status': 'offline',
          };
        }
      });

      final contactsRaw = await Future.wait(contactsFutures);
      final contacts =
          contactsRaw.whereType<Map<String, dynamic>>().toList();

      // 🔍 调试：打印转换后的前5个联系人
      logger.debug('📊 [MessageService] 转换后的联系人列表（前${contacts.length > 5 ? 5 : contacts.length}个）:');
      for (int i = 0; i < contacts.length && i < 5; i++) {
        final contact = contacts[i];
        final type = contact['type'] == 'group' ? '[群组]' : '[私聊]';
        final name = contact['full_name'] ?? contact['username'] ?? 'Unknown';
        final time = contact['last_message_time'];
        logger.debug('  ${i + 1}. $type $name - 最后消息时间: $time');
      }

      return {
        'code': 0,
        'message': '成功',
        'data': {'contacts': contacts},
      };
    } catch (e) {
      logger.debug('获取最近联系人列表失败: $e');
      return {'code': -1, 'message': '获取失败: $e', 'data': null};
    }
  }

  // ============ 群聊消息 ============

  /// 获取群聊消息
  Future<List<MessageModel>> getGroupMessageList({
    required int groupId,
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      // 获取当前用户ID，用于过滤已删除的消息
      final currentUserId = await Storage.getUserId();

      // 从本地数据库获取消息
      final messages = await _localDb.getGroupMessages(
        groupId: groupId,
        userId: currentUserId, // 传入用户ID以过滤该用户已删除的消息
        limit: pageSize,
      );

      // 🔍 调试：查看数据库返回的原始数据
      logger.debug('📥 从数据库查询到 ${messages.length} 条群组消息');
      if (messages.isNotEmpty) {
        final firstMsg = messages.first;
        logger.debug('📥 第一条消息原始数据: $firstMsg');
        logger.debug('📥 第一条消息 channel_name 字段: ${firstMsg['channel_name']}');
        logger.debug('📥 第一条消息 message_type: ${firstMsg['message_type']}');
      }

      // 转换为MessageModel
      final messageList = messages
          .map((json) => MessageModel.fromJson(json))
          .toList();
      
      // 🔍 调试：查看转换后的 MessageModel
      if (messageList.isNotEmpty) {
        final firstModel = messageList.first;
        logger.debug('📥 转换后第一条消息 channelName: ${firstModel.channelName}');
        logger.debug('📥 转换后第一条消息 messageType: ${firstModel.messageType}');
      }

      return messageList;
    } catch (e) {
      logger.debug('获取群聊消息失败: $e');
      return [];
    }
  }

  /// 获取群聊消息（兼容旧API）
  Future<Map<String, dynamic>> getGroupMessages({
    required int groupId,
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      final messages = await getGroupMessageList(
        groupId: groupId,
        page: page,
        pageSize: pageSize,
      );

      return {
        'code': 0,
        'message': '成功',
        'data': {
          'messages': messages.map((m) => m.toJson()).toList(),
          'page': page,
          'page_size': pageSize,
          'total': messages.length,
        },
      };
    } catch (e) {
      logger.debug('获取群聊消息失败: $e');
      return {'code': -1, 'message': '获取失败: $e', 'data': null};
    }
  }

  /// 保存群聊消息到本地数据库
  Future<int> saveGroupMessage(Map<String, dynamic> messageData) async {
    try {
      return await _localDb.insertGroupMessage(messageData);
    } catch (e) {
      logger.debug('保存群聊消息失败: $e');
      rethrow;
    }
  }

  /// 撤回群聊消息
  Future<void> recallGroupMessage(int messageId) async {
    try {
      await _localDb.recallGroupMessage(messageId);
    } catch (e) {
      logger.debug('撤回群聊消息失败: $e');
      rethrow;
    }
  }

  /// 删除群聊消息
  Future<void> deleteGroupMessage(int messageId, int userId) async {
    try {
      await _localDb.deleteGroupMessage(messageId, userId);
    } catch (e) {
      logger.debug('删除群聊消息失败: $e');
      rethrow;
    }
  }

  /// 标记群聊消息为已读
  Future<void> markGroupMessageAsRead(int groupMessageId, int userId) async {
    try {
      await _localDb.markGroupMessageAsRead(groupMessageId, userId);
    } catch (e) {
      logger.debug('标记群聊消息为已读失败: $e');
      rethrow;
    }
  }

  /// 批量标记群组消息为已读
  Future<void> markGroupMessagesAsRead(int groupId) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) return;

      await _localDb.markGroupMessagesAsRead(groupId, userId);
    } catch (e) {
      logger.debug('批量标记群组消息为已读失败: $e');
      rethrow;
    }
  }

  /// 获取群组未读消息数量
  Future<int> getGroupUnreadMessageCount(int groupId, int userId) async {
    try {
      return await _localDb.getGroupUnreadMessageCount(groupId, userId);
    } catch (e) {
      logger.debug('获取群组未读消息数量失败: $e');
      return 0;
    }
  }

  /// 获取群聊消息已读状态
  Future<List<Map<String, dynamic>>> getGroupMessageReads(
    int groupMessageId,
  ) async {
    try {
      return await _localDb.getGroupMessageReads(groupMessageId);
    } catch (e) {
      logger.debug('获取群聊消息已读状态失败: $e');
      return [];
    }
  }

  // ============ 数据库管理 ============

  /// 清空所有本地消息数据（退出登录时调用）
  Future<void> clearAllData() async {
    try {
      await _localDb.clearAllData();
      logger.debug('已清空所有本地消息数据');
    } catch (e) {
      logger.debug('清空本地消息数据失败: $e');
      rethrow;
    }
  }

  /// 关闭数据库连接
  Future<void> close() async {
    await _localDb.close();
  }
}
