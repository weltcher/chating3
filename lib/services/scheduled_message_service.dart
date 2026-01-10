import '../models/scheduled_message_model.dart';
import 'api_service.dart';
import '../utils/logger.dart';

/// 定时消息服务
class ScheduledMessageService {
  /// 创建定时消息
  static Future<ScheduledMessageModel?> create({
    required String token,
    required int receiverId,
    required bool isGroup,
    required String title,
    required String sendTime,
    String? sendDate, // 🔴 新增：单次任务的日期
    required bool isDaily,
    required String content,
  }) async {
    try {
      final body = <String, dynamic>{
        'receiver_id': receiverId,
        'message_type': isGroup ? 'group' : 'private',
        'title': title,
        'send_time': sendTime,
        'send_type': isDaily ? 'daily' : 'once',
        'content': content,
      };
      // 🔴 单次任务才传日期
      if (sendDate != null && !isDaily) {
        body['send_date'] = sendDate;
      }
      
      final response = await ApiService.post(
        '/api/scheduled-messages',
        body,
        token: token,
      );

      if (response['code'] == 0 && response['data'] != null) {
        return ScheduledMessageModel.fromJson(response['data']);
      }
      return null;
    } catch (e) {
      logger.error('创建定时消息失败: $e');
      rethrow;
    }
  }

  /// 更新定时消息
  static Future<ScheduledMessageModel?> update({
    required String token,
    required int id,
    required String title,
    required String sendTime,
    String? sendDate, // 🔴 新增：单次任务的日期
    required bool isDaily,
    required String content,
  }) async {
    try {
      final body = <String, dynamic>{
        'title': title,
        'send_time': sendTime,
        'send_type': isDaily ? 'daily' : 'once',
        'content': content,
      };
      // 🔴 单次任务才传日期
      if (sendDate != null && !isDaily) {
        body['send_date'] = sendDate;
      }
      
      final response = await ApiService.put(
        '/api/scheduled-messages/$id',
        body,
        token: token,
      );

      if (response['code'] == 0 && response['data'] != null) {
        return ScheduledMessageModel.fromJson(response['data']);
      }
      return null;
    } catch (e) {
      logger.error('更新定时消息失败: $e');
      rethrow;
    }
  }

  /// 删除定时消息
  static Future<bool> delete({
    required String token,
    required int id,
  }) async {
    try {
      final response = await ApiService.delete(
        '/api/scheduled-messages/$id',
        token: token,
      );

      return response['code'] == 0;
    } catch (e) {
      logger.error('删除定时消息失败: $e');
      rethrow;
    }
  }

  /// 获取定时消息列表
  static Future<List<ScheduledMessageModel>> getList({
    required String token,
    required int receiverId,
    required bool isGroup,
  }) async {
    try {
      final messageType = isGroup ? 'group' : 'private';
      final response = await ApiService.get(
        '/api/scheduled-messages?receiver_id=$receiverId&message_type=$messageType',
        token: token,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final List<dynamic> dataList = response['data'];
        return dataList
            .map((json) => ScheduledMessageModel.fromJson(json))
            .toList();
      }
      return [];
    } catch (e) {
      logger.error('获取定时消息列表失败: $e');
      rethrow;
    }
  }

  /// 获取定时消息详情
  static Future<ScheduledMessageModel?> getById({
    required String token,
    required int id,
  }) async {
    try {
      final response = await ApiService.get(
        '/api/scheduled-messages/$id',
        token: token,
      );

      if (response['code'] == 0 && response['data'] != null) {
        return ScheduledMessageModel.fromJson(response['data']);
      }
      return null;
    } catch (e) {
      logger.error('获取定时消息详情失败: $e');
      rethrow;
    }
  }
}
