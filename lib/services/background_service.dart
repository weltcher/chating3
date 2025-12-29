import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../utils/logger.dart';
import 'websocket_service.dart';

/// 后台服务管理器
/// 用于在移动端后台保持WebSocket连接
class BackgroundServiceManager {
  static final BackgroundServiceManager _instance =
      BackgroundServiceManager._internal();
  factory BackgroundServiceManager() => _instance;
  BackgroundServiceManager._internal();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;
  bool _isListening = false;

  /// 初始化后台服务（仅移动端）
  Future<void> initialize() async {
    // 只在移动端初始化
    if (!Platform.isAndroid && !Platform.isIOS) {
      logger.debug('📱 [后台服务] 非移动端，跳过初始化');
      return;
    }

    if (_isInitialized) {
      logger.debug('📱 [后台服务] 已初始化，跳过');
      return;
    }

    logger.debug('📱 [后台服务] 开始初始化...');

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: 'youdu_background_service',
        initialNotificationTitle: '有度',
        initialNotificationContent: '保持消息连接中...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    _isInitialized = true;
    logger.debug('✅ [后台服务] 初始化完成');
  }

  /// 启动后台服务
  Future<void> startService() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      logger.debug('📱 [后台服务] 启动服务...');
      await _service.startService();
    } else {
      logger.debug('📱 [后台服务] 服务已在运行');
    }

    // 只监听一次，避免重复监听
    if (!_isListening) {
      _isListening = true;
      // 监听后台服务发来的检查连接请求
      _service.on('checkConnection').listen((event) {
        _handleCheckConnection();
      });
    }
  }

  /// 处理检查连接请求 - 检测到断开时触发重连
  Future<void> _handleCheckConnection() async {
    final wsService = WebSocketService();
    final isConnected = wsService.isConnected;

    // 更新后台服务的连接状态显示
    _service.invoke('updateStatus', {'connected': isConnected});

    // 🔴 如果断开连接，触发强制重连
    if (!isConnected) {
      logger.debug('🔄 [后台服务] 检测到WebSocket断开，触发强制重连...');
      final success = await wsService.forceReconnect();
      if (success) {
        logger.debug('✅ [后台服务] 强制重连成功');
      } else {
        logger.debug('⚠️ [后台服务] 强制重连失败，将在下次检查时重试');
      }
    }
  }

  /// 停止后台服务
  Future<void> stopService() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final isRunning = await _service.isRunning();
    if (isRunning) {
      logger.debug('📱 [后台服务] 停止服务...');
      _service.invoke('stopService');
    }
  }

  /// 检查服务是否运行中
  Future<bool> isRunning() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return await _service.isRunning();
  }
}

/// iOS后台处理入口
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  return true;
}

/// 后台服务入口点
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  logger.debug('📱 [后台服务] ========== 服务已启动 ==========');
  logger.debug('📱 [后台服务] 时间: ${DateTime.now()}');

  bool isConnected = true;
  int heartbeatCount = 0;

  // 监听停止服务命令
  service.on('stopService').listen((event) {
    logger.debug('📱 [后台服务] 收到停止命令');
    service.stopSelf();
  });

  // 监听状态更新
  service.on('updateStatus').listen((event) {
    if (event != null && event['connected'] != null) {
      isConnected = event['connected'] as bool;
    }
  });

  // 定期检查连接状态（每5秒检查一次，减少频率）
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    heartbeatCount++;
    logger.debug('📱 [后台服务] 💓 心跳 #$heartbeatCount - 时间: ${DateTime.now()}');
    
    // 向主 Isolate 发送检查连接请求
    service.invoke('checkConnection');

    // 更新通知（Android）
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        final status = isConnected ? '已连接' : '正在连接...';
        service.setForegroundNotificationInfo(
          title: '有度',
          content: '消息服务$status (心跳#$heartbeatCount)',
        );
        logger.debug('📱 [后台服务] 通知已更新: $status');
      }
    }
  });
}
