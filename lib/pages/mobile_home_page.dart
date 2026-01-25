import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/message_service.dart';
import '../services/websocket_service.dart';
import '../services/agora_service.dart';
import '../services/local_database_service.dart';
import '../services/notification_service.dart';
import '../services/native_call_service.dart';
import '../services/native_message_service.dart';
import '../services/app_initialization_service.dart';
import '../services/image_preload_service.dart';
import '../services/background_service.dart';
import '../services/message_sync_service.dart';
import '../services/callkit_service.dart';
import '../services/tuicallkit_service.dart';
import '../config/feature_config.dart';
import '../config/api_config.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';
import '../utils/app_localizations.dart';
import 'permission_settings_page.dart';
import '../models/recent_contact_model.dart';
import '../models/contact_model.dart';
import '../models/message_model.dart';
import '../utils/mobile_permission_helper.dart';
import '../widgets/message_notification_popup.dart';
import 'mobile_chat_page.dart';
import 'mobile_contacts_page.dart';
import 'mobile_news_page.dart';
import 'mobile_create_group_page.dart';
import 'mobile_profile_page.dart';
import 'qr_scanner_page.dart';
import 'add_friend_from_qr_page.dart';
import 'join_group_from_qr_page.dart';
import 'call_page.dart';
import '../services/update_checker.dart';

/// 移动端主页
class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key});

  // 🔴 静态缓存变量（移到Widget类，便于外部访问）
  static List<RecentContactModel>? _cachedContacts;
  static DateTime? _cacheTimestamp;
  static Map<String, int>? _cachedPinnedChats;
  static Set<String>? _cachedDeletedChats;
  
  // 🔴 新增：静态已读状态缓存（即使页面重建也能保留已读状态）
  // key: "user_123" 或 "group_456"
  // 🔴 修改：现在会持久化到SharedPreferences，应用重启后也能保留
  static Set<String> _readStatusCache = {};
  static bool _readStatusCacheLoaded = false; // 标记是否已从Storage加载
  
  // 🔴 新增：未读数量缓存（key: "user_123" 或 "group_456", value: 未读数量）
  // 只有缓存中存在的会话才显示未读气泡
  static Map<String, int> _unreadCountCache = {};

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();

  /// 清除所有最近联系人和偏好设置缓存（公开静态方法，供登录后调用）
  static void clearAllCache() {
    _cachedContacts = null;
    _cacheTimestamp = null;
    _cachedPinnedChats = null;
    _cachedDeletedChats = null;
    _readStatusCache.clear(); // 🔴 同时清除已读状态缓存
    _readStatusCacheLoaded = false; // 重置加载标记
    _unreadCountCache.clear(); // 🔴 同时清除未读数量缓存
    // 🔴 同时清除持久化的已读状态缓存
    Storage.clearReadStatusCache();
    logger.info('🗑️ [MobileHomePage] 已清除所有最近联系人和偏好设置缓存');
  }
  
  /// 🔴 从Storage加载已读状态缓存（应用启动时调用）
  static Future<void> loadReadStatusCacheFromStorage() async {
    if (_readStatusCacheLoaded) {
      logger.debug('📖 [MobileHomePage] 已读缓存已加载过，跳过。当前缓存: ${_readStatusCache.length}条, keys: $_readStatusCache');
      return;
    }
    final cache = await Storage.loadReadStatusCache();
    _readStatusCache = cache;
    _readStatusCacheLoaded = true;
    logger.debug('📖 [MobileHomePage] 从Storage加载已读状态缓存: ${cache.length}条, keys: $cache');
  }
  
  /// 🔴 更新未读数量缓存
  static void updateUnreadCount(String key, int count) {
    if (count > 0) {
      _unreadCountCache[key] = count;
    } else {
      _unreadCountCache.remove(key);
    }
  }
  
  /// 🔴 获取缓存的未读数量（如果缓存中没有则返回0）
  static int getCachedUnreadCount(String key) {
    return _unreadCountCache[key] ?? 0;
  }
  
  /// 🔴 检查缓存中是否有该会话的未读数量
  static bool hasUnreadInCache(String key) {
    return _unreadCountCache.containsKey(key) && _unreadCountCache[key]! > 0;
  }

  /// 🔴 添加到已读状态缓存（同时持久化到Storage）
  static void addToReadStatusCache(String key) {
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('📖 [MobileHomePage.addToReadStatusCache] 开始添加: $key');
    final beforeCount = _readStatusCache.length;
    final beforeKeys = Set<String>.from(_readStatusCache);
    _readStatusCache.add(key);
    final afterCount = _readStatusCache.length;
    logger.debug('📖 [MobileHomePage.addToReadStatusCache] 内存缓存变化: $beforeCount -> $afterCount');
    logger.debug('📖 [MobileHomePage.addToReadStatusCache] 之前的keys: $beforeKeys');
    logger.debug('📖 [MobileHomePage.addToReadStatusCache] 之后的keys: $_readStatusCache');
    // 🔴 同时保存到Storage（异步，不阻塞）
    Storage.addToReadStatusCache(key).then((_) {
      logger.debug('📖 [MobileHomePage.addToReadStatusCache] Storage保存完成: $key');
      logger.debug('═══════════════════════════════════════════════════════════');
    }).catchError((e) {
      logger.debug('❌ [MobileHomePage.addToReadStatusCache] Storage保存失败: $key, error: $e');
    });
  }

  /// 🔴 检查会话是否在已读缓存中
  static bool isInReadStatusCache(String key) {
    final result = _readStatusCache.contains(key);
    return result;
  }

  /// 🔴 从已读状态缓存中移除
  static void removeFromReadStatusCache(String key) {
    _readStatusCache.remove(key);
  }

  /// 🔴 清除置顶聊天缓存（公开静态方法，供聊天页面调用）
  static void clearPinnedChatsCache() {
    _cachedPinnedChats = null;
  }
}

