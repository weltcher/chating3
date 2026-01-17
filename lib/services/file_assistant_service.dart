import '../models/message_model.dart';
import 'local_database_service.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';

/// 文件助手服务
/// 管理文件传输助手的消息
class FileAssistantService {
  final _localDb = LocalDatabaseService();

  /// 保存文件助手消息到本地数据库
  Future<int> saveMessage({
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
  }) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) throw Exception('用户未登录');

      final message = {
        'user_id': userId,
        'content': content,
        'message_type': messageType,
        'status': 'normal',
        'created_at': DateTime.now().toIso8601String(),
      };

      if (fileName != null) message['file_name'] = fileName;
      if (quotedMessageId != null) message['quoted_message_id'] = quotedMessageId;
      if (quotedMessageContent != null) message['quoted_message_content'] = quotedMessageContent;

      final id = await _localDb.insertFileAssistantMessage(message);
      logger.debug('保存文件助手消息成功: ID=$id');
      return id;
    } catch (e) {
      logger.debug('保存文件助手消息失败: $e');
      rethrow;
    }
  }

  /// 获取文件助手消息列表
  Future<List<MessageModel>> getMessages({
    int limit = 100,
  }) async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) {
        logger.debug('❌ 获取文件助手消息：用户ID为空');
        return [];
      }

      logger.debug('📂 获取文件助手消息：userId=$userId, limit=$limit');
      final username = await Storage.getUsername() ?? 'User';

      final results = await _localDb.getFileAssistantMessages(
        userId: userId,
        limit: limit,
      );

      logger.debug('✅ 查询到文件助手消息: ${results.length}条');
      if (results.isEmpty) {
        logger.debug('⚠️ 文件助手消息为空，可能原因：1.数据库被清空 2.userId不匹配 3.确实没有消息');
      }

      // 🔄 对于image、video、file、voice类型，替换content中的OSS域名前缀
      final processedResults = <Map<String, dynamic>>[];
      for (final data in results) {
        final messageType = data['message_type'] as String?;
        final messageId = data['id'];
        
        // 创建可修改的副本
        final mutableData = Map<String, dynamic>.from(data);
        
        // 替换消息内容
        if (messageType == 'image' || messageType == 'video' || messageType == 'file' || messageType == 'voice') {
          final content = mutableData['content'] as String?;
          
          if (content != null && content.isNotEmpty) {
            final replacedContent = await Storage.replaceOSSPrefixInUrl(content);
            if (replacedContent != content) {
              logger.debug('🔄 [FileAssistant] ID=$messageId, 类型=$messageType, 替换content: $content -> $replacedContent');
              mutableData['content'] = replacedContent;
            }
          }
        }
        
        // 🔄 替换引用消息内容（quoted_message_content）
        final quotedContent = mutableData['quoted_message_content'] as String?;
        if (quotedContent != null && quotedContent.isNotEmpty) {
          final replacedQuotedContent = await Storage.replaceOSSPrefixInUrl(quotedContent);
          if (replacedQuotedContent != quotedContent) {
            logger.debug('🔄 [FileAssistant] ID=$messageId, 替换quoted_content: $quotedContent -> $replacedQuotedContent');
            mutableData['quoted_message_content'] = replacedQuotedContent;
          }
        }
        
        processedResults.add(mutableData);
      }

      return processedResults.map((data) {
        return MessageModel(
          id: data['id'] as int,
          senderId: userId,
          receiverId: userId,
          senderName: username,
          receiverName: '文件传输助手',
          content: data['content'] as String,
          messageType: data['message_type'] as String? ?? 'text',
          fileName: data['file_name'] as String?,
          quotedMessageId: data['quoted_message_id'] as int?,
          quotedMessageContent: data['quoted_message_content'] as String?,
          status: data['status'] as String? ?? 'normal',
          isRead: true,
          createdAt: DateTime.parse(data['created_at'] as String),
        );
      }).toList();
    } catch (e) {
      logger.debug('获取文件助手消息列表失败: $e');
      return [];
    }
  }

  /// 撤回文件助手消息
  Future<bool> recallMessage(int messageId) async {
    try {
      await _localDb.recallFileAssistantMessage(messageId);
      logger.debug('撤回文件助手消息成功: ID=$messageId');
      return true;
    } catch (e) {
      logger.debug('撤回文件助手消息失败: $e');
      return false;
    }
  }

  /// 删除文件助手消息
  Future<bool> deleteMessage(int messageId) async {
    try {
      await _localDb.deleteFileAssistantMessage(messageId);
      logger.debug('删除文件助手消息成功: ID=$messageId');
      return true;
    } catch (e) {
      logger.debug('删除文件助手消息失败: $e');
      return false;
    }
  }

  /// 获取文件助手消息（返回API兼容格式）
  Future<Map<String, dynamic>> getMessagesApiFormat({
    int page = 1,
    int pageSize = 50,
  }) async {
    try {
      final messages = await getMessages(limit: pageSize);

      return {
        'code': 0,
        'message': '获取成功',
        'data': {
          'messages': messages.map((m) => m.toJson()).toList(),
          'page': page,
          'page_size': pageSize,
          'total': messages.length,
        },
      };
    } catch (e) {
      logger.debug('获取文件助手消息失败: $e');
      return {
        'code': -1,
        'message': '获取失败: $e',
        'data': null,
      };
    }
  }
}
