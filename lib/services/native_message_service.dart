import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/logger.dart';

/// 原生消息弹窗服务
/// 用于在 Android/iOS 端应用后台时显示系统级消息弹窗
class NativeMessageService {
  static final NativeMessageService _instance = NativeMessageService._internal();
  factory NativeMessageService() => _instance;
  NativeMessageService._internal();

  static const MethodChannel _channel = MethodChannel('com.example.youdu/message');

  /// 点击消息弹窗的回调
  Function(Map<String, dynamic> messageData)? onMessageTapped;

  /// 初始化消息服务
  void initialize({
    Function(Map<String, dynamic> messageData)? onMessageTapped,
  }) {
    if (!Platform.isAndroid && !Platform.isIOS) {
      logger.debug('⚠️ 原生消息服务仅支持 Android/iOS 平台');
      return;
    }

    this.onMessageTapped = onMessageTapped;

    // 设置消息回调
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onMessageTapped') {
        final messageData = Map<String, dynamic>.from(call.arguments as Map);
        logger.debug('📱 收到消息点击回调: $messageData');
        this.onMessageTapped?.call(messageData);
      }
    });

    logger.debug('✅ 原生消息服务已初始化 (${Platform.isAndroid ? "Android" : "iOS"})');
  }

  /// 显示消息弹窗（系统级 Heads-up 通知样式）
  /// 
  /// [senderName] 发送者名称
  /// [senderId] 发送者 ID
  /// [content] 消息内容
  /// [messageType] 消息类型 'text', 'image', 'file' 等
  /// [isGroupMessage] 是否是群组消息
  /// [groupId] 群组 ID（群组消息时提供）
  /// [groupName] 群组名称（群组消息时提供）
  /// [senderAvatar] 发送者头像 URL
  Future<bool> showMessageOverlay({
    required String senderName,
    required int senderId,
    required String content,
    String messageType = 'text',
    bool isGroupMessage = false,
    int? groupId,
    String? groupName,
    String? senderAvatar,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      logger.debug('⚠️ 原生消息服务仅支持 Android/iOS 平台');
      return false;
    }

    try {
      logger.debug('═══════════════════════════════════════');
      logger.debug('📨 [showMessageOverlay] 准备显示消息弹窗');
      logger.debug('📨 参数信息:');
      logger.debug('   - senderName: $senderName');
      logger.debug('   - senderId: $senderId');
      logger.debug('   - content: $content');
      logger.debug('   - messageType: $messageType');
      logger.debug('   - isGroupMessage: $isGroupMessage');
      logger.debug('   - groupId: $groupId');
      logger.debug('   - groupName: $groupName');
      
      final params = {
        'senderName': senderName,
        'senderId': senderId,
        'content': content,
        'messageType': messageType,
        'isGroupMessage': isGroupMessage,
      };

      // 如果是群组消息，添加群组信息
      if (isGroupMessage && groupId != null) {
        params['groupId'] = groupId;
        if (groupName != null) {
          params['groupName'] = groupName;
        }
      }

      if (senderAvatar != null) {
        params['senderAvatar'] = senderAvatar;
      }

      logger.debug('📨 [showMessageOverlay] 最终 params: $params');
      logger.debug('═══════════════════════════════════════');

      final result = await _channel.invokeMethod<bool>('showMessageOverlay', params);
      
      logger.debug('📨 显示消息弹窗结果: $result');
      return result ?? false;
    } catch (e) {
      logger.debug('❌ 显示消息弹窗失败: $e');
      return false;
    }
  }

  /// 关闭消息弹窗
  Future<bool> dismissMessageOverlay() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('dismissMessageOverlay');
      logger.debug('❌ 消息弹窗已关闭: $result');
      return result ?? false;
    } catch (e) {
      logger.debug('❌ 关闭消息弹窗失败: $e');
      return false;
    }
  }
}