class _MobileHomePageState extends State<MobileHomePage>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final WebSocketService _wsService = WebSocketService();
  // 条件初始化 Agora 服务
  late final AgoraService? _agoraService = FeatureConfig.enableWebRTC
      ? AgoraService()
      : null;

  // 用户信息
  String _userDisplayName = '';
  String _username = '';
  String _userId = '';
  String? _userAvatar;
  String? _fullName;
  String? _gender;
  String? _phone;
  String? _email;
  String? _department;
  String? _position;
  String? _region;
  String? _workSignature;
  String? _inviteCode; // 邀请码
  String _userStatus = 'online';
  String? _token;

  // 页面控制器
  final PageController _pageController = PageController();

  // 🔴 网络连接状态
  bool _isConnecting = false; // 是否正在连接网络
  bool _isNetworkConnected = false; // 网络是否已连接
  
  // 首次同步数据状态
  bool _isSyncingData = false; // 是否正在同步数据
  String? _syncStatusMessage; // 同步状态消息
  Timer? _networkStatusTimer; // 网络状态监听定时器
  
  // 🔴 新增：重连同步防抖标志
  bool _isReconnectSyncing = false; // 是否正在执行重连同步
  DateTime? _lastReconnectSyncTime; // 上次重连同步时间

  // 聊天列表页面的 GlobalKey
  final GlobalKey<_MobileChatListPageState> _chatListKey = GlobalKey();

  // 通讯录待审核数量（新联系人 + 群通知）
  int _contactsPendingCount = 0;

  // WebSocket消息订阅
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  // 来电对话框状态
  bool _isShowingIncomingCallDialog = false;
  BuildContext? _incomingCallDialogContext; // 🔴 新增：保存来电对话框的 context
  AudioPlayer? _ringtonePlayer; // 来电铃声播放器
  Timer? _vibrationTimer; // 震动定时器

  // 通话状态相关
  bool _isInGroupCall = false; // 是否为群组通话
  int? _currentGroupCallId; // 当前群组通话的群组ID
  int? _currentCallUserId; // 当前通话的用户ID
  CallType? _currentCallType; // 当前通话类型
  bool _callEndedMessageSent = false; // 🔴 新增：标记通话结束消息是否已发送（防止重复发送）

  // 🔴 新增：通话悬浮按钮状态
  bool _showCallFloatingButton = false;
  int? _floatingCallUserId;
  String? _floatingCallDisplayName;
  CallType? _floatingCallType;
  bool _floatingIsGroupCall = false;
  int? _floatingGroupId;
  List<int>? _floatingGroupCallUserIds; // 群组通话成员ID列表
  List<String>? _floatingGroupCallDisplayNames; // 群组通话成员显示名称列表

  // 🔴 新增：通话连接中遮盖层状态
  bool _showConnectingOverlay = false; // 是否显示"正在连接中"遮盖层
  int? _connectingCallerId; // 正在连接的来电者ID
  String? _connectingCallerName; // 正在连接的来电者名称
  CallType? _connectingCallType; // 正在连接的通话类型

  // 动态生成页面列表
  List<Widget> get _pages => [
    MobileChatListPage(
      key: _chatListKey,
      onRefresh: _onRefresh, // 🔴 添加下拉刷新回调
      onChatSelected: (userId, displayName, isGroup,
          {int? groupId, String? avatar}) async {
        // 判断是否是文件传输助手（userId等于当前用户ID且不是群组）
        final currentUserId = await Storage.getUserId();
        final isFileAssistant = !isGroup && currentUserId != null && userId == currentUserId;
        
        final result = await Navigator.push<dynamic>(
          context,
          MaterialPageRoute(
            builder: (context) => MobileChatPage(
              userId: isGroup ? 0 : userId, // 群聊时userId设为0
              displayName: displayName,
              isGroup: isGroup,
              avatar: avatar,
              isFileAssistant: isFileAssistant, // 传递文件传输助手标识
              groupId:
                  groupId ??
                  (isGroup
                      ? userId
                      : null), // 如果是群组，使用传入的groupId或userId作为groupId
              onChatClosed: (int closedContactId, bool closedIsGroup) async {
                // 🔴 退出聊天页面时，只更新该会话的最新消息
                logger.debug('📤 聊天页面已关闭，更新单个会话: contactId=$closedContactId, isGroup=$closedIsGroup');
                await _updateSingleContact(closedContactId, closedIsGroup);
              },
              // 🔴 新增：免打扰状态变化回调
              onDoNotDisturbChanged: (int contactId, bool isGroup, bool doNotDisturb) {
                logger.debug('📥 收到免打扰状态变化通知 - contactId: $contactId, isGroup: $isGroup, doNotDisturb: $doNotDisturb');
                _chatListKey.currentState?._updateContactDoNotDisturb(contactId, isGroup, doNotDisturb);
              },
            ),
          ),
        );

        // 处理返回结果
        if (result is Map) {
          // 🔴 关键修复：处理聊天页面返回的通话状态
          final showFloatingButton = result['showFloatingButton'] as bool?;
          if (showFloatingButton == true) {
            logger.debug('📱 [HomePage] 聊天页面返回，需要显示悬浮按钮');

            // 从 AgoraService 获取最小化的通话信息
            if (_agoraService != null && _agoraService.isCallMinimized) {
              final floatingUserId = _agoraService.minimizedCallUserId;
              final floatingDisplayName =
                  _agoraService.minimizedCallDisplayName;
              final floatingCallType = _agoraService.minimizedCallType;

              logger.debug('📱 [HomePage] 从 AgoraService 获取最小化通话信息');
              logger.debug('  - userId: $floatingUserId');
              logger.debug('  - displayName: $floatingDisplayName');
              logger.debug('  - callType: $floatingCallType');

              if (mounted && floatingUserId != null && floatingUserId != 0) {
                setState(() {
                  _showCallFloatingButton = true;
                  _floatingCallUserId = floatingUserId;
                  _floatingCallDisplayName = floatingDisplayName ?? 'Unknown';
                  _floatingCallType = floatingCallType ?? CallType.voice;
                  _floatingIsGroupCall = _agoraService.minimizedIsGroupCall;
                  _floatingGroupId = _agoraService.minimizedGroupId;
                  _floatingGroupCallUserIds =
                      _agoraService.currentGroupCallUserIds;
                  _floatingGroupCallDisplayNames =
                      _agoraService.currentGroupCallDisplayNames;
                });
                logger.debug('📱 [HomePage] ✅ 主页面悬浮按钮已设置');
              }
            }
          }

          // 如果需要刷新，处理聊天页面返回的刷新需求
          final needRefresh = result['needRefresh'] as bool?;
          if (needRefresh == true) {
            final contactId = result['contactId'] as int?;
            final isGroup = result['isGroup'] as bool?;

            if (contactId != null && isGroup != null) {
              // 刷新特定联系人的未读数量
              _chatListKey.currentState?.refreshContactUnreadCount(
                contactId,
                isGroup,
              );
            } else {
              // 刷新整个聊天列表
              _chatListKey.currentState?.refresh();
            }
          }
        } else if (result is bool && result == true) {
          // 兼容旧的返回值格式
          _chatListKey.currentState?.refresh();
        }
      },
    ),
    MobileContactsPage(
      onPendingCountChanged: (count) {
        if (mounted) {
          setState(() {
            _contactsPendingCount = count;
          });
        }
      },
    ),
    const MobileNewsPage(),
    MobileProfilePage(
      userDisplayName: _userDisplayName,
      username: _username,
      userId: _userId,
      userAvatar: _userAvatar,
      fullName: _fullName,
      gender: _gender,
      phone: _phone,
      email: _email,
      department: _department,
      position: _position,
      region: _region,
      workSignature: _workSignature,
      inviteCode: _inviteCode, // 传递邀请码
      userStatus: _userStatus,
      token: _token,
      onUserInfoUpdate: _loadUserInfo,
      onChatListNeedRefresh: () {
        // 刷新聊天列表（文件传输助手创建占位消息后需要刷新）
        _chatListKey.currentState?.refresh();
      },
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 🔴 移除页面恢复功能，每次启动都默认显示"会话"页面
    // _restoreLastPageIndex();

    // 🔴 初始化后台服务（仅移动端）
    _initBackgroundService();

    // 初始化数据
    _initializeData();
  }

  // 🔴 初始化后台服务
  Future<void> _initBackgroundService() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final bgService = BackgroundServiceManager();
        await bgService.initialize();
        await bgService.startService();
        logger.debug('✅ [移动端] 后台服务已启动');
      } catch (e) {
        logger.error('❌ [移动端] 后台服务启动失败: $e');
      }
    }
  }

  // 恢复上次的页面索引
  Future<void> _restoreLastPageIndex() async {
    try {
      final userId = await Storage.getUserId();
      if (userId != null) {
        final lastRoute = await Storage.getLastPageRoute(userId);
        if (lastRoute != null) {
          int targetIndex = 0;
          // 将路由路径转换回页面索引
          if (lastRoute == '/home/chat') {
            targetIndex = 0;
          } else if (lastRoute == '/home/contacts') {
            targetIndex = 1;
          } else if (lastRoute == '/home/news') {
            targetIndex = 2;
          } else if (lastRoute == '/home/profile') {
            targetIndex = 3;
          }
          
          if (targetIndex != _currentIndex) {
            setState(() {
              _currentIndex = targetIndex;
            });
            // 使用jumpToPage而不是animateToPage，避免闪烁
            _pageController.jumpToPage(targetIndex);
            logger.debug('📍 已恢复上次页面: $lastRoute (索引: $targetIndex)');
          }
        }
      }
    } catch (e) {
      logger.debug('⚠️ 恢复页面索引失败: $e');
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _networkStatusTimer?.cancel(); // 🔴 取消网络状态监听定时器
    MessageSyncService().stopPeriodicSync(); // 🔴 停止消息同步服务
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // 停止响铃和震动
    _stopRingtone();
    // 不需要dispose Agora服务，因为它是单例
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // NotificationService 现在使用 WidgetsBindingObserver 自动监听生命周期

    if (state == AppLifecycleState.resumed) {
      // 🔴 应用恢复前台时立即检测连接状态并重连
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📱 [AppLifecycle] 应用恢复前台，检测WebSocket连接状态...');
      logger.debug('📱 [AppLifecycle] 当前内存已读缓存: ${MobileHomePage._readStatusCache.length}条, keys: ${MobileHomePage._readStatusCache}');
      
      // 🔴 关键修复：应用恢复前台时，强制从Storage重新加载已读缓存
      // 这样可以确保内存中的缓存与Storage同步
      _reloadReadStatusCacheFromStorage();
      
      if (!_wsService.isConnected) {
        // 连接已断开，立即重连
        logger.debug('🔄 [AppLifecycle] WebSocket已断开，立即尝试重连...');
        setState(() {
          _isConnecting = true;
        });
        
        _wsService.connect().then((connected) {
          if (connected) {
            _wsService.sendStatusChange('online');
            logger.debug('✅ [AppLifecycle] 重连成功，已发送在线状态');
            // 重连成功后会通过 onReconnected 回调自动同步数据
          } else {
            logger.debug('❌ [AppLifecycle] 重连失败');
            if (mounted) {
              setState(() {
                _isConnecting = false;
              });
            }
          }
        });
      } else {
        // 连接正常，发送在线状态
        _wsService.sendStatusChange('online');
        logger.debug('✅ 应用恢复前台，连接正常，已发送在线状态');
      }

      // 🔴 新增：检查是否有最小化的通话需要显示悬浮按钮
      if (_agoraService != null &&
          _agoraService.isCallMinimized &&
          !_showCallFloatingButton) {
        logger.debug('📱 [AppLifecycle] 应用恢复前台，检测到最小化通话');

        final minimizedUserId = _agoraService.minimizedCallUserId;
        if (minimizedUserId != null && minimizedUserId != 0) {
          setState(() {
            _showCallFloatingButton = true;
            _floatingCallUserId = minimizedUserId;
            _floatingCallDisplayName =
                _agoraService.minimizedCallDisplayName ?? 'Unknown';
            _floatingCallType =
                _agoraService.minimizedCallType ?? CallType.voice;
            _floatingIsGroupCall = _agoraService.minimizedIsGroupCall;
            _floatingGroupId = _agoraService.minimizedGroupId;
            _floatingGroupCallUserIds = _agoraService.currentGroupCallUserIds;
            _floatingGroupCallDisplayNames =
                _agoraService.currentGroupCallDisplayNames;
          });

          logger.debug('📱 [AppLifecycle] ✅ 悬浮按钮已显示');
        }
      }
    } else if (state == AppLifecycleState.paused || 
               state == AppLifecycleState.detached) {
      // 🔴 移除页面索引保存功能，每次启动都默认显示"会话"页面
      // _saveCurrentPageIndex();
      
      // 🔴 关键修复：应用进入后台时，强制保存已读缓存到Storage
      // 这样可以确保用户阅读过的消息在恢复前台后不会重新显示未读红点
      _saveReadStatusCacheToStorage();
      
      // 🔴 iOS 后台保持 WebSocket 连接，用于接收来电通知
      // WebSocket 在 iOS 后台仍然可以工作（心跳保持连接）
    }
  }

  // 保存当前页面索引
  Future<void> _saveCurrentPageIndex() async {
    try {
      final userId = await Storage.getUserId();
      if (userId != null) {
        // 将页面索引转换为路由路径
        String route = '/home'; // 默认主页
        switch (_currentIndex) {
          case 0:
            route = '/home/chat';
            break;
          case 1:
            route = '/home/contacts';
            break;
          case 2:
            route = '/home/news';
            break;
          case 3:
            route = '/home/profile';
            break;
        }
        await Storage.saveLastPageRoute(userId, route);
        logger.debug('📍 已保存当前页面索引: $_currentIndex -> $route');
      }
    } catch (e) {
      logger.debug('⚠️ 保存页面索引失败: $e');
    }
  }

  // 🔴 关键修复：保存已读缓存到Storage（应用进入后台时调用）
  Future<void> _saveReadStatusCacheToStorage() async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('💾 [AppLifecycle] 应用进入后台，开始保存已读缓存...');
      logger.debug('💾 [AppLifecycle] 当前内存已读缓存: ${MobileHomePage._readStatusCache.length}条, keys: ${MobileHomePage._readStatusCache}');
      if (MobileHomePage._readStatusCache.isNotEmpty) {
        await Storage.saveReadStatusCache(MobileHomePage._readStatusCache);
        logger.debug('💾 [AppLifecycle] 已保存已读缓存到Storage: ${MobileHomePage._readStatusCache.length}条, keys: ${MobileHomePage._readStatusCache}');
      } else {
        logger.debug('💾 [AppLifecycle] 已读缓存为空，跳过保存');
      }
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e) {
      logger.debug('⚠️ [AppLifecycle] 保存已读缓存失败: $e');
    }
  }

  // 🔴 关键修复：从Storage重新加载已读缓存（应用恢复前台时调用）
  Future<void> _reloadReadStatusCacheFromStorage() async {
    try {
      final cache = await Storage.loadReadStatusCache();
      logger.debug('📖 [AppLifecycle] 从Storage加载已读缓存: ${cache.length}条, keys: $cache');
      // 合并Storage中的缓存和内存中的缓存（取并集）
      final beforeCount = MobileHomePage._readStatusCache.length;
      MobileHomePage._readStatusCache.addAll(cache);
      MobileHomePage._readStatusCacheLoaded = true;
      logger.debug('📖 [AppLifecycle] 合并后内存已读缓存: ${MobileHomePage._readStatusCache.length}条 (之前: $beforeCount条), keys: ${MobileHomePage._readStatusCache}');
      logger.debug('═══════════════════════════════════════════════════════════');
    } catch (e) {
      logger.debug('⚠️ [AppLifecycle] 加载已读缓存失败: $e');
    }
  }

  Future<void> _initializeData() async {
    // 请求必要权限
    await MobilePermissionHelper.requestAllPermissions(context);

    // 加载用户信息
    await _loadUserInfo();

    // 🔴 执行应用初始化（首次安装时同步历史消息和收藏数据）
    logger.debug('🚀 MobileHomePage _initializeData - 开始执行应用初始化服务');
    await AppInitializationService().initialize(
      onSyncStatusChanged: (isSyncing, message) {
        if (mounted) {
          setState(() {
            _isSyncingData = isSyncing;
            _syncStatusMessage = message;
          });
          // 通知聊天列表页面更新同步状态
          _chatListKey.currentState?.updateSyncStatus(isSyncing, message);
        }
      },
    );
    logger.debug('✅ MobileHomePage _initializeData - 应用初始化服务完成');

    // 🔴 检查并显示全屏权限设置页面
    await _checkAndShowFullScreenPermissionSettings();
    
    // 🔴 检查并引导用户开启通知横幅权限（华为等手机需要）
    await _checkAndShowNotificationBannerGuide();

    // 🔴 初始化原生来电服务（Android）
    if (Platform.isAndroid) {
      await _initializeNativeCallService();
    }
    
    // 🔴 初始化 iOS CallKit 服务
    if (Platform.isIOS) {
      await _initializeCallKitService();
    }
    
    // 🔴 初始化原生消息弹窗服务（Android/iOS）
    if (Platform.isAndroid || Platform.isIOS) {
      _initializeNativeMessageService();
    }

    // 连接WebSocket
    await _connectWebSocket();

    // 🔴 启动消息同步服务（每5秒检查一次未同步的消息）
    final userId = await Storage.getUserId();
    if (userId != null && userId > 0) {
      MessageSyncService().startPeriodicSync(userId);
      logger.debug('✅ 消息同步服务已启动，用户ID: $userId');
    }

    // 等待一小段时间确保WebSocket连接完全建立
    await Future.delayed(const Duration(milliseconds: 500));

    // 初始化Agora服务（在WebSocket之后）
    await _initAgora();

    // 设置通知点击回调
    _setupNotificationHandler();

    // 开始监听WebSocket消息（必须在WebSocket连接后）
    _listenToWebSocketMessages();

    // 🔴 设置网络状态监听
    _setupNetworkStatusListener();
    
    // 🔴 检查初始连接状态，如果未连接且应用在前台则触发真正的刷新
    if (!_wsService.isConnected && NotificationService().isAppInForeground) {
      setState(() {
        _isConnecting = true;
      });
      logger.debug('🔄 [网络状态-会话] 应用启动时检测到未连接，显示正在刷新并触发重连...');
      // 🔴 关键修复：触发真正的刷新操作，而不仅仅是显示UI
      _performRealRefresh();
    }

    // 加载通讯录待审核数量
    await _loadContactsPendingCount();

    // 登录后检查更新（异步执行，不阻塞主流程）
    if (mounted) {
      UpdateChecker().reset(); // 重置检查状态，确保每次登录都检查
      UpdateChecker().checkAfterLogin(context);
    }
  }

  /// 初始化原生来电服务（Android）
  Future<void> _initializeNativeCallService() async {
    try {
      logger.debug('🔧 开始初始化原生来电服务...');
      
      // 检查通知权限
      final notificationPermission = await Permission.notification.status;
      logger.debug('📋 通知权限状态: $notificationPermission');
      
      final nativeCallService = NativeCallService();
      
      // 初始化并设置来电回调
      logger.debug('🔧 设置来电回调...');
      nativeCallService.initialize(
        onIncomingCall: (callData) async {
          logger.debug('═══════════════════════════════════════');
          logger.debug('📱 [MobileHomePage] 收到原生来电回调!');
          logger.debug('📱 原始数据: $callData');
          logger.debug('═══════════════════════════════════════');
          
          // 解析来电数据
          final callerName = callData['callerName'] as String?;
          final callerId = callData['callerId'] as int?;
          final callType = callData['callType'] as String?;
          final channelName = callData['channelName'] as String?;
          final isGroupCall = callData['isGroupCall'] as bool? ?? false;
          final isAnswered = callData['isAnswered'] as bool? ?? false; // 🔴 新增：是否已接听
          final groupId = callData['groupId'] as int?;
          final membersJson = callData['members'] as String?;
          
          logger.debug('📋 解析后的数据:');
          logger.debug('  - callerName: $callerName');
          logger.debug('  - callerId: $callerId');
          logger.debug('  - callType: $callType');
          logger.debug('  - channelName: $channelName');
          logger.debug('  - isGroupCall: $isGroupCall');
          logger.debug('  - isAnswered: $isAnswered'); // 🔴 新增日志
          logger.debug('  - groupId: $groupId');
          logger.debug('  - membersJson: $membersJson');
          
          if (callerName == null || callerId == null || callType == null || channelName == null) {
            logger.debug('❌ 来电数据不完整');
            return;
          }
          
          final type = callType == 'video' ? CallType.video : CallType.voice;
          
          // 显示 Flutter 来电页面
          if (mounted) {
            // 🔴 停止铃声
            _stopRingtone();
            
            // 🔴 关键修复：无论是否已在锁屏接听，都需要调用acceptCall来真正接听通话
            if (isAnswered) {
              logger.debug('🔑 用户已在锁屏时点击接听，现在真正接听通话');
            } else {
              logger.debug('🎯 用户从通知栏或应用内点击，准备接听通话');
            }
            
            // 真正接听通话（无论哪种情况都需要调用）
            if (FeatureConfig.enableWebRTC && _agoraService != null) {
              try {
                // 🔴 检查 AgoraService 是否处于 ringing 状态
                if (_agoraService.callState == CallState.ringing) {
                  await _agoraService.acceptCall();
                  logger.debug('✅ 通话已接听（从 ringing 状态）');
                } else {
                  logger.debug('⚠️ AgoraService 不在 ringing 状态: ${_agoraService.callState}');
                  logger.debug('📱 直接导航到通话页面，由通话页面处理接听');
                }
              } catch (e) {
                logger.debug('❌ 接听通话失败: $e');
              }
            }
            
            // 🔴 延迟一小段时间，确保页面准备就绪
            await Future.delayed(const Duration(milliseconds: 100));
            
            logger.debug('🔍 检查 mounted 状态: $mounted');
            if (!mounted) {
              logger.debug('❌ Widget 已销毁，无法导航');
              return;
            }
            
            if (isGroupCall && groupId != null && membersJson != null) {
              // 群组通话
              if (isAnswered) {
                logger.debug('🎯 打开群组通话页面（已接听，直接进入通话）...');
              } else {
                logger.debug('🎯 打开群组来电页面（等待接听）...');
              }
              logger.debug('🎯 检查 context: ${context != null}');
              
              try {
                // 解析成员列表JSON
                final membersData = (json.decode(membersJson) as List)
                    .map((e) => e as Map<String, dynamic>)
                    .toList();
                
                final memberUserIds = membersData.map((m) => m['user_id'] as int).toList();
                final memberDisplayNames = membersData.map((m) => m['display_name'] as String).toList();
                
                // 获取当前用户ID
                final currentUserId = _userId.isNotEmpty ? int.tryParse(_userId) : null;
                
                logger.debug('🎯 解析到 ${membersData.length} 个成员');
                logger.debug('🎯 成员ID: $memberUserIds');
                logger.debug('🎯 成员名称: $memberDisplayNames');
                logger.debug('🎯 当前用户ID: $currentUserId');
                logger.debug('🎯 准备导航到群组通话页面...');
                
                // 🔴 关键修复：如果已接听，设置 isIncoming=false，直接显示通话界面
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置5] 原生来电服务-群组通话 - 打开VoiceCallPage/GroupVideoCallPage');
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置5] callerId=$callerId, callerName=$callerName, type=$type, isAnswered=$isAnswered');
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => type == CallType.video
                        ? GroupVideoCallPage(
                            targetUserId: callerId,
                            targetDisplayName: callerName,
                            isIncoming: !isAnswered, // 已接听时不是来电
                            groupCallUserIds: memberUserIds,
                            groupCallDisplayNames: memberDisplayNames,
                            currentUserId: currentUserId,
                            groupId: groupId,
                          )
                        : VoiceCallPage(
                            targetUserId: callerId,
                            targetDisplayName: callerName,
                            callType: type,
                            isIncoming: !isAnswered, // 已接听时不是来电
                            groupCallUserIds: memberUserIds,
                            groupCallDisplayNames: memberDisplayNames,
                            currentUserId: currentUserId,
                            groupId: groupId,
                          ),
                  ),
                );
                logger.debug('🎯 群组通话页面已打开');
              } catch (e) {
                logger.debug('❌ 解析成员列表失败: $e');
                logger.debug('❌ 错误详情: ${e.toString()}');
                // 回退到单人通话
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置6] 原生来电服务-回退单人通话 - 打开VoiceCallPage');
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置6] callerId=$callerId, callerName=$callerName, type=$type');
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => VoiceCallPage(
                      targetUserId: callerId,
                      targetDisplayName: callerName,
                      callType: type,
                      isIncoming: !isAnswered, // 已接听时不是来电
                    ),
                  ),
                );
              }
            } else {
              // 单人通话
              if (isAnswered) {
                logger.debug('🎯 打开单人通话页面（已接听，直接进入通话）...');
              } else {
                logger.debug('🎯 打开单人来电页面（等待接听）...');
              }
              logger.debug('🔴🔴🔴 [VoiceCallPage-位置7] 原生来电服务-单人通话 - 打开VoiceCallPage');
              logger.debug('🔴🔴🔴 [VoiceCallPage-位置7] callerId=$callerId, callerName=$callerName, type=$type, isAnswered=$isAnswered');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => VoiceCallPage(
                    targetUserId: callerId,
                    targetDisplayName: callerName,
                    callType: type,
                    isIncoming: !isAnswered, // 已接听时不是来电
                  ),
                ),
              );
            }
          }
        },
        onCallRejected: (callerId, callType) async {
          logger.debug('═══════════════════════════════════════');
          logger.debug('❌ [MobileHomePage] 收到拒绝通话回调!');
          logger.debug('❌ callerId: $callerId');
          logger.debug('❌ callType: $callType');
          logger.debug('═══════════════════════════════════════');
          
          // 🔴 停止铃声（用户已拒绝）
          _stopRingtone();
          
          // 调用 AgoraService 拒绝通话
          if (FeatureConfig.enableWebRTC && _agoraService != null) {
            try {
              await _agoraService.rejectCall();
              logger.debug('✅ AgoraService.rejectCall() 调用成功');
            } catch (e) {
              logger.debug('❌ AgoraService.rejectCall() 调用失败: $e');
            }
          }
          
          // 发送拒绝消息到服务器
          try {
            final token = await Storage.getToken();
            if (token == null || token.isEmpty) {
              logger.debug('❌ Token为空，无法发送拒绝消息');
              return;
            }
            
            final type = callType == 'video' ? CallType.video : CallType.voice;
            final messageType = type == CallType.video ? 'call_rejected_video' : 'call_rejected';
            
            logger.debug('📤 准备发送拒绝消息:');
            logger.debug('   - receiverId: $callerId');
            logger.debug('   - messageType: $messageType');
            logger.debug('   - callType: $callType');
            
            // 通过 WebSocket 发送拒绝消息
            final success = await _wsService.sendMessage(
              receiverId: callerId,
              content: '已拒绝',
              messageType: messageType,
              callType: callType,
            );
            
            if (success) {
              logger.debug('✅ 拒绝消息已发送');
            } else {
              logger.debug('❌ 拒绝消息发送失败');
            }
          } catch (e) {
            logger.debug('❌ 发送拒绝消息异常: $e');
          }
        },
        onStopAudio: () {
          // 🔴 新增：接收来自原生端的停止音频广播（锁屏拒绝/接听时）
          logger.debug('═══════════════════════════════════════');
          logger.debug('🔇 [MobileHomePage] 收到停止音频回调（锁屏操作）');
          logger.debug('═══════════════════════════════════════');
          
          // 停止播放铃声
          _stopRingtone();
        },
      );
      
      logger.debug('✅ 原生来电服务已初始化');
      
      // 🔴 不再启动持久的前台服务，只在真正有来电时才启动
      logger.debug('ℹ️ 前台服务将在收到来电时自动启动');
    } catch (e) {
      logger.debug('❌ 初始化原生来电服务失败: $e');
    }
  }

  /// 初始化 iOS CallKit 服务
  Future<void> _initializeCallKitService() async {
    try {
      logger.debug('🔧 [iOS] 开始初始化 CallKit 服务...');
      
      final callKitService = CallKitService();
      await callKitService.initialize();
      
      // 设置 CallKit 回调
      callKitService.onCallAccepted = (callInfo) async {
        logger.debug('╔═══════════════════════════════════════════════════════════════╗');
        logger.debug('║ 📱 [CallKit-onCallAccepted] 开始处理用户接听来电              ║');
        logger.debug('╚═══════════════════════════════════════════════════════════════╝');
        logger.debug('📱 [CallKit-onCallAccepted] 通话信息: $callInfo');
        logger.debug('📱 [CallKit-onCallAccepted] mounted: $mounted');
        logger.debug('📱 [CallKit-onCallAccepted] 当前生命周期状态: ${WidgetsBinding.instance.lifecycleState}');
        
        // 停止铃声
        _stopRingtone();
        logger.debug('📱 [CallKit-onCallAccepted] 铃声已停止');
        
        // 解析通话信息
        final callerId = callInfo['caller_id'] as int?;
        final callerName = callInfo['caller_name'] as String?;
        final callType = callInfo['call_type'] as String?;
        final channelName = callInfo['channel_name'] as String?;
        final token = callInfo['token'] as String?;
        final isGroupCall = callInfo['is_group_call'] as bool? ?? false;
        final groupId = callInfo['group_id'] as int?;
        
        logger.debug('📱 [CallKit-onCallAccepted] 解析后的数据:');
        logger.debug('   - callerId: $callerId');
        logger.debug('   - callerName: $callerName');
        logger.debug('   - callType: $callType');
        logger.debug('   - channelName: $channelName');
        logger.debug('   - isGroupCall: $isGroupCall');
        logger.debug('   - groupId: $groupId');
        
        if (callerId == null || callerName == null) {
          logger.debug('❌ [CallKit-onCallAccepted] 通话信息不完整，退出');
          return;
        }
        
        // 接听通话
        if (FeatureConfig.enableWebRTC && _agoraService != null) {
          logger.debug('📱 [CallKit-onCallAccepted] 开始调用 _agoraService.acceptCall()...');
          logger.debug('📱 [CallKit-onCallAccepted] AgoraService 当前状态: ${_agoraService.callState}');
          
          await _agoraService.acceptCall();
          
          logger.debug('✅ [CallKit-onCallAccepted] _agoraService.acceptCall() 完成');
          logger.debug('📱 [CallKit-onCallAccepted] AgoraService 接听后状态: ${_agoraService.callState}');
          
          // 🔴 修改：等待应用恢复前台，但同时检查通话状态
          // 如果通话已结束，则不再打开通话页面
          logger.debug('📱 [CallKit-onCallAccepted] 开始等待应用恢复前台...');
          int waitCount = 0;
          bool callStillActive = true;
          while (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed && waitCount < 30) {
            await Future.delayed(const Duration(milliseconds: 100));
            waitCount++;
            
            // 🔴 检查通话是否还在进行中
            if (_agoraService.callState == CallState.ended || _agoraService.callState == CallState.idle) {
              logger.debug('📱 [CallKit-onCallAccepted] ⚠️ 通话已结束，停止等待');
              callStillActive = false;
              break;
            }
            
            if (waitCount % 5 == 0) {
              logger.debug('📱 [CallKit-onCallAccepted] 等待应用恢复前台... ($waitCount) 当前状态: ${WidgetsBinding.instance.lifecycleState}, 通话状态: ${_agoraService.callState}');
            }
          }
          logger.debug('📱 [CallKit-onCallAccepted] 等待结束，应用状态: ${WidgetsBinding.instance.lifecycleState}，等待次数: $waitCount, 通话仍活跃: $callStillActive');
          
          // 🔴 如果通话已结束，不再打开通话页面
          if (!callStillActive) {
            logger.debug('📱 [CallKit-onCallAccepted] 通话已结束，不打开通话页面');
            // 刷新聊天列表
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _chatListKey.currentState?.refresh();
                  setState(() {});
                }
              });
            }
            return;
          }
          
          // 🔴 额外等待确保UI完全就绪（缩短等待时间）
          logger.debug('📱 [CallKit-onCallAccepted] 额外等待 200ms 确保 UI 就绪...');
          await Future.delayed(const Duration(milliseconds: 200));
          logger.debug('📱 [CallKit-onCallAccepted] 额外等待完成');
          
          // 🔴 再次检查通话状态
          if (_agoraService.callState == CallState.ended || _agoraService.callState == CallState.idle) {
            logger.debug('📱 [CallKit-onCallAccepted] ⚠️ 额外等待后通话已结束，不打开通话页面');
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _chatListKey.currentState?.refresh();
                  setState(() {});
                }
              });
            }
            return;
          }
          
          // 打开通话页面
          logger.debug('📱 [CallKit-onCallAccepted] 检查 mounted: $mounted');
          if (mounted) {
            final type = callType == 'video' ? CallType.video : CallType.voice;
            
            logger.debug('📱 [CallKit-onCallAccepted] 准备打开 Flutter 通话页面...');
            logger.debug('📱 [CallKit-onCallAccepted] 通话类型: $type');
            logger.debug('📱 [CallKit-onCallAccepted] 当前通话状态: ${_agoraService.callState}');
            
            // 🔴 最后一次检查通话状态
            if (_agoraService.callState == CallState.ended || _agoraService.callState == CallState.idle) {
              logger.debug('📱 [CallKit-onCallAccepted] ⚠️ 打开页面前通话已结束，不打开通话页面');
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _chatListKey.currentState?.refresh();
                  setState(() {});
                }
              });
              return;
            }
            
            // 🔴 关键修复：使用 pushReplacement 或��保导航上下文有效
            // 先检查当前导航状态
            logger.debug('📱 [CallKit-onCallAccepted] 获取 Navigator...');
            final navigator = Navigator.of(context);
            logger.debug('📱 [CallKit-onCallAccepted] Navigator 获取成功');
            
            try {
              logger.debug('╔═══════════════════════════════════════════════════════════════╗');
              logger.debug('║ 📱 [CallKit-onCallAccepted] 开始 Navigator.push VoiceCallPage ║');
              logger.debug('╚═══════════════════════════════════════════════════════════════╝');
              
              logger.debug('🔴🔴🔴 [VoiceCallPage-位置4] CallKit-onCallAccepted - 打开VoiceCallPage');
              logger.debug('🔴🔴🔴 [VoiceCallPage-位置4] callerId=$callerId, callerName=$callerName, type=$type, isGroupCall=$isGroupCall');
              final result = await navigator.push(
                MaterialPageRoute(
                  builder: (context) {
                    logger.debug('📱 [CallKit-onCallAccepted] MaterialPageRoute builder 被调用');
                    return VoiceCallPage(
                      targetUserId: callerId,
                      targetDisplayName: callerName,
                      callType: type,
                      isIncoming: false, // 已接听，不是来电状态
                      groupId: isGroupCall ? groupId : null,
                    );
                  },
                ),
              );
              
              logger.debug('╔═══════════════════════════════════════════════════════════════╗');
              logger.debug('║ 📱 [CallKit-onCallAccepted] Navigator.push 返回了！           ║');
              logger.debug('╚═══════════════════════════════════════════════════════════════╝');
              logger.debug('📱 [CallKit-onCallAccepted] VoiceCallPage 返回结果: $result');
              logger.debug('📱 [CallKit-onCallAccepted] 返回后 mounted: $mounted');
              logger.debug('📱 [CallKit-onCallAccepted] 返回后生命周期状态: ${WidgetsBinding.instance.lifecycleState}');
              
              // 🔴 通话页面关闭后，确保主页面刷新
              if (mounted) {
                logger.debug('📱 [CallKit-onCallAccepted] 通话结束，准备刷新主页面状态...');
                // 🔴 使用 WidgetsBinding 确保在下一帧刷新，避免导航冲突
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  logger.debug('📱 [CallKit-onCallAccepted] PostFrameCallback 执行中...');
                  if (mounted) {
                    logger.debug('📱 [CallKit-onCallAccepted] 调用 _chatListKey.currentState?.refresh()');
                    _chatListKey.currentState?.refresh();
                    logger.debug('📱 [CallKit-onCallAccepted] 调用 setState()');
                    setState(() {});
                    logger.debug('📱 [CallKit-onCallAccepted] 刷新完成');
                  } else {
                    logger.debug('📱 [CallKit-onCallAccepted] PostFrameCallback 中 mounted=false，跳过刷新');
                  }
                });
                logger.debug('📱 [CallKit-onCallAccepted] PostFrameCallback 已注册');
              } else {
                logger.debug('📱 [CallKit-onCallAccepted] mounted=false，跳过刷新');
              }
              
              logger.debug('╔═══════════════════════════════════════════════════════════════╗');
              logger.debug('║ 📱 [CallKit-onCallAccepted] 处理完成                          ║');
              logger.debug('╚═══════════════════════════════════════════════════════════════╝');
              
            } catch (e, stackTrace) {
              logger.debug('❌ [CallKit-onCallAccepted] 导航到 VoiceCallPage 失败: $e');
              logger.debug('❌ [CallKit-onCallAccepted] 堆栈跟踪: $stackTrace');
              // 🔴 如果导航失败，尝试恢复状态
              if (mounted) {
                logger.debug('📱 [CallKit-onCallAccepted] 尝试恢复状态...');
                setState(() {});
              }
            }
          } else {
            logger.debug('❌ [CallKit-onCallAccepted] mounted=false，无法打开通话页面');
          }
        } else {
          logger.debug('❌ [CallKit-onCallAccepted] WebRTC 未启用或 AgoraService 为 null');
        }
      };
      
      callKitService.onCallRejected = (callInfo) async {
        logger.debug('═══════════════════════════════════════');
        logger.debug('📱 [CallKit] 用户拒绝来电!');
        logger.debug('📱 通话信息: $callInfo');
        logger.debug('═══════════════════════════════════════');
        
        // 停止铃声
        _stopRingtone();
        
        // 解析通话信息
        final callerId = callInfo['caller_id'] as int?;
        final callType = callInfo['call_type'] as String?;
        
        // 拒绝通话
        if (FeatureConfig.enableWebRTC && _agoraService != null) {
          await _agoraService.rejectCall();
          logger.debug('✅ [CallKit] 通话已拒绝');
        }
        
        // 发送拒绝消息
        if (callerId != null) {
          final type = callType == 'video' ? CallType.video : CallType.voice;
          await _sendCallRejectedMessage(callerId, type);
        }
        
        // 重置来电状态
        setState(() {
          _isShowingIncomingCallDialog = false;
        });
      };
      
      // 🔴 新增：处理通话结束（用户通过 CallKit 挂断已接听的通话）
      // 注意：由于我们在接听时立即关闭了 CallKit，这个回调通常不会被触发
      // 但为了安全起见，我们仍然保留这个处理逻辑
      callKitService.onCallEnded = (callInfo) async {
        logger.debug('╔═══════════════════════════════════════════════════════════════╗');
        logger.debug('║ 📱 [CallKit-onCallEnded] 收到通话结束回调                      ║');
        logger.debug('╚═══════════════════════════════════════════════════════════════╝');
        logger.debug('📱 [CallKit-onCallEnded] 通话信息: $callInfo');
        logger.debug('📱 [CallKit-onCallEnded] mounted: $mounted');
        logger.debug('📱 [CallKit-onCallEnded] 当前生命周期状态: ${WidgetsBinding.instance.lifecycleState}');
        
        // 结束 Agora 通话
        if (FeatureConfig.enableWebRTC && _agoraService != null) {
          logger.debug('📱 [CallKit-onCallEnded] AgoraService 当前状态: ${_agoraService.callState}');
          
          // 🔴 只有在通话还在进行中时才结束
          if (_agoraService.callState == CallState.connected || 
              _agoraService.callState == CallState.calling ||
              _agoraService.callState == CallState.ringing) {
            logger.debug('📱 [CallKit-onCallEnded] 通话进行中，调用 endCall...');
            await _agoraService.endCall(isLocalHangup: true);
            logger.debug('✅ [CallKit-onCallEnded] Agora 通话已结束');
          } else {
            logger.debug('📱 [CallKit-onCallEnded] 通话已经结束 (状态: ${_agoraService.callState})，跳过 endCall');
          }
        } else {
          logger.debug('📱 [CallKit-onCallEnded] WebRTC 未启用或 AgoraService 为 null');
        }
        
        // 🔴 刷新主页面状态（不再强制 popUntil，因为 VoiceCallPage 会自己 pop）
        if (mounted) {
          logger.debug('📱 [CallKit-onCallEnded] 注册 PostFrameCallback 刷新状态...');
          // 使用 WidgetsBinding 确保在下一帧刷新，避免导航冲突
          WidgetsBinding.instance.addPostFrameCallback((_) {
            logger.debug('📱 [CallKit-onCallEnded] PostFrameCallback 执行中...');
            if (mounted) {
              setState(() {
                _isShowingIncomingCallDialog = false;
              });
              _chatListKey.currentState?.refresh();
              logger.debug('📱 [CallKit-onCallEnded] 主页面状态已刷新');
            } else {
              logger.debug('📱 [CallKit-onCallEnded] PostFrameCallback 中 mounted=false');
            }
          });
        } else {
          logger.debug('📱 [CallKit-onCallEnded] mounted=false，跳过刷新');
        }
        
        logger.debug('╔═══════════════════════════════════════════════════════════════╗');
        logger.debug('║ 📱 [CallKit-onCallEnded] 处理完成                              ║');
        logger.debug('╚═══════════════════════════════════════════════════════════════╝');
      };
      
      logger.debug('✅ [iOS] CallKit 服务已初始化');
    } catch (e) {
      logger.debug('❌ [iOS] 初始化 CallKit 服务失败: $e');
    }
  }

  /// 初始化原生消息弹窗服务（Android/iOS）
  void _initializeNativeMessageService() {
    try {
      logger.debug('🔧 开始初始化原生消息弹窗服务...');
      
      final nativeMessageService = NativeMessageService();
      
      nativeMessageService.initialize(
        onMessageTapped: (messageData) async {
          logger.debug('═══════════════════════════════════════');
          logger.debug('📨 [MobileHomePage] 收到消息点击回调!');
          logger.debug('📨 原始数据: $messageData');
          logger.debug('═══════════════════════════════════════');
          
          // 解析消息数据
          final senderId = messageData['senderId'] as int?;
          final senderName = messageData['senderName'] as String?;
          final isGroupMessage = messageData['isGroupMessage'] as bool? ?? false;
          final groupId = messageData['groupId'] as int?;
          final groupName = messageData['groupName'] as String?;
          
          if (senderId == null) {
            logger.debug('❌ 消息数据不完整');
            return;
          }
          
          if (!mounted) {
            logger.debug('❌ Widget 已销毁，无法导航');
            return;
          }
          
          // 导航到聊天页面
          if (isGroupMessage && groupId != null) {
            // 群组聊天
            logger.debug('🎯 打开群组聊天页面: $groupName ($groupId)');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MobileChatPage(
                  userId: senderId,
                  displayName: groupName ?? '群聊',
                  isGroup: true,
                  groupId: groupId,
                ),
              ),
            );
          } else {
            // 私聊
            logger.debug('🎯 打开私聊页面: $senderName ($senderId)');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MobileChatPage(
                  userId: senderId,
                  displayName: senderName ?? '未知用户',
                  isGroup: false,
                ),
              ),
            );
          }
        },
      );
      
      logger.debug('✅ 原生消息弹窗服务已初始化');
    } catch (e) {
      logger.debug('❌ 初始化原生消息弹窗服务失败: $e');
    }
  }

  // 设置通知点击处理
  void _setupNotificationHandler() {
    NotificationService.instance.onNotificationTap = (payload) {
      if (payload == null) return;

      logger.debug('🔔 用户点击通知: $payload');

      // 解析payload: 格式为 "private:userId" 或 "group:groupId"
      final parts = payload.split(':');
      if (parts.length != 2) return;

      final type = parts[0];
      final id = int.tryParse(parts[1]);
      if (id == null) return;

      // 导航到聊天页面
      if (type == 'private') {
        // 私聊
        _navigateToChatFromNotification(id, isGroup: false);
      } else if (type == 'group') {
        // 群聊
        _navigateToChatFromNotification(id, isGroup: true);
      }
    };
  }

  /// 检查并显示全屏权限设置页面
  Future<void> _checkAndShowFullScreenPermissionSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 检查是否已经显示过权限设置页面
      final hasShownSettings = prefs.getBool('fullscreen_permission_settings_shown') ?? false;
      
      if (!hasShownSettings) {
        // 标记已显示过权限设置
        await prefs.setBool('fullscreen_permission_settings_shown', true);
        
        // 显示全屏权限设置页面
        _showFullScreenPermissionSettings();
      }
    } catch (e) {
      logger.debug('检查全屏权限设置状态失败: $e');
    }
  }
  
  /// 🔴 检查并引导用户开启通知横幅权限（华为等手机需要手动开启）
  Future<void> _checkAndShowNotificationBannerGuide() async {
    // 仅Android需要此引导
    if (!Platform.isAndroid) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      // 检查是否已经显示过通知横幅引导
      final hasShownGuide = prefs.getBool('notification_banner_guide_shown') ?? false;
      
      if (!hasShownGuide) {
        // 标记已显示过引导
        await prefs.setBool('notification_banner_guide_shown', true);
        
        // 延迟一下再显示，避免与其他对话框冲突
        await Future.delayed(const Duration(milliseconds: 500));
        
        if (mounted) {
          _showNotificationBannerGuideDialog();
        }
      }
    } catch (e) {
      logger.debug('检查通知横幅引导状态失败: $e');
    }
  }
  
  /// 🔴 显示通知横幅权限引导对话框
  void _showNotificationBannerGuideDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.notifications_active, color: Theme.of(context).primaryColor),
              const SizedBox(width: 8),
              const Text('开启消息横幅通知'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '为了在收到新消息时能像微信一样在屏幕顶部显示弹窗提醒，请开启通知横幅权限：',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text('1', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('点击下方"去设置"按钮', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text('2', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('找到"消息通知"渠道', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text('3', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('开启"横幅"或"悬浮通知"', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('稍后设置'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                // 打开应用通知设置页面
                await NotificationService.instance.openNotificationSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
  }

  /// 显示全屏权限设置页面
  void _showFullScreenPermissionSettings() {
    if (!mounted) return;
    
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PermissionSettingsPage(),
        fullscreenDialog: true,
      ),
    );
  }

  /// 检查并显示权限设置页面
  Future<void> _checkAndShowPermissionSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 检查是否已经显示过权限设置页面
      final hasShownSettings = prefs.getBool('permission_settings_shown') ?? false;
      
      if (!hasShownSettings) {
        // 标记已显示过权限设置
        await prefs.setBool('permission_settings_shown', true);
        
        // 显示权限设置页面
        _showPermissionSettingsDialog();
      }
    } catch (e) {
      logger.debug('检查权限设置状态失败: $e');
    }
  }

  /// 检查系统弹窗权限
  Future<void> _checkSystemAlertWindowPermission() async {
    try {
      logger.debug('🔍 检查系统弹窗权限...');
      final systemAlertPermission = await Permission.systemAlertWindow.status;
      logger.debug('📋 系统弹窗权限状态: $systemAlertPermission');
      
      if (!systemAlertPermission.isGranted) {
        logger.debug('⚠️ 系统弹窗权限未授予，显示引导对话框');
        // 显示权限引导对话框
        _showSystemAlertWindowGuideDialog();
      } else {
        logger.debug('✅ 系统弹窗权限已授予');
        // 检查是否首次启动，如果是则显示后台弹窗权限引导
        await _checkAndShowBackgroundPopupGuide();
      }
    } catch (e) {
      logger.debug('❌ 检查系统弹窗权限失败: $e');
    }
  }

  /// 显示权限设置对话框
  void _showPermissionSettingsDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('权限设置'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '为了正常使用来电功能，请开启以下权限：',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 20),
                  _PermissionSettingItem(
                    title: '在其他应用上层显示',
                    description: '允许应用在其他应用上方显示来电弹窗',
                    permission: Permission.systemAlertWindow,
                    onChanged: (value) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  _PermissionSettingItem(
                    title: '通知权限',
                    description: '允许应用发送来电通知',
                    permission: Permission.notification,
                    onChanged: (value) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  // 🔴 新增：后台活动设置项
                  if (Platform.isAndroid)
                    _BackgroundActivitySettingItem(
                      onChanged: (value) {
                        setState(() {});
                      },
                    ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '💡 提示',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.blue,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '部分设备还需要在系统设置中手动开启"后台弹窗"权限',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('稍后设置'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    // 显示后台弹窗权限引导
                    _showBackgroundPopupGuide();
                  },
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 显示系统弹窗权限引导对话框
  void _showSystemAlertWindowGuideDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('权限设置'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('为了正常接收来电通知，需要开启以下权限：'),
              SizedBox(height: 12),
              Text('• 在其他应用上层显示'),
              Text('• 后台弹窗'),
              Text('• 通知权限'),
              SizedBox(height: 12),
              Text('点击"去设置"按钮，在应用权限管理中开启这些权限。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('稍后设置'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // 请求系统弹窗权限
                final result = await Permission.systemAlertWindow.request();
                if (result.isGranted) {
                  // 权限授予后显示后台弹窗引导
                  await _checkAndShowBackgroundPopupGuide();
                } else {
                  // 权限被拒绝，跳转到设置页面
                  openAppSettings();
                }
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
  }

  /// 显示权限设置引导对话框
  void _showPermissionGuideDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('权限设置'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('为了正常接收来电通知，请开启以下权限：'),
              SizedBox(height: 12),
              Text('1. 在其他应用上层显示'),
              Text('2. 后台弹窗'),
              Text('3. 通知权限'),
              SizedBox(height: 12),
              Text('点击"去设置"按钮，在应用权限管理中开启这些权限。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('稍后设置'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
  }

  /// 检查并显示后台弹窗权限引导
  Future<void> _checkAndShowBackgroundPopupGuide() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 检查是否已经显示过引导
      final hasShownGuide = prefs.getBool('background_popup_guide_shown') ?? false;
      
      if (!hasShownGuide) {
        // 标记已显示过引导
        await prefs.setBool('background_popup_guide_shown', true);
        
        // 显示引导
        _showBackgroundPopupGuide();
      }
    } catch (e) {
      logger.debug('检查后台弹窗引导状态失败: $e');
    }
  }

  /// 显示后台弹窗权限引导
  void _showBackgroundPopupGuide() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('重要提示'),
          content: const SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '为确保来电弹窗正常显示，请按以下步骤设置：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                Text(
                  '华为设备：',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue),
                ),
                Text('• 设置 → 应用和服务 → 应用管理'),
                Text('• 找到本应用 → 权限'),
                Text('• 开启"后台弹窗"权限'),
                SizedBox(height: 8),
                Text(
                  '小米设备：',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.orange),
                ),
                Text('• 设置 → 应用设置 → 应用管理'),
                Text('• 找到本应用 → 其他权限'),
                Text('• 开启"后台弹出界面"'),
                SizedBox(height: 8),
                Text(
                  'OPPO/Vivo设备：',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.green),
                ),
                Text('• 设置 → 应用管理'),
                Text('• 找到本应用 → 权限'),
                Text('• 开启"悬浮窗"和"后台启动"'),
                SizedBox(height: 12),
                Text(
                  '注意：不同设备的设置路径可能略有差异',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('我知道了'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
  }

  // 从通知点击导航到聊天页面
  Future<void> _navigateToChatFromNotification(
    int id, {
    required bool isGroup,
  }) async {
    try {
      // 切换到聊天列表页面
      setState(() {
        _currentIndex = 0;
      });
      _pageController.jumpToPage(0);

      // 等待页面切换完成
      await Future.delayed(const Duration(milliseconds: 100));

      // 获取联系人或群组信息
      if (isGroup) {
        // 群聊：获取群组详情
        final token = await Storage.getToken() ?? '';
        final response = await ApiService.getGroupDetail(
          token: token,
          groupId: id,
        );

        // 解析群组信息
        final groupData = response['data'] as Map<String, dynamic>?;
        final groupInfo = groupData?['group'] as Map<String, dynamic>?;
        final groupName = groupInfo?['name'] as String? ?? '群聊 $id';

        // 导航到群聊页面
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MobileChatPage(
                userId: id,
                displayName: groupName,
                isGroup: true,
                groupId: id,
                onChatClosed: (int closedContactId, bool closedIsGroup) async {
                  // 🔴 退出聊天页面时，只更新该会话的最新消息
                  logger.debug('📤 聊天页面已关闭，更新单个会话: contactId=$closedContactId, isGroup=$closedIsGroup');
                  await _updateSingleContact(closedContactId, closedIsGroup);
                },
              ),
            ),
          );
        }
      } else {
        // 🔴 修改：私聊 - 从本地数据库获取联系人信息
        final currentUserId = await Storage.getUserId();
        if (currentUserId == null) {
          logger.error('无法获取当前用户ID');
          return;
        }

        // 从本地数据库的联系人快照中获取联系人信息
        final snapshot = await LocalDatabaseService().getContactSnapshot(
          ownerId: currentUserId,
          contactId: id,
          contactType: 'user',
        );

        String displayName = '用户 $id';
        if (snapshot != null) {
          displayName = snapshot['full_name']?.toString() ??
              snapshot['username']?.toString() ??
              '用户 $id';
        }

        // 导航到私聊页面
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MobileChatPage(
                userId: id,
                displayName: displayName,
                isGroup: false,
                onChatClosed: (int closedContactId, bool closedIsGroup) async {
                  // 🔴 退出聊天页面时，只更新该会话的最新消息
                  logger.debug('📤 聊天页面已关闭，更新单个会话: contactId=$closedContactId, isGroup=$closedIsGroup');
                  await _updateSingleContact(closedContactId, closedIsGroup);
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      logger.error('🔔 从通知导航到聊天页面失败: $e');
    }
  }

  // 监听WebSocket消息
  void _listenToWebSocketMessages() {
    _messageSubscription?.cancel();

    logger.debug('📱 移动端主页开始监听WebSocket消息');

    _messageSubscription = _wsService.messageStream.listen(
      (data) {
        final type = data['type'] as String?;

        switch (type) {
          case 'contact_request':
            // 收到好友请求通知
            logger.debug('🔔 收到好友请求通知，准备处理');
            unawaited(_handleContactRequest(data['data']));
            break;
          case 'contact_status_changed':
            // 收到联系人状态变更通知（审核通过/拒绝）
            logger.debug('🔔 收到联系人状态变更通知，准备处理');
            unawaited(_handleContactStatusChanged(data['data']));
            break;
          case 'pending_group_member':
            // 收到待审核群成员通知
            logger.debug('🔔 收到待审核群成员通知，准备处理');
            unawaited(_handlePendingGroupMemberNotification(data['data']));
            break;
          case 'message':
            // 🔴 处理私聊消息：通话结束 + 会话恢复
            _handleMessageForCallEnd(data['data']);
            // 🔴 同时检查并恢复已删除的会话（如好友请求通过等场景）
            unawaited(_checkAndRestoreDeletedChatFromMessage(data['data']));
            break;
          case 'avatar_updated':
            // 处理头像更新通知
            logger.debug('🔔 收到头像更新通知，准备处理');
            _handleAvatarUpdated(data['data']);
            break;
          case 'group_nickname_updated':
            // 处理群组昵称更新通知
            logger.debug('👤 收到群组昵称更新通知，准备处理');
            _handleGroupNicknameUpdated(data['data']);
            break;
          case 'group_info_updated':
            // 处理群组信息更新通知（包括群组头像、名称等）
            logger.debug('📢 收到群组信息更新通知，准备处理');
            _handleGroupInfoUpdated(data['data']);
            break;
          case 'contact_blocked':
            // 收到被拉黑通知
            logger.debug('🚫 收到被拉黑通知，准备处理');
            _handleContactBlocked(data['data']);
            break;
          case 'contact_deleted':
            // 收到被删除通知
            logger.debug('🗑️ 收到被删除通知，准备处理');
            _handleContactDeleted(data['data']);
            break;
          case 'contact_unblocked':
            // 收到被恢复通知
            logger.debug('✅ 收到被恢复通知，准备处理');
            _handleContactUnblocked(data['data']);
            break;
          case 'message_recalled':
            // 🔴 收到消息撤回通知，更新本地数据库
            logger.debug('↩️ 收到消息撤回通知，准备更新本地数据库');
            unawaited(_handleMessageRecalled(data['data']));
            break;
          case 'clear_chat_history':
            // 🔴 收到清空聊天历史通知（好友审核通过/驳回时触发）
            logger.debug('🗑️ 收到清空聊天历史通知，准备刷新会话列表');
            unawaited(_handleClearChatHistoryForList(data['data']));
            break;
          case 'group_message':
            // 处理群组消息（检测群组创建/邀请，刷新通讯录）
            logger.debug('📱 收到群组消息，检测是否需要刷新通讯录');
            _handleGroupMessageForRefresh(data['data']);
            // 🔴 同时检查并恢复已删除的群聊会话
            unawaited(_checkAndRestoreDeletedGroupChatFromMessage(data['data']));
            break;
          default:
            // 其他消息类型（如 typing_indicator 等）
            // 由各自的页面处理，这里不做任何操作
            break;
        }
      },
      onError: (error) {
        logger.error('❌ WebSocket消息流错误: $error');
      },
    );

    logger.debug('✅ WebSocket消息监听器已设置');
  }

  /// 🔴 更新单个会话的最新消息（在 _MobileHomePageState 中）
  /// 退出聊天页面时调用，只更新该会话而不重新加载整个列表
  Future<void> _updateSingleContact(int contactId, bool isGroup) async {
    // 通知聊天列表页面更新
    final chatListState = _chatListKey.currentState;
    if (chatListState != null && chatListState.mounted) {
      await chatListState._updateSingleContact(contactId, isGroup);
    }
  }

  // 处理联系人请求通知
  Future<void> _handleContactRequest(dynamic data) async {
    try {
      if (data == null) return;
      if (!mounted) return;

      final requestData = data as Map<String, dynamic>;
      final senderId = requestData['sender_id'] as int?;
      final senderName = requestData['sender_name'] as String?;
      final relationId = requestData['relation_id'] as int?;

      logger.debug(
        '📬 收到联系人请求通知 - 发送者ID: $senderId, 发送者名称: $senderName, 关系ID: $relationId',
      );

      await _recordPendingContact(senderId);

      // 🔴 清除通讯录缓存并通知页面刷新
      logger.debug('🔄 清除通讯录缓存并通知刷新');
      MobileContactsPage.clearCacheAndRefresh();

      // 重新加载待审核数量（使用await确保更新完成）
      logger.debug('🔄 开始重新加载待审核数量...');
      await _loadContactsPendingCount();
      logger.debug('✅ 待审核数量已更新: $_contactsPendingCount');

      // 可选：显示提示消息
      if (mounted && senderName != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$senderName 请求添加您为好友,待审核'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      logger.debug('处理联系人请求通知失败: $e');
    }
  }

  // 处理联系人状态变更通知（审核通过/拒绝）
  Future<void> _handleContactStatusChanged(dynamic data) async {
    try {
      if (data == null) return;
      if (!mounted) return;

      final statusData = data as Map<String, dynamic>;
      final status = statusData['status'] as String?;
      final initiatorId = statusData['initiator_id'] as int?;
      final approverId = statusData['approver_id'] as int?;
      final initiatorName = statusData['initiator_name'] as String?;
      final approverName = statusData['approver_name'] as String?;

      logger.debug(
        '✅ 收到联系人状态变更通知 - 状态: $status, 发起人: $initiatorName (ID: $initiatorId), 审核人: $approverName (ID: $approverId)',
      );

      // 🔴 清除通讯录缓存并强制重新加载联系人列表
      logger.debug('🔄 清除通讯录缓存并强制重新加载联系人列表');
      MobileContactsPage.clearCacheAndRefresh();

      // 🔴 关键修复：在刷新前，先将当前内存中的已读状态保存到静态缓存
      // 这样即使 refresh() 清除了缓存，已读状态也能被保留
      final chatListState = _chatListKey.currentState;
      if (chatListState != null) {
        chatListState._preserveReadStatusToCache();
      }

      // 🔴 刷新最近联系人列表（确保新好友立即显示）
      logger.debug('🔄 刷新最近联系人列表');
      _chatListKey.currentState?.refresh();

      // 重新加载待审核数量（使用await确保更新完成）
      logger.debug('🔄 开始重新加载待审核数量...');
      await _loadContactsPendingCount();
      logger.debug('✅ 待审核数量已更新: $_contactsPendingCount');

      // 获取当前用户ID，判断是发起人还是审核人
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) return;

      // 显示提示消息
      if (mounted) {
        String message = '';
        
        if (currentUserId == initiatorId) {
          // 当前用户是发起人，收到审核结果通知
          if (status == 'approved') {
            message = '$approverName 已通过您的好友请求';
          } else if (status == 'rejected') {
            message = '$approverName 已拒绝您的好友请求';
          }
        } else if (currentUserId == approverId) {
          // 当前用户是审核人，收到自己审核操作的确认
          if (status == 'approved') {
            message = '您已通过 $initiatorName 的好友请求';
          } else if (status == 'rejected') {
            message = '您已拒绝 $initiatorName 的好友请求';
          }
        }

        if (message.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 3),
              backgroundColor: status == 'approved' 
                  ? Colors.green 
                  : Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('处理联系人状态变更通知失败: $e');
    }
  }

  // 处理待审核群成员通知
  Future<void> _handlePendingGroupMemberNotification(dynamic data) async {
    try {
      if (data == null) return;
      if (!mounted) return;

      final notificationData = data as Map<String, dynamic>;
      final groupId = notificationData['group_id'] as int?;
      final groupName = notificationData['group_name'] as String?;
      final operatorName = notificationData['operator_name'] as String?;
      final newMemberName = notificationData['new_member_name'] as String?;

      logger.debug(
        '👥 收到待审核群成员通知 - 群组ID: $groupId, 群组名称: $groupName, 操作者: $operatorName, 新成员: $newMemberName',
      );

      // 🔴 清除通讯录缓存并强制重新加载（群组成员变更）
      logger.debug('🔄 清除通讯录缓存并强制重新加载群组列表');
      MobileContactsPage.clearCacheAndRefresh();

      // 🔴 关键修复：在刷新前，先将当前内存中的已读状态保存到静态缓存
      final chatListState = _chatListKey.currentState;
      if (chatListState != null) {
        chatListState._preserveReadStatusToCache();
      }

      // 🔴 刷新最近联系人列表（确保群组更新立即显示）
      logger.debug('🔄 刷新最近联系人列表');
      _chatListKey.currentState?.refresh();

      // 重新加载待审核数量（使用await确保更新完成）
      logger.debug('🔄 开始重新加载待审核数量...');
      await _loadContactsPendingCount();
      logger.debug('✅ 待审核数量已更新: $_contactsPendingCount');

      // 可选：显示提示消息
      if (mounted && groupName != null && newMemberName != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$operatorName 邀请 $newMemberName 加入群组「$groupName」，待审核',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      logger.debug('处理待审核群成员通知失败: $e');
    }
  }

  // 处理头像更新通知
  Future<void> _handleAvatarUpdated(dynamic data) async {
    try {
      if (data == null) {
        logger.debug('⚠️ 头像更新数据为空');
        return;
      }

      final userId = data['user_id'] as int?;
      final newAvatar = data['avatar'] as String?;

      if (userId == null) {
        logger.debug('⚠️ 头像更新消息缺少user_id');
        return;
      }

      logger.debug('🎭 移动端收到头像更新通知 - 用户ID: $userId, 新头像: $newAvatar');

      // 更新本地数据库中的头像信息
      final localDb = LocalDatabaseService();
      final dbUpdatedCount = await localDb.updateUserAvatarInMessages(userId, newAvatar);
      logger.debug('🗄️ 移动端数据库头像已更新 - 用户ID: $userId, 更新了 $dbUpdatedCount 条记录');

      // 同步更新联系人快照表中的头像，确保后续从contact_snapshots读取到的是最新头像
      final currentUserId = await Storage.getUserId();
      if (currentUserId != null) {
        await localDb.upsertContactSnapshot(
          ownerId: currentUserId,
          contactId: userId,
          contactType: 'user',
          avatar: newAvatar,
        );
        logger.debug('📇 移动端联系人快照头像已更新 - ownerId=$currentUserId, contactId=$userId');
      } else {
        logger.debug('⚠️ 无法更新联系人快照头像：currentUserId 为空');
      }

      // 通知聊天列表页面更新头像（异步刷新会话列表）
      final chatListState = _chatListKey.currentState;
      if (chatListState != null && chatListState.mounted) {
        await chatListState._handleAvatarUpdated(userId, newAvatar);
      }

      logger.debug('🎭 移动端头像更新处理完成（数据库+会话列表）');
    } catch (e) {
      logger.debug('移动端处理头像更新失败: $e');
    }
  }

  // 处理群组昵称更新通知
  Future<void> _handleGroupNicknameUpdated(dynamic data) async {
    try {
      if (data == null) {
        logger.debug('⚠️ 群组昵称更新数据为空');
        return;
      }

      final groupId = data['group_id'] as int?;
      final userId = data['user_id'] as int?;
      final newNickname = data['new_nickname'] as String?;

      if (groupId == null || userId == null || newNickname == null) {
        logger.debug('⚠️ 群组昵称更新消息缺少必要字段');
        return;
      }

      logger.debug('👤 移动端收到群组昵称更新通知 - 群组ID: $groupId, 用户ID: $userId, 新昵称: $newNickname');

      // WebSocketService已经更新了本地数据库，这里通知聊天列表刷新
      // 如果当前正在聊天列表页面，刷新会话列表以显示更新后的昵称
      final chatListState = _chatListKey.currentState;
      if (chatListState != null && chatListState.mounted) {
        // 刷新最近联系人列表，显示最新的昵称
        await chatListState._loadRecentContacts();
      }

      logger.debug('✅ 移动端群组昵称更新处理完成');
    } catch (e) {
      logger.debug('❌ 移动端处理群组昵称更新失败: $e');
    }
  }

  // 处理群组信息更新通知（包括群组头像、名称等）
  Future<void> _handleGroupInfoUpdated(dynamic data) async {
    try {
      if (data == null) {
        logger.debug('⚠️ 群组信息更新数据为空');
        return;
      }

      final groupId = data['group_id'] as int?;
      final groupData = data['group'] as Map<String, dynamic>?;

      if (groupId == null || groupData == null) {
        logger.debug('⚠️ 群组信息更新消息缺少必要字段');
        return;
      }

      logger.debug('📢 移动端收到群组信息更新通知 - 群组ID: $groupId, 数据: $groupData');

      // 更新本地数据库中的群组信息
      final localDb = LocalDatabaseService();
      await localDb.updateGroupInfoInMessages(
        groupId: groupId,
        groupName: groupData['name'] as String?,
        groupAvatar: groupData['avatar'] as String?,
      );
      logger.debug('🗄️ 移动端数据库群组信息已更新');

      // 通知聊天列表页面更新群组信息（异步刷新会话列表）
      final chatListState = _chatListKey.currentState;
      if (chatListState != null && chatListState.mounted) {
        await chatListState._handleGroupInfoUpdated(data);
      }

      logger.debug('📢 移动端群组信息更新处理完成（数据库+会话列表）');
    } catch (e) {
      logger.error('❌ 移动端处理群组信息更新失败: $e');
    }
  }

  /// 🔴 处理消息撤回通知，更新本地数据库
  Future<void> _handleMessageRecalled(dynamic data) async {
    try {
      if (data == null) return;

      final messageId = data['message_id'] as int?;
      final groupId = data['group_id'] as int?;
      final senderId = data['sender_id'] as int?;

      if (messageId == null) {
        logger.debug('⚠️ 撤回消息通知缺少message_id');
        return;
      }

      logger.debug('↩️ [移动端主页] 处理消息撤回 - messageId: $messageId, groupId: $groupId, senderId: $senderId');

      // 更新本地数据库中的消息状态
      final localDb = LocalDatabaseService();
      if (groupId != null) {
        // 群组消息撤回
        await localDb.recallGroupMessageByServerId(messageId);
        logger.debug('✅ [移动端主页] 群组消息已标记为撤回 - messageId: $messageId');
      } else {
        // 私聊消息撤回
        await localDb.recallMessageByServerId(messageId);
        logger.debug('✅ [移动端主页] 私聊消息已标记为撤回 - messageId: $messageId');
      }

      // 🔴 清除该会话的消息缓存，让进入聊天页面时从数据库重新加载
      final currentUserId = await Storage.getUserId();
      if (currentUserId != null) {
        if (groupId != null) {
          MobileChatPage.clearCache(isGroup: true, id: groupId, currentUserId: currentUserId);
          logger.debug('🗑️ [移动端主页] 已清除群组 $groupId 的消息缓存');
        } else if (senderId != null) {
          MobileChatPage.clearCache(isGroup: false, id: senderId, currentUserId: currentUserId);
          logger.debug('🗑️ [移动端主页] 已清除用户 $senderId 的消息缓存');
        }
      }

      // 🔴 直接更新内存中联系人列表的最后消息状态，而不是重新加载整个列表
      final chatListState = _chatListKey.currentState;
      if (chatListState != null && chatListState.mounted) {
        chatListState._updateContactLastMessageStatus(
          senderId: senderId,
          groupId: groupId,
          messageId: messageId,
        );
      }
    } catch (e) {
      logger.debug('❌ [移动端主页] 处理消息撤回失败: $e');
    }
  }

  /// 🔴 处理清空聊天历史通知（好友审核通过/驳回时触发）
  /// 用于在会话列表中正确显示新好友的会话和未读数
  Future<void> _handleClearChatHistoryForList(dynamic data) async {
    try {
      if (data == null) return;

      final senderId = data['user_id'] as int?;
      final receiverId = data['contact_id'] as int?;
      final content = data['content'] as String?;
      final senderName = data['sender_name'] as String?;
      final senderAvatar = data['sender_avatar'] as String?;
      final createdAt = data['created_at'] as String?;

      logger.debug('🗑️ [移动端主页] 处理清空聊天历史 - senderId: $senderId, receiverId: $receiverId, content: $content');

      if (senderId == null || receiverId == null) return;

      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) return;

      // 🔴 清除该会话的消息缓存
      MobileChatPage.clearCache(isGroup: false, id: senderId, currentUserId: currentUserId);
      logger.debug('🗑️ [移动端主页] 已清除用户 $senderId 的消息缓存');

      // 🔴 关键：判断当前用户是发送方还是接收方
      // 如果当前用户是接收方（receiverId），说明是收到了好友审核消息，需要显示未读数
      final isReceiver = currentUserId == receiverId;
      final contactId = isReceiver ? senderId : receiverId;

      // 🔴 关键修复：检查并恢复已删除的会话
      // 当用户之前删除了会话，然后重新添加好友并通过审核时，需要恢复会话
      final contactKey = Storage.generateContactKey(isGroup: false, id: contactId);
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 [移动端主页] 检测到已删除的会话，准备恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        // 更新静态缓存
        MobileHomePage._cachedDeletedChats?.remove(contactKey);
        logger.debug('✅ [移动端主页] 已恢复删除的会话: $contactKey');
      }

      // 🔴 更新未读数量缓存
      if (isReceiver && content == '请求添加好友【已通过】') {
        final unreadKey = 'user_$contactId';
        MobileHomePage.updateUnreadCount(unreadKey, 1);
        logger.debug('📢 [移动端主页] 已更新未读数量缓存: $unreadKey -> 1');
        
        // 🔴 从已读状态缓存中移除该会话
        MobileHomePage._readStatusCache.remove(unreadKey);
        logger.debug('📢 [移动端主页] 已从已读缓存移除: $unreadKey');
      }

      // 🔴 通知聊天列表刷新
      final chatListState = _chatListKey.currentState;
      if (chatListState != null && chatListState.mounted) {
        // 延迟一小段时间，确保数据库操作完成
        await Future.delayed(const Duration(milliseconds: 100));
        // 🔴 先刷新配置（包括删除列表），再刷新联系人列表
        await chatListState._loadPreferences();
        await chatListState._loadRecentContacts();
        logger.debug('✅ [移动端主页] 会话列表已刷新');
      }
    } catch (e) {
      logger.debug('❌ [移动端主页] 处理清空聊天历史失败: $e');
    }
  }

  // 加载通讯录待审核数量
  Future<void> _loadContactsPendingCount() async {
    try {
      final token = await Storage.getToken();
      if (token == null) return;

      // 🔴 修改：从 API 获取待审核联系人数量（与 MobileContactsPage 保持一致）
      final requestsResponse = await ApiService.getPendingContactRequests(token: token);
      final requestsData = requestsResponse['data']?['requests'] as List?;
      final newContactCount = requestsData?.length ?? 0;

      // 加载待审核群组成员数量
      int groupNotificationCount = 0;

      final groupsResponse = await ApiService.getUserGroups(token: token);

      // 检查响应是否成功以及data是否存在
      if (groupsResponse['code'] == 0 && groupsResponse['data'] != null) {
        final groupsData = groupsResponse['data']['groups'] as List?;

        if (groupsData != null && groupsData.isNotEmpty) {
          for (var groupJson in groupsData) {
            final groupId = groupJson['id'] as int;

            // 获取群组详情
            final detailResponse = await ApiService.getGroupDetail(
              token: token,
              groupId: groupId,
            );

            if (detailResponse['code'] == 0 && detailResponse['data'] != null) {
              final data = detailResponse['data'];
              final groupData = data['group'] as Map<String, dynamic>?;
              final members = data['members'] as List?;
              final memberRole = data['member_role'] as String?;

              final inviteConfirmation =
                  groupData?['invite_confirmation'] as bool? ?? false;

              if (inviteConfirmation &&
                  (memberRole == 'owner' || memberRole == 'admin')) {
                if (members != null) {
                  for (var member in members) {
                    final approvalStatus =
                        member['approval_status'] as String? ?? 'approved';
                    if (approvalStatus == 'pending') {
                      groupNotificationCount++;
                    }
                  }
                }
              }
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _contactsPendingCount = newContactCount + groupNotificationCount;
        });
        logger.debug(
          '📊 通讯录待审核数量初始化 - 新联系人: $newContactCount, 群通知: $groupNotificationCount, 总计: $_contactsPendingCount',
        );
      }
    } catch (e) {
      logger.error('加载通讯录待审核数量失败: $e');
    }
  }

  Future<void> _recordPendingContact(int? contactUserId) async {
    if (contactUserId == null) return;
    try {
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) return;
      await Storage.addPendingContact(currentUserId, contactUserId);
      logger.debug('📌 记录待审核联系人: $contactUserId');
    } catch (e) {
      logger.debug('记录待审核联系人失败: $e');
    }
  }

  Future<void> _loadUserInfo() async {
    try {
      final token = await Storage.getToken();
      if (token == null) {
        throw Exception('No token found');
      }

      final response = await ApiService.getUserProfile(token: token);
      final userInfo = response['data']['user'];

      if (mounted) {
        setState(() {
          _token = token;
          _userId = userInfo['id']?.toString() ?? '';
          _username = userInfo['username'] ?? '';
          _fullName = userInfo['full_name'];
          _userDisplayName = _fullName ?? _username;
          _userAvatar = userInfo['avatar'];
          _gender = userInfo['gender'];
          _phone = userInfo['phone'];
          _email = userInfo['email'];
          _department = userInfo['department'];
          _position = userInfo['position'];
          _region = userInfo['region'];
          _workSignature = userInfo['work_signature'];
          _inviteCode = userInfo['invite_code']; // 加载邀请码
          _userStatus = userInfo['status'] ?? 'online';
        });
        
        // 🔴 更新 Storage 中的头像URL（确保聊天页面能加载最新头像）
        if (_userAvatar != null && _userAvatar!.isNotEmpty) {
          await Storage.saveAvatar(_userAvatar!);
          logger.debug('✅ 已更新 Storage 中的头像: $_userAvatar');
        }
        
        // 🔴 更新已登录账号列表中的头像（确保切换账号页面显示最新头像）
        final userId = int.tryParse(_userId);
        if (userId != null) {
          await Storage.addLoggedInAccount(
            userId: userId,
            username: _username,
            fullName: _fullName,
            avatar: _userAvatar,
          );
          logger.debug('✅ 已更新已登录账号列表中的头像');
        }
      }
    } catch (e) {
      logger.error('加载用户信息失败: $e');
      if (mounted) {
        // Handle error
      }
    }
  }

  Future<void> _connectWebSocket() async {
    try {
      final connected = await _wsService.connect();
      if (connected) {
        logger.debug('✅ 移动端主页 - WebSocket连接成功');
        
        // 设置被踢下线回调
        _wsService.onForcedLogout = (message) {
          logger.debug('🚫 [强制登出] 移动端收到被踢下线通知，准备跳转到登录页面');
          if (mounted) {
            // 🔴 立即取消所有定时器，防止继续触发网络请求
            _networkStatusTimer?.cancel();
            _networkStatusTimer = null;
            _vibrationTimer?.cancel();
            _vibrationTimer = null;
            
            // 🔴 清除 Storage 中的 token，防止自动登录
            Storage.clearToken();
            
            // 显示提示消息
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
            
            // 清除本地状态
            _token = null;
            _userId = '';
            
            // 延迟一小段时间让用户看到提示，然后跳转到登录页面
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                Navigator.of(context).pushReplacementNamed('/login');
              }
            });
          }
        };

        // 设置消息发送错误回调
        _wsService.onMessageError = (errorType, errorMessage) {
          logger.debug('🚫 [消息错误] 移动端收到消息发送错误: $errorType - $errorMessage');
          // 🔴 修复：不在全局显示错误消息，让聊天页面自己处理
          // 避免重复显示错误提示
          logger.debug('🚫 [消息错误] 错误消息将由聊天页面处理，避免重复显示');
        };
        
        // 🔴 设置重连成功回调：同步消息并刷新UI
        _wsService.onReconnected = () {
          logger.debug('🔄 [重连成功-移动端] 开始同步数据和刷新UI');
          if (mounted) {
            // 触发数据同步
            _syncDataAfterReconnect().then((_) {
              logger.debug('✅ [重连成功-移动端] 数据同步完成');
            }).catchError((error) {
              logger.error('❌ [重连成功-移动端] 数据同步失败', error: error);
            });
          }
        };
        
        // 🔴 连接成功后，发送在线状态（与PC端保持一致）
        try {
          await _wsService.sendStatusChange('online');
          logger.debug('✅ 移动端已发送在线状态到服务器');
        } catch (e) {
          logger.debug('⚠️ 移动端发送在线状态失败: $e');
        }
      } else {
        logger.error('❌ 移动端主页 - WebSocket连接失败');
      }
    } catch (e) {
      logger.error('WebSocket连接失败: $e');
    }
  }

  // 🔴 设置网络状态监听
  void _setupNetworkStatusListener() {
    // 取消之前的定时器（如果存在）
    _networkStatusTimer?.cancel();
    
    // 初始化网络连接状态
    _isNetworkConnected = _wsService.isConnected;
    _isConnecting = !_isNetworkConnected; // 初始状态：断网就显示刷新
    
    // 监听WebSocket连接状态变化
    _networkStatusTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final currentConnected = _wsService.isConnected;
      
      // 🔴 关键修复：如果应用在后台，不要触发重连逻辑
      if (!NotificationService().isAppInForeground) {
        return;
      }
      
      // 🔴 简化逻辑：断网就显示"正在刷新"，连上就取消
      final shouldShowRefreshing = !currentConnected;
      
      if (shouldShowRefreshing != _isConnecting) {
        setState(() {
          _isConnecting = shouldShowRefreshing;
          _isNetworkConnected = currentConnected;
        });
        
        if (shouldShowRefreshing) {
          logger.debug('🔄 [网络状态-会话] 网络断开，显示正在刷新...');
        } else {
          logger.debug('✅ [网络状态-会话] 网络已连接，取消刷新提示');
          // 连接成功后同步数据（异步执行，不阻塞UI）
          _syncDataAfterReconnect();
        }
      }
    });
  }

  // 🔴 网络重连后同步数据
  Future<void> _syncDataAfterReconnect() async {
    // 🔴 防抖：如果正在同步或者距离上次同步不到2秒，跳过
    if (_isReconnectSyncing) {
      logger.debug('⏭️ [数据同步-会话] 正在同步中，跳过重复调用');
      return;
    }
    
    final now = DateTime.now();
    if (_lastReconnectSyncTime != null && 
        now.difference(_lastReconnectSyncTime!).inMilliseconds < 2000) {
      logger.debug('⏭️ [数据同步-会话] 距离上次同步不到2秒，跳过');
      return;
    }
    
    _isReconnectSyncing = true;
    _lastReconnectSyncTime = now;
    
    try {
      logger.debug('🔄 [数据同步-会话] 开始重连后数据同步...');
      
      // 1. 等待离线消息同步完成
      // WebSocket重连后，服务器会自动推送离线消息到本地数据库
      // 离线消息会通过 offline_messages_saved 信号触发 _updateContactsFromOfflineMessages 直接更新内存缓存
      logger.debug('⏳ [数据同步-会话] 等待离线消息同步完成...');
      
      // 🔴 优化：等待更长时间（最多10秒），确保离线消息处理完成
      int waitTime = 0;
      const maxWaitTime = 10000; // 10秒
      bool offlineMessagesSynced = false;
      
      while (waitTime < maxWaitTime) {
        // 检查WebSocket服务的同步状态标志
        if (_wsService.offlineMessagesSynced || _wsService.offlineGroupMessagesSynced) {
          offlineMessagesSynced = true;
          logger.debug('✅ [数据同步-会话] 检测到离线消息同步完成标志');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 200));
        waitTime += 200;
        
        // 每2秒打印一次等待日志
        if (waitTime % 2000 == 0) {
          logger.debug('⏳ [数据同步-会话] 已等待 ${waitTime / 1000} 秒...');
        }
      }
      
      if (offlineMessagesSynced) {
        logger.debug('✅ [数据同步-会话] 离线消息同步完成，内存缓存已通过 _updateContactsFromOfflineMessages 更新');
      } else {
        logger.debug('⏰ [数据同步-会话] 离线消息同步超时');
      }
      
      // 🔴 关键修复：清除聊天页面的消息缓存
      // 这样用户进入聊天页面时会从数据库重新加载，能看到离线消息
      MobileChatPage.clearAllCache();
      logger.debug('🗑️ [数据同步-会话] 已清空聊天页面消息缓存');
      
      // 🔴 不再重新加载联系人列表，离线消息已通过 _updateContactsFromOfflineMessages 直接更新内存缓存
      
      logger.debug('✅ [数据同步-会话] 重连后数据同步完成');
    } catch (e) {
      logger.error('❌ [数据同步-会话] 重连后数据同步失败', error: e);
    } finally {
      // 🔴 重置防抖标志
      _isReconnectSyncing = false;
    }
  }

  // 🔴 下拉刷新方法
  Future<void> _onRefresh() async {
    logger.debug('🔄 [下拉刷新-会话] 用户触发下拉刷新');
    
    setState(() {
      _isConnecting = true;
    });
    
    try {
      // 尝试重新连接WebSocket
      await _wsService.connect();
      
      // 刷新聊天列表
      final chatListState = _chatListKey.currentState;
      if (chatListState != null) {
        await chatListState._loadRecentContacts();
      }
      
      logger.debug('✅ [下拉刷新-会话] 刷新完成');
    } catch (e) {
      logger.error('❌ [下拉刷新-会话] 刷新失败', error: e);
    }
    
    // 延迟1秒后隐藏刷新状态
    Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    });
  }

  // 🔴 新增：执行真正的刷新操作（与下拉刷新相同的效果）
  // 用于应用启动时检测到未连接的情况，会循环尝试重连直到成功
  Future<void> _performRealRefresh() async {
    logger.debug('🔄 [自动刷新-会话] 开始执行真正的刷新操作...');
    
    const int retryIntervalSeconds = 3; // 重试间隔（秒）
    const int maxRetries = 100; // 最大重试次数，防止无限循环
    int retryCount = 0;
    
    while (mounted && retryCount < maxRetries) {
      // 🔴 关键修复：如果应用在后台，停止重连尝试
      if (!NotificationService().isAppInForeground) {
        logger.debug('📱 [自动刷新-会话] 应用在后台，停止重连尝试');
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
        }
        return;
      }
      
      retryCount++;
      logger.debug('🔌 [自动刷新-会话] 第 $retryCount 次尝试重新连接WebSocket...');
      
      try {
        // 1. 尝试重新连接WebSocket
        await _wsService.connect();
        
        // 2. 等待连接建立
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 3. 检查是否连接成功
        if (_wsService.isConnected) {
          logger.debug('✅ [自动刷新-会话] WebSocket连接成功！');
          
          // 4. 刷新聊天列表
          final chatListState = _chatListKey.currentState;
          if (chatListState != null) {
            logger.debug('📋 [自动刷新-会话] 刷新聊天列表...');
            // 🔴 关键修复：重连后清除所有缓存，让数据库的 is_read 状态决定未读数
            MobileHomePage._unreadCountCache.clear();
            MobileHomePage._readStatusCache.clear();
            // 🔴 关键修复：清除内存中的联系人列表，避免本地已读状态覆盖离线消息的未读数量
            chatListState._clearRecentContactsForReconnect();
            await chatListState._loadRecentContacts();
          }
          
          logger.debug('✅ [自动刷新-会话] 刷新完成');
          
          // 5. 连接成功，隐藏刷新状态并退出循环
          if (mounted) {
            setState(() {
              _isConnecting = false;
            });
            logger.debug('🎯 [自动刷新-会话] 已隐藏刷新提示');
          }
          return; // 退出循环
        } else {
          logger.debug('⚠️ [自动刷新-会话] 连接未成功，${retryIntervalSeconds}秒后重试...');
        }
      } catch (e) {
        logger.error('❌ [自动刷新-会话] 第 $retryCount 次连接失败: $e');
      }
      
      // 等待一段时间后重试
      if (mounted && retryCount < maxRetries) {
        await Future.delayed(Duration(seconds: retryIntervalSeconds));
      }
    }
    
    // 达到最大重试次数仍未成功
    if (mounted) {
      logger.debug('⚠️ [自动刷新-会话] 达到最大重试次数 $maxRetries，停止重试');
      setState(() {
        _isConnecting = false;
      });
    }
  }

  // 🔴 新增：处理通话结束消息，隐藏悬浮按钮
  void _handleMessageForCallEnd(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final messageData = data as Map<String, dynamic>;
      final messageType = messageData['message_type'] as String?;
      final senderId = messageData['sender_id'] as int?;
      final receiverId = messageData['receiver_id'] as int?;

      logger.debug(
        '📞 [HomePage] 收到消息 - 类型: $messageType, 发送者: $senderId, 接收者: $receiverId',
      );

      // 检查是否是通话结束消息
      if (messageType == 'call_ended' || messageType == 'call_ended_video') {
        logger.debug('📞 [HomePage] 收到通话结束消息，检查是否需要隐藏悬浮按钮');
        logger.debug('📞 [HomePage] 当前悬浮按钮状态: $_showCallFloatingButton');
        logger.debug('📞 [HomePage] 悬浮按钮用户ID: $_floatingCallUserId');

        // 如果有悬浮按钮显示，且与当前通话相关，隐藏它
        if (_showCallFloatingButton) {
          final currentUserId = int.tryParse(_userId);
          logger.debug('📞 [HomePage] 当前用户ID: $currentUserId');

          // 判断这个通话结束消息是否与当前悬浮按钮的通话相关
          // 如果发送者或接收者与悬浮按钮的用户ID匹配，说明是同一个通话
          final isRelatedCall =
              (senderId == _floatingCallUserId ||
                  receiverId == _floatingCallUserId) &&
              (senderId == currentUserId || receiverId == currentUserId);

          logger.debug('📞 [HomePage] 是否相关通话: $isRelatedCall');

          if (isRelatedCall) {
            logger.debug('📞 [HomePage] 🔥 隐藏悬浮按钮（收到通话结束消息）');
            setState(() {
              _showCallFloatingButton = false;
              _floatingCallUserId = null;
              _floatingCallDisplayName = null;
              _floatingCallType = null;
              _floatingIsGroupCall = false;
              _floatingGroupId = null;
            });
            logger.debug('📞 [HomePage] ✅ 悬浮按钮已隐藏');
          } else {
            logger.debug('📞 [HomePage] ⚠️ 不是相关通话，不隐藏悬浮按钮');
          }
        } else {
          logger.debug('📞 [HomePage] ⚠️ 悬浮按钮未显示，无需隐藏');
        }
      }
    } catch (e) {
      logger.error('❌ [HomePage] 处理通话结束消息失败: $e');
    }
  }

  // 🔴 新增：检查并恢复已删除的会话（主页面监听器版本）
  Future<void> _checkAndRestoreDeletedChatFromMessage(dynamic data) async {
    try {
      if (data == null) return;

      final messageData = data as Map<String, dynamic>;
      final senderId = messageData['sender_id'] as int?;
      
      if (senderId == null) return;

      // 检查会话是否被删除
      final contactKey = Storage.generateContactKey(
        isGroup: false,
        id: senderId,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      
      if (isDeleted) {
        logger.debug('🔄 [主页面] 收到来自已删除会话的新消息，自动恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ [主页面] 已删除会话已恢复: $contactKey，准备通知聊天列表刷新');
        
        // 通知聊天列表Tab刷新
        final chatListState = _chatListKey.currentState;
        if (chatListState != null && chatListState.mounted) {
          // 调用聊天列表的重新加载方法
          await chatListState._loadPreferences();
          await chatListState._loadRecentContacts();
          logger.debug('✅ [主页面] 已通知聊天列表刷新，消息应该会显示');
        }
      }
    } catch (e) {
      logger.error('❌ [主页面] 恢复已删除会话失败: $e');
    }
  }

  // 🔴 新增：检查并恢复已删除的群聊会话（主页面监听器版本）
  Future<void> _checkAndRestoreDeletedGroupChatFromMessage(dynamic data) async {
    try {
      if (data == null) return;

      final messageData = data as Map<String, dynamic>;
      final groupId = messageData['group_id'] as int?;
      
      if (groupId == null) return;

      // 检查群聊会话是否被删除
      final contactKey = Storage.generateContactKey(
        isGroup: true,
        id: groupId,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      
      if (isDeleted) {
        logger.debug('🔄 [主页面] 收到来自已删除群聊的新消息，自动恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ [主页面] 已删除群聊会话已恢复: $contactKey，准备通知聊天列表刷新');
        
        // 通知聊天列表Tab刷新
        final chatListState = _chatListKey.currentState;
        if (chatListState != null && chatListState.mounted) {
          // 调用聊天列表的重新加载方法
          await chatListState._loadPreferences();
          await chatListState._loadRecentContacts();
          logger.debug('✅ [主页面] 已通知聊天列表刷新，群组消息应该会显示');
        }
      }
    } catch (e) {
      logger.error('❌ [主页面] 恢复已删除群聊会话失败: $e');
    }
  }

  /// 初始化Agora服务
  Future<void> _initAgora() async {
    // 只在启用 WebRTC 功能时初始化
    if (!FeatureConfig.enableWebRTC || _agoraService == null) {
      logger.debug(
        '📞 Agora 功能已禁用 - enableWebRTC: ${FeatureConfig.enableWebRTC}, service: ${_agoraService != null}',
      );
      return;
    }

    if (_userId.isEmpty) {
      logger.debug('📞 用户ID为空，无法初始化Agora服务');
      return;
    }

    final currentUserId = int.tryParse(_userId);
    if (currentUserId == null) {
      logger.debug('📞 用户ID格式错误: $_userId');
      return;
    }

    logger.debug('📞 开始初始化 Agora 服务，当前用户ID: $currentUserId');

    // 初始化 Agora 服务
    await _agoraService.initialize(currentUserId);

    // 🔴 设置通话错误回调（处理对方拒绝通话等情况）
    _agoraService.onError = (error) {
      logger.debug('📞 [MobileHomePage] Agora 错误: $error');
      
      // 🔴 不再在这里发送拒绝消息，因为：
      // 1. 如果是 PC 端拒绝，PC 端会发送"对方已拒绝"消息
      // 2. 如果是移动端拒绝，onCallRejectedByMe 回调会处理
      // 在这里发送会导致重复消息
      
      // 显示错误提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
    };

    // 🔴 新增：UserSig 过期回调（触发退出登录）
    _agoraService.onUserSigExpired = (message) {
      logger.debug('📞 [MobileHomePage] UserSig 过期: $message');
      if (mounted) {
        // 🔴 立即取消所有定时器，防止继续触发网络请求
        _networkStatusTimer?.cancel();
        _networkStatusTimer = null;
        _vibrationTimer?.cancel();
        _vibrationTimer = null;
        
        // 🔴 清除 Storage 中的 token，防止自动登录
        Storage.clearToken();
        
        // 显示提示消息
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        
        // 清除本地状态
        _token = null;
        _userId = '';
        
        // 延迟一小段时间让用户看到提示，然后跳转到登录页面
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            Navigator.of(context).pushReplacementNamed('/login');
          }
        });
      }
    };

    // 设置来电回调
    // 🔴 所有来电（包括 PC 端和移动端）都使用 TUICallKit 标准 av_call 信令
    // TUICallKit 内置 UI 会自动处理来电显示，不需要自定义弹窗
    _agoraService.onIncomingCall = (userId, displayName, callType) {
      logger.debug('📞 Agora 来电回调被触发 - 用户: $displayName ($userId)');
      logger.debug('📞 TUICallKit 内置 UI 已启用，来电由 TUICallKit 自动处理');
      // 🔴 仅保存通话状态信息，用于后续处理（如通话结束消息发送）
      _currentCallUserId = userId;
      _currentCallType = callType;
      _isInGroupCall = false;
      _currentGroupCallId = null;
    };

    // 🔴 新增：TUICallKit 来电回调（用于准备遮盖层显示）
    _agoraService.onTUICallReceived = (callerId, callerIdStr, callType, isGroupCall, calleeIdList) async {
      logger.debug('📞 [HomePage] TUICallKit 来电回调 - callerId: $callerId, callType: $callType');
      logger.debug('📞 [HomePage] 是否群组通话: $isGroupCall, 被叫用户数: ${calleeIdList.length}');
      
      // 🔴 如果是群组通话，设置群组通话标志
      if (isGroupCall) {
        _isInGroupCall = true;
        // 🔴 注意：此时我们还不知道群组ID，需要从其他地方获取
        // 群组ID 会在 join_voice_button 消息中包含
        logger.debug('📞 [HomePage] 已设置群组通话标志: _isInGroupCall=true');
      }
      
      // 保存来电信息，用于显示遮盖层
      _connectingCallerId = callerId;
      _connectingCallType = callType;
      // 尝试获取来电者名称
      try {
        final currentUserId = int.tryParse(_userId);
        if (currentUserId != null) {
          final snapshot = await LocalDatabaseService().getContactSnapshot(
            ownerId: currentUserId,
            contactId: callerId,
            contactType: 'user',
          );
          _connectingCallerName = snapshot?['display_name']?.toString() ?? snapshot?['nickname']?.toString() ?? callerIdStr;
        } else {
          _connectingCallerName = callerIdStr;
        }
      } catch (e) {
        _connectingCallerName = callerIdStr;
      }
      logger.debug('📞 [HomePage] 来电者名称: $_connectingCallerName');
    };

    // 🔴 新增：通话已连接回调（隐藏遮盖层）
    _agoraService.onCallConnected = () {
      logger.debug('📞 [HomePage] 通话已连接，隐藏遮盖层');
      if (mounted && _showConnectingOverlay) {
        setState(() {
          _showConnectingOverlay = false;
        });
      }
    };

    // 🔴 新增：通话连接中回调（显示遮盖层）
    _agoraService.onCallConnecting = () {
      logger.debug('📞 [HomePage] 通话连接中，显示遮盖层');
      if (mounted) {
        setState(() {
          _showConnectingOverlay = true;
        });
      }
    };

    // 🔴 修复：设置群组来电回调
    // 🔴 来自 PC 端的群组来电需要显示自定义弹窗（因为不是通过 TUICallKit 信令发送的）
    _agoraService.onIncomingGroupCall =
        (
          int userId,
          String displayName,
          CallType callType,
          List<Map<String, dynamic>> members,
          int? groupId,
        ) {
          logger.debug('📞 Agora 群组来电回调被触发 - 发起人: $displayName ($userId)');
          logger.debug('📞 群组ID: $groupId');
          logger.debug('📞 成员数量: ${members.length}');
          
          // 🔴 来自 PC 端的群组来电需要显示自定义弹窗
          // 因为这是通过 WebSocket 发送的，TUICallKit 不会自动处理
          logger.debug('📞 显示群组来电弹窗');
          _showIncomingGroupCallDialog(
            userId,
            displayName,
            callType,
            members,
            groupId,
          );
        };

    // 🔴 新增：监听通话状态，通话结束时自动隐藏悬浮按钮
    _agoraService.onCallStateChanged = (callState) {
      logger.debug('📱 [HomePage] 💫 onCallStateChanged 被调用: $callState');
      logger.debug(
        '📱 [HomePage] _showCallFloatingButton: $_showCallFloatingButton',
      );
      logger.debug('📱 [HomePage] mounted: $mounted');

      // 🔴 新增：当收到来电（ringing）且应用在后台时，播放铃声
      if (callState == CallState.ringing) {
        final isAppInBackground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
        if (Platform.isAndroid && isAppInBackground) {
          logger.debug('🔔 检测到来电且应用在后台，开始播放铃声');
          _startRingtone();
        }
      }

      if (callState == CallState.ended || callState == CallState.idle) {
        // 🔴 新增：通话结束时停止铃声
        _stopRingtone();
        
        // 🔴 新增：通话结束时隐藏遮盖层
        if (_showConnectingOverlay && mounted) {
          setState(() {
            _showConnectingOverlay = false;
          });
        }
        
        // 🔴 iOS: 通知 CallKit 通话已结束
        if (Platform.isIOS) {
          CallKitService().reportCallEnded();
        }
        
        if (_showCallFloatingButton && mounted) {
          logger.debug('📱 [HomePage] 🔥 通话已结束（状态: $callState），立即隐藏主页面悬浮按钮');
          setState(() {
            _showCallFloatingButton = false;
            // 🔴 新增：清空所有悬浮按钮相关状态
            _floatingCallUserId = null;
            _floatingCallDisplayName = null;
            _floatingCallType = null;
            _floatingIsGroupCall = false;
            _floatingGroupId = null;
            _floatingGroupCallUserIds = null;
            _floatingGroupCallDisplayNames = null;
          });
          logger.debug('📱 [HomePage] ✅ 主页面悬浮按钮已隐藏（通过 onCallStateChanged）');
        } else {
          if (!_showCallFloatingButton) {
            logger.debug('📱 [HomePage] ⚠️ 悬浮按钮未显示，无需隐藏');
          } else if (!mounted) {
            logger.debug('📱 [HomePage] ⚠️ Widget 已销毁，无法隐藏');
          }
        }
      } else if (callState == CallState.connected) {
        // 🔴 关键修复：当从聊天页面最小化通话回到主页面时，显示悬浮按钮
        if (!_showCallFloatingButton &&
            mounted &&
            _agoraService.isCallMinimized) {
          final minimizedUserId = _agoraService.minimizedCallUserId;
          if (minimizedUserId != null && minimizedUserId != 0) {
            logger.debug('📱 [HomePage] 🔥 检测到最小化的通话，显示主页面悬浮按钮');
            logger.debug('📱 [HomePage] minimizedUserId: $minimizedUserId');
            logger.debug(
              '📱 [HomePage] minimizedCallDisplayName: ${_agoraService.minimizedCallDisplayName}',
            );

            setState(() {
              _showCallFloatingButton = true;
              _floatingCallUserId = minimizedUserId;
              _floatingCallDisplayName =
                  _agoraService.minimizedCallDisplayName ?? 'Unknown';
              _floatingCallType =
                  _agoraService.minimizedCallType ?? CallType.voice;
              _floatingIsGroupCall = _agoraService.minimizedIsGroupCall;
              _floatingGroupId = _agoraService.minimizedGroupId;
              _floatingGroupCallUserIds = _agoraService.currentGroupCallUserIds;
              _floatingGroupCallDisplayNames =
                  _agoraService.currentGroupCallDisplayNames;
            });
            logger.debug('📱 [HomePage] ✅ 主页面悬浮按钮已显示');
          }
        }
      }
    };

    // 🔴 新增：群组通话中用户离开但通话仍在继续回调
    // 用于在群组对话框中显示"加入通话"按钮
    _agoraService.onGroupCallLeftButContinuing = (int groupId, CallType callType, int callDuration, String? callId) {
      logger.debug('📞 [MobileHomePage] 群组通话离开但仍在继续回调被触发');
      logger.debug('📞 [MobileHomePage] groupId: $groupId, callType: $callType, callDuration: $callDuration, callId: $callId');
      
      // 🔴 使用 callId 作为 channelName（用于重新加入通话）
      final channelName = callId;
      logger.debug('📞 [MobileHomePage] 使用 callId 作为 channelName: $channelName');
      
      // 通知当前打开的聊天页面显示"加入通话"按钮
      if (MobileChatPage.onGroupCallLeftButContinuingCallback != null) {
        logger.debug('📞 [MobileHomePage] 调用 MobileChatPage 的回调显示"加入通话"按钮, channelName=$channelName, callId=$callId');
        MobileChatPage.onGroupCallLeftButContinuingCallback?.call(groupId, callType, channelName, callId);
      } else {
        logger.debug('📞 [MobileHomePage] MobileChatPage 回调未设置，可能聊天页面未打开');
      }
    };
    
    // 🔴 新增：群组通话挂断回调
    // 当只剩1个或0个已连接成员时触发，发送通话时长消息给群组
    // 所有群组成员都能在对话框中看到这条消息
    _agoraService.onGroupCallHangup = (int groupId, CallType callType, int callDuration, bool isLastMember) {
      logger.debug('📞 [MobileHomePage] ========== 群组通话挂断回调 ==========');
      logger.debug('📞 [MobileHomePage] groupId: $groupId, callType: $callType, duration: $callDuration, isLastMember: $isLastMember');
      
      // 🔴 只要触发了这个回调（remoteUidsCount <= 1），就发送通话时长消息
      // 这条消息会群发给所有群组成员
      logger.debug('📞 [MobileHomePage] 发送群组通话结束消息（时长: $callDuration 秒）');
      _sendGroupCallEndedMessage(groupId, callDuration, callType);
    };

    // 🔴 新增：群组通话房间已进入回调（使用 TRTC SDK 直接进入房间后触发）
    // 当发起群组通话并成功进入 TRTC 房间后，导航到通话页面
    _agoraService.onGroupCallRoomEntered = (int roomId, List<int> userIds, List<String> displayNames, CallType callType, int? groupId) async {
      logger.debug('📞 [MobileHomePage] 群组通话房间已进入回调被触发');
      logger.debug('📞 [MobileHomePage] roomId: $roomId, userIds: $userIds, callType: $callType, groupId: $groupId');
      
      if (!mounted) {
        logger.debug('📞 [MobileHomePage] Widget 已销毁，无法导航到通话页面');
        return;
      }
      
      // 保存通话状态信息
      _isInGroupCall = true;
      _currentGroupCallId = groupId;
      _currentCallType = callType;
      
      // 导航到通话页面
      logger.debug('📞 [MobileHomePage] 导航到群组通话页面...');
      
      try {
        final navigator = Navigator.of(context);
        
        // 获取第一个被叫用户作为显示
        final targetUserId = userIds.isNotEmpty ? userIds.first : 0;
        final targetDisplayName = displayNames.isNotEmpty ? displayNames.first : '群组通话';
        
        logger.debug('🔴🔴🔴 [VoiceCallPage-群组通话发起] 打开VoiceCallPage');
        logger.debug('🔴🔴🔴 [VoiceCallPage-群组通话发起] targetUserId=$targetUserId, targetDisplayName=$targetDisplayName, type=$callType, groupId=$groupId');
        
        final result = await navigator.push(
          MaterialPageRoute(
            builder: (context) {
              return VoiceCallPage(
                targetUserId: targetUserId,
                targetDisplayName: targetDisplayName,
                callType: callType,
                isIncoming: false,  // 发起方，不是来电
                groupId: groupId,
                groupCallUserIds: userIds,
                groupCallDisplayNames: displayNames,
              );
            },
          ),
        );
        
        logger.debug('📞 [MobileHomePage] 群组通话页面返回，结果: $result');
        
        // 通话页面关闭后，刷新主页面状态
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _chatListKey.currentState?.refresh();
              setState(() {});
            }
          });
        }
      } catch (e, stackTrace) {
        logger.debug('❌ [MobileHomePage] 导航到群组通话页面失败: $e');
        logger.debug('❌ [MobileHomePage] 堆栈跟踪: $stackTrace');
      }
    };

    // 设置通话结束回调
    _agoraService.onCallEnded = (int callDuration) {
      logger.debug('📞 [Mobile] 通话结束回调被触发，时长: $callDuration 秒');

      // 🔴 关键修复：立即保存 isLocalHangup 的值
      // 因为 _resetCallState() 会在回调后被调用，将 _isLocalHangup 重置为 false
      // 如果在延迟后才获取，会导致 isLocalHangup 始终为 false，无法发送通话结束消息
      final isLocalHangup = _agoraService.isLocalHangup;
      final lastCallUserId = _agoraService.lastCallUserId;
      final lastGroupId = _agoraService.lastGroupId;
      final lastCallType = _agoraService.lastCallType;
      
      logger.debug('📞 [Mobile] 立即保存的状态: isLocalHangup=$isLocalHangup, lastCallUserId=$lastCallUserId, lastGroupId=$lastGroupId');

      if (callDuration > 0 && isLocalHangup) {
        _callEndedMessageSent = true;
        logger.debug('📞 [Mobile] 预先标记 _callEndedMessageSent = true（防止重复发送）');
      }

      // 🔴 修复：不要立即隐藏悬浮按钮，等待通话页面的返回结果
      // 如果是从悬浮按钮恢复的通话，通话页面会处理悬浮按钮的隐藏
      // 只有在非悬浮按钮场景下（如对方挂断），才在这里隐藏
      if (_showCallFloatingButton && mounted) {
        logger.debug('📞 [Mobile] 检测到悬浮按钮显示中，等待通话页面处理');
        // 不在这里隐藏，让通话页面的返回结果来决定
      }

      // 🔴 延迟发送通话结束消息（等待UI状态稳定）
      Future.delayed(const Duration(milliseconds: 300), () async {
        if (!mounted) return;

        logger.debug('🎯 [Mobile] ========== 延迟300ms后执行 ==========');

        // 关闭来电对话框（如果正在显示）
        // 🔴 修复：只有在来电对话框确实显示时才关闭
        if (_isShowingIncomingCallDialog) {
          logger.debug('🎯 [Mobile] 检测到来电对话框标志为 true，准备关闭');
          
          // 🔴 修复：使用保存的 dialogContext 关闭对话框
          if (_incomingCallDialogContext != null) {
            try {
              Navigator.of(_incomingCallDialogContext!).pop();
              logger.debug('🎯 [Mobile] 已通过 Navigator.pop() 关闭来电对话框');
            } catch (e) {
              logger.debug('⚠️ [Mobile] 关闭来电对话框失败: $e');
            }
            _incomingCallDialogContext = null;
          }
          
          setState(() {
            _isShowingIncomingCallDialog = false;
          });
          logger.debug('🎯 [Mobile] 已重置 _isShowingIncomingCallDialog 标志');
        }

        // 🔴 新增：延迟检查悬浮按钮状态
        // 如果通话已结束但悬浮按钮仍显示，可能是对方挂断或其他异常情况
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted &&
              _showCallFloatingButton &&
              _agoraService != null &&
              (_agoraService.callState == CallState.idle ||
                  _agoraService.callState == CallState.ended)) {
            logger.debug('📞 [Mobile] 延迟检查：通话已结束但悬浮按钮仍显示，现在隐藏');
            setState(() {
              _showCallFloatingButton = false;
              _floatingCallUserId = null;
              _floatingCallDisplayName = null;
              _floatingCallType = null;
              _floatingIsGroupCall = false;
              _floatingGroupId = null;
            });
          }
        });

        // 🔴 发送通话结束消息
        // ⚠️ 注意：只有本地主动挂断时才发送通话结束消息，避免双方都发送导致重复
        // 🔴 使用回调开始时保存的 isLocalHangup 值，而不是延迟后重新获取
        logger.debug('🎯 [Mobile] 是否本地主动挂断: $isLocalHangup (使用保存的值)');
        
        if (callDuration > 0 && isLocalHangup) {
          logger.debug('🎯 [Mobile] 检查通话类型:');
          logger.debug('  - _isInGroupCall: $_isInGroupCall');
          logger.debug('  - _currentGroupCallId: $_currentGroupCallId');
          logger.debug('  - lastGroupId (保存的): $lastGroupId');
          logger.debug('  - lastCallType (保存的): $lastCallType');

          // 🔴 使用回调开始时保存的 lastGroupId（支持 TUICallKit 发起的群组通话）
          final effectiveGroupId = lastGroupId ?? _currentGroupCallId;
          final effectiveCallType = lastCallType ?? _currentCallType ?? CallType.voice;

          if (effectiveGroupId != null && effectiveGroupId > 0) {
            // 群组通话：发送群组消息
            logger.debug('📞 [Mobile] 发送群组通话结束消息，时长: $callDuration 秒, 群组ID: $effectiveGroupId');
            await _sendGroupCallEndedMessage(
              effectiveGroupId,
              callDuration,
              effectiveCallType,
            );
          } else {
            // 🔴 使用回调开始时保存的 lastCallUserId
            logger.debug('🎯 [Mobile] 进入一对一通话分支');
            logger.debug('🎯 [Mobile] lastCallUserId (保存的): $lastCallUserId, _currentCallUserId: $_currentCallUserId');
            final effectiveCallUserId = lastCallUserId ?? _currentCallUserId;
            logger.debug('🎯 [Mobile] effectiveCallUserId: $effectiveCallUserId');
            
            if (effectiveCallUserId != null && effectiveCallUserId != 0) {
              // 一对一通话：发送私聊消息
              logger.debug('🎯 [Mobile] 发送一对一通话结束消息，时长: $callDuration 秒, 目标用户: $effectiveCallUserId');
              await _sendCallEndedMessage(
                effectiveCallUserId,
                callDuration,
                effectiveCallType,
              );
              // 注意：_callEndedMessageSent 已在回调开始时设置，这里不需要重复设置
            } else {
              logger.debug('🎯 [Mobile] 无有效的目标用户或群组，跳过发送消息');
            }
          }
        } else if (callDuration > 0 && !isLocalHangup) {
          logger.debug('🎯 [Mobile] 对方挂断，不发送通话结束消息（由对方发送）');
        }

        // 重置群组通话标志
        _isInGroupCall = false;
        _currentGroupCallId = null;
        _currentCallUserId = null;
        _currentCallType = null;

        logger.debug('🎯 [Mobile] ========== 延迟回调完成 ==========');
      });
    };

    // 🔴 新增：设置通话取消回调（发起方取消或接收方收到取消通知时触发）
    _agoraService.onCallCancelled = (int targetUserId, CallType callType, bool isCaller) async {
      logger.debug('📞 [Mobile] 通话取消回调被触发');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 是否为发起方: $isCaller');
      
      // 🔴 如果是接收方收到取消通知，需要关闭来电对话框，但不发送消息
      if (!isCaller) {
        logger.debug('📞 [Mobile] 接收方收到取消通知，关闭来电对话框，不发送消息（由发起方发送）');
        
        // 停止铃声和震动
        _stopRingtone();
        
        // 关闭来电对话框（如果正在显示）
        if (_isShowingIncomingCallDialog) {
          logger.debug('📞 [Mobile] 正在关闭来电对话框...');
          
          // 使用保存的 dialogContext 关闭对话框
          if (_incomingCallDialogContext != null) {
            try {
              Navigator.of(_incomingCallDialogContext!).pop();
              logger.debug('📞 [Mobile] 已通过 Navigator.pop() 关闭来电对话框');
            } catch (e) {
              logger.debug('⚠️ [Mobile] 关闭来电对话框失败: $e');
            }
            _incomingCallDialogContext = null;
          }
          
          if (mounted) {
            setState(() {
              _isShowingIncomingCallDialog = false;
            });
          }
          logger.debug('📞 [Mobile] 已重置 _isShowingIncomingCallDialog 标志');
        }
        
        // 重置通话状态
        _currentCallUserId = null;
        _currentCallType = null;
        _isInGroupCall = false;
        _currentGroupCallId = null;
        
        // 🔴 接收方不发送消息，因为发起方已经发送了"对方已取消"消息
        return;
      }
      
      // 🔴 只有发起方取消时才发送消息
      await _sendCallCancelledMessage(targetUserId, callType, isCaller: isCaller);
    };

    // 🔴 新增：设置接收方拒绝通话回调（通过 TUICallKit 内置 UI 拒绝时触发）
    _agoraService.onCallRejectedByMe = (int callerUserId, CallType callType) async {
      logger.debug('📞 [Mobile] 接收方拒绝通话回调被触发');
      logger.debug('  - 发起方用户ID: $callerUserId');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      
      // 发送拒绝消息给发起方
      await _sendCallRejectedMessage(callerUserId, callType, isRejecter: true);
    };
    
    // 🔴 新增：设置通话中收到新来电被自动拒绝回调（发送"对方正在通话中"消息）
    _agoraService.onCallBusyRejected = (int callerId, CallType callType) async {
      logger.debug('📞 [Mobile] 通话中收到新来电被自动拒绝回调被触发');
      logger.debug('  - 来电者用户ID: $callerId');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      
      // 发送"对方正在通话中"消息给来电者
      await _sendCallBusyMessage(callerId, callType);
    };

    logger.debug('📞 Agora 服务初始化完成');
  }

  /// 开始播放来电铃声和震动
  void _startRingtone() async {
    try {
      // 播放铃声
      _ringtonePlayer = AudioPlayer();
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop); // 循环播放
      await _ringtonePlayer!.play(AssetSource('mp3/wait.mp3'));
      logger.debug('🔔 开始播放来电铃声');

      // 开始震动 - 使用定时器实现间歇性震动
      _vibrationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        HapticFeedback.heavyImpact(); // 重震动
        logger.debug('📳 触发震动');
      });
    } catch (e) {
      logger.error('❌ 播放铃声或震动失败: $e');
    }
  }

  /// 停止播放来电铃声和震动
  void _stopRingtone() {
    try {
      // 停止播放铃声
      if (_ringtonePlayer != null) {
        _ringtonePlayer!.stop();
        _ringtonePlayer!.dispose();
        _ringtonePlayer = null;
        logger.debug('🔇 停止播放来电铃声');
      }

      // 停止震动
      if (_vibrationTimer != null) {
        _vibrationTimer!.cancel();
        _vibrationTimer = null;
        logger.debug('📴 停止震动');
      }
    } catch (e) {
      logger.error('❌ 停止铃声或震动失败: $e');
    }
  }

  /// 显示来电对话框
  void _showIncomingCallDialog(
    int userId,
    String displayName,
    CallType callType,
  ) {
    logger.debug('🔔 显示来电对话框 - 用户: $displayName ($userId), 类型: $callType');

    // 🔴 检查应用生命周期状态
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    logger.debug('🔔 [showDialog] 应用生命周期状态: $lifecycleState');

    // 🔴 保存通话状态（用于后续处理）
    _currentCallUserId = userId;
    _currentCallType = callType;
    _isInGroupCall = false; // 一对一通话
    _currentGroupCallId = null;

    // 防止重复显示对话框
    if (_isShowingIncomingCallDialog) {
      logger.debug('⚠️ 对话框已在显示中，跳过重复调用');
      return;
    }

    setState(() {
      _isShowingIncomingCallDialog = true;
    });

    // 开始播放铃声和震动
    _startRingtone();

    final currentUserId = int.tryParse(_userId);
    if (currentUserId == null) {
      logger.debug('⚠️ 当前用户ID无效: $_userId');
      _isShowingIncomingCallDialog = false;
      return;
    }

    // 🔴 iOS 后台时，调用 CallKit 显示系统来电界面
    if (Platform.isIOS && lifecycleState != AppLifecycleState.resumed) {
      logger.debug('📱 [iOS] 应用在后台，调用 CallKit 显示来电');
      
      // 获取 Agora 通话信息
      final channelName = _agoraService?.currentChannelName ?? '';
      final token = _agoraService?.currentToken ?? '';
      
      // 调用 CallKit 显示来电界面
      CallKitService().reportIncomingCall(
        callerId: userId,
        callerName: displayName,
        callType: callType == CallType.voice ? 'voice' : 'video',
        channelName: channelName,
        token: token,
        isGroupCall: false,
      );
      
      // 铃声已经在播放，等待用户通过 CallKit 接听或拒绝
      return;
    }

    // 🔴 调试：检查 context 和 mounted 状态
    logger.debug('🔔 [showDialog] 准备显示对话框...');
    logger.debug('🔔 [showDialog] mounted: $mounted');
    logger.debug('🔔 [showDialog] context.mounted: ${context.mounted}');
    
    if (!mounted) {
      logger.debug('❌ [showDialog] Widget 未挂载，无法显示对话框');
      _isShowingIncomingCallDialog = false;
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        logger.debug('🔔 [showDialog] AlertDialog builder 被调用');
        // 🔴 保存 dialogContext，用于在通话取消时关闭对话框
        _incomingCallDialogContext = dialogContext;
        return AlertDialog(
          title: Text('${callType == CallType.voice ? '语音' : '视频'}通话'),
          content: Text('$displayName 正在呼叫...'),
          actions: [
            TextButton(
              onPressed: () {
                logger.debug('🔴 用户点击拒接按钮');
                _stopRingtone(); // 停止响铃和震动
                _incomingCallDialogContext = null; // 🔴 清除保存的 context
                Navigator.of(dialogContext).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    await _agoraService.rejectCall();
                    logger.debug('🔴 拒绝通话操作完成');

                    // 发送拒绝消息到聊天记录
                    await _sendCallRejectedMessage(userId, callType);
                  }
                });
              },
              child: const Text('拒接'),
            ),
            ElevatedButton(
              onPressed: () {
                logger.debug('🟢 用户点击接听按钮');
                _stopRingtone(); // 停止响铃和震动

                // 🔴 修复：保存context引用，避免对话框关闭后context失效
                final navigatorContext = Navigator.of(dialogContext).context;
                _incomingCallDialogContext = null; // 🔴 清除保存的 context
                Navigator.of(dialogContext).pop();

                // 🔴 显示"正在连接中..."弹窗
                _showConnectingDialog(
                  navigatorContext,
                  userId,
                  displayName,
                  callType,
                  currentUserId,
                  isGroupCall: false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: const Text('接听'),
            ),
          ],
        );
      },
    ).then((_) {
      if (mounted) {
        setState(() {
          _isShowingIncomingCallDialog = false;
        });
        // 确保对话框关闭时停止响铃和震动
        _stopRingtone();
      }
    });
  }

  /// 🔴 显示"正在连接中..."弹窗，连接成功后跳转到通话页面
  void _showConnectingDialog(
    BuildContext navigatorContext,
    int userId,
    String displayName,
    CallType callType,
    int currentUserId, {
    bool isGroupCall = false,
    List<int>? groupCallUserIds,
    List<String>? groupCallDisplayNames,
    int? groupId,
  }) {
    logger.debug('🔗 显示连接中弹窗...');
    
    // 用于控制连接弹窗的关闭
    bool isConnectingDialogShowing = true;
    BuildContext? connectingDialogContext;
    
    // 显示连接中弹窗
    showDialog(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (ctx) {
        connectingDialogContext = ctx;
        return WillPopScope(
          onWillPop: () async => false, // 禁止返回键关闭
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '正在连接中...',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  displayName,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    
    // 执行接听操作
    Future.microtask(() async {
      if (FeatureConfig.enableWebRTC && _agoraService != null) {
        logger.debug('🟢 准备接听通话...');
        await _agoraService.acceptCall();
        logger.debug('🟢 通话已接听');

        // 关闭连接中弹窗
        if (isConnectingDialogShowing && connectingDialogContext != null) {
          Navigator.of(connectingDialogContext!).pop();
          isConnectingDialogShowing = false;
        }

        if (mounted) {
          logger.debug('🟢 准备打开通话页面');
          // 在本地尝试获取主叫头像，用于通话页面展示
          String? callerAvatar;
          try {
            final snapshot = await LocalDatabaseService()
                .getContactSnapshot(
              ownerId: currentUserId,
              contactId: userId,
              contactType: 'user',
            );
            if (snapshot != null) {
              callerAvatar = snapshot['avatar']?.toString();
              logger.debug(
                '📞 [MobileHomePage] 来电使用本地联系人头像: $callerAvatar',
              );
            }
          } catch (e) {
            logger.debug(
              '⚠️ [MobileHomePage] 获取本地主叫头像失败: $e',
            );
          }

          logger.debug('🔴🔴🔴 [VoiceCallPage-位置1] 来电单人通话 - 打开VoiceCallPage');
          logger.debug('🔴🔴🔴 [VoiceCallPage-位置1] userId=$userId, displayName=$displayName, callType=$callType');
          final result = await Navigator.of(navigatorContext).push(
            MaterialPageRoute(
              builder: (ctx) => VoiceCallPage(
                targetUserId: userId,
                targetDisplayName: displayName,
                targetAvatar: callerAvatar,
                isIncoming: true,
                callType: callType,
                currentUserId: currentUserId,
              ),
            ),
          );

          // 处理通话结束后的结果
          if (result is Map) {
            logger.debug('📱 [Mobile] 通话页面返回结果: $result');

            // 🔴 修复：处理通话最小化（用户点击返回箭头，通话继续）
            if (result['showFloatingButton'] == true) {
              logger.debug('📱 [Mobile] 一对一通话最小化，显示悬浮按钮，通话继续');
              logger.debug('📱 [Mobile] 保存悬浮按钮状态:');
              logger.debug('  - userId: $userId');
              logger.debug('  - displayName: $displayName');
              logger.debug('  - callType: $callType');
              // 显示悬浮按钮，用户可以点击恢复通话窗口
              setState(() {
                _showCallFloatingButton = true;
                _floatingCallUserId = userId;
                _floatingCallDisplayName = displayName;
                _floatingCallType = callType;
                _floatingIsGroupCall = false; // 一对一通话
                _floatingGroupId = null;
              });
              logger.debug(
                '📱 [Mobile] ✅ setState完成，_showCallFloatingButton = $_showCallFloatingButton',
              );

              // 🔴 修复：延迟触发 onCallStateChanged，等通话页面完全 dispose
              // 延迟时间增加到600ms，确保通话页面完全dispose并恢复监听器
              Future.delayed(const Duration(milliseconds: 600), () {
                logger.debug(
                  '📱 [Mobile] 🔥 延迟触发 onCallStateChanged 通知其他页面',
                );
                _agoraService!.onCallStateChanged?.call(
                  CallState.connected,
                );
              });

              return;
            }

            // 通话结束的各种情况都需要隐藏悬浮按钮
            if (result['callRejected'] == true) {
              // 接收方拒绝了通话（在通话页面点击拒接）
              setState(() {
                _showCallFloatingButton = false;
              });
              final returnedCallType = result['callType'] as CallType?;
              await _sendCallRejectedMessage(
                userId,
                returnedCallType ?? callType,
              );
            } else if (result['callCancelled'] == true) {
              // 对方取消了通话
              setState(() {
                _showCallFloatingButton = false;
              });
              final returnedCallType = result['callType'] as CallType?;
              await _sendCallCancelledMessage(
                userId,
                returnedCallType ?? callType,
                isCaller: false,
              );
            } else if (result['callEnded'] == true) {
              // 正常结束通话
              setState(() {
                _showCallFloatingButton = false;
              });
              // 🔴 修复：使用返回结果中的 isLocalHangup，而不是从 agoraService 读取
              // 因为 agoraService 的状态可能已经被重置
              final isLocalHangup = result['isLocalHangup'] as bool? ?? false;
              if (!_callEndedMessageSent && isLocalHangup) {
                final callDuration = result['callDuration'] as int? ?? 0;
                final returnedCallType = result['callType'] as CallType?;
                await _sendCallEndedMessage(
                  userId,
                  callDuration,
                  returnedCallType ?? callType,
                );
              } else {
                logger.debug('🎯 [Mobile] 通话结束消息已发送或对方挂断，跳过发送');
              }
              // 重置标志
              _callEndedMessageSent = false;
            }
          }
        }
      }
    });
  }

  /// 显示群组来电对话框
  void _showIncomingGroupCallDialog(
    int userId,
    String displayName,
    CallType callType,
    List<Map<String, dynamic>> members,
    int? groupId,
  ) {
    logger.debug('🔔 ========== 显示群组来电对话框 ==========');
    logger.debug('🔔 发起人ID: $userId, 名称: $displayName, 类型: $callType');
    logger.debug('🔔 群组ID: $groupId');
    logger.debug('🔔 成员数量: ${members.length}');
    logger.debug('🔔 成员详情: $members');
    logger.debug('🔔 当前用户ID: $_userId');
    logger.debug('🔔 当前标志状态: $_isShowingIncomingCallDialog');

    // 🔴 保存通话状态
    _isInGroupCall = true;
    _currentGroupCallId = groupId;
    _currentCallUserId = userId;
    _currentCallType = callType;

    // 🔴 防止重复显示对话框
    if (_isShowingIncomingCallDialog) {
      logger.debug('⚠️ 对话框已在显示中，跳过重复调用');
      return;
    }

    // 如果显示名称为空，使用默认值
    final effectiveDisplayName = displayName.isEmpty ? 'Unknown' : displayName;

    // 标记对话框正在显示
    setState(() {
      _isShowingIncomingCallDialog = true;
    });

    // 开始播放铃声和震动
    _startRingtone();

    final currentUserId = int.tryParse(_userId);
    if (currentUserId == null) {
      logger.debug('⚠️ 当前用户ID无效: $_userId');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        // 🔴 保存 dialogContext，用于在通话取消时关闭对话框
        _incomingCallDialogContext = dialogContext;
        
        // 🔴 构建成员名称列表（排除自己）
        final memberNames = members
            .where((m) => m['user_id'] != currentUserId)
            .map((m) => m['display_name'] as String? ?? '未知')
            .toList();
        final memberNamesText = memberNames.length > 3 
            ? '${memberNames.take(3).join('、')} 等${memberNames.length}人'
            : memberNames.join('、');
        
        return AlertDialog(
          title: Text('${callType == CallType.voice ? '群组语音' : '群组视频'}通话'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$effectiveDisplayName 邀请你加入群组通话'),
              const SizedBox(height: 8),
              Text(
                '参与成员: $memberNamesText',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                logger.debug('🔴 用户拒绝群组通话');
                _stopRingtone(); // 停止响铃和震动
                _incomingCallDialogContext = null; // 🔴 清除保存的 context
                Navigator.of(dialogContext).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    await _agoraService.rejectCall();
                    logger.debug('🔴 拒绝通话操作完成');
                  }
                });
              },
              child: const Text('拒接'),
            ),
            ElevatedButton(
              onPressed: () {
                logger.debug('🟢 用户接听群组通话');
                _stopRingtone(); // 停止响铃和震动

                // 🔴 修复：保存context引用，避免对话框关闭后context失效
                final navigatorContext = Navigator.of(dialogContext).context;
                _incomingCallDialogContext = null; // 🔴 清除保存的 context
                Navigator.of(dialogContext).pop();

                // 提取成员的用户ID和显示名称列表
                final memberUserIds = members
                    .map((m) => m['user_id'] as int)
                    .toList();
                final memberDisplayNames = members.map((m) {
                  // 对于当前用户，显示名称应该显示"我"
                  if (m['user_id'] == currentUserId) {
                    return '我';
                  }
                  return m['display_name'] as String;
                }).toList();

                // 🔴 显示"正在连接中..."弹窗
                _showConnectingDialogForGroupCall(
                  navigatorContext,
                  userId,
                  effectiveDisplayName,
                  callType,
                  currentUserId,
                  memberUserIds,
                  memberDisplayNames,
                  groupId,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: const Text('接听'),
            ),
          ],
        );
      },
    ).then((_) {
      if (mounted) {
        setState(() {
          _isShowingIncomingCallDialog = false;
        });
        // 确保对话框关闭时停止响铃和震动
        _stopRingtone();
      }
    });
  }

  /// 🔴 显示群组通话"正在连接中..."弹窗
  void _showConnectingDialogForGroupCall(
    BuildContext navigatorContext,
    int userId,
    String displayName,
    CallType callType,
    int currentUserId,
    List<int> memberUserIds,
    List<String> memberDisplayNames,
    int? groupId,
  ) {
    logger.debug('🔗 显示群组通话连接中弹窗...');
    
    // 用于控制连接弹窗的关闭
    bool isConnectingDialogShowing = true;
    BuildContext? connectingDialogContext;
    
    // 显示连接中弹窗
    showDialog(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (ctx) {
        connectingDialogContext = ctx;
        return WillPopScope(
          onWillPop: () async => false, // 禁止返回键关闭
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '正在连接中...',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  displayName,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    
    // 执行接听操作
    Future.microtask(() async {
      if (FeatureConfig.enableWebRTC && _agoraService != null) {
        logger.debug('🟢 准备接听群组通话...');
        await _agoraService.acceptCall();
        logger.debug('🟢 群组通话已接听');

        // 关闭连接中弹窗
        if (isConnectingDialogShowing && connectingDialogContext != null) {
          Navigator.of(connectingDialogContext!).pop();
          isConnectingDialogShowing = false;
        }

        if (mounted) {
          logger.debug('🟢 准备打开群组通话页面');
          logger.debug('🟢 成员ID列表: $memberUserIds');
          logger.debug('🟢 成员显示名称: $memberDisplayNames');

          // 为群组成员构建头像URL列表（来电场景）
          final List<String?> memberAvatarUrls = [];
          try {
            final db = LocalDatabaseService();
            logger.debug('📞 [MobileHomePage] 开始构建来电群组通话成员头像列表');
            logger.debug('📞 [MobileHomePage] 成员数量: ${memberUserIds.length}, currentUserId: $currentUserId');
            for (final uid in memberUserIds) {
              String? avatarUrl;
              if (uid == currentUserId) {
                // 当前用户使用本地存储的头像
                avatarUrl = await Storage.getAvatar();
                logger.debug('📞 [MobileHomePage] 成员$uid是当前用户，使用Storage头像: $avatarUrl');
              } else {
                final snapshot = await db.getContactSnapshot(
                  ownerId: currentUserId,
                  contactId: uid,
                  contactType: 'user',
                );
                if (snapshot == null) {
                  logger.debug('📞 [MobileHomePage] 成员$uid在contact_snapshots中未找到记录，使用空头像');
                } else {
                  logger.debug('📞 [MobileHomePage] 成员$uid命中contact_snapshots，avatar=${snapshot['avatar']}');
                }
                avatarUrl = snapshot?['avatar']?.toString();
              }
              logger.debug('📞 [MobileHomePage] 成员$uid最终使用头像: $avatarUrl');
              memberAvatarUrls.add(avatarUrl);
            }
            logger.debug('📞 [MobileHomePage] 来电群组通话成员头像列表构建完成，长度: ${memberAvatarUrls.length}');
          } catch (e) {
            logger.debug('⚠️ [MobileHomePage] 构建来电群组成员头像列表失败: $e');
            while (memberAvatarUrls.length < memberUserIds.length) {
              memberAvatarUrls.add(null);
            }
          }

          // 跳转到群组通话页面，并处理返回结果
          logger.debug('🔴🔴🔴 [VoiceCallPage-位置2] 来电群组通话 - 打开VoiceCallPage/GroupVideoCallPage');
          logger.debug('🔴🔴🔴 [VoiceCallPage-位置2] userId=$userId, displayName=$displayName, callType=$callType, groupId=$groupId');
          final result = await Navigator.of(navigatorContext).push(
            MaterialPageRoute(
              builder: (ctx) => callType == CallType.voice
                  ? VoiceCallPage(
                      targetUserId: userId,
                      targetDisplayName: displayName,
                      isIncoming: true,
                      callType: callType,
                      groupCallUserIds: memberUserIds,
                      groupCallDisplayNames: memberDisplayNames,
                      groupCallAvatarUrls: memberAvatarUrls,
                      currentUserId: currentUserId,
                      groupId: groupId,
                    )
                  : GroupVideoCallPage(
                      targetUserId: userId,
                      targetDisplayName: displayName,
                      isIncoming: true,
                      groupCallUserIds: memberUserIds,
                      groupCallDisplayNames: memberDisplayNames,
                      currentUserId: currentUserId,
                      groupId: groupId,
                    ),
            ),
          );

          // 处理群组通话结束
          if (result is Map<String, dynamic>) {
            logger.debug('📱 [Mobile] 群组通话页面返回结果: $result');

            // 🔴 修复：处理通话最小化（用户点击返回箭头，通话继续）
            if (result['showFloatingButton'] == true) {
              logger.debug('📱 [Mobile] 群组通话最小化，显示悬浮按钮，通话继续');
              // 显示悬浮按钮，用户可以点击恢复通话窗口
              setState(() {
                _showCallFloatingButton = true;
                _floatingCallUserId = userId;
                _floatingCallDisplayName = displayName;
                _floatingCallType = callType;
                _floatingIsGroupCall = true; // 群组通话
                _floatingGroupId = groupId;
                _floatingGroupCallUserIds = memberUserIds; // 保存群组成员ID
                _floatingGroupCallDisplayNames = memberDisplayNames; // 保存群组成员显示名称
              });

              // 🔴 修复：延迟触发 onCallStateChanged，等通话页面完全 dispose
              // 延迟时间增加到600ms，确保通话页面完全dispose并恢复监听器
              Future.delayed(const Duration(milliseconds: 600), () {
                logger.debug(
                  '📱 [Mobile] 🔥 延迟触发 onCallStateChanged 通知其他页面（群组通话）',
                );
                _agoraService!.onCallStateChanged?.call(
                  CallState.connected,
                );
              });

              return;
            }

            // 通话真正结束时也要隐藏悬浮按钮
            if (result['callEnded'] == true ||
                result['callRejected'] == true ||
                result['callCancelled'] == true) {
              setState(() {
                _showCallFloatingButton = false;
              });

              if (result['callEnded'] == true) {
                final callDuration = result['callDuration'] as int? ?? 0;
                logger.debug('🟢 群组通话结束，时长: $callDuration 秒');
                logger.debug('🟢 群组ID: $groupId');
                // 🔴 修复：移除客户端发送群组通话时长消息的逻辑
                // 群组通话时长消息由服务器端统一处理（只有最后一个成员离开时才发送）
                if (groupId != null && callDuration > 0) {
                  logger.debug('📞 [Mobile] 群组通话结束，服务器端将处理通话时长消息');
                  // 注意：服务器会自动删除"加入通话"按钮并推送delete_message通知
                  // 客户端通过WebSocket自动处理，不需要手动刷新
                }
              }
            }
          }
        }
      }
    });
  }

  /// 发送通话拒绝消息
  /// isRejecter: true 表示是拒绝方（接收方），false 表示是发起方（收到拒绝通知）
  Future<void> _sendCallRejectedMessage(
    int targetUserId,
    CallType callType, {
    bool isRejecter = true,
  }) async {
    try {
      // 发送给对方的消息内容
      // 如果是接收方拒绝，发送给发起方显示"对方已拒绝"
      // 如果是发起方收到拒绝通知，发送给接收方显示"已拒绝"
      final contentToSend = isRejecter ? '对方已拒绝' : '已拒绝';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_rejected_video'
          : 'call_rejected';

      logger.debug('📞 [Mobile] 发送通话拒绝消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为拒绝方: $isRejecter');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 消息类型: $messageType');

      // 🔴 如果是接收方拒绝，先发送 WebRTC 信令通知 PC 端关闭呼叫界面
      if (isRejecter) {
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          _wsService.sendWebRTCSignal({
            'type': 'call_rejected',
            'to_user_id': targetUserId,
            'from_user_id': currentUserId,
            'call_type': callType == CallType.video ? 'video' : 'voice',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
          logger.debug('📞 [Mobile] 已发送 call_rejected WebRTC 信令给 PC 端');
        }
      }

      // 发送聊天消息（用于在对话框中显示）
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      logger.debug('✅ [Mobile] 通话拒绝消息已发送，等待message_sent确认后保存到数据库');
    } catch (e) {
      logger.error('❌ [Mobile] 发送通话拒绝消息失败: $e');
    }
  }

  /// 🔴 新增：发送"对方正在通话中"消息
  /// 当用户正在通话中收到一对一来电时，自动拒绝并发送此消息
  Future<void> _sendCallBusyMessage(
    int targetUserId,
    CallType callType,
  ) async {
    try {
      // 消息内容：对方正在通话中
      const contentToSend = '对方正在通话中';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_busy_video'
          : 'call_busy';

      logger.debug('📞 [Mobile] 发送"对方正在通话中"消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 消息类型: $messageType');

      // 发送聊天消息（用于在对话框中显示）
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      logger.debug('✅ [Mobile] "对方正在通话中"消息已发送');
    } catch (e) {
      logger.error('❌ [Mobile] 发送"对方正在通话中"消息失败: $e');
    }
  }


  /// 发送通话取消消息
  Future<void> _sendCallCancelledMessage(
    int targetUserId,
    CallType callType, {
    bool isCaller = true,
  }) async {
    try {
      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_cancelled_video'
          : 'call_cancelled';

      logger.debug('📞 [Mobile] 发送通话取消消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 是否为发起方: $isCaller');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 消息类型: $messageType');

      if (isCaller) {
        // 🔴 发起方取消通话：发送"已取消"消息
        // 消息内容统一为"已取消"，显示时根据 isSender 转换：
        // - 发送者（发起方）看到"已取消"
        // - 接收者看到"对方已取消"
        await _wsService.sendMessage(
          receiverId: targetUserId,
          content: '已取消',
          messageType: messageType,
        );
        logger.debug('✅ [Mobile] 发起方取消消息已发送给对方');
        
        // 🔴 同时发送 WebRTC 信令，确保 PC 端能收到取消通知
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          _wsService.sendWebRTCSignal({
            'type': 'call-cancel',
            'to_user_id': targetUserId,
            'from_user_id': currentUserId,
          });
          logger.debug('✅ [Mobile] WebRTC 取消信令已发送给 PC 端');
        }
      } else {
        // 🔴 接收方收到取消通知：不需要发送消息给对方
        // 因为发起方已经发送了取消消息，接收方会通过 WebSocket 收到
        logger.debug('📞 [Mobile] 接收方收到取消通知，不需要发送消息（由发起方发送）');
      }

      // 短暂延迟后刷新聊天列表
      await Future.delayed(const Duration(milliseconds: 300));
      _chatListKey.currentState?.refresh();
      logger.debug('🔄 [Mobile] 已触发聊天列表刷新');
    } catch (e) {
      logger.error('❌ [Mobile] 发送通话取消消息失败: $e');
    }
  }

  /// 发送通话结束消息
  Future<void> _sendCallEndedMessage(
    int targetUserId,
    int callDuration,
    CallType callType,
  ) async {
    // 如果通话时长是 0，说明通话没有真正进行，不发送通话结束消息
    if (callDuration <= 0) {
      logger.debug('📞 [Mobile] 通话时长是 0，不发送通话结束消息');
      return;
    }

    try {
      // 格式化通话时长
      final hours = callDuration ~/ 3600;
      final minutes = (callDuration % 3600) ~/ 60;
      final secs = callDuration % 60;
      String durationText;
      if (hours > 0) {
        durationText =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      } else {
        durationText =
            '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      }

      // 获取通话类型字符串
      final callTypeStr = (callType == CallType.video) ? 'video' : 'voice';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_ended_video'
          : 'call_ended';

      logger.debug('📞 [Mobile] 发送通话结束消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 通话时长: $durationText');
      logger.debug('  - 通话类型: $callTypeStr');
      logger.debug('  - 消息类型: $messageType');

      // 发送消息
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: durationText,
        messageType: messageType,
        callType: callTypeStr,
      );

      logger.debug('✅ [Mobile] 通话结束消息已发送');

      // 短暂延迟后刷新聊天列表
      await Future.delayed(const Duration(milliseconds: 300));
      _chatListKey.currentState?.refresh();
      logger.debug('🔄 [Mobile] 已触发聊天列表刷新');
    } catch (e) {
      logger.error('❌ [Mobile] 发送通话结束消息失败: $e');
    }
  }

  /// 发送群组通话结束消息
  Future<void> _sendGroupCallEndedMessage(
    int groupId,
    int callDuration,
    CallType callType,
  ) async {
    // 如果通话时长是 0，说明通话没有真正进行，不发送消息
    if (callDuration <= 0) {
      logger.debug('📞 [Mobile] 通话时长是 0，不发送群组通话结束消息');
      return;
    }

    try {
      // 格式化通话时长
      final hours = callDuration ~/ 3600;
      final minutes = (callDuration % 3600) ~/ 60;
      final secs = callDuration % 60;
      String durationText;
      if (hours > 0) {
        durationText =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      } else {
        durationText =
            '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      }

      final content = '通话时长 $durationText';

      logger.debug('📞 [Mobile] 发送群组通话结束消息:');
      logger.debug('  - 群组ID: $groupId');
      logger.debug('  - 通话时长: $durationText');
      logger.debug('  - 内容: $content');

      // 根据通话类型设置正确的 message_type
      final messageType = callType == CallType.video
          ? 'call_ended_video'
          : 'call_ended';

      // 发送群组消息
      await _wsService.sendGroupMessage(
        groupId: groupId,
        content: content,
        messageType: messageType,
      );

      logger.debug('✅ [Mobile] 群组通话结束消息已发送');

      // 短暂延迟后刷新聊天列表
      await Future.delayed(const Duration(milliseconds: 300));
      _chatListKey.currentState?.refresh();
      logger.debug('🔄 [Mobile] 已触发聊天列表刷新');
    } catch (e) {
      logger.error('❌ [Mobile] 发送群组通话结束消息失败: $e');
    }
  }

  /// 发送群组通话发起消息
  Future<void> _sendGroupCallInitiatedMessage(
    int groupId,
    CallType callType,
  ) async {
    try {
      final callTypeText = callType == CallType.video ? '视频' : '语音';
      final senderName = _userDisplayName.isNotEmpty
          ? _userDisplayName
          : _username;
      final content = '$senderName 发起了${callTypeText}通话';

      logger.debug('📞 [Mobile] 准备发送群组通话发起消息:');
      logger.debug('  - 群组ID: $groupId');
      // 注释：不再由客户端发送通话发起消息，改由服务器端统一发送 join_voice_button 或 join_video_button 消息
      // final content = '$displayName 发起了$callTypeText';
      // await _wsService.sendGroupMessage(
      //   groupId: groupId,
      //   content: content,
      //   messageType: 'call_initiated',
      // );

      logger.debug('✅ [Mobile] 群组通话发起，服务器端将发送按钮消息');
    } catch (e) {
      logger.error('❌ [Mobile] 发送群组通话发起消息失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // 🔴 新方案：检查 AgoraService 的全局最小化标识
    if (_agoraService != null &&
        !_showCallFloatingButton &&
        _agoraService.isCallMinimized) {
      final agoraService = _agoraService;
      final minimizedUserId = agoraService.minimizedCallUserId;
      logger.debug('📱 [HomePage Build] 🔥 检测到最小化通话');
      logger.debug('  - minimizedUserId: $minimizedUserId');

      if (minimizedUserId != null && minimizedUserId != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_showCallFloatingButton) {
            logger.debug('📱 [HomePage Build] ✅ 通过全局标识设置悬浮按钮');

            setState(() {
              _showCallFloatingButton = true;
              _floatingCallUserId = minimizedUserId;
              _floatingCallDisplayName =
                  agoraService.minimizedCallDisplayName ?? 'Unknown';
              _floatingCallType =
                  agoraService.minimizedCallType ?? CallType.voice;
              _floatingIsGroupCall = agoraService.minimizedIsGroupCall;
              _floatingGroupId = agoraService.minimizedGroupId;
              _floatingGroupCallUserIds = agoraService.currentGroupCallUserIds;
              _floatingGroupCallDisplayNames =
                  agoraService.currentGroupCallDisplayNames;
            });
          }
        });
      }
    }

    // 🔴 添加调试日志
    if (_showCallFloatingButton) {
      logger.debug(
        '📱 [Build] 悬浮按钮状态: $_showCallFloatingButton, userId: $_floatingCallUserId',
      );
    }

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFEEF1F6),
            elevation: 0,
            centerTitle: true,
            title: Column(
              children: [
                Text(
                  _getPageTitle(l10n),
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // 🔴 网络连接状态显示
                if (_isConnecting)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '正在刷新...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            actions: [
              // 🔴 测试按钮：模拟网络断开（仅在调试模式下显示）
              if (kDebugMode)
                IconButton(
                  icon: Icon(
                    _isConnecting ? Icons.wifi_off : Icons.wifi,
                    color: _isConnecting ? Colors.red : Colors.green,
                  ),
                  onPressed: () {
                    setState(() {
                      _isConnecting = !_isConnecting;
                    });
                    logger.debug('🧪 [测试-会话] 手动切换连接状态: $_isConnecting');
                  },
                  tooltip: '测试网络状态',
                ),
              // 菜单按钮（仅在聊天页面显示）
              if (_currentIndex == 0)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.menu, color: Colors.black87),
                  offset: const Offset(0, 50),
                  itemBuilder: (BuildContext context) => [
                    const PopupMenuItem<String>(
                      value: 'add_contact',
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_add,
                            color: Color(0xFF666666),
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text('添加联系人', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'create_group',
                      child: Row(
                        children: [
                          Icon(
                            Icons.group_add,
                            color: Color(0xFF666666),
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text('创建群组', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'scan_qrcode',
                      child: Row(
                        children: [
                          Icon(
                            Icons.qr_code_scanner,
                            color: Color(0xFF666666),
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text('扫一扫', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (String value) {
                    if (value == 'add_contact') {
                      _chatListKey.currentState?.showAddContactDialog();
                    } else if (value == 'create_group') {
                      _chatListKey.currentState?.showCreateGroupDialog();
                    } else if (value == 'scan_qrcode') {
                      _chatListKey.currentState?.showQRCodeScanner();
                    }
                  },
                ),
            ],
          ),
          body: PageView(
            controller: _pageController,
            // 禁用左右滑动切换，用户只能通过底部导航栏切换页面
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            children: _pages,
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() => _currentIndex = index);
              _pageController.animateToPage(
                index,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.white,
            selectedItemColor: const Color(0xFF4A90E2),
            unselectedItemColor: Colors.grey,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.message),
                label: l10n.translate('chat'),
              ),
              BottomNavigationBarItem(
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.contacts),
                    if (_contactsPendingCount > 0)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 16),
                          height: 16,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF4D4F),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _contactsPendingCount > 99
                                ? '99+'
                                : '$_contactsPendingCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                label: l10n.translate('contacts'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.article),
                label: l10n.translate('news'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.person),
                label: l10n.translate('profile'),
              ),
            ],
          ),
        ), // Scaffold结束
        // 🔴 新增：通话悬浮按钮
        if (_showCallFloatingButton && _floatingCallUserId != null) ...[
          Builder(
            builder: (context) {
              logger.debug('📱 [Mobile] 🎨 正在构建悬浮按钮 Widget');
              return const SizedBox.shrink();
            },
          ),
          Positioned(
            right: 16,
            bottom: 80,
            child: GestureDetector(
              onTap: () async {
                logger.debug('📱 [Mobile] 点击悬浮按钮，恢复通话窗口');
                logger.debug(
                  '📱 [Mobile] 悬浮按钮信息: userId=$_floatingCallUserId, displayName=$_floatingCallDisplayName, callType=$_floatingCallType',
                );

                // 🔴 空安全检查（与PC端保持一致）
                if (_agoraService == null) {
                  logger.debug('⚠️ AgoraService 为空，无法恢复通话');
                  return;
                }

                // 重新打开通话页面
                final currentUserId = int.tryParse(_userId);
                if (currentUserId == null) return;

                final callType = _floatingCallType ?? CallType.voice;

                // 🔴 修复：根据通话类型和是否群组选择正确的页面
                // 只有群组视频通话才使用 GroupVideoCallPage
                // 群组语音通话、一对一通话都使用 VoiceCallPage

                // 🔴 移动端修复：像PC端一样，直接从AgoraService获取最新的群组成员列表
                // 而不是使用状态变量中保存的旧数据，这样可以确保恢复时使用的是最新数据
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置3] 悬浮按钮恢复通话 - 打开VoiceCallPage/GroupVideoCallPage');
                logger.debug('🔴🔴🔴 [VoiceCallPage-位置3] _floatingCallUserId=$_floatingCallUserId, _floatingIsGroupCall=$_floatingIsGroupCall, callType=$callType');
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        (_floatingIsGroupCall && callType == CallType.video)
                        ? GroupVideoCallPage(
                            targetUserId: _floatingCallUserId!,
                            targetDisplayName:
                                _floatingCallDisplayName ?? 'Unknown',
                            isIncoming: false,
                            groupCallUserIds: _floatingIsGroupCall
                                ? _agoraService.currentGroupCallUserIds
                                : null,
                            groupCallDisplayNames: _floatingIsGroupCall
                                ? _agoraService.currentGroupCallDisplayNames
                                : null,
                            currentUserId: currentUserId,
                            groupId: _floatingIsGroupCall
                                ? _agoraService.minimizedGroupId
                                : null,
                          )
                        : VoiceCallPage(
                            targetUserId: _floatingCallUserId!,
                            targetDisplayName:
                                _floatingCallDisplayName ?? 'Unknown',
                            isIncoming: false,
                            callType: callType,
                            groupCallUserIds: _floatingIsGroupCall
                                ? _agoraService.currentGroupCallUserIds
                                : null,
                            groupCallDisplayNames: _floatingIsGroupCall
                                ? _agoraService.currentGroupCallDisplayNames
                                : null,
                            currentUserId: currentUserId,
                            groupId: _floatingIsGroupCall
                                ? _agoraService.minimizedGroupId
                                : null,
                          ),
                  ),
                );

                // 处理通话结束后的结果
                if (result is Map) {
                  // 🔴 修复：如果是再次最小化，保持悬浮按钮显示
                  if (result['showFloatingButton'] == true) {
                    logger.debug('📱 再次最小化，悬浮按钮继续显示');
                    // 不做任何操作，悬浮按钮继续显示
                    return;
                  }

                  // 只有通话真正结束时才隐藏悬浮按钮
                  if (result['callEnded'] == true ||
                      result['callRejected'] == true ||
                      result['callCancelled'] == true) {
                    logger.debug('📱 [Mobile] 收到通话结束结果，立即隐藏悬浮按钮');
                    logger.debug(
                      '📱 [Mobile] callEnded: ${result['callEnded']}',
                    );
                    logger.debug(
                      '📱 [Mobile] callRejected: ${result['callRejected']}',
                    );
                    logger.debug(
                      '📱 [Mobile] callCancelled: ${result['callCancelled']}',
                    );

                    // 🔴 修复：先保存状态，再清空
                    final savedFloatingCallUserId = _floatingCallUserId;
                    final savedFloatingCallType = _floatingCallType;
                    final savedFloatingIsGroupCall = _floatingIsGroupCall;
                    final savedFloatingGroupId = _floatingGroupId;

                    setState(() {
                      _showCallFloatingButton = false;
                      // 🔴 新增：清空相关状态，确保完全重置
                      _floatingCallUserId = null;
                      _floatingCallDisplayName = null;
                      _floatingCallType = null;
                      _floatingIsGroupCall = false;
                      _floatingGroupId = null;
                      _floatingGroupCallUserIds = null;
                      _floatingGroupCallDisplayNames = null;
                    });
                    logger.debug('📱 [Mobile] ✅ 悬浮按钮已隐藏');

                    if (result['callEnded'] == true) {
                      // 🔴 修复：使用返回结果中的 isLocalHangup，而不是从 agoraService 读取
                      final isLocalHangup = result['isLocalHangup'] as bool? ?? false;
                      if (_callEndedMessageSent) {
                        logger.debug('🎯 [Mobile] 通话结束消息已在onCallEnded中发送，跳过重复发送');
                        _callEndedMessageSent = false;
                      } else if (!isLocalHangup) {
                        logger.debug('🎯 [Mobile] 对方挂断，不发送通话结束消息');
                      } else {
                        // 正常结束通话（本地主动挂断）
                        final callDuration = result['callDuration'] as int? ?? 0;
                        final returnedCallType = result['callType'] as CallType?;

                        // 🔴 根据是否是群组通话发送不同的消息
                        if (savedFloatingIsGroupCall && savedFloatingGroupId != null) {
                          // 🔴 修复：移除客户端发送群组通话时长消息的逻辑
                          // 群组通话时长消息由服务器端统一处理（只有最后一个成员离开时才发送）
                          logger.debug('📱 群组通话结束，服务器端将处理通话时长消息');
                        } else if (savedFloatingCallUserId != null) {
                          // 一对一通话结束
                          logger.debug('📱 一对一通话结束，发送私聊消息');
                          await _sendCallEndedMessage(
                            savedFloatingCallUserId,
                            callDuration,
                            returnedCallType ??
                                savedFloatingCallType ??
                                CallType.voice,
                          );
                        } else {
                          logger.debug('📱 ⚠️ 无法发送通话结束消息：缺少目标用户ID');
                        }
                      }
                    }
                  }
                }
              },
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  _floatingCallType == CallType.video
                      ? Icons.videocam
                      : Icons.phone,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
        // 🔴 新增：通话连接中遮盖层
        if (_showConnectingOverlay) ...[
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '正在连接中...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_connectingCallerName != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _connectingCallerName!,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 14,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      _connectingCallType == CallType.video ? '视频通话' : '语音通话',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _getPageTitle(AppLocalizations l10n) {
    switch (_currentIndex) {
      case 0:
        return l10n.translate('chat');
      case 1:
        return l10n.translate('contacts');
      case 2:
        return l10n.translate('news');
      case 3:
        return '我的';
      default:
        return l10n.translate('app_name');
    }
  }

  // 处理被拉黑通知
  void _handleContactBlocked(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final blockData = data as Map<String, dynamic>;
      final operatorName = blockData['operator_name'] as String?;
      final message = blockData['message'] as String?;

      logger.debug('🚫 移动端收到被拉黑通知 - 操作者: $operatorName, 消息: $message');

      // 清除通讯录缓存并刷新
      MobileContactsPage.clearCacheAndRefresh();

      // 显示通知
      if (message != null && message.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      logger.debug('处理被拉黑通知失败: $e');
    }
  }

  // 处理被删除通知
  void _handleContactDeleted(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final deleteData = data as Map<String, dynamic>;
      final operatorName = deleteData['operator_name'] as String?;
      final message = deleteData['message'] as String?;

      logger.debug('🗑️ 移动端收到被删除通知 - 操作者: $operatorName, 消息: $message');

      // 清除通讯录缓存并刷新
      MobileContactsPage.clearCacheAndRefresh();

      // 显示通知
      if (message != null && message.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      logger.debug('处理被删除通知失败: $e');
    }
  }

  // 处理被恢复通知
  void _handleContactUnblocked(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final unblockData = data as Map<String, dynamic>;
      final operatorName = unblockData['operator_name'] as String?;
      final message = unblockData['message'] as String?;

      logger.debug('✅ 移动端收到被恢复通知 - 操作者: $operatorName, 消息: $message');

      // 清除通讯录缓存并刷新
      MobileContactsPage.clearCacheAndRefresh();

      // 显示通知
      if (message != null && message.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      logger.debug('处理被恢复通知失败: $e');
    }
  }

  // 处理群组消息（仅用于刷新通讯录群组列表）
  void _handleGroupMessageForRefresh(dynamic data) {
    try {
      if (data == null) return;

      final messageData = data as Map<String, dynamic>;
      final content = messageData['content'] as String? ?? '';
      final messageType = messageData['message_type'] as String? ?? '';

      logger.debug('📱 检查群组消息 - 内容: $content, 类型: $messageType');

      // 检测是否是群组创建/邀请的系统消息
      if (messageType == 'system' && 
          (content.contains('群组已创建') || 
           content.contains('创建新群组') || 
           content.contains('您已被邀请加入群组'))) {
        logger.debug('🆕 检测到群组创建/邀请消息，刷新通讯录群组缓存: $content');
        
        // 清除通讯录群组缓存并刷新
        MobileContactsPage.clearCacheAndRefresh();
        
        logger.debug('✅ 通讯录群组缓存已刷新');
      }
    } catch (e) {
      logger.debug('处理群组消息刷新失败: $e');
    }
  }
}

/// 移动端聊天列表页面
class MobileChatListPage extends StatefulWidget {
  final Function(int userId, String displayName, bool isGroup,
      {int? groupId, String? avatar}) onChatSelected;
  final Future<void> Function()? onRefresh; // 🔴 添加下拉刷新回调

  const MobileChatListPage({
    Key? key, 
    required this.onChatSelected,
    this.onRefresh, // 🔴 添加可选的刷新回调
  }) : super(key: key);

  @override
  State<MobileChatListPage> createState() => _MobileChatListPageState();

  // 🔴 静态 StreamController：用于通知聊天列表刷新
  static final StreamController<void> _refreshController = 
      StreamController<void>.broadcast();

  // 🔴 静态方法：通知聊天列表刷新（供外部调用，如通讯录页面）
  static void needRefresh() {
    logger.debug('📢 [MobileChatListPage] 收到刷新请求');
    _refreshController.add(null);
  }
}

class _MobileChatListPageState extends State<MobileChatListPage> {
  List<RecentContactModel> _recentContacts = [];
  Map<String, int> _pinnedChats = {}; // 顶置的会话配置 {contactKey: timestamp}
  Set<String> _deletedChats = {}; // 删除的会话配置
  int? _currentUserId; // 当前用户ID（用于文件传输助手的删除过滤）
  bool _isLoading = false; // 🔴 不显示加载动画，直接根据数据状态展示
  bool _isFirstLoad = true; // 🔴 新增：标记是否首次加载
  String? _error;
  
  // 首次同步数据状态
  bool _isSyncingData = false; // 是否正在同步数据
  String? _syncStatusMessage; // 同步状态消息
  
  /// 更新同步状态（供父组件调用）
  void updateSyncStatus(bool isSyncing, String? message) {
    if (mounted) {
      setState(() {
        _isSyncingData = isSyncing;
        _syncStatusMessage = message;
      });
      
      // 🔴 同步完成后刷新聊天列表
      if (!isSyncing && message == null) {
        logger.debug('✅ [同步完成] 刷新最近联系人列表');
        refresh();
      }
    }
  }
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  StreamSubscription<void>? _refreshSubscription; // 🔴 新增：刷新监听器
  final AudioPlayer _audioPlayer = AudioPlayer(); // 音频播放器（用于播放新消息提示音）

  // 🔴 新增：缓存相关（使用Widget类的静态变量）
  static const Duration _cacheDuration = Duration(seconds: 5); // 缓存有效期5秒

  @override
  void initState() {
    super.initState();

    // 🔴 关键优化：同步加载缓存的偏好设置
    if (MobileHomePage._cachedPinnedChats != null) {
      _pinnedChats = Map.from(MobileHomePage._cachedPinnedChats!);
      logger.debug('📦 [同步] 使用缓存的顶置配置 (${_pinnedChats.length}条)');
    }
    if (MobileHomePage._cachedDeletedChats != null) {
      _deletedChats = Set.from(MobileHomePage._cachedDeletedChats!);
      logger.debug('📦 [同步] 使用缓存的删除配置 (${_deletedChats.length}条)');
    }

    // 🔴 关键优化：同步检查缓存并立即设置状态，避免异步等待
    if (_isCacheValid()) {
      _recentContacts = List.from(MobileHomePage._cachedContacts!);
      _isFirstLoad = false;
      logger.debug('📦 [同步] 使用缓存的联系人列表 (${MobileHomePage._cachedContacts!.length}条)');
    }

    // 异步加载其他数据
    _loadPreferences();
    _loadRecentContactsWithCache(); // 如果缓存过期，会重新加载
    _listenToMessages();

    // 🔴 新增：监听刷新请求（来自通讯录页面等）
    _refreshSubscription = MobileChatListPage._refreshController.stream.listen((_) async {
      logger.debug('📢 [MobileChatListPage] 收到刷新信号，重新加载偏好设置和列表');
      await _loadPreferences(); // 🔴 重要：先重新加载偏好设置（包括删除配置）
      await _loadRecentContacts();
    });

    // 设置群组 doNotDisturb 更新回调
    MobileCreateGroupPage.onDoNotDisturbChanged = _updateGroupDoNotDisturb;
  }

  // 加载用户偏好设置
  Future<void> _loadPreferences() async {
    final pinnedChats = await Storage.getPinnedChatsForCurrentUser();
    final deletedChats = await Storage.getDeletedChatsForCurrentUser();
    final currentUserId = await Storage.getUserId(); // 获取当前用户ID

    // 🔴 更新偏好设置缓存
    MobileHomePage._cachedPinnedChats = pinnedChats;
    MobileHomePage._cachedDeletedChats = deletedChats;

    if (mounted) {
      setState(() {
        _pinnedChats = pinnedChats;
        _deletedChats = deletedChats;
        _currentUserId = currentUserId; // 保存当前用户ID
      });
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _refreshSubscription?.cancel(); // 🔴 新增：取消刷新监听器
    _searchController.dispose();
    // 清理回调
    MobileCreateGroupPage.onDoNotDisturbChanged = null;
    super.dispose();
  }

  // 🔴 新增：将当前内存中的已读状态保存到静态缓存
  // 在刷新前调用，确保已读状态不会丢失
  // 🔴 修复：只保留已经在已读缓存中的会话，不要把所有未读数为0的会话都加入
  void _preserveReadStatusToCache() {
    logger.debug('💾 [已读状态保留] 开始保存当前已读状态到静态缓存...');
    // 🔴 修复：不再自动把未读数为0的会话加入已读缓存
    // 只有用户真正点击进入过的会话才应该在已读缓存中
    // 已读缓存已经在用户点击时添加了，这里不需要再添加
    logger.debug('💾 [已读状态保留] 当前已读缓存数: ${MobileHomePage._readStatusCache.length}, keys: ${MobileHomePage._readStatusCache}');
  }

  // 公开的刷新方法，供外部调用
  void refresh() {
    logger.debug('🔄 外部调用刷新最近联系人列表');
    // 🔴 关键修复：在清除缓存前，先保存当前已读状态到静态缓存
    _preserveReadStatusToCache();
    _invalidateCache(); // 清除缓存
    _loadRecentContacts();
  }

  // 🔴 新增：使缓存失效
  void _invalidateCache() {
    MobileHomePage._cachedContacts = null;
    MobileHomePage._cacheTimestamp = null;
  }
  
  // 🔴 新增：清除内存中的联系人列表（用于重连同步时，避免本地已读状态覆盖离线消息的未读数量）
  void _clearRecentContactsForReconnect() {
    _recentContacts = [];
    logger.debug('🗑️ [重连同步] 已清除内存中的联系人列表');
  }

  // 🔴 新增：检查缓存是否有效
  bool _isCacheValid() {
    if (MobileHomePage._cachedContacts == null || MobileHomePage._cacheTimestamp == null) {
      return false;
    }
    final now = DateTime.now();
    return now.difference(MobileHomePage._cacheTimestamp!) < _cacheDuration;
  }

  // 🔴 新增：带缓存的加载方法
  Future<void> _loadRecentContactsWithCache() async {
    // 检查缓存是否有效
    if (_isCacheValid()) {
      // 🔴 优化：如果缓存已经在 initState 中同步加载，不需要再次 setState
      if (_recentContacts.isNotEmpty) {
        logger.debug('📦 缓存已在 initState 中加载，跳过');
        return;
      }

      logger.debug('📦 使用缓存的联系人列表 (${MobileHomePage._cachedContacts!.length}条)');
      if (mounted) {
        setState(() {
          _recentContacts = List.from(MobileHomePage._cachedContacts!);
          _isFirstLoad = false; // 🔴 标记已完成首次加载
          _error = null;
        });
      }
      return;
    }

    // 缓存无效，从数据库加载
    logger.debug('🔄 缓存无效，从数据库加载联系人列表');
    await _loadRecentContacts();
  }

  // 刷新指定联系人的未读数量
  void refreshContactUnreadCount(int contactId, bool isGroup) {
    logger.debug('🔄 刷新联系人未读数量 - ID: $contactId, 是群组: $isGroup');

    // 查找并更新联系人
    final contactIndex = _recentContacts.indexWhere((contact) {
      if (isGroup) {
        return contact.isGroup &&
            (contact.groupId ?? contact.userId) == contactId;
      } else {
        return !contact.isGroup && contact.userId == contactId;
      }
    });

    if (contactIndex != -1) {
      setState(() {
        _recentContacts[contactIndex] = _recentContacts[contactIndex].copyWith(
          unreadCount: 0,
          hasMentionedMe: false,
        );
        
        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
      });
      logger.debug(
        '✅ 已清除联系人 ${_recentContacts[contactIndex].displayName} 的未读数量',
      );
    }

    // 也可以选择重新加载整个列表以确保数据一致性
    // _loadRecentContacts();
  }

  // 更新指定群组的 doNotDisturb 状态
  void _updateGroupDoNotDisturb(int groupId, bool doNotDisturb) {
    logger.debug('🔔 收到群组 $groupId 的 doNotDisturb 更新通知: $doNotDisturb');

    // 在 _recentContacts 列表中找到对应的群组并更新
    final contactIndex = _recentContacts.indexWhere(
      (contact) => contact.isGroup && contact.groupId == groupId,
    );

    if (contactIndex != -1) {
      setState(() {
        final oldContact = _recentContacts[contactIndex];
        final updatedContact = oldContact.copyWith(doNotDisturb: doNotDisturb);
        _recentContacts[contactIndex] = updatedContact;
        logger.debug('✅ 已更新群组 $groupId 在最近联系人列表中的 doNotDisturb 状态');
        
        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
      });
    } else {
      logger.debug('⚠️ 群组 $groupId 不在最近联系人列表中');
    }
  }

  // 🔴 新增：更新联系人（一对一或群聊）的免打扰状态
  void _updateContactDoNotDisturb(int contactId, bool isGroup, bool doNotDisturb) {
    logger.debug('🔔 更新联系人免打扰状态 - contactId: $contactId, isGroup: $isGroup, doNotDisturb: $doNotDisturb');

    // 查找联系人
    final contactIndex = _recentContacts.indexWhere((contact) {
      if (isGroup) {
        return contact.isGroup && (contact.groupId ?? contact.userId) == contactId;
      } else {
        return !contact.isGroup && contact.userId == contactId;
      }
    });

    if (contactIndex != -1) {
      setState(() {
        final oldContact = _recentContacts[contactIndex];
        final updatedContact = oldContact.copyWith(doNotDisturb: doNotDisturb);
        _recentContacts[contactIndex] = updatedContact;
        
        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        
        logger.debug('✅ 已更新联系人 ${oldContact.displayName} 的免打扰状态: $doNotDisturb');
      });
    } else {
      logger.debug('⚠️ 联系人 $contactId (isGroup: $isGroup) 不在最近联系人列表中');
    }
  }

  // 🔴 新增：更新联系人的最后消息状态（用于撤回消息时更新显示）
  void _updateContactLastMessageStatus({
    int? senderId,
    int? groupId,
    required int messageId,
  }) {
    logger.debug('↩️ 更新联系人最后消息状态 - senderId: $senderId, groupId: $groupId, messageId: $messageId');

    // 查找联系人
    int contactIndex = -1;
    if (groupId != null) {
      contactIndex = _recentContacts.indexWhere((contact) =>
          contact.isGroup && (contact.groupId ?? contact.userId) == groupId);
    } else if (senderId != null) {
      contactIndex = _recentContacts.indexWhere((contact) =>
          !contact.isGroup && contact.userId == senderId);
    }

    if (contactIndex != -1) {
      setState(() {
        final oldContact = _recentContacts[contactIndex];
        // 只更新最后消息状态为recalled，显示"消息已撤回"
        final updatedContact = oldContact.copyWith(
          lastMessageStatus: 'recalled',
        );
        _recentContacts[contactIndex] = updatedContact;

        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();

        logger.debug('✅ 已更新联系人 ${oldContact.displayName} 的最后消息状态为recalled');
      });
    } else {
      logger.debug('⚠️ 未找到对应的联系人 - senderId: $senderId, groupId: $groupId');
    }
  }

  // 监听WebSocket消息
  void _listenToMessages() {
    _messageSubscription?.cancel();

    logger.debug('📱 移动端聊天列表开始监听WebSocket消息');

    _messageSubscription = _wsService.messageStream.listen(
      (data) async {
        final type = data['type'] as String?;
        logger.debug('📨 移动端聊天列表收到WebSocket消息 - 类型: $type, 完整数据: $data');

        switch (type) {
          case 'message':
            // 接收到私聊消息
            logger.debug('📱 处理私聊消息');
            _handleNewMessage(data['data']);
            // 🔴 简化：收到新消息后直接刷新列表重新排序
            await _loadRecentContacts();
            break;
          case 'group_message':
            // 接收到群组消息
            logger.debug('📱 处理群组消息');
            _handleGroupMessage(data['data']);
            // 🔴 简化：收到新消息后直接刷新列表重新排序
            await _loadRecentContacts();
            break;
          case 'avatar_updated':
            // 处理头像更新通知
            logger.debug('📱 处理头像更新通知');
            final avatarData = data['data'];
            if (avatarData != null) {
              final userId = avatarData['user_id'] as int?;
              final newAvatar = avatarData['avatar'] as String?;
              if (userId != null) {
                _handleAvatarUpdated(userId, newAvatar);
              }
            }
            break;
          case 'group_info_updated':
            // 处理群组信息更新通知（包括群组头像更新）
            logger.debug('📱 处理群组信息更新通知');
            await _handleGroupInfoUpdated(data['data']);
            break;
          case 'offline_messages_saved':
            // 离线私聊消息已保存，直接更新内存缓存
            
            final senderIds = data['data']?['sender_ids'] as List?;
            final savedCount = data['data']?['count'] as int? ?? 0;
            final fromClient = data['data']?['from_client'] as bool? ?? false;
            final messagesData = data['data']?['messages'] as List?; // 🔴 新增：离线消息数据
            
            logger.debug('📱 [离线私聊消息] 收到 offline_messages_saved 信号');
            logger.debug('📱 [离线私聊消息] - senderIds: $senderIds');
            logger.debug('📱 [离线私聊消息] - savedCount: $savedCount');
            logger.debug('📱 [离线私聊消息] - fromClient: $fromClient');
            logger.debug('📱 [离线私聊消息] - messagesData: ${messagesData?.length ?? 0}条');
            
            // 🔴 只处理客户端内部发送的信号（包含 sender_ids）
            if (senderIds == null || senderIds.isEmpty) {
              logger.debug('📱 [离线私聊消息] 忽略服务器信号（无 sender_ids）');
              break;
            }
            
            // 🔴 直接更新内存中的联系人列表，不重新从数据库加载
            await _updateContactsFromOfflineMessages(
              senderIds: senderIds.cast<int>(),
              messagesData: messagesData,
              isGroup: false,
            );
            break;
          case 'offline_group_messages_saved':
            // 离线群组消息已保存，直接更新内存缓存
            final groupId = data['data']?['group_id'];
            final groupSavedCount = data['data']?['count'] as int? ?? 0;
            final groupFromClient = data['data']?['from_client'] as bool? ?? false;
            final groupMessagesData = data['data']?['messages'] as List?; // 🔴 新增：离线消息数据
            
            logger.debug('📱 [离线群组消息] 收到 offline_group_messages_saved 信号');
            logger.debug('📱 [离线群组消息] - groupId: $groupId');
            logger.debug('📱 [离线群组消息] - savedCount: $groupSavedCount');
            logger.debug('📱 [离线群组消息] - fromClient: $groupFromClient');
            logger.debug('📱 [离线群组消息] - messagesData: ${groupMessagesData?.length ?? 0}条');
            
            // 🔴 只处理客户端内部发送的信号（包含 group_id）
            if (groupId == null) {
              logger.debug('📱 [离线群组消息] 忽略服务器信号（无 group_id）');
              break;
            }
            
            // 🔴 直接更新内存中的联系人列表，不重新从数据库加载
            await _updateContactsFromOfflineMessages(
              senderIds: [groupId as int],
              messagesData: groupMessagesData,
              isGroup: true,
            );
            break;
          case 'delete_message':
            // 处理删除消息通知（例如删除"加入通话"按钮）
            // 刷新会话列表，因为最新消息可能已变化
            await _loadRecentContacts();
            break;
          case 'update_message_type':
            // 🔴 处理消息类型更新通知（通话结束后将按钮消息转换为普通系统消息）
            await _handleUpdateMessageType(data['data']);
            break;
          case 'message_sent':
            // 处理消息发送成功确认（主要用于通话拒绝消息的保存）
            await _handleMessageSentInChatList(data);
            break;
          case 'clear_chat_history':
            // 🔴 处理清空聊天历史通知（好友审核通过/驳回时触发）
            await _handleClearChatHistoryInList(data['data']);
            break;
          default:
            break;
        }
      },
      onError: (error) {
        logger.error('❌ WebSocket消息流错误: $error');
      },
    );

  }

  /// 处理消息发送成功确认（聊天列表版本）
  /// 注意：这个方法处理所有消息的server_id更新
  /// 如果是在聊天对话框内发送的，会由聊天对话框页面自己处理，这里跳过
  Future<void> _handleMessageSentInChatList(Map<String, dynamic> data) async {
    try {
      
      // 🔴 关键检查：如果聊天对话框页面正在打开，由聊天对话框处理，这里跳过
      if (MobileChatPage.isChatPageOpen) {
        return;
      }
      
      final messageData = data['data'] as Map<String, dynamic>?;
      if (messageData == null) {
        return;
      }

      final messageId = messageData['message_id'] as int?;

      // 🔴 修复：更新所有消息的server_id（不仅仅是通话消息）
      // 从临时存储中查找最近发送的消息并更新数据库
      final wsService = WebSocketService();
      final pendingMessages = wsService.getPendingPrivateMessages();
      
      if (pendingMessages.isNotEmpty && messageId != null) {
        // 查找最近发送的消息
        String? targetKey;
        DateTime? latestTime;
        int? receiverId;
        
        for (final entry in pendingMessages.entries) {
          final msg = entry.value;
          final createdAtStr = msg['created_at'] as String?;
          if (createdAtStr != null) {
            try {
              final createdAt = DateTime.parse(createdAtStr);
              if (latestTime == null || createdAt.isAfter(latestTime)) {
                latestTime = createdAt;
                targetKey = entry.key;
                receiverId = msg['receiverId'] as int?;
              }
            } catch (e) {
              // 忽略解析错误
            }
          }
        }
        
        // 如果找到了消息，更新数据库
        if (receiverId != null) {
          await wsService.saveRecentPendingMessage(
            receiverId,
            serverMessageId: messageId,
          );
          
          // 🔴 关键修复：清除该会话的消息缓存，确保进入聊天页面时从数据库加载最新消息
          final currentUserId = await Storage.getUserId();
          if (currentUserId != null) {
            MobileChatPage.clearCache(isGroup: false, id: receiverId, currentUserId: currentUserId);
          }
        }
      }
      
      // 刷新聊天列表以显示最新消息
      await _loadRecentContacts();

    } catch (e) {
      logger.error('❌ [聊天列表] 处理消息发送确认失败: $e');
    }
  }

  /// 🔴 处理消息类型更新通知（通话结束后将按钮消息转换为普通系统消息）
  Future<void> _handleUpdateMessageType(dynamic data) async {
    try {
      if (data == null) return;
      
      final messageId = data['message_id'] as int?;
      final groupId = data['group_id'] as int?;
      final newMessageType = data['new_message_type'] as String?;
      
      logger.debug('🔄 [首页] 收到消息类型更新通知 - messageId: $messageId, groupId: $groupId, newType: $newMessageType');
      
      if (messageId == null || newMessageType == null) return;
      
      // 更新本地数据库中的消息类型
      final localDb = LocalDatabaseService();
      if (groupId != null) {
        await localDb.updateGroupMessageType(messageId, newMessageType);
        logger.debug('🔄 [首页] 已更新数据库中的群组消息类型');
        
        // 清除该群组的消息缓存，确保重新进入聊天时加载最新数据
        MobileChatPage.clearCache(isGroup: true, id: groupId);
        logger.debug('🔄 [首页] 已清除群组 $groupId 的消息缓存');
      }
      
      // 刷新会话列表
      await _loadRecentContacts();
    } catch (e) {
      logger.error('❌ [首页] 处理消息类型更新失败: $e');
    }
  }

  /// 🔴 处理清空聊天历史通知（好友审核通过/驳回时触发）
  /// 用于在会话列表中正确显示新好友的会话和未读数
  Future<void> _handleClearChatHistoryInList(dynamic data) async {
    try {
      if (data == null) return;

      final senderId = data['user_id'] as int?;
      final receiverId = data['contact_id'] as int?;
      final content = data['content'] as String?;
      final senderName = data['sender_name'] as String?;
      final senderAvatar = data['sender_avatar'] as String?;
      final createdAt = data['created_at'] as String?;


      if (senderId == null || receiverId == null) return;

      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) return;

      // 🔴 清除该会话的消息缓存
      MobileChatPage.clearCache(isGroup: false, id: senderId, currentUserId: currentUserId);

      // 🔴 关键：判断当前用户是发送方还是接收方
      // 如果当前用户是接收方（receiverId），说明是收到了好友审核消息，需要显示未读数
      final isReceiver = currentUserId == receiverId;
      final contactId = isReceiver ? senderId : receiverId;

      // 🔴 关键修复：检查并恢复已删除的会话
      // 当用户之前删除了会话，然后重新添加好友并通过审核时，需要恢复会话
      final contactKey = Storage.generateContactKey(isGroup: false, id: contactId);
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        // 更新内存中的删除列表
        _deletedChats.remove(contactKey);
        MobileHomePage._cachedDeletedChats?.remove(contactKey);
      }

      // 🔴 更新未读数量缓存
      if (isReceiver && content == '请求添加好友【已通过】') {
        final unreadKey = 'user_$contactId';
        MobileHomePage.updateUnreadCount(unreadKey, 1);
        
        // 🔴 从已读状态缓存中移除该会话
        MobileHomePage._readStatusCache.remove(unreadKey);
      }

      // 🔴 延迟一小段时间，确保数据库操作完成后再刷新
      await Future.delayed(const Duration(milliseconds: 100));
      await _loadRecentContacts();
    } catch (e) {
      logger.error('❌ [聊天列表] 处理清空聊天历史失败: $e');
    }
  }

  /// 保存最近的通话相关消息（聊天列表版本）
  Future<void> _saveRecentCallMessageInChatList({int? serverMessageId}) async {
    try {
      final wsService = WebSocketService();
      
      // 获取WebSocket服务中的临时消息
      final pendingMessages = wsService.getPendingPrivateMessages();
      
      if (pendingMessages.isEmpty) {
        return;
      }

      // 查找最近的通话相关消息
      String? targetKey;
      DateTime? latestTime;
      int? receiverId;
      
      for (final entry in pendingMessages.entries) {
        final msg = entry.value;
        final messageType = msg['message_type'] as String?;
        
        // 只处理通话相关消息
        if (messageType == 'call_rejected' || 
            messageType == 'call_rejected_video' ||
            messageType == 'call_cancelled' ||
            messageType == 'call_cancelled_video') {
          
          final createdAt = DateTime.parse(msg['created_at'] as String);
          if (latestTime == null || createdAt.isAfter(latestTime)) {
            latestTime = createdAt;
            targetKey = entry.key;
            receiverId = msg['receiver_id'] as int?;
          }
        }
      }
      
      if (targetKey != null && receiverId != null) {
        // 调用WebSocket服务的保存方法，传递serverMessageId
        await wsService.saveRecentPendingMessage(receiverId, serverMessageId: serverMessageId);
        
        // 🔴 关键修复：清除该会话的消息缓存，确保进入聊天页面时从数据库加载最新消息
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          MobileChatPage.clearCache(isGroup: false, id: receiverId, currentUserId: currentUserId);
        }
      } else {
      }
    } catch (e) {
      logger.error('❌ [聊天列表] 保存通话消息失败: $e');
    }
  }

  /// 🔴 新增：直接更新内存中的联系人列表（不重新从数据库加载）
  /// 用于处理离线消息，提高性能和响应速度
  Future<void> _updateContactsFromOfflineMessages({
    required List<int> senderIds,
    List? messagesData,
    required bool isGroup,
  }) async {
    if (!mounted) return;
    
    logger.debug('📱 [离线消息更新] 开始更新内存缓存 - isGroup: $isGroup, senderIds: $senderIds');
    
    // 获取当前用户ID
    final currentUserId = _currentUserId ?? await Storage.getUserId();
    
    // 检查用户当前是否在某个对话框中
    final isInChatPage = MobileChatPage.isChatPageOpen;
    final currentChatUserId = MobileChatPage.currentChatUserId;
    final currentChatGroupId = MobileChatPage.currentChatGroupId;
    final currentChatIsGroup = MobileChatPage.currentChatIsGroup;
    
    logger.debug('📱 [离线消息更新] 用户状态 - isInChatPage: $isInChatPage, currentChatUserId: $currentChatUserId, currentChatGroupId: $currentChatGroupId');
    
    // 解析离线消息数据，获取最新消息内容
    Map<int, Map<String, dynamic>> latestMessages = {};
    Map<int, int> messageCountPerSender = {};
    
    if (messagesData != null) {
      for (final msgData in messagesData) {
        if (msgData is Map<String, dynamic>) {
          final senderId = isGroup 
              ? (msgData['group_id'] as int?) 
              : (msgData['sender_id'] as int?);
          if (senderId != null) {
            // 记录每个发送者的消息数量
            messageCountPerSender[senderId] = (messageCountPerSender[senderId] ?? 0) + 1;
            // 保存最新的消息（假设消息按时间顺序排列，最后一条是最新的）
            latestMessages[senderId] = msgData;
          }
        }
      }
    }
    
    // 更新联系人列表
    bool needsUpdate = false;
    final updatedContacts = List<RecentContactModel>.from(_recentContacts);
    
    for (final senderId in senderIds) {
      final contactKey = isGroup ? 'group_$senderId' : 'user_$senderId';
      
      // 检查用户是否正在查看这个对话
      bool isViewingThisChat = false;
      if (isInChatPage) {
        if (isGroup && currentChatIsGroup && currentChatGroupId == senderId) {
          isViewingThisChat = true;
        } else if (!isGroup && !currentChatIsGroup && currentChatUserId == senderId) {
          isViewingThisChat = true;
        }
      }
      
      logger.debug('📱 [离线消息更新] 处理 $contactKey - isViewingThisChat: $isViewingThisChat');
      
      // 🔴 关键修复：标记该会话需要刷新（进入聊天页面时会强制从数据库加载）
      MobileChatPage.markSessionNeedRefresh(contactKey);
      
      // 清除该会话的消息缓存，确保进入聊天时从数据库加载最新消息
      logger.debug('📱 [离线消息更新] 清除聊天缓存 - isGroup: $isGroup, id: $senderId, currentUserId: $currentUserId');
      MobileChatPage.clearCache(
        isGroup: isGroup,
        id: senderId,
        currentUserId: currentUserId,
      );
      logger.debug('📱 [离线消息更新] ✅ 聊天缓存已清除');
      
      // 查找现有联系人
      final existingIndex = updatedContacts.indexWhere((c) {
        if (isGroup) {
          return c.isGroup && (c.groupId == senderId || c.userId == senderId);
        } else {
          return !c.isGroup && c.userId == senderId;
        }
      });
      
      if (existingIndex >= 0) {
        // 更新现有联系人
        final existing = updatedContacts[existingIndex];
        final latestMsg = latestMessages[senderId];
        final newMessageCount = messageCountPerSender[senderId] ?? 1;
        
        int newUnreadCount;
        if (isViewingThisChat) {
          // 用户正在查看这个对话，标记为已读
          newUnreadCount = 0;
          MobileHomePage.addToReadStatusCache(contactKey);
          logger.debug('📱 [离线消息更新] $contactKey 用户正在查看，标记为已读');
        } else {
          // 用户不在这个对话中，增加未读数
          newUnreadCount = existing.unreadCount + newMessageCount;
          MobileHomePage.removeFromReadStatusCache(contactKey);
          logger.debug('📱 [离线消息更新] $contactKey 增加未读数: ${existing.unreadCount} -> $newUnreadCount');
        }
        
        // 更新联系人信息
        String? newLastMessageTime;
        if (latestMsg?['created_at'] != null) {
          newLastMessageTime = latestMsg!['created_at'].toString();
        }
        
        updatedContacts[existingIndex] = existing.copyWith(
          unreadCount: newUnreadCount,
          lastMessage: latestMsg?['content'] as String? ?? existing.lastMessage,
          lastMessageTime: newLastMessageTime ?? existing.lastMessageTime,
        );
        needsUpdate = true;
        logger.debug('📱 [离线消息更新] ✅ 已更新联系人: ${existing.displayName}');
      } else {
        // 联系人不在列表中，需要从数据库加载
        logger.debug('📱 [离线消息更新] ⚠️ 联系人 $contactKey 不在列表中，需要重新加载');
        // 这种情况下需要重新加载整个列表
        await _loadRecentContacts();
        return;
      }
    }
    
    if (needsUpdate && mounted) {
      // 按最后消息时间重新排序（置顶的除外）
      updatedContacts.sort((a, b) {
        final aKey = a.isGroup ? 'group_${a.groupId ?? a.userId}' : 'user_${a.userId}';
        final bKey = b.isGroup ? 'group_${b.groupId ?? b.userId}' : 'user_${b.userId}';
        
        final aIsPinned = _pinnedChats.containsKey(aKey);
        final bIsPinned = _pinnedChats.containsKey(bKey);
        
        // 置顶的排在前面
        if (aIsPinned && !bIsPinned) return -1;
        if (!aIsPinned && bIsPinned) return 1;
        
        // 都置顶或都不置顶，按时间排序（lastMessageTime是String类型）
        final aTime = DateTime.tryParse(a.lastMessageTime) ?? DateTime(1970);
        final bTime = DateTime.tryParse(b.lastMessageTime) ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
      
      setState(() {
        _recentContacts = updatedContacts;
      });
      
      // 更新静态缓存
      MobileHomePage._cachedContacts = List.from(updatedContacts);
      MobileHomePage._cacheTimestamp = DateTime.now();
      
      logger.debug('📱 [离线消息更新] ✅ 内存缓存已更新，共 ${updatedContacts.length} 个联系人');
    }
  }

  Future<void> _loadRecentContacts() async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📋 [_loadRecentContacts] 开始加载联系人列表...');
      
      // 🔴 首先确保已读状态缓存已从Storage加载
      await MobileHomePage.loadReadStatusCacheFromStorage();
      logger.debug('📋 [_loadRecentContacts] 当前已读缓存: ${MobileHomePage._readStatusCache.length}条, keys: ${MobileHomePage._readStatusCache}');
      
      // 🔴 直接获取数据并更新，不显示加载动画
      final response = await MessageService().getRecentContacts();
      final contactsData = response['data']?['contacts'] as List?;
      final contacts = (contactsData ?? [])
          .map((json) => RecentContactModel.fromJson(json as Map<String, dynamic>))
          .toList();

      logger.debug('📋 [_loadRecentContacts] 从数据库获取到 ${contacts.length} 个联系人');
      
      // 🔍 调试：打印获取到的联系人列表（前10个）
      for (int i = 0; i < contacts.length && i < 10; i++) {
        final c = contacts[i];
        final type = c.isGroup ? '[群组]' : '[私聊]';
        final key = c.isGroup ? 'group_${c.groupId ?? c.userId}' : 'user_${c.userId}';
        final isInReadCache = MobileHomePage.isInReadStatusCache(key);
        final dbUnreadCount = c.unreadCount;
        final lastMsg = (c.lastMessage?.length ?? 0) > 20 ? '${c.lastMessage?.substring(0, 20)}...' : c.lastMessage;
        logger.debug('📋 [_loadRecentContacts] $type ${c.displayName}: key=$key, dbUnread=$dbUnreadCount, inReadCache=$isInReadCache, lastMsg="$lastMsg"');
      }

      if (mounted) {
        // 🔴 修复：只使用静态已读缓存来判断是否已读
        // 不再从 _recentContacts 中获取已读状态，因为那会导致旧的已读状态覆盖新的未读消息
        
        // 合并服务器数据和本地已读状态
        final mergedContacts = contacts.map((contact) {
          final key = contact.isGroup 
              ? 'group_${contact.groupId ?? contact.userId}' 
              : 'user_${contact.userId}';
          
          // 🔴 优先使用未读数量缓存中的值
          final cachedUnreadCount = MobileHomePage.getCachedUnreadCount(key);
          if (cachedUnreadCount > 0) {
            logger.debug('📋 [_loadRecentContacts] ${contact.displayName}: 使用缓存未读数 $cachedUnreadCount');
            return contact.copyWith(unreadCount: cachedUnreadCount);
          }
          
          // 🔴 修复：只有在静态已读缓存中的联系人才设为已读
          // 这样当收到新消息并从缓存中移除后，就能正确显示未读数
          if (MobileHomePage._readStatusCache.contains(key)) {
            logger.debug('📋 [_loadRecentContacts] ${contact.displayName}: 在已读缓存中，设为已读 (原未读数: ${contact.unreadCount})');
            return contact.copyWith(unreadCount: 0, hasMentionedMe: false);
          }
          
          logger.debug('📋 [_loadRecentContacts] ${contact.displayName}: 保持数据库未读数 ${contact.unreadCount}');
          return contact;
        }).toList();
        
        setState(() {
          _recentContacts = mergedContacts;
          _isFirstLoad = false; // 🔴 标记已完成首次加载
          _error = null;
        });

        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(mergedContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        
        logger.debug('📋 [_loadRecentContacts] ✅ 联系人列表加载完成');
        logger.debug('═══════════════════════════════════════════════════════════');
        
        // 🚀 后台预加载所有会话的消息缓存（不阻塞UI）
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null && mergedContacts.isNotEmpty) {
          unawaited(MobileChatPage.preloadMessagesCache(
            contacts: mergedContacts,
            currentUserId: currentUserId,
          ));
          
          // 🔴 场景1：首次登录后，预加载所有会话前20条消息的图片
          unawaited(_preloadAllSessionsImages(mergedContacts, currentUserId));
        }
      }
    } catch (e) {
      logger.error('加载最近联系人失败: $e');
      if (mounted) {
        setState(() {
          _isFirstLoad = false; // 🔴 即使失败也标记为已加载
          _error = e.toString();
        });
      }
    }
  }

  /// 🔴 场景1：首次登录后，预加载所有会话前20条消息的图片
  Future<void> _preloadAllSessionsImages(List<RecentContactModel> contacts, int currentUserId) async {
    if (!mounted) return;
    
    final imagePreloadService = ImagePreloadService();
    final messageService = MessageService();
    
    // 🔴 修复：创建列表副本，避免并发修改异常
    final contactsCopy = List<RecentContactModel>.from(contacts);
    
    for (final contact in contactsCopy) {
      if (!mounted) break;
      
      try {
        List<MessageModel> messages = [];
        
        if (contact.isGroup && contact.groupId != null) {
          // 群聊消息
          messages = await messageService.getGroupMessageList(
            groupId: contact.groupId!,
            pageSize: 20,
          );
        } else if (!contact.isGroup) {
          // 私聊消息
          messages = await messageService.getMessages(
            contactId: contact.userId,
            pageSize: 20,
          );
        }
        
        // 预加载图片到内存
        if (messages.isNotEmpty && mounted) {
          await imagePreloadService.preloadMessagesImages(context, messages);
        }
      } catch (e) {
        logger.debug('⚠️ [图片预加载] 会话 ${contact.displayName} 预加载失败: $e');
      }
    }
  }

  /// 🔴 更新单个会话的最新消息
  /// 退出聊天页面时调用，只更新该会话而不重新加载整个列表
  Future<void> _updateSingleContact(int contactId, bool isGroup) async {
    try {
      
      // 🔴 修复：重新加载置顶状态（因为可能在聊天页面修改了置顶状态）
      await _loadPreferences();
      
      // 1. 清空该会话的缓存
      MobileChatPage.clearCache(isGroup: isGroup, id: contactId);
      
      // 2. 从数据库查询该会话的最新消息
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) {
        logger.debug('⚠️ 当前用户ID为空，跳过更新');
        return;
      }
      
      String? lastMessage;
      String? lastMessageTime;
      
      if (isGroup) {
        // 查询群聊的最后一条消息
        // 注意：由于SQL使用id ASC排序，pageSize=1会返回最老的消息
        // 所以这里需要查询所有消息，然后取最后一条
        final messages = await MessageService().getGroupMessageList(
          groupId: contactId,
          pageSize: 999, // 查询足够多的消息以确保获取到最新的
        );
        if (messages.isNotEmpty) {
          final msg = messages.last; // 取最后一条（最新的）
          // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
          final isSender = msg.senderId == currentUserId;
          lastMessage = _formatMessagePreview(msg.messageType, msg.content, isSender: isSender);
          lastMessageTime = msg.createdAt.toIso8601String();
          logger.debug('✅ 查询到群聊最新消息: "$lastMessage" (共${messages.length}条消息)');
        }
      } else {
        // 查询私聊的最后一条消息
        // 注意：由于SQL使用id ASC排序，pageSize=1会返回最老的消息
        // 所以这里需要查询所有消息，然后取最后一条
        final messages = await MessageService().getMessages(
          contactId: contactId,
          pageSize: 999, // 查询足够多的消息以确保获取到最新的
        );
        if (messages.isNotEmpty) {
          final msg = messages.last; // 取最后一条（最新的）
          // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
          final isSender = msg.senderId == currentUserId;
          lastMessage = _formatMessagePreview(msg.messageType, msg.content, isSender: isSender);
          lastMessageTime = msg.createdAt.toIso8601String();
          logger.debug('✅ 查询到私聊最新消息: "$lastMessage" (共${messages.length}条消息)');
        }
      }
      
      // 3. 查找会话在列表中的位置
      final contactIndex = _recentContacts.indexWhere(
        (c) => (isGroup 
          ? (c.isGroup && c.groupId == contactId)
          : (!c.isGroup && c.userId == contactId)),
      );
      
      // 4. 更新会话（即使没有消息也保留会话，只是将最新消息置空）
      if (contactIndex != -1 && mounted) {
        // 会话已在列表中
        if (lastMessage != null && lastMessageTime != null) {
          // 🔴 修复：有最新消息时，只更新会话内容，不移动位置
          // 只有在收到新消息时才会移动会话到顶部（在_handleNewMessage和_handleGroupMessage中处理）
          // 🔴 关键修复：退出聊天页面时，将未读数设置为0（因为用户已经阅读了消息）
          setState(() {
            final contact = _recentContacts[contactIndex];
            final updatedContact = contact.copyWith(
              lastMessage: lastMessage,
              lastMessageTime: lastMessageTime,
              unreadCount: 0, // 🔴 关键：退出聊天页面时清除未读数
              hasMentionedMe: false, // 🔴 同时清除@提醒状态
            );
            
            // 直接在原位置更新，不移动位置
            _recentContacts[contactIndex] = updatedContact;
            
            logger.debug('✅ 已更新会话内容并清除未读数，保持原位置: "$lastMessage"');
          });
          
          // 🔴 关键修复：同时更新数据库中的已读状态
          if (isGroup) {
            unawaited(MessageService().markGroupMessagesAsRead(contactId));
            logger.debug('✅ 已触发群组数据库已读状态更新 - groupId: $contactId');
          } else {
            unawaited(MessageService().markMessagesAsRead(contactId));
            logger.debug('✅ 已触发数据库已读状态更新 - userId: $contactId');
          }
        } else {
          // 🔴 没有最新消息（清空聊天记录后），保留会话但将最新消息置空
          // 🔴 修复：标记已读时不更新时间，避免会话移动到前面
          setState(() {
            final contact = _recentContacts[contactIndex];
            final updatedContact = contact.copyWith(
              lastMessage: '', // 最新消息置空
              // 🔴 关键修复：不更新 lastMessageTime，保持原有时间，避免会话排序变化
              unreadCount: 0, // 🔴 关键：同样清除未读数
              hasMentionedMe: false, // 🔴 同时清除@提醒状态
            );
            
            // 直接在原位置更新，不移动位置
            _recentContacts[contactIndex] = updatedContact;
            
            logger.debug('✅ 已清空会话的最新消息和未读数但保留会话在列表中（时间不变）');
          });
          
          // 🔴 关键修复：同时更新数据库中的已读状态（即使没有消息也要更新）
          if (isGroup) {
            unawaited(MessageService().markGroupMessagesAsRead(contactId));
            logger.debug('✅ 已触发群组数据库已读状态更新 - groupId: $contactId');
          } else {
            unawaited(MessageService().markMessagesAsRead(contactId));
            logger.debug('✅ 已触发数据库已读状态更新 - userId: $contactId');
          }
        }
        
        // 🔴 修复：重新排序会话列表（因为置顶状态可能已改变）
        // 使用_filteredContacts getter来获取排序后的列表
        final sortedContacts = _filteredContacts;
        setState(() {
          _recentContacts = sortedContacts;
        });
        
        // 更新缓存
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        logger.debug('💾 缓存已更新，会话列表已重新排序');
      } else if (lastMessage != null && lastMessageTime != null) {
        // 🔴 会话不在列表中且有新消息，重新加载整个列表（确保新会话能显示）
        logger.debug('💡 会话不在列表中，重新加载联系人列表以显示新会话');
        await _loadRecentContacts();
        
        // 更新缓存已在_loadRecentContacts中完成
        logger.debug('✅ 已重新加载联系人列表，新会话应该已显示');
      } else {
        logger.debug('⚠️ 会话不在列表中且无最新消息，不做处理');
      }
    } catch (e) {
      logger.error('❌ 更新单个会话失败: $e');
    }
  }

  // 处理头像更新通知
  Future<void> _handleAvatarUpdated(int userId, String? newAvatar) async {
    try {
      logger.debug('🎭 移动端聊天列表收到头像更新通知 - 用户ID: $userId, 新头像: $newAvatar');

      // 1. 立即更新内存中的会话列表
      bool updated = false;
      for (int i = 0; i < _recentContacts.length; i++) {
        if (_recentContacts[i].userId == userId && !_recentContacts[i].isGroup) {
          setState(() {
            _recentContacts[i] = _recentContacts[i].copyWith(avatar: newAvatar);
          });
          updated = true;
          logger.debug('✅ 已更新移动端聊天列表内存中用户 $userId 的头像');
          break;
        }
      }

      // 2. 更新缓存
      if (updated) {
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        logger.debug('💾 移动端头像更新后内存缓存已更新');
      } else {
        logger.debug('⚠️ 在移动端聊天列表内存中未找到用户 $userId');
      }

      // 3. 重新从数据库加载会话列表（确保数据库中的头像也是最新的）
      logger.debug('🔄 重新从数据库加载会话列表，确保显示最新头像');
      await _loadRecentContactsWithCache();

      logger.debug('🎭 移动端聊天列表头像更新处理完成（内存+数据库）');
    } catch (e) {
      logger.debug('移动端聊天列表处理头像更新失败: $e');
    }
  }

  // 处理群组信息更新通知（包括群组头像、名称等）
  Future<void> _handleGroupInfoUpdated(dynamic data) async {
    try {
      if (data == null) {
        logger.debug('⚠️ 群组信息更新数据为空');
        return;
      }

      final groupId = data['group_id'] as int?;
      final groupData = data['group'] as Map<String, dynamic>?;

      if (groupId == null || groupData == null) {
        logger.debug('⚠️ 群组信息更新消息缺少必要字段');
        return;
      }

      logger.debug('📢 移动端收到群组信息更新通知 - 群组ID: $groupId, 数据: $groupData');

      // 1. 立即更新内存中的会话列表
      bool updated = false;
      for (int i = 0; i < _recentContacts.length; i++) {
        if (_recentContacts[i].isGroup && (_recentContacts[i].groupId ?? _recentContacts[i].userId) == groupId) {
          setState(() {
            _recentContacts[i] = _recentContacts[i].copyWith(
              username: groupData['name'] as String?,
              fullName: groupData['name'] as String?,
              avatar: groupData['avatar'] as String?,
              groupName: groupData['name'] as String?,
            );
          });
          updated = true;
          logger.debug('✅ 已更新移动端聊天列表内存中群组 $groupId 的信息');
          logger.debug('   - 群组名称: ${groupData['name']}');
          logger.debug('   - 群组头像: ${groupData['avatar']}');
          break;
        }
      }

      // 2. 更新缓存
      if (updated) {
        MobileHomePage._cachedContacts = List.from(_recentContacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        logger.debug('💾 移动端群组信息更新后内存缓存已更新');
      } else {
        logger.debug('⚠️ 在移动端聊天列表内存中未找到群组 $groupId');
      }

      // 3. 更新本地数据库中的群组信息
      final localDb = LocalDatabaseService();
      await localDb.updateGroupInfoInMessages(
        groupId: groupId,
        groupName: groupData['name'] as String?,
        groupAvatar: groupData['avatar'] as String?,
      );
      logger.debug('🗄️ 移动端数据库群组信息已更新');

      // 4. 重新从数据库加载会话列表（确保数据库中的信息也是最新的）
      logger.debug('🔄 重新从数据库加载会话列表，确保显示最新群组信息');
      await _loadRecentContactsWithCache();

      logger.debug('📢 移动端群组信息更新处理完成（内存+数据库）');
    } catch (e) {
      logger.error('移动端处理群组信息更新失败: $e');
    }
  }

  List<RecentContactModel> get _filteredContacts {
    // 1. 过滤搜索
    var contacts = _searchText.isEmpty
        ? _recentContacts
        : _recentContacts.where((contact) {
            final name = contact.displayName.toLowerCase();
            final search = _searchText.toLowerCase();
            return name.contains(search);
          }).toList();

    // 2. 过滤已删除的会话
    contacts = contacts.where((contact) {
      // 🔴 文件传输助手特殊处理：使用当前用户ID
      int contactId = contact.userId;
      if (contact.type == 'file_assistant' && _currentUserId != null) {
        // 文件传输助手的contactKey需要使用当前用户ID
        // 因为文件传输助手的userId是0，但实际存储时使用的是当前用户ID
        contactId = _currentUserId!;
      }
      
      final contactKey = Storage.generateContactKey(
        isGroup: contact.type == 'group',
        id: contactId,
      );
      return !_deletedChats.contains(contactKey);
    }).toList();

    // 3. 分离顶置和非顶置的会话
    final List<MapEntry<RecentContactModel, int>> pinnedList = [];
    final List<RecentContactModel> unpinnedList = [];

    for (final contact in contacts) {
      // 🔴 文件传输助手特殊处理：使用当前用户ID
      int contactId = contact.userId;
      if (contact.type == 'file_assistant' && _currentUserId != null) {
        contactId = _currentUserId!;
      }
      
      final contactKey = Storage.generateContactKey(
        isGroup: contact.type == 'group',
        id: contactId,
      );
      final pinnedTimestamp = _pinnedChats[contactKey];
      if (pinnedTimestamp != null) {
        pinnedList.add(MapEntry(contact, pinnedTimestamp));
      } else {
        unpinnedList.add(contact);
      }
    }

    // 4. 对顶置列表按顶置时间倒序排序（最新顶置的在最前面）
    pinnedList.sort((a, b) => b.value.compareTo(a.value));

    // 5. 对非顶置列表按最后消息时间倒序排序（最新消息在最前面）
    unpinnedList.sort((a, b) {
      // 🔴 关键修复：统一时区处理
      // - 带Z后缀的是UTC时间，DateTime.parse会自动转换为本地时间
      // - 不带Z后缀的是本地时间，直接解析即可
      int aMillis;
      int bMillis;
      
      try {
        if (a.lastMessageTime.isNotEmpty) {
          final aTimeStr = a.lastMessageTime;
          // DateTime.parse 会自动处理带Z和不带Z的情况
          // 带Z的会转换为本地时间，不带Z的当作本地时间
          aMillis = DateTime.parse(aTimeStr).millisecondsSinceEpoch;
        } else {
          aMillis = 0;
        }
      } catch (e) {
        logger.debug('⚠️ [排序] 解析时间失败: ${a.displayName}, time: ${a.lastMessageTime}, error: $e');
        aMillis = 0;
      }
      
      try {
        if (b.lastMessageTime.isNotEmpty) {
          final bTimeStr = b.lastMessageTime;
          bMillis = DateTime.parse(bTimeStr).millisecondsSinceEpoch;
        } else {
          bMillis = 0;
        }
      } catch (e) {
        logger.debug('⚠️ [排序] 解析时间失败: ${b.displayName}, time: ${b.lastMessageTime}, error: $e');
        bMillis = 0;
      }
      
      return bMillis.compareTo(aMillis); // 降序：最新的在前
    });

    // 6. 合并列表：顶置的在前，非顶置的在后
    final result = <RecentContactModel>[];
    result.addAll(pinnedList.map((e) => e.key));
    result.addAll(unpinnedList);

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 🔴 性能优化：缓存 _filteredContacts 到局部变量，避免重复计算排序
    final filteredContacts = _filteredContacts;

    return Column(
      children: [
        // 搜索框
        Container(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          color: const Color(0xFFEEF1F6),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.translate('search'),
              hintStyle: TextStyle(color: Colors.grey[500]),
              prefixIcon: Icon(Icons.search, size: 20, color: Colors.grey[600]),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              isDense: true,
            ),
            onChanged: (value) {
              setState(() => _searchText = value);
            },
          ),
        ),

        // 聊天列表
        Expanded(
          child: Container(
            color: const Color(0xFFEEF1F6),
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadRecentContacts,
                          child: Text(l10n.translate('retry')),
                        ),
                      ],
                    ),
                  )
                : filteredContacts.isEmpty
                // 🔴 关键修改：只有在首次加载完成后，且列表为空时，才显示空状态页面
                ? (_isSyncingData
                    // 首次同步数据时显示加载状态
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF07C160)),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _syncStatusMessage ?? '同步数据中...',
                              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
                            ),
                          ],
                        ),
                      )
                    : _isFirstLoad
                    ? const SizedBox.shrink() // 首次加载中，不显示任何内容
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.chat_bubble_outline,
                              size: 64,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _searchText.isEmpty
                                  ? l10n.translate('no_conversations')
                                  : l10n.translate('no_search_results'),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ))
                : RefreshIndicator(
                    onRefresh: () async {
                      // 🔴 优先调用父组件的刷新方法（包含网络重连）
                      if (widget.onRefresh != null) {
                        await widget.onRefresh!();
                      }
                      // 然后刷新本地数据
                      await _loadRecentContacts();
                    },
                    child: ListView.builder(
                      itemCount: filteredContacts.length,
                      itemBuilder: (context, index) {
                        final contact = filteredContacts[index];
                        return _buildChatItem(contact);
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatItem(RecentContactModel contact) {
    // 🔴 文件传输助手特殊处理：使用当前用户ID（与 _filteredContacts 保持一致）
    int contactId = contact.userId;
    if (contact.type == 'file_assistant' && _currentUserId != null) {
      contactId = _currentUserId!;
    }
    
    final contactKey = Storage.generateContactKey(
      isGroup: contact.type == 'group',
      id: contactId,
    );
    final isPinned = _pinnedChats.containsKey(contactKey);

    return Slidable(
      key: ValueKey(contact.userId),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.4,
        children: [
          // 顶置/取消顶置按钮
          SlidableAction(
            onPressed: (context) async {
              if (isPinned) {
                // 取消顶置
                await Storage.removePinnedChatForCurrentUser(contactKey);
              } else {
                // 顶置
                await Storage.addPinnedChatForCurrentUser(contactKey);
              }
              // 重新加载配置
              await _loadPreferences();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(isPinned ? '已取消顶置' : '已顶置'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
            backgroundColor: const Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            spacing: 0,
            padding: EdgeInsets.zero,
          ),
          // 删除按钮
          SlidableAction(
            onPressed: (context) {
              _deleteContact(contact, contactKey);
            },
            backgroundColor: const Color(0xFFFF4D4F),
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            spacing: 0,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          // 🔴 修复：置顶会话使用灰色背景，非置顶使用白色背景
          color: isPinned ? const Color(0xFFF5F5F5) : Colors.white,
          border: const Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1.3),
          ),
        ),
        child: InkWell(
          onTap: () async {
            logger.debug(
              '📧 点击联系人 ${contact.displayName}，未读消息数: ${contact.unreadCount}',
            );

            // 🔴 立即清除UI上的未读计数（点击即清除红色气泡）
            if (contact.unreadCount > 0) {
              final contactIndex = _recentContacts.indexWhere((c) => 
                c.userId == contact.userId && c.type == contact.type);
              if (contactIndex != -1 && mounted) {
                setState(() {
                  _recentContacts[contactIndex] = _recentContacts[contactIndex].copyWith(
                    unreadCount: 0,
                    hasMentionedMe: false,
                  );
                });
                // 🔴 关键修复：同步更新缓存，避免刷新时恢复旧的未读数
                MobileHomePage._cachedContacts = List.from(_recentContacts);
                MobileHomePage._cacheTimestamp = DateTime.now();
                
                // 🔴 关键修复：添加到静态已读状态缓存（即使页面重建也能保留）
                final readKey = contact.isGroup 
                    ? 'group_${contact.groupId ?? contact.userId}' 
                    : 'user_${contact.userId}';
                MobileHomePage._readStatusCache.add(readKey);
                
                // 🔴 关键：清除未读数量缓存
                MobileHomePage.updateUnreadCount(readKey, 0);
                logger.debug('✅ 已清除联系人 ${contact.displayName} 的未读计数并更新缓存，readKey: $readKey');
                
                // 🔴 关键修复：同时更新数据库中的已读状态
                // 这样即使会话列表刷新，也不会显示错误的未读数
                if (contact.type != 'group') {
                  // 私聊：标记该联系人发送的所有消息为已读
                  unawaited(MessageService().markMessagesAsRead(contact.userId));
                  logger.debug('✅ 已触发数据库已读状态更新 - userId: ${contact.userId}');
                } else {
                  // 群聊：标记该群组的所有消息为已读
                  unawaited(MessageService().markGroupMessagesAsRead(contact.userId));
                  logger.debug('✅ 已触发群组数据库已读状态更新 - groupId: ${contact.userId}');
                }
              }
            }

            // 文件传输助手特殊处理
            if (contact.type == 'file_assistant') {
              try {
                final userId = await Storage.getUserId();
                if (userId != null) {
                  // 确保文件传输助手在最近联系人列表中
                  await _ensureFileAssistantInRecentContacts(userId);
                  
                  if (mounted) {
                    // 导航到文件传输助手聊天页面
                    widget.onChatSelected(
                      userId,
                      AppLocalizations.of(context).translate('file_transfer_assistant'),
                      false,
                      avatar: null,
                    );
                  }
                }
              } catch (e) {
                logger.error('打开文件传输助手失败: $e');
              }
              return;
            }

            // 导航到聊天页面
            widget.onChatSelected(
              contact.userId,
              contact.displayName,
              contact.type == 'group',
              groupId: contact.type == 'group' ? contact.userId : null,
              avatar: contact.avatar,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // 左侧头像
                Stack(
                  children: [
                    contact.type == 'file_assistant'
                        ? // 文件传输助手：绿色文件夹图标
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: const Color(0xFF07C160), // 微信绿色
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.folder_open,
                              color: Colors.white,
                              size: 28,
                            ),
                          )
                        : contact.isGroup
                        ? CircleAvatar(
                            radius: 26,
                            backgroundColor:
                                (contact.avatar != null &&
                                    contact.avatar!.isNotEmpty)
                                ? Colors.transparent
                                : const Color(0xFF52C41A),
                            backgroundImage:
                                (contact.avatar != null &&
                                    contact.avatar!.isNotEmpty)
                                ? NetworkImage(contact.avatar!)
                                : null,
                            child:
                                (contact.avatar == null ||
                                    contact.avatar!.isEmpty)
                                ? const Icon(
                                    Icons.people,
                                    color: Colors.white,
                                    size: 26,
                                  )
                                : null,
                          )
                        : CircleAvatar(
                            radius: 26,
                            backgroundColor:
                                contact.avatar != null &&
                                    contact.avatar!.isNotEmpty
                                ? Colors.transparent
                                : const Color(0xFF4A90E2),
                            backgroundImage:
                                contact.avatar != null &&
                                    contact.avatar!.isNotEmpty
                                ? NetworkImage(contact.avatar!)
                                : null,
                            child:
                                contact.avatar == null ||
                                    contact.avatar!.isEmpty
                                ? Text(
                                    contact.displayName.isNotEmpty
                                        ? contact.displayName[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 20,
                                    ),
                                  )
                                : null,
                          ),
                    // 未读消息气泡（左上角）- 优先使用contact.unreadCount，缓存作为备用
                    Builder(
                      builder: (context) {
                        // 生成会话key
                        final contactKey = contact.isGroup 
                            ? 'group_${contact.groupId ?? contact.userId}' 
                            : 'user_${contact.userId}';
                        
                        // 🔴 调试日志
                        final isInReadCache = MobileHomePage.isInReadStatusCache(contactKey);
                        final cachedUnreadCount = MobileHomePage.getCachedUnreadCount(contactKey);
                        final contactUnreadCount = contact.unreadCount;
                        
                        // 🔴 修复：如果会话在已读缓存中，不显示红色气泡
                        if (isInReadCache) {
                          return const SizedBox.shrink();
                        }
                        
                        // 🔴 修复：优先使用contact.unreadCount，缓存只用于实时更新
                        // 使用缓存值或contact的未读数量（取较大值，确保不会漏显示）
                        final displayUnreadCount = cachedUnreadCount > 0 ? cachedUnreadCount : contactUnreadCount;
                        // 只有有未读数量时才显示气泡
                        if (displayUnreadCount <= 0) {
                          return const SizedBox.shrink();
                        }
                        
                        return Positioned(
                          left: 0,
                          top: 0,
                          child: contact.doNotDisturb
                              ? // 消息免打扰（一对一或群组）：显示小红点
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 1.5,
                                    ),
                                  ),
                                )
                              : // 正常情况：显示未读数量气泡
                                Container(
                                  constraints: const BoxConstraints(minWidth: 20),
                                  height: 20,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 1.5,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    displayUnreadCount >= 100
                                        ? '99+'
                                        : displayUnreadCount.toString(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      height: 1.0,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                // 中间内容
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 名称和时间
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                // 名称
                                Flexible(
                                  child: Text(
                                    contact.type == 'file_assistant' 
                                        ? AppLocalizations.of(context).translate('file_transfer_assistant')
                                        : contact.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      fontSize: 16,
                                      color: Colors.black87,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // 消息免打扰图标（一对一或群组）
                                if (contact.doNotDisturb)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Icon(
                                      Icons.notifications_off,
                                      size: 14,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 时间
                          Text(
                            _formatTime(contact.lastMessageTime),
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 最后消息
                      // 🔴 如果最后一条消息已撤回，显示"消息已撤回"
                      Text(
                        contact.lastMessageStatus == 'recalled' 
                            ? '消息已撤回' 
                            : contact.lastMessage,
                        style: TextStyle(
                          color: Colors.grey[600], 
                          fontSize: 14,
                          fontStyle: contact.lastMessageStatus == 'recalled' 
                              ? FontStyle.italic 
                              : FontStyle.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 删除联系人
  void _deleteContact(RecentContactModel contact, String contactKey) {
    // 保存context引用，避免在异步操作后使用已失效的context
    final savedContext = context;

    showDialog(
      context: savedContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定要删除与 ${contact.displayName} 的会话吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);

              try {
                // 获取当前用户ID
                final currentUserId = await Storage.getUserId();
                if (currentUserId == null) {
                  throw Exception('无法获取当前用户ID');
                }

                // 根据类型标记删除对应的所有消息（软删除）
                final localDb = LocalDatabaseService();
                if (contact.type == 'user') {
                  // 标记私聊消息为已删除
                  await localDb.deleteAllMessagesWithContact(
                    currentUserId,
                    contact.userId,
                  );
                  logger.debug('已标记与用户 ${contact.userId} 的所有私聊消息为已删除');
                } else if (contact.type == 'group') {
                  // 标记群聊消息为已删除
                  await localDb.deleteAllGroupMessages(
                    contact.userId,
                    currentUserId,
                  );
                  logger.debug('已标记群组 ${contact.userId} 的所有消息为已删除');
                } else if (contact.type == 'file_assistant') {
                  // 删除文件传输助手的所有消息
                  await localDb.deleteAllFileAssistantMessages(currentUserId);
                  logger.debug('已删除文件传输助手的所有消息');
                }

                // 保存删除状态到本地（会自动取消顶置）
                await Storage.addDeletedChatForCurrentUser(contactKey);

                // 🔴 清除聊天页面的消息缓存，避免恢复会话后显示旧消息
                MobileChatPage.clearCache(
                  isGroup: contact.type == 'group',
                  id: contact.userId,
                  currentUserId: currentUserId,
                  isFileAssistant: contact.type == 'file_assistant',
                );
                logger.debug('💾 已清除会话缓存: $contactKey');

                // 重新加载配置
                await _loadPreferences();

                if (mounted) {
                  ScaffoldMessenger.of(savedContext).showSnackBar(
                    const SnackBar(
                      content: Text('会话和历史消息已删除'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              } catch (e) {
                logger.error('删除会话失败: $e', error: e);
                if (mounted) {
                  ScaffoldMessenger.of(savedContext).showSnackBar(
                    SnackBar(
                      content: Text('删除失败: $e'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // 显示添加联系人对话框
  void showAddContactDialog() {
    final TextEditingController usernameController = TextEditingController();
    final outerContext = context; // 保存外层context

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A90E2).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.person_add,
                      color: Color(0xFF4A90E2),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    '添加联系人',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // 输入框
              TextField(
                controller: usernameController,
                decoration: InputDecoration(
                  hintText: '好友用户名',
                  prefixIcon: const Icon(
                    Icons.account_circle,
                    color: Color(0xFF4A90E2),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF4A90E2),
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
                autofocus: true,
              ),
              const SizedBox(height: 24),
              // 按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      side: BorderSide(color: Colors.grey[400]!),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      '取消',
                      style: TextStyle(color: Colors.grey[700], fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () async {
                      final username = usernameController.text.trim();

                      if (username.isEmpty) {
                        ScaffoldMessenger.of(
                          outerContext,
                        ).showSnackBar(const SnackBar(content: Text('请输入用户名')));
                        return;
                      }

                      // 先关闭输入对话框
                      Navigator.pop(dialogContext);

                      // 显示加载提示
                      showDialog(
                        context: outerContext,
                        barrierDismissible: false,
                        builder: (loadingContext) =>
                            const Center(child: CircularProgressIndicator()),
                      );

                      // 调用添加联系人API
                      try {
                        logger.debug('📞 [添加联系人] 开始添加联系人: $username');
                        
                        final token = await Storage.getToken();
                        if (token == null) {
                          logger.debug('❌ [添加联系人] Token为空，用户未登录');
                          if (mounted) {
                            Navigator.of(
                              outerContext,
                              rootNavigator: true,
                            ).pop();
                            ScaffoldMessenger.of(outerContext).showSnackBar(
                              const SnackBar(content: Text('未登录')),
                            );
                          }
                          return;
                        }

                        logger.debug('📞 [添加联系人] Token已获取，准备调用API');
                        logger.debug('📞 [添加联系人] API URL: ${ApiConfig.getApiUrl(ApiConfig.contacts)}');
                        
                        final response = await ApiService.addContact(
                          token: token,
                          friendUsername: username,
                        );
                        
                        logger.debug('✅ [添加联系人] API调用成功，响应: $response');

                        // 关闭加载提示
                        if (mounted) {
                          Navigator.of(outerContext, rootNavigator: true).pop();
                        }

                        if (mounted) {
                          _handleAddContactResponse(response, outerContext);
                        }
                      } catch (e, stackTrace) {
                        // 关闭加载提示
                        logger.debug('❌ [添加联系人] API调用失败');
                        logger.debug('❌ [添加联系人] 错误类型: ${e.runtimeType}');
                        logger.debug('❌ [添加联系人] 错误信息: $e');
                        logger.debug('❌ [添加联系人] 堆栈跟踪: $stackTrace');
                        
                        if (mounted) {
                          Navigator.of(outerContext, rootNavigator: true).pop();
                        }
                        
                        // 提取更友好的错误信息
                        String errorMessage = '添加失败';
                        if (e.toString().contains('网络请求失败')) {
                          errorMessage = '网络连接失败，请检查网络设置';
                        } else if (e.toString().contains('请求失败')) {
                          errorMessage = '服务器响应异常: $e';
                        } else {
                          errorMessage = '添加失败: $e';
                        }
                        
                        if (mounted) {
                          ScaffoldMessenger.of(
                            outerContext,
                          ).showSnackBar(
                            SnackBar(
                              content: Text(errorMessage),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 显示创建群组对话框
  void showCreateGroupDialog() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MobileCreateGroupPage()),
    );

    // 如果创建成功，可以在这里做一些处理
    if (result == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('群组创建成功')));
      
      // 🔴 关键修复：刷新会话列表（此时 group_members 表已更新）
      await _loadRecentContacts();
      
      // 🔴 新增：同时清除通讯录缓存并通知刷新群组列表
      logger.debug('🔄 群组创建成功，清除通讯录缓存并刷新群组列表');
      MobileContactsPage.clearCacheAndRefresh();
    }
  }

  // 显示二维码扫描器
  void showQRCodeScanner() async {
    try {
      // 导航到二维码扫描页面
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const QRScannerPage()),
      );

      if (!mounted) return;

      // 处理扫描结果
      if (result != null && result is String) {
        logger.debug('扫描到二维码: $result');

        // 尝试解析二维码内容
        // 支持格式：
        // 1. user-{userId}-{username} - 用户ID和用户名
        // 2. group-{groupId} - 群组ID
        // 3. youdu://user/{username} - 用户名
        // 4. youdu://group/{groupId} - 群组ID
        if (result.startsWith('user-')) {
          // 用户ID格式: user-{userId}-{username}
          final parts = result.substring('user-'.length).split('-');
          if (parts.length >= 2) {
            // 新格式：user-{userId}-{username}
            final userId = parts[0];
            final username = parts.sublist(1).join('-'); // 用户名可能包含-
            _handleAddContactByUserId(userId, username: username);
          } else {
            // 旧格式兼容：user-{userId}
            final userId = parts[0];
            _handleAddContactByUserId(userId);
          }
        } else if (result.startsWith('group-')) {
          // 群组ID格式
          final groupIdStr = result.substring('group-'.length);
          final groupId = int.tryParse(groupIdStr);
          if (groupId != null) {
            _handleJoinGroupByQRCode(groupId);
          } else {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('无效的群组二维码')));
          }
        } else if (result.startsWith('youdu://user/')) {
          final username = result.substring('youdu://user/'.length);
          _handleAddContactByUsername(username);
        } else if (result.startsWith('youdu://group/')) {
          final groupId = result.substring('youdu://group/'.length);
          _handleJoinGroupById(groupId);
        } else {
          // 如果不是特定格式，显示原始内容
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('扫描结果: $result')));
        }
      }
    } catch (e) {
      logger.debug('扫描二维码失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败: $e')));
      }
    }
  }

  // 处理添加联系人的响应
  void _handleAddContactResponse(
    Map<String, dynamic> response,
    BuildContext context,
  ) {
    final code = response['code'] ?? -1;
    final message = response['message'] ?? '添加失败';

    switch (code) {
      case 0:
        // 成功发送（包括重新发送）
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('好友请求已发送')));
        break;
      case 2:
        // 待审核中
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已向该联系人发起过申请，请耐心等待'),
            duration: Duration(seconds: 3),
          ),
        );
        break;
      case 3:
        // 已是好友
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        break;
      case 5:
        // 对方已经发送请求给你
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 4),
          ),
        );
        break;
      default:
        // 其他错误（包括临时的文本匹配方案）
        String displayMessage = message;

        // 临时方案：如果后端还没有完全按照新格式返回
        if (message.contains('待') ||
            message.contains('审核') ||
            message.contains('pending')) {
          displayMessage = '已向该联系人发起过申请，请耐心等待';
        }

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(displayMessage)));
    }
  }

  // 通过用户ID添加联系人
  void _handleAddContactByUserId(String userId, {String? username}) async {
    try {
      logger.debug('📞 [扫码添加] 通过用户ID添加: $userId, 用户名: $username');
      
      // 跳转到添加个人页面
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AddFriendFromQRPage(
              userId: userId,
              username: username,
            ),
          ),
        );
      }
    } catch (e) {
      logger.error('处理用户ID失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('处理失败: $e')));
      }
    }
  }

  // 通过用户名添加联系人
  void _handleAddContactByUsername(String username) async {
    try {
      logger.debug('📞 [扫码添加] 开始添加联系人: $username');
      
      final token = await Storage.getToken();
      if (token == null) {
        logger.debug('❌ [扫码添加] Token为空，用户未登录');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      logger.debug('📞 [扫码添加] Token已获取，准备调用API');
      final response = await ApiService.addContact(
        token: token,
        friendUsername: username,
      );
      
      logger.debug('✅ [扫码添加] API调用成功，响应: $response');

      if (mounted) {
        _handleAddContactResponse(response, context);
      }
    } catch (e, stackTrace) {
      logger.debug('❌ [扫码添加] API调用失败');
      logger.debug('❌ [扫码添加] 错误信息: $e');
      logger.debug('❌ [扫码添加] 堆栈跟踪: $stackTrace');
      
      if (mounted) {
        String errorMessage = '添加失败';
        if (e.toString().contains('网络请求失败')) {
          errorMessage = '网络连接失败，请检查网络设置';
        } else if (e.toString().contains('请求失败')) {
          errorMessage = '服务器响应异常: $e';
        } else {
          errorMessage = '添加失败: $e';
        }
        
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // 通过二维码加入群组
  void _handleJoinGroupByQRCode(int groupId) async {
    try {
      logger.debug('📞 [扫码加群] 通过群组ID加入: $groupId');
      
      // 跳转到加入群组页面
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JoinGroupFromQRPage(
              groupId: groupId,
            ),
          ),
        );
      }
    } catch (e) {
      logger.error('处理群组二维码失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('处理失败: $e')));
      }
    }
  }

  // 通过群组ID加入群组
  void _handleJoinGroupById(String groupId) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('加入群组: $groupId')));
    // TODO: 实现加入群组功能
  }

  // 播放新消息提示音
  Future<void> _playNewMessageSound() async {
    try {
      // 检查是否开启了新消息提示音
      final soundEnabled = await Storage.getNewMessageSoundEnabled();
      if (!soundEnabled) {
        logger.debug('🔇 新消息提示音已关闭，不播放');
        return;
      }

      // 播放提示音
      logger.debug('🔔 播放新消息提示音');
      await _audioPlayer.play(AssetSource('mp3/notice.mp3'));
    } catch (e) {
      logger.error('播放提示音失败: $e');
    }
  }

  // 显示新消息通知弹窗
  Future<void> _showMessageNotificationPopup({
    required String title,
    required String message,
    String? avatar,
    String? senderName,
    bool isGroup = false,
    int? contactId,
  }) async {
    try {
      // 检查是否开启了新消息弹窗
      final popupEnabled = await Storage.getNewMessagePopupEnabled();
      if (!popupEnabled) {
        logger.debug('🔇 新消息弹窗已关闭，不显示');
        return;
      }

      // � AP：P在前台时不显示应用内弹窗
      // 原因：用户正在使用APP，会在聊天列表中看到新消息，不需要额外弹窗打扰
      // APP在后台时：系统通知会自动显示（NotificationService.showMessageNotification）
      if (NotificationService.instance.isAppInForeground) {
        logger.debug('🔔 APP在前台，不显示应用内弹窗（避免打扰用户）');
        return;
      }

      logger.debug('🔔 APP在后台，不显示应用内弹窗（系统通知会处理）');
      return;

      // 以下代码已禁用 - 如需启用应用内弹窗，请移除上面的return语句
      // 检查widget是否还在树中
      if (!mounted) return;

      // 显示弹窗
      MessageNotificationPopup.show(
        context: context,
        title: title,
        message: message,
        avatar: avatar,
        senderName: senderName,
        isGroup: isGroup,
        onTap: () {
          // 点击弹窗后跳转到对应的聊天页面
          if (contactId != null) {
            _openChat(contactId, isGroup);
          }
        },
      );

      logger.debug('🔔 显示消息通知弹窗: $title - $message');
    } catch (e) {
      logger.error('显示消息通知弹窗失败: $e');
    }
  }

  // 打开聊天页面
  void _openChat(int contactId, bool isGroup) {
    try {
      // 在最近联系人列表中查找
      final contact = _recentContacts.firstWhere(
        (c) => c.userId == contactId && c.isGroup == isGroup,
        orElse: () => RecentContactModel(
          userId: contactId,
          username: contactId.toString(),
          fullName: contactId.toString(),
          avatar: null,
          lastMessageTime: DateTime.now().toIso8601String(),
          lastMessage: '',
          unreadCount: 0,
          status: 'offline',
          type: isGroup ? 'group' : 'user',
          groupId: isGroup ? contactId : null,
          groupName: isGroup ? '群聊$contactId' : null,
        ),
      );

      // 打开聊天页面
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MobileChatPage(
            userId: contact.userId,
            displayName: contact.fullName,
            isGroup: isGroup,
            groupId: isGroup ? contactId : null,
            avatar: contact.avatar,
            onChatClosed: (int closedContactId, bool closedIsGroup) async {
              // 🔴 退出聊天页面时，只更新该会话的最新消息
              logger.debug('📤 聊天页面已关闭，更新单个会话: contactId=$closedContactId, isGroup=$closedIsGroup');
              await _updateSingleContact(closedContactId, closedIsGroup);
            },
          ),
        ),
      );
    } catch (e) {
      logger.error('打开聊天页面失败: $e');
    }
  }

  // 处理私聊新消息
  Future<void> _handleNewMessage(dynamic data) async {
    try {
      if (data == null) return;
      if (!mounted) return;

      final messageData = data as Map<String, dynamic>;
      final senderId = messageData['sender_id'] as int?;
      final content = messageData['content'] as String? ?? '';
      final messageType = messageData['message_type'] as String? ?? 'text';
      final createdAt = messageData['created_at'] as String?;

      if (senderId == null) return;

      logger.debug('📨 收到私聊消息 - 发送者ID: $senderId');

      // 🔴 特殊处理：如果是好友审核消息，跳过_handleNewMessage的处理
      // 因为这类消息会通过clear_chat_history事件单独处理
      if (content == '请求添加好友【已通过】' || content == '请求添加好友【已驳回】') {
        logger.debug('📨 检测到好友审核消息，跳过_handleNewMessage处理，由clear_chat_history事件处理');
        return;
      }

      // 判断是否是当前用户发送的消息
      final currentUserId = await Storage.getUserId();
      final isMyMessage = currentUserId != null && senderId == currentUserId;
      logger.debug(
        '📨 消息发送者判断 - 当前用户ID: $currentUserId, 发送者ID: $senderId, 是否是我的消息: $isMyMessage',
      );

      // 🔴 关键修复：将新消息追加到聊天缓存中，确保进入聊天页面时能看到最新消息
      if (currentUserId != null) {
        final cacheKey = 'user_${senderId}_$currentUserId';
        final newMessage = MessageModel(
          id: messageData['id'] as int? ?? 0,
          serverId: messageData['id'] as int?,
          senderId: senderId,
          receiverId: messageData['receiver_id'] as int? ?? currentUserId,
          content: content,
          messageType: messageType,
          isRead: false,
          createdAt: createdAt != null ? DateTime.parse(createdAt) : DateTime.now(),
          senderName: (messageData['sender_name'] as String?) ?? '',
          receiverName: (messageData['receiver_name'] as String?) ?? '',
          senderAvatar: messageData['sender_avatar'] as String?,
          receiverAvatar: messageData['receiver_avatar'] as String?,
          fileName: messageData['file_name'] as String?,
          status: 'normal',
          quotedMessageId: messageData['quoted_message_id'] as int?,
          quotedMessageContent: messageData['quoted_message_content'] as String?,
        );
        MobileChatPage.appendToCache(cacheKey, newMessage);
        logger.debug('📦 已将新消息追加到缓存: $cacheKey');
      }

      // 🔴 关键修改：如果该联系人在删除列表中，先移除删除标记
      // 参考PC端实现：直接从Storage读取最新状态，而不是依赖内存中的_deletedChats
      final contactKey = Storage.generateContactKey(
        isGroup: false,
        id: senderId,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 收到来自已删除会话的新消息，自动恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ 已删除会话已恢复: $contactKey，现在继续处理当前消息以确保显示在列表中');
        // 重新加载配置以更新状态
        await _loadPreferences();
        
        // 播放新消息提示音（有新未读消息且不是自己发送的）
        if (!isMyMessage) {
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
          final senderName = senderInfo['name']!;
          final senderAvatar = senderInfo['avatar'];
          final messageType = messageData['message_type'] as String? ?? 'text';
          final formattedMessage = _formatMessagePreview(messageType, content);
          _showMessageNotificationPopup(
            title: senderName,
            message: formattedMessage,
            avatar: senderAvatar,
            senderName: senderName,
            isGroup: false,
            contactId: senderId,
          );
        }
        // 🔴 不再直接返回，继续处理当前消息，确保消息能正确显示在最近联系人列表中
      }

      // 查找联系人是否在列表中
      final contactIndex = _recentContacts.indexWhere(
        (contact) => !contact.isGroup && contact.userId == senderId,
      );

      if (contactIndex != -1) {
        // 联系人在列表中，更新未读计数和最后消息
        logger.debug('🔍 [私聊消息] 更新前 - contactIndex: $contactIndex, 联系人: ${_recentContacts[contactIndex].displayName}');
        if (_recentContacts.length >= 2) {
          logger.debug('🔍 [私聊消息] 更新前列表前2个: ${_recentContacts[0].displayName}, ${_recentContacts[1].displayName}');
        }
        
        setState(() {
          final contact = _recentContacts[contactIndex];
          final oldUnreadCount = contact.unreadCount;
          
          // 🔴 关键修复：检查用户是否正在查看该对话
          // 只有当用户真正在聊天页面查看该对话时，才不增加未读数
          // 已读缓存只用于UI显示，不应该阻止未读数增加
          final readKey = 'user_$senderId';
          
          // 🔍 调试日志：追踪首次登录后未读气泡不显示的问题
          logger.debug('🔍 [私聊消息-未读判断] readKey: $readKey, isMyMessage: $isMyMessage, oldUnreadCount: $oldUnreadCount');
          
          // 🔴 修复：收到新消息时，应该从已读缓存中移除，并增加未读数
          // 只有自己发送的消息才不增加未读数
          final newUnreadCount = isMyMessage ? oldUnreadCount : oldUnreadCount + 1;
          
          // 🔴 关键：收到新消息时，从已读缓存中移除该会话
          if (!isMyMessage && MobileHomePage._readStatusCache.contains(readKey)) {
            MobileHomePage._readStatusCache.remove(readKey);
            logger.debug('🔍 [私聊消息-未读判断] 收到新消息，已从已读缓存移除: $readKey');
          }
          
          logger.debug('🔍 [私聊消息-未读判断] 计算后的newUnreadCount: $newUnreadCount');

          // 格式化消息预览
          // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
          final formattedMessage = _formatMessagePreview(messageType, content, isSender: isMyMessage);

          // 🔴 时区处理：将UTC时间转换为本地时间格式（不带Z后缀），与数据库存储格式保持一致
          String lastMessageTime;
          if (createdAt != null && createdAt.isNotEmpty) {
            try {
              // 解析时间（DateTime.parse会自动处理UTC时间）
              final parsedTime = DateTime.parse(createdAt);
              // 转换为本地时间并格式化为不带Z的ISO格式
              lastMessageTime = parsedTime.toLocal().toIso8601String().replaceAll('Z', '');
            } catch (e) {
              lastMessageTime = DateTime.now().toIso8601String();
            }
          } else {
            lastMessageTime = DateTime.now().toIso8601String();
          }

          // 更新联系人信息（包括头像）
          final senderAvatar = messageData['sender_avatar'] as String?;
          final updatedContact = contact.copyWith(
            unreadCount: newUnreadCount,
            lastMessage: formattedMessage,
            lastMessageTime: lastMessageTime,
            lastMessageStatus: 'normal', // 🔴 清除撤回状态，显示新消息内容
            avatar: senderAvatar, // 更新发送者头像
          );

          // 移除旧的联系人
          _recentContacts.removeAt(contactIndex);

          // 找到第一个非顶置联系人的位置（插入到顶置联系人之下）
          int targetIndex = _recentContacts.length; // 默认插入到末尾
          for (int i = 0; i < _recentContacts.length; i++) {
            final c = _recentContacts[i];
            final key = Storage.generateContactKey(
              isGroup: c.isGroup,
              id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
            );
            if (!_pinnedChats.containsKey(key)) {
              targetIndex = i;
              break;
            }
          }

          _recentContacts.insert(targetIndex, updatedContact);
          logger.debug('📍 [私聊消息] 会话已移动到位置: $targetIndex (顶置联系人之后)');
          if (_recentContacts.length >= 2) {
            logger.debug('🔍 [私聊消息] 更新后列表前2个: ${_recentContacts[0].displayName}(${_recentContacts[0].lastMessageTime}), ${_recentContacts[1].displayName}(${_recentContacts[1].lastMessageTime})');
          }

          logger.debug('✅ 已更新联系人 - 未读数: $oldUnreadCount -> $newUnreadCount');
          
          // 🔴 更新缓存
          MobileHomePage._cachedContacts = List.from(_recentContacts);
          MobileHomePage._cacheTimestamp = DateTime.now();
          
          // 🔴 关键：收到新消息时，更新未读数量缓存
          final unreadKey = 'user_$senderId';
          MobileHomePage.updateUnreadCount(unreadKey, newUnreadCount);
          
          logger.debug('💾 缓存已更新（私聊消息更新），未读数: $newUnreadCount');
        });

        // 播放新消息提示音（有新未读消息且不是自己发送的）
        if (!isMyMessage) {
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
          final senderName = senderInfo['name']!;
          final senderAvatar = senderInfo['avatar'];
          final messageType = messageData['message_type'] as String? ?? 'text';
          final formattedMessage = _formatMessagePreview(messageType, content);
          _showMessageNotificationPopup(
            title: senderName,
            message: formattedMessage,
            avatar: senderAvatar,
            senderName: senderName,
            isGroup: false,
            contactId: senderId,
          );
        }
      } else {
        // 联系人不在列表中，参考PC端逻辑：直接创建新的联系人条目并插入到列表
        logger.debug('⚠️ 联系人不在列表中，创建新条目');
        
        // 获取发送者信息
        final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
        final senderName = senderInfo['name']!;
        final senderAvatar = senderInfo['avatar'];
        
        setState(() {
          // 格式化消息预览
          // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
          final formattedMessage = _formatMessagePreview(messageType, content, isSender: isMyMessage);
          
          // 🔴 时区处理：本地数据库存储的时间已经是上海时区，直接使用
          String lastMessageTime = createdAt ?? DateTime.now().toIso8601String();
          
          // 🔴 计算未读数量
          final unreadCount = isMyMessage ? 0 : 1;
          
          // 创建新的联系人条目
          final newContact = RecentContactModel(
            type: 'user', // 明确指定为用户类型
            userId: senderId,
            username: senderName,
            fullName: senderName,
            avatar: senderAvatar,
            lastMessage: formattedMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: unreadCount, // 自己发送的消息未读数为0
            status: 'offline',
          );
          
          // 找到第一个非顶置联系人的位置（插入到顶置联系人之下）
          int targetIndex = 0;
          for (int i = 0; i < _recentContacts.length; i++) {
            final c = _recentContacts[i];
            final key = Storage.generateContactKey(
              isGroup: c.isGroup,
              id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
            );
            if (!_pinnedChats.containsKey(key)) {
              targetIndex = i;
              break;
            }
          }
          
          // 插入到目标位置
          _recentContacts.insert(targetIndex, newContact);
          
          logger.debug('✅ 已创建新的联系人条目并插入到列表');
          
          // 🔴 更新缓存
          MobileHomePage._cachedContacts = List.from(_recentContacts);
          MobileHomePage._cacheTimestamp = DateTime.now();
          
          // 🔴 更新未读数量缓存
          if (unreadCount > 0) {
            final unreadKey = 'user_$senderId';
            MobileHomePage.updateUnreadCount(unreadKey, unreadCount);
            logger.debug('💾 缓存已更新（新联系人添加），未读数: $unreadCount');
          } else {
            logger.debug('💾 缓存已更新（新联系人添加），无未读消息');
          }
        });

        // 播放新消息提示音（有新未读消息且不是自己发送的）
        if (!isMyMessage) {
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final formattedMessage = _formatMessagePreview(messageType, content);
          _showMessageNotificationPopup(
            title: senderName,
            message: formattedMessage,
            avatar: senderAvatar,
            senderName: senderName,
            isGroup: false,
            contactId: senderId,
          );
        }
      }
    } catch (e) {
      logger.error('❌ 处理私聊消息失败: $e');
    }
  }

  // 处理群组新消息
  Future<void> _handleGroupMessage(dynamic data) async {
    try {
      if (data == null) return;
      if (!mounted) return;

      final messageData = data as Map<String, dynamic>;
      final groupId = messageData['group_id'] as int?;
      final senderId = messageData['sender_id'] as int?;
      final content = messageData['content'] as String? ?? '';
      final messageType = messageData['message_type'] as String? ?? 'text';
      final createdAt = messageData['created_at'] as String?;
      final quotedMessageId = messageData['quoted_message_id'] as int?;
      final quotedMessageContent = messageData['quoted_message_content'] as String?;

      if (groupId == null) return;

      logger.debug(
        '📨 收到群组消息 - 群组ID: $groupId, 发送者ID: $senderId, 内容: $content, 消息类型: $messageType, 引用消息ID: $quotedMessageId',
      );

      // 🔴 关键修复：如果是通话发起消息（join_voice_button/join_video_button），保存群组ID
      // 这样当 TUICallKit 来电回调触发时，我们就知道是哪个群组的通话
      if (messageType == 'join_voice_button' || messageType == 'join_video_button') {
        logger.debug('📞 [HomePage] 收到群组通话发起消息，保存群组ID: $groupId');
        // 🔴 通知 tuicallkit_service 保存群组ID（使用单例访问）
        AgoraService().setCurrentGroupId(groupId);
      }

      // 🔴 关键修复：将新消息追加到群聊缓存中，确保进入聊天页面时能看到最新消息
      final cacheKey = 'group_$groupId';
      final newMessage = MessageModel(
        id: messageData['id'] as int? ?? 0,
        serverId: messageData['id'] as int?,
        senderId: senderId ?? 0,
        receiverId: 0,
        content: content,
        messageType: messageType,
        isRead: false,
        createdAt: createdAt != null ? DateTime.parse(createdAt) : DateTime.now(),
        senderName: (messageData['sender_name'] as String?) ?? '',
        receiverName: '',
        senderAvatar: messageData['sender_avatar'] as String?,
        fileName: messageData['file_name'] as String?,
        status: 'normal',
        quotedMessageId: quotedMessageId,
        quotedMessageContent: quotedMessageContent,
      );
      MobileChatPage.appendToCache(cacheKey, newMessage);
      logger.debug('📦 已将新群组消息追加到缓存: $cacheKey');

      // 🔴 检测是否是群组创建/邀请的系统消息
      if (messageType == 'system' && 
          (content.contains('群组已创建') || 
           content.contains('创建新群组') || 
           content.contains('您已被邀请加入群组'))) {
        logger.debug('🆕 检测到群组创建/邀请消息，立即刷新会话列表和通讯录群组缓存: $content');
        
        // 🔴 关键修复：先将当前用户添加到group_members表，确保SQL查询能找到该群组
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          final localDb = LocalDatabaseService();
          await localDb.addGroupMember(groupId, currentUserId);
          logger.debug('✅ 已将用户 $currentUserId 添加到群组 $groupId 的成员表');
        }
        
        // 1. 清除通讯录群组缓存并刷新
        MobileContactsPage.clearCacheAndRefresh();
        
        // 2. 立即刷新会话列表（如果用户在会话页面）
        await _loadRecentContacts();
        logger.debug('✅ 会话列表已刷新，新群组已显示');
        
        // 🔴 关键修复：刷新列表后直接返回，避免后续代码再次处理导致排序混乱
        return;
      }

      // 判断是否是当前用户发送的消息
      final currentUserId = await Storage.getUserId();
      final isMyMessage = currentUserId != null && senderId == currentUserId;
      logger.debug(
        '📨 群组消息发送者判断 - 当前用户ID: $currentUserId, 发送者ID: $senderId, 是否是我的消息: $isMyMessage',
      );

      // 🔴 关键修改：如果该群组在删除列表中，先移除删除标记
      // 参考PC端实现：直接从Storage读取最新状态，而不是依赖内存中的_deletedChats
      final contactKey = Storage.generateContactKey(isGroup: true, id: groupId);
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 收到来自已删除群聊的新消息，自动恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ 已删除群聊会话已恢复: $contactKey，现在继续处理当前消息以确保显示在列表中');
        // 重新加载配置以更新状态
        await _loadPreferences();
        
        // 播放新消息提示音（有新未读消息且不是自己发送的）
        if (!isMyMessage) {
          _playNewMessageSound();

          // 显示新消息通知弹窗（先创建一个默认的群组信息，后续会通过重新加载更新）
          final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
          final senderName = senderInfo['name']!;
          final senderAvatar = senderInfo['avatar'];
          final formattedMessage = _formatMessagePreview(messageType, content);
          final displayMessage = '$senderName: $formattedMessage';
          _showMessageNotificationPopup(
            title: '群聊$groupId',
            message: displayMessage,
            avatar: senderAvatar,
            senderName: senderName,
            isGroup: true,
            contactId: groupId,
          );
        }
        // 🔴 不再直接返回，继续处理当前消息，确保消息能正确显示在最近联系人列表中
      }

      // 查找群组是否在列表中
      final contactIndex = _recentContacts.indexWhere(
        (contact) => contact.isGroup && contact.groupId == groupId,
      );

      if (contactIndex != -1) {
        // 群组在列表中，更新未读计数和最后消息
        logger.debug('🔍 [群组消息] 更新前 - contactIndex: $contactIndex, 群组: ${_recentContacts[contactIndex].displayName}');
        if (_recentContacts.length >= 2) {
          logger.debug('🔍 [群组消息] 更新前列表前2个: ${_recentContacts[0].displayName}, ${_recentContacts[1].displayName}');
        }
        
        setState(() {
          final contact = _recentContacts[contactIndex];
          final oldUnreadCount = contact.unreadCount;
          final isDoNotDisturb = contact.doNotDisturb;

          // 🔴 关键修复：收到新消息时，应该从已读缓存中移除，并增加未读数
          // 只有自己发送的消息才不增加未读数
          final readKey = 'group_$groupId';
          
          // 如果群组设置了消息免打扰，未读数固定为1（只显示红点，不显示具体数量）
          // 否则正常累加未读数
          final newUnreadCount = isDoNotDisturb ? 1 : (isMyMessage ? oldUnreadCount : oldUnreadCount + 1);
          
          // 🔴 关键：收到新消息时，从已读缓存中移除该群组
          if (!isMyMessage && MobileHomePage._readStatusCache.contains(readKey)) {
            MobileHomePage._readStatusCache.remove(readKey);
            logger.debug('🔍 [群组消息-未读判断] 收到新消息，已从已读缓存移除: $readKey');
          }

          // 格式化消息预览
          // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
          final formattedMessage = _formatMessagePreview(messageType, content, isSender: isMyMessage);

          logger.debug(
            '📊 群组消息未读数更新：原未读数=$oldUnreadCount, 新未读数=$newUnreadCount, 免打扰=$isDoNotDisturb',
          );

          // 🔴 时区处理：将UTC时间转换为本地时间格式（不带Z后缀），与数据库存储格式保持一致
          String lastMessageTime;
          if (createdAt != null && createdAt.isNotEmpty) {
            try {
              final parsedTime = DateTime.parse(createdAt);
              lastMessageTime = parsedTime.toLocal().toIso8601String().replaceAll('Z', '');
            } catch (e) {
              lastMessageTime = DateTime.now().toIso8601String();
            }
          } else {
            lastMessageTime = DateTime.now().toIso8601String();
          }

          // 更新群组信息
          final updatedContact = contact.copyWith(
            unreadCount: newUnreadCount,
            lastMessage: formattedMessage,
            lastMessageTime: lastMessageTime,
            lastMessageStatus: 'normal', // 🔴 清除撤回状态，显示新消息内容
          );

          // 移除旧的群组
          _recentContacts.removeAt(contactIndex);

          // 找到第一个非顶置联系人的位置（插入到顶置联系人之下）
          int targetIndex = _recentContacts.length; // 默认插入到末尾
          for (int i = 0; i < _recentContacts.length; i++) {
            final c = _recentContacts[i];
            final key = Storage.generateContactKey(
              isGroup: c.isGroup,
              id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
            );
            if (!_pinnedChats.containsKey(key)) {
              targetIndex = i;
              break;
            }
          }

          _recentContacts.insert(targetIndex, updatedContact);
          logger.debug('📍 [群组消息] 群组会话已移动到位置: $targetIndex (顶置联系人之后)');
          if (_recentContacts.length >= 2) {
            logger.debug('🔍 [群组消息] 更新后列表前2个: ${_recentContacts[0].displayName}(${_recentContacts[0].lastMessageTime}), ${_recentContacts[1].displayName}(${_recentContacts[1].lastMessageTime})');
          }

          logger.debug('✅ 已更新群组 - 未读数: $oldUnreadCount -> $newUnreadCount');
          
          // 🔴 更新缓存
          MobileHomePage._cachedContacts = List.from(_recentContacts);
          MobileHomePage._cacheTimestamp = DateTime.now();
          
          // 🔴 关键：收到新群组消息时，更新未读数量缓存
          final unreadKey = 'group_$groupId';
          MobileHomePage.updateUnreadCount(unreadKey, newUnreadCount);
          
          logger.debug('💾 缓存已更新（群组消息更新），未读数: $newUnreadCount');
        });

        // 播放新消息提示音（有新未读消息且不是自己发送的）
        if (!isMyMessage) {
          _playNewMessageSound();

          // 显示新消息通知弹窗（群组已移到targetIndex位置）
          final groupContact = _recentContacts.firstWhere(
            (c) => c.isGroup && c.groupId == groupId,
            orElse: () => RecentContactModel.group(
              groupId: groupId,
              groupName: '群聊$groupId',
              lastMessage: '',
              lastMessageTime: DateTime.now().toIso8601String(),
            ),
          );
          final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
          final senderName = senderInfo['name']!;
          final senderAvatar = senderInfo['avatar'];
          final formattedMessage = _formatMessagePreview(messageType, content);
          final displayMessage = '$senderName: $formattedMessage';
          _showMessageNotificationPopup(
            title: groupContact.groupName ?? groupContact.fullName,
            message: displayMessage,
            avatar: senderAvatar,
            senderName: senderName,
            isGroup: true,
            contactId: groupId,
          );
        }
      } else {
        // 群组不在列表中，获取群组信息并添加
        logger.debug('⚠️ 群组不在列表中，获取群组信息并添加');
        try {
          final token = await Storage.getToken();
          if (token != null && token.isNotEmpty) {
            // 获取群组详情
            final groupResponse = await ApiService.getGroupDetail(
              token: token,
              groupId: groupId,
            );

            if (groupResponse['code'] == 0 && groupResponse['data'] != null) {
              final groupData =
                  groupResponse['data']['group'] as Map<String, dynamic>;
              final groupName = groupData['name'] as String? ?? '未知群组';
              final groupAvatar = groupData['avatar'] as String?; // 获取群组头像
              final remark = groupData['remark'] as String?;
              final doNotDisturb =
                  groupData['do_not_disturb'] as bool? ?? false;

              // 格式化消息预览
              // 🔴 修复：传入isSender参数，用于通话拒绝/取消消息的正确显示
              final formattedMessage = _formatMessagePreview(
                messageType,
                content,
                isSender: isMyMessage,
              );

              // 创建群组联系人
              final groupContact = RecentContactModel.group(
                groupId: groupId,
                groupName: groupName,
                avatar: groupAvatar, // 传递群组头像
                lastMessage: formattedMessage,
                lastMessageTime: createdAt ?? DateTime.now().toIso8601String(),
                remark: remark,
                doNotDisturb: doNotDisturb,
              ).copyWith(unreadCount: 1);

              setState(() {
                // 将群组添加到列表顶部（顶置之下）
                _insertContactAtTop(groupContact);
                
                // 🔴 更新缓存
                MobileHomePage._cachedContacts = List.from(_recentContacts);
                MobileHomePage._cacheTimestamp = DateTime.now();
                
                // 🔴 更新未读数量缓存
                final unreadKey = 'group_$groupId';
                MobileHomePage.updateUnreadCount(unreadKey, 1);
                logger.debug('💾 缓存已更新（新群组添加），未读数: 1');
              });

              logger.debug('✅ 已将群组添加到列表');

              // 播放新消息提示音（有新未读消息且不是自己发送的）
              if (!isMyMessage) {
                _playNewMessageSound();

                // 显示新消息通知弹窗
                final senderInfo = await _getSenderAvatarInfo(messageData, senderId);
                final senderName = senderInfo['name'];
                final senderAvatar = senderInfo['avatar'];
                final formattedMessage = _formatMessagePreview(messageType, content);
                final displayMessage = '$senderName: $formattedMessage';
                _showMessageNotificationPopup(
                  title: groupName,
                  message: displayMessage,
                  avatar: senderAvatar,
                  senderName: senderName,
                  isGroup: true,
                  contactId: groupId,
                );
              }
            }
          }
        } catch (e) {
          logger.error('❌ 获取群组信息失败: $e');
        }
      }
    } catch (e) {
      logger.error('❌ 处理群组消息失败: $e');
    }
  }

  // 获取发送者头像信息（如果消息中没有则通过API获取）
  Future<Map<String, String?>> _getSenderAvatarInfo(Map<String, dynamic> messageData, int? senderId) async {
    String? senderAvatar = messageData['sender_avatar'] as String?;
    String? senderName = messageData['sender_name'] as String?;
    
    // 如果消息中没有头像或头像为空，尝试通过API获取
    if ((senderAvatar == null || senderAvatar.isEmpty) && senderId != null) {
      try {
        final token = await Storage.getToken();
        if (token != null) {
          final userInfo = await ApiService.getUserInfo(senderId, token: token);
          if (userInfo['code'] == 0) {
            final userData = userInfo['data'];
            senderAvatar = userData?['avatar'] as String?;
            // 如果消息中没有用户名，也从API获取
            if (senderName == null || senderName.isEmpty) {
              final fullName = userData?['full_name'] as String?;
              final username = userData?['username'] as String?;
              senderName = (fullName != null && fullName.isNotEmpty) ? fullName : username;
            }
            logger.debug('🔔 通过API获取发送者信息 - 头像: $senderAvatar, 姓名: $senderName');
          }
        }
      } catch (e) {
        logger.debug('🔔 获取发送者信息失败: $e');
      }
    }
    
    return {
      'avatar': senderAvatar,
      'name': senderName ?? (senderId?.toString() ?? '未知用户'),
    };
  }

  // 将新联系人插入到顶部（顶置联系人之下）
  void _insertContactAtTop(RecentContactModel contact) {
    // 找到第一个非顶置联系人的位置
    int targetIndex = 0;
    for (int i = 0; i < _recentContacts.length; i++) {
      final c = _recentContacts[i];
      final key = Storage.generateContactKey(
        isGroup: c.isGroup,
        id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
      );
      if (!_pinnedChats.containsKey(key)) {
        targetIndex = i;
        break;
      }
    }

    _recentContacts.insert(targetIndex, contact);
  }

  // 格式化消息预览
  // [isSender] 当前用户是否是消息的发送者（用于通话拒绝/取消消息的显示）
  String _formatMessagePreview(String messageType, String content, {bool isSender = false}) {
    switch (messageType) {
      case 'image':
        return '[图片]';
      case 'file':
        return '[文件]';
      case 'voice':
        return '[语音]';
      case 'video':
        return '[视频]';
      // 🔴 修复：通话拒绝消息根据当前用户是发送者还是接收者显示不同内容
      case 'call_rejected':
      case 'call_rejected_video':
        // 发送者（拒绝方）看到"已拒绝"，接收者（被拒绝方）看到"对方已拒绝"
        return isSender ? '已拒绝' : '对方已拒绝';
      case 'call_cancelled':
      case 'call_cancelled_video':
        // 发送者（取消方）看到"已取消"，接收者（被取消方）看到"对方已取消"
        return isSender ? '已取消' : '对方已取消';
      case 'call_ended':
      case 'call_ended_video':
        return '[通话结束]';
      default:
        // 检测是否为纯表情消息（格式：[emotion:xxx.png]）
        // 移除所有表情标记后，如果剩余内容为空，则说明是纯表情消息
        if (content.contains('[emotion:')) {
          final withoutEmotions = content
              .replaceAll(RegExp(r'\[emotion:[^\]]+\.png\]'), '')
              .trim();
          if (withoutEmotions.isEmpty) {
            return '[表情]';
          }
        }
        // 检测是否为URL（可能是头像或图片链接）
        if (content.startsWith('http://') || content.startsWith('https://')) {
          // 检查是否是图片URL
          if (content.contains('.png') || content.contains('.jpg') || 
              content.contains('.jpeg') || content.contains('.gif') ||
              content.contains('.webp')) {
            return '[图片]';
          }
          return '[链接]';
        }
        return content;
    }
  }

  String _formatTime(String timeStr) {
    // 尝试解析时间字符串
    try {
      final time = DateTime.parse(timeStr);
      final now = DateTime.now();
      final diff = now.difference(time);

      if (diff.inDays > 0) {
        if (diff.inDays == 1) return '昨天';
        if (diff.inDays < 7) return '${diff.inDays}天前';
        return '${time.month}/${time.day}';
      }

      if (diff.inHours > 0) return '${diff.inHours}小时前';
      if (diff.inMinutes > 0) return '${diff.inMinutes}分钟前';
      return '刚刚';
    } catch (e) {
      // 如果解析失败，直接返回原字符串
      return timeStr;
    }
  }

  // 确保文件传输助手存在于最近联系人列表中
  Future<void> _ensureFileAssistantInRecentContacts(int userId) async {
    try {
      // 🔴 步骤1：检查文件传输助手是否被标记为已删除，如果是则恢复它
      final contactKey = Storage.generateContactKey(
        isGroup: false,
        id: userId,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 文件传输助手已被删除，现在恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ 文件传输助手已恢复');
        
        // 重新加载配置以更新 _deletedChats 状态
        await _loadPreferences();
        
        // 重新加载联系人列表，确保文件传输助手显示出来
        await _loadRecentContacts();
      }
      
      final localDb = LocalDatabaseService();
      
      // 🔴 步骤2：检查是否已有文件传输助手消息
      final existingMessages = await localDb.getFileAssistantMessages(
        userId: userId,
        limit: 1,
      );
      
      if (existingMessages.isEmpty) {
        // 如果没有消息记录，创建一个占位消息
        final now = DateTime.now();
        final placeholderMessage = {
          'user_id': userId,
          'content': '欢迎使用文件传输助手',
          'message_type': 'text',
          'sender_id': userId,
          'receiver_id': userId,
          'sender_name': await Storage.getUsername() ?? '',
          'receiver_name': '文件传输助手',
          'sender_avatar': await Storage.getAvatar() ?? '',
          'receiver_avatar': '',
          'created_at': now.toIso8601String(),
          'is_read': true,
          'status': 'normal',
        };
        
        await localDb.insertFileAssistantMessage(placeholderMessage);
        logger.debug('✅ 已创建文件传输助手占位消息，将出现在最近联系人列表中');
        
        // 🔴 立即重新加载联系人列表，更新缓存和UI
        await _loadRecentContacts();
        logger.debug('🔄 已重新加载联系人列表，缓存已更新');
      } else {
        logger.debug('✅ 文件传输助手已存在消息记录');
      }
    } catch (e) {
      logger.error('确保文件传输助手在最近联系人列表中失败: $e');
    }
  }
}

/// 权限设置项组件
class _PermissionSettingItem extends StatefulWidget {
  final String title;
  final String description;
  final Permission permission;
  final ValueChanged<bool>? onChanged;

  const _PermissionSettingItem({
    required this.title,
    required this.description,
    required this.permission,
    this.onChanged,
  });

  @override
  State<_PermissionSettingItem> createState() => _PermissionSettingItemState();
}

class _PermissionSettingItemState extends State<_PermissionSettingItem> {
  bool _isGranted = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkPermissionStatus();
  }

  Future<void> _checkPermissionStatus() async {
    try {
      final status = await widget.permission.status;
      if (mounted) {
        setState(() {
          _isGranted = status.isGranted;
        });
      }
    } catch (e) {
      logger.debug('检查权限状态失败: $e');
    }
  }

  Future<void> _togglePermission(bool value) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      if (value) {
        // 请求权限
        final result = await widget.permission.request();
        if (mounted) {
          setState(() {
            _isGranted = result.isGranted;
            _isLoading = false;
          });
          
          if (!result.isGranted) {
            // 权限被拒绝，引导用户到设置页面
            _showPermissionDeniedDialog();
          }
        }
      } else {
        // 不能直接关闭权限，引导用户到设置页面
        openAppSettings();
        setState(() {
          _isLoading = false;
        });
      }
      
      widget.onChanged?.call(_isGranted);
    } catch (e) {
      logger.debug('切换权限失败: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('权限被拒绝'),
          content: Text('${widget.title}权限被拒绝，请在系统设置中手动开启。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _isLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Switch(
                  value: _isGranted,
                  onChanged: _togglePermission,
                  activeColor: Colors.green,
                ),
        ],
      ),
    );
  }
}

