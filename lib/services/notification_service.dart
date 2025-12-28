import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:youdu/utils/logger.dart';

/// 本地通知服务 - 用于锁屏消息提醒
class NotificationService with WidgetsBindingObserver {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static NotificationService get instance => _instance;

  final FlutterLocalNotificationsPlugin _notifications = 
      FlutterLocalNotificationsPlugin();
  
  bool _initialized = false;
  
  /// 通知点击回调
  Function(String? payload)? onNotificationTap;
  
  /// APP是否在前台（用于判断是否显示通知）
  bool _isAppInForeground = true;

  /// 开始监听应用生命周期
  void startLifecycleObserver() {
    WidgetsBinding.instance.addObserver(this);
    logger.debug('🔔 开始监听应用生命周期状态');
  }

  /// 停止监听应用生命周期
  void stopLifecycleObserver() {
    WidgetsBinding.instance.removeObserver(this);
    logger.debug('🔔 停止监听应用生命周期状态');
  }

  /// 检查APP是否在前台
  bool get isAppInForeground => _isAppInForeground;

  /// 监听应用生命周期变化
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      _isAppInForeground = false;
      logger.debug('🔔 ➡️ APP 进入后台（paused）');
    }

    if (state == AppLifecycleState.resumed) {
      _isAppInForeground = true;
      logger.debug('🔔 ⬅️ APP 回到前台（resumed）');
    }

    if (state == AppLifecycleState.inactive) {
      logger.debug('🔔 ⚠️ APP 临时不可交互（比如来电话、分屏）');
    }

    if (state == AppLifecycleState.detached) {
      logger.debug('🔔 ❌ APP 已分离（退出前）');
    }
  }

  /// 初始化通知服务
  Future<void> initialize() async {
    if (_initialized) {
      logger.debug('🔔 通知服务已初始化，跳过');
      return;
    }

    try {
      // Android 初始化设置
      const AndroidInitializationSettings androidSettings = 
          AndroidInitializationSettings('@mipmap/ic_launcher');

      // iOS 初始化设置
      const DarwinInitializationSettings iosSettings = 
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      // 初始化插件
      await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // 创建Android通知渠道（确保高优先级渠道存在）
      await _createNotificationChannel();

      // 请求权限
      await _requestPermissions();

      _initialized = true;
      logger.debug('🔔 通知服务初始化成功');
    } catch (e) {
      logger.error('🔔 通知服务初始化失败: $e');
    }
  }

  /// 创建Android通知渠道
  Future<void> _createNotificationChannel() async {
    if (!Platform.isAndroid) return;

    try {
      // 🔴 使用新的渠道ID，确保创建新的高优先级渠道
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'message_channel_v2', // 🔴 新的频道ID
        '消息通知', // 频道名称
        description: '接收新消息通知（横幅弹窗）',
        importance: Importance.max, // 🔴 最高重要性，确保显示横幅弹窗
        playSound: true,
        enableVibration: true,
        showBadge: true,
        enableLights: true, // 🔴 启用LED灯
      );

      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      await androidImplementation?.createNotificationChannel(channel);
      logger.debug('🔔 Android通知渠道创建成功（message_channel_v2，最高重要性）');
    } catch (e) {
      logger.error('🔔 创建通知渠道失败: $e');
    }
  }

  /// 请求通知权限
  Future<void> _requestPermissions() async {
    if (Platform.isIOS) {
      await _notifications
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    } else if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      
      // Android 13+ 需要请求通知权限
      await androidImplementation?.requestNotificationsPermission();
    }
  }

  /// 处理通知点击事件
  void _onNotificationTapped(NotificationResponse response) {
    logger.debug('🔔 用户点击通知: ${response.payload}');
    onNotificationTap?.call(response.payload);
  }

  /// 显示新消息通知
  /// 
  /// [id] 通知ID（用于更新或取消通知）
  /// [title] 通知标题（发送者名称）
  /// [body] 通知内容（消息内容）
  /// [payload] 通知载荷（用于点击跳转，格式：userId:messageId）
  Future<void> showMessageNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    logger.debug('🔔 [showMessageNotification] 收到显示通知请求 - APP状态: ${_isAppInForeground ? "前台" : "后台"}');
    
    // 只在APP后台时显示通知
    if (_isAppInForeground) {
      logger.debug('🔔 APP在前台，不显示系统通知（应该显示应用内弹窗）');
      return;
    }
    
    logger.debug('🔔 APP在后台，准备显示系统通知 - 标题: $title, 内容: $body');

    if (!_initialized) {
      logger.warning('🔔 通知服务未初始化，正在初始化...');
      await initialize();
    }

    try {
      // Android 通知详情 - 配置为横幅弹窗模式（类似微信）
      const AndroidNotificationDetails androidDetails = 
          AndroidNotificationDetails(
        'message_channel_v2', // 🔴 使用新的频道ID
        '消息通知', // 频道名称
        channelDescription: '接收新消息通知（横幅弹窗）',
        importance: Importance.max, // 🔴 改为max，确保显示横幅
        priority: Priority.max, // 🔴 改为max，确保显示横幅
        showWhen: true,
        enableVibration: true,
        playSound: true,
        // 🔴 启用全屏Intent，在后台时弹出通知
        fullScreenIntent: true,
        // 通知样式
        styleInformation: BigTextStyleInformation(''),
        // 确保显示悬浮通知（heads-up notification）
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.public,
        // 在锁屏上显示
        ticker: 'New Message',
        // 🔴 设置通知在屏幕顶部弹出的时间（毫秒）
        timeoutAfter: 10000, // 10秒后自动消失
        // 🔴 设置为ongoing可以让通知更持久
        ongoing: false,
        // 🔴 自动取消
        autoCancel: true,
      );

      // iOS 通知详情
      const DarwinNotificationDetails iosDetails = 
          DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        id,
        title,
        body,
        notificationDetails,
        payload: payload,
      );

      logger.debug('🔔 ✅ 系统通知已发送 - ID: $id, 标题: $title, 内容: $body');
    } catch (e) {
      logger.error('🔔 显示通知失败: $e');
    }
  }

  /// 显示群组消息通知
  Future<void> showGroupMessageNotification({
    required int id,
    required String groupName,
    required String senderName,
    required String message,
    String? payload,
  }) async {
    final title = '$groupName';
    final body = '$senderName: $message';
    await showMessageNotification(
      id: id,
      title: title,
      body: body,
      payload: payload,
    );
  }

  /// 取消指定通知
  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }

  /// 取消所有通知
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  /// 格式化消息内容（根据消息类型）
  String formatMessageContent(String messageType, String content, String? fileName) {
    switch (messageType) {
      case 'image':
        return '[图片]';
      case 'video':
        return '[视频]';
      case 'file':
        return fileName != null ? '[文件] $fileName' : '[文件]';
      case 'audio':
      case 'voice':
        return '[语音]';
      case 'call_ended':
      case 'call_ended_video':
        return '[通话结束]';
      default:
        // 检查是否是纯表情消息
        if (content.startsWith('[emotion:') && content.endsWith('.png]')) {
          return '[表情]';
        }
        // 限制文本长度
        if (content.length > 100) {
          return '${content.substring(0, 100)}...';
        }
        return content;
    }
  }
}
