import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'websocket_service.dart';

/// 全局认证状态服务
/// 用于处理token失效、强制登出等认证相关的全局状态
class AuthStateService {
  static final AuthStateService _instance = AuthStateService._internal();
  factory AuthStateService() => _instance;
  AuthStateService._internal();

  // 全局导航key，用于在任何地方跳转到登录页面
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // 强制登出的消息流，供UI层监听
  final _forceLogoutController = StreamController<String>.broadcast();
  Stream<String> get forceLogoutStream => _forceLogoutController.stream;

  // 是否已经在处理登出（防止重复触发）
  bool _isHandlingLogout = false;

  // 待显示的登出消息
  String? _pendingLogoutMessage;

  /// 处理token失效（被踢下线或token过期）
  /// [message] 显示给用户的消息
  Future<void> handleTokenInvalid(String message) async {
    if (_isHandlingLogout) {
      logger.debug('🔄 [AuthState] 已在处理登出，跳过重复触发');
      return;
    }

    _isHandlingLogout = true;
    _pendingLogoutMessage = message;
    logger.debug('🚫 [AuthState] Token失效，准备强制登出: $message');

    try {
      // 标记WebSocket为强制登出状态
      final wsService = WebSocketService();

      // 断开WebSocket连接
      await wsService.disconnect();

      // 清除本地存储的token
      await Storage.clearToken();

      // 通知UI层
      _forceLogoutController.add(message);

      // 🔴 使用 SchedulerBinding 确保在下一帧执行导航，避免在构建过程中导航
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _navigateToLogin(message);
      });
    } catch (e) {
      logger.error('❌ [AuthState] 处理登出时出错: $e');
      _isHandlingLogout = false;
    }
  }

  /// 跳转到登录页面
  void _navigateToLogin(String message) {
    logger.debug('🔄 [AuthState] 尝试跳转到登录页面...');

    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      logger.debug('✅ [AuthState] Navigator可用，执行跳转');

      // 先跳转
      navigator.pushNamedAndRemoveUntil('/login', (route) => false);

      // 延迟显示提示消息
      Future.delayed(const Duration(milliseconds: 800), () {
        _showLogoutMessage(message);
        // 重置标志
        _isHandlingLogout = false;
        _pendingLogoutMessage = null;
      });
    } else {
      logger.debug('⚠️ [AuthState] Navigator不可用，延迟重试...');
      // Navigator不可用时，延迟重试
      Future.delayed(const Duration(milliseconds: 100), () {
        final retryNavigator = navigatorKey.currentState;
        if (retryNavigator != null) {
          logger.debug('✅ [AuthState] 重试成功，执行跳转');
          retryNavigator.pushNamedAndRemoveUntil('/login', (route) => false);
          Future.delayed(const Duration(milliseconds: 800), () {
            _showLogoutMessage(message);
            _isHandlingLogout = false;
            _pendingLogoutMessage = null;
          });
        } else {
          logger.error('❌ [AuthState] Navigator仍不可用，放弃跳转');
          _isHandlingLogout = false;
          _pendingLogoutMessage = null;
        }
      });
    }
  }

  /// 显示登出提示消息
  void _showLogoutMessage(String message) {
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      final context = navigator.context;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// 重置状态（用户重新登录时调用）
  void reset() {
    _isHandlingLogout = false;
    _pendingLogoutMessage = null;
    logger.debug('🔄 [AuthState] 认证状态已重置');
  }

  /// 释放资源
  void dispose() {
    _forceLogoutController.close();
  }
}