/// 后台活动设置项组件（Android 专用）
class _BackgroundActivitySettingItem extends StatefulWidget {
  final ValueChanged<bool>? onChanged;

  const _BackgroundActivitySettingItem({
    this.onChanged,
  });

  @override
  State<_BackgroundActivitySettingItem> createState() => _BackgroundActivitySettingItemState();
}

class _BackgroundActivitySettingItemState extends State<_BackgroundActivitySettingItem> {
  static const MethodChannel _channel = MethodChannel('com.example.youdu/notification');
  bool _isIgnoringBatteryOptimizations = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkBatteryOptimizationStatus();
  }

  Future<void> _checkBatteryOptimizationStatus() async {
    try {
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      if (mounted) {
        setState(() {
          _isIgnoringBatteryOptimizations = result ?? false;
        });
      }
    } catch (e) {
      logger.debug('检查电池优化状态失败: $e');
    }
  }

  // 🔴 显示后台活动引导弹窗（不跳转，只提示）
  Future<void> _showBackgroundActivityGuide() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // 显示引导对话框
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启后台活动'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '为确保应用在后台时能正常接收消息和来电通知，请按以下步骤操作：',
                style: TextStyle(fontSize: 15),
              ),
              SizedBox(height: 16),
              Text('1. 打开手机"设置"', style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('2. 进入"电池"', style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('3. 找到"有度"应用，点击进入"应用耗电详情"', style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('4. 开启"允许后台活动"', style: TextStyle(fontSize: 14)),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      logger.debug('显示后台活动引导失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '后台活动',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '允许应用在后台运行，确保消息和来电通知正常',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _isLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Switch(
                  value: _isIgnoringBatteryOptimizations,
                  onChanged: (value) => _showBackgroundActivityGuide(),
                  activeColor: Colors.green,
                ),
        ],
      ),
    );
  }
}