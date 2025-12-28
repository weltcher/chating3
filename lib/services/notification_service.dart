import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:youdu/utils/logger.dart';

/// 本地通知服务 - 用于锁屏消息提醒和悬浮通知（Heads-up）
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

    final previousState = _isAppInForeground;

    if (state == AppLifecycleState.paused) {
      _isAppInForeground = false;
      logger.debug('🔔 ==================== 生命周期变化 ====================');
      logger.debug('🔔 ➡️ APP 进入后台（paused）');
      logger.debug('🔔 _isAppInForeground: $previousState -> $_isAppInForeground');
      logger.debug('🔔 ====================================================');
    }

    if (state == AppLifecycleState.resumed) {
      _isAppInForeground = true;
      logger.debug('🔔 ==================== 生命周期变化 ====================');
      logger.debug('🔔 ⬅️ APP 回到前台（resumed）');
      logger.debug('🔔 _isAppInForeground: $previousState -> $_isAppInForeground');
      logger.debug('🔔 ====================================================');
    }

    if (state == AppLifecycleState.inactive) {
      logger.debug(
          '🔔 ⚠️ APP 临时不可交互（比如来电话、分屏）- _isAppInForeground保持: $_isAppInForeground');
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
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      // 🔴 删除旧渠道（如果存在），确保使用最新配置
      await androidImplementation?.deleteNotificationChannel('message_channel');
      await androidImplementation
          ?.deleteNotificationChannel('message_channel_v2');

      // 🔴 创建高优先级消息通知渠道 - 用于悬浮通知（Heads-up）
      const AndroidNotificationChannel messageChannel =
          AndroidNotificationChannel(
        'message_channel_v3', // 🔴 新的频道ID
        '消息通知', // 频道名称
        description: '接收新消息通知，支持横幅弹窗',
        importance: Importance.max, // 🔴 最高重要性，确保显示横幅弹窗
        playSound: true,
        enableVibration: true,
        showBadge: true,
        enableLights: true,
      );

      await androidImplementation?.createNotificationChannel(messageChannel);
      logger.debug('🔔 Android通知渠道创建成功（message_channel_v3，最高重要性）');

      // 🔴 检查通知渠道是否被用户禁用了横幅显示
      await _checkNotificationChannelSettings();
    } catch (e) {
      logger.error('🔔 创建通知渠道失败: $e');
    }
  }

  /// 检查通知渠道设置（提示用户开启横幅通知）
  Future<void> _checkNotificationChannelSettings() async {
    if (!Platform.isAndroid) return;

    try {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      // 检查通知权限是否开启
      final areNotificationsEnabled =
          await androidImplementation?.areNotificationsEnabled();
      if (areNotificationsEnabled == false) {
        logger.warning('🔔 ⚠️ 通知权限未开启，请在系统设置中开启');
      }
    } catch (e) {
      logger.error('🔔 检查通知渠道设置失败: $e');
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
    logger.debug(
        '🔔 ==================== showMessageNotification 开始 ====================');
    logger.debug(
        '🔔 [showMessageNotification] 参数: id=$id, title=$title, body=$body');
    logger.debug('🔔 [showMessageNotification] APP前台状态: $_isAppInForeground');
    logger.debug('🔔 [showMessageNotification] 通知服务初始化状态: $_initialized');

    // 只在APP后台时显示通知
    if (_isAppInForeground) {
      logger.debug('🔔 [showMessageNotification] ❌ APP在前台，跳过系统通知');
      return;
    }

    logger.debug('🔔 [showMessageNotification] ✅ APP在后台，准备显示系统通知');

    if (!_initialized) {
      logger.warning('🔔 [showMessageNotification] 通知服务未初始化，正在初始化...');
      await initialize();
      logger.debug('🔔 [showMessageNotification] 通知服务初始化完成');
    }

    try {
      // 检查通知权限
      final hasPermission = await checkNotificationPermission();
      logger.debug('🔔 [showMessageNotification] 通知权限状态: $hasPermission');

      if (!hasPermission) {
        logger.warning('🔔 [showMessageNotification] ⚠️ 通知权限未开启！');
      }

      // iOS 通知详情
      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      logger.debug('🔔 [showMessageNotification] 准备调用 _notifications.show()...');

      // 🔴 华为手机特殊处理：使用fullScreenIntent强制显示悬浮通知
      final AndroidNotificationDetails androidDetailsWithFullScreen =
          AndroidNotificationDetails(
        'message_channel_v3',
        '消息通知',
        channelDescription: '接收新消息通知，支持横幅弹窗',
        importance: Importance.max,
        priority: Priority.max,
        showWhen: true,
        enableVibration: true,
        playSound: true,
        // 🔴 关键：启用fullScreenIntent，华为等手机需要这个才能显示悬浮通知
        fullScreenIntent: true,
        styleInformation: const BigTextStyleInformation(''),
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.public,
        ticker: '新消息',
        ongoing: false,
        autoCancel: true,
        color: const Color(0xFF2196F3),
        ledColor: const Color(0xFF2196F3),
        ledOnMs: 1000,
        ledOffMs: 500,
      );

      final NotificationDetails notificationDetailsNew = NotificationDetails(
        android: androidDetailsWithFullScreen,
        iOS: iosDetails,
      );

      await _notifications.show(
        id,
        title,
        body,
        notificationDetailsNew,
        payload: payload,
      );

      logger.debug('🔔 [showMessageNotification] ✅✅✅ 系统通知已成功发送！');
      logger.debug(
          '🔔 ==================== showMessageNotification 结束 ====================');
    } catch (e, stackTrace) {
      logger.error('🔔 [showMessageNotification] ❌❌❌ 显示通知失败: $e');
      logger.error('🔔 [showMessageNotification] 堆栈: $stackTrace');
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
  String formatMessageContent(
      String messageType, String content, String? fileName) {
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

  /// 打开系统通知设置页面
  /// 用于引导用户开启悬浮通知（横幅通知）权限
  Future<void> openNotificationSettings() async {
    if (Platform.isAndroid) {
      try {
        // 使用 MethodChannel 打开通知渠道设置（直接打开"消息通知"渠道）
        const platform = MethodChannel('com.example.youdu/notification');
        await platform.invokeMethod(
            'openChannelSettings', {'channelId': 'message_channel_v3'});
      } catch (e) {
        logger.error('🔔 打开通知渠道设置失败: $e, 尝试打开应用通知设置');
        try {
          const platform = MethodChannel('com.example.youdu/notification');
          await platform.invokeMethod('openNotificationSettings');
        } catch (e2) {
          logger.error('🔔 打开应用通知设置也失败: $e2');
          // 备用方案：使用 flutter_local_notifications 的方法
          final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
              _notifications.resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>();
          // 请求通知权限（会弹出系统权限对话框）
          await androidImplementation?.requestNotificationsPermission();
        }
      }
    }
  }

  /// 检查通知权限状态
  Future<bool> checkNotificationPermission() async {
    if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      return await androidImplementation?.areNotificationsEnabled() ?? false;
    }
    return true;
  }
}
