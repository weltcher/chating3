import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';

/// 极光推送服务
/// 通过原生 MethodChannel 与 Android 原生 JPush SDK 通信
class JPushService {
  static final JPushService _instance = JPushService._internal();
  factory JPushService() => _instance;
  JPushService._internal();

  static JPushService get instance => _instance;

  static const MethodChannel _channel = MethodChannel('com.example.youdu/jpush');
  
  bool _initialized = false;
  String? _registrationId;

  String? get registrationId => _registrationId;

  Function(Map<String, dynamic> message)? onNotificationOpened;
  Function(Map<String, dynamic> message)? onReceiveMessage;
  Function(Map<String, dynamic> message)? onReceiveNotification;

  /// 初始化极光推送
  Future<void> initialize() async {
    // 仅 Android 初始化（iOS 暂不支持）
    if (!Platform.isAndroid) {
      logger.debug('📱 [JPush] 非 Android 平台，跳过初始化');
      return;
    }

    if (_initialized) {
      logger.debug('📱 [JPush] 已初始化，跳过');
      return;
    }

    try {
      logger.debug('📱 [JPush] 开始初始化...');

      // 调用原生初始化
      await _channel.invokeMethod('init');
      
      // 🔴 延迟获取 Registration ID（JPush 需要时间连接服务器）
      await Future.delayed(const Duration(seconds: 2));
      
      // 获取 Registration ID（最多重试 3 次）
      for (int i = 0; i < 3; i++) {
        _registrationId = await _channel.invokeMethod('getRegistrationId');
        if (_registrationId != null && _registrationId!.isNotEmpty) {
          break;
        }
        logger.debug('📱 [JPush] Registration ID 为空，等待重试 (${i + 1}/3)...');
        await Future.delayed(const Duration(seconds: 2));
      }
      
      logger.debug('📱 [JPush] Registration ID: $_registrationId');
      
      // 保存到本地
      if (_registrationId != null && _registrationId!.isNotEmpty) {
        await Storage.setJPushRegistrationId(_registrationId!);
        logger.info('📱 [JPush] ✅ 初始化成功，Registration ID: $_registrationId');
      } else {
        logger.warning('📱 [JPush] ⚠️ 初始化完成但 Registration ID 为空，推送可能无法正常工作');
      }

      _initialized = true;
    } catch (e) {
      logger.error('📱 [JPush] ❌ 初始化失败: $e');
    }
  }

  /// 设置别名（用于定向推送给特定用户）
  Future<void> setAlias(String alias) async {
    if (!Platform.isAndroid) return;
    
    try {
      await _channel.invokeMethod('setAlias', {'alias': alias});
      logger.debug('📱 [JPush] 设置别名成功: $alias');
    } catch (e) {
      logger.error('📱 [JPush] 设置别名失败: $e');
    }
  }

  /// 删除别名（用户登出时调用）
  Future<void> deleteAlias() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('deleteAlias');
      logger.debug('📱 [JPush] 删除别名成功');
    } catch (e) {
      logger.error('📱 [JPush] 删除别名失败: $e');
    }
  }

  /// 设置标签（用于群发推送）
  Future<void> setTags(List<String> tags) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('setTags', {'tags': tags});
      logger.debug('📱 [JPush] 设置标签成功: $tags');
    } catch (e) {
      logger.error('📱 [JPush] 设置标签失败: $e');
    }
  }

  /// 清除所有通知
  Future<void> clearAllNotifications() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('clearAllNotifications');
      logger.debug('📱 [JPush] 清除所有通知成功');
    } catch (e) {
      logger.error('📱 [JPush] 清除所有通知失败: $e');
    }
  }

  /// 停止推送
  Future<void> stopPush() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('stopPush');
      logger.debug('📱 [JPush] 停止推送成功');
    } catch (e) {
      logger.error('📱 [JPush] 停止推送失败: $e');
    }
  }

  /// 恢复推送
  Future<void> resumePush() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('resumePush');
      logger.debug('📱 [JPush] 恢复推送成功');
    } catch (e) {
      logger.error('📱 [JPush] 恢复推送失败: $e');
    }
  }
}
