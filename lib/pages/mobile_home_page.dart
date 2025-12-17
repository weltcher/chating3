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
import '../services/app_initialization_service.dart';
import '../config/feature_config.dart';
import '../config/api_config.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';
import '../utils/app_localizations.dart';
import 'permission_settings_page.dart';
import '../models/recent_contact_model.dart';
import '../models/contact_model.dart';
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
import 'voice_call_page.dart';
import 'group_video_call_page.dart';
import '../services/update_checker.dart';

/// 移动端主页
class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key});

  // 🔴 静态缓存变量（移到Widget类，便于外部访问）
  static List<RecentContactModel>? _cachedContacts;
  static DateTime? _cacheTimestamp;
  static Map<String, int>? _cachedPinnedChats;
  static Set<String>? _cachedDeletedChats;

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();

  /// 清除所有最近联系人和偏好设置缓存（公开静态方法，供登录后调用）
  static void clearAllCache() {
    _cachedContacts = null;
    _cacheTimestamp = null;
    _cachedPinnedChats = null;
    _cachedDeletedChats = null;
    logger.info('🗑️ [MobileHomePage] 已清除所有最近联系人和偏好设置缓存');
  }

  /// 🔴 清除置顶聊天缓存（公开静态方法，供聊天页面调用）
  static void clearPinnedChatsCache() {
    _cachedPinnedChats = null;
    logger.debug('🗑️ [MobileHomePage] 已清除置顶聊天缓存');
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

  // 聊天列表页面的 GlobalKey
  final GlobalKey<_MobileChatListPageState> _chatListKey = GlobalKey();

  // 通讯录待审核数量（新联系人 + 群通知）
  int _contactsPendingCount = 0;

  // WebSocket消息订阅
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  // 来电对话框状态
  bool _isShowingIncomingCallDialog = false;
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

    // 初始化数据
    _initializeData();
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
      // 应用恢复前台时重新连接WebSocket并发送在线状态
      _wsService.connect().then((connected) {
        if (connected) {
          _wsService.sendStatusChange('online');
          logger.debug('✅ 应用恢复前台，已发送在线状态');
        }
      });

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

    // 🔴 初始化原生来电服务（Android）
    if (Platform.isAndroid) {
      await _initializeNativeCallService();
    }

    // 连接WebSocket
    await _connectWebSocket();

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
    
    // 🔴 检查初始连接状态
    if (!_wsService.isConnected) {
      setState(() {
        _isConnecting = true;
      });
      logger.debug('🔄 [网络状态-会话] 应用启动时检测到未连接，显示正在刷新...');
    }

    // 加载通讯录待审核数量
    await _loadContactsPendingCount();

    // 登录后检查更新（异步执行，不阻塞主流程）
    if (mounted) {
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
    
    // 监听WebSocket连接状态变化
    _networkStatusTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final currentConnected = _wsService.isConnected;
      
      // 检测连接状态变化
      if (currentConnected != _isNetworkConnected) {
        setState(() {
          _isNetworkConnected = currentConnected;
          
          if (!currentConnected && !_isConnecting) {
            // 连接断开，显示正在刷新
            _isConnecting = true;
            logger.debug('🔄 [网络状态-会话] 检测到连接断开，显示正在刷新...');
          } else if (currentConnected && _isConnecting) {
            // 重连成功，开始数据同步（但不立即隐藏刷新提示）
            logger.debug('✅ [网络状态-会话] 重连成功，开始数据同步和UI渲染...');
            
            // 异步执行数据同步和UI渲染，完成后才隐藏刷新提示
            _syncDataAfterReconnect().then((_) {
              if (mounted) {
                setState(() {
                  _isConnecting = false; // 数据同步和UI渲染完成后才隐藏提示
                });
                logger.debug('🎯 [网络状态-会话] 数据同步和UI渲染完成，已隐藏刷新提示');
              }
            }).catchError((error) {
              logger.error('❌ [网络状态-会话] 数据同步失败，隐藏刷新提示', error: error);
              if (mounted) {
                setState(() {
                  _isConnecting = false; // 即使失败也要隐藏提示
                });
              }
            });
          }
        });
      }
    });
  }

  // 🔴 网络重连后同步数据
  Future<void> _syncDataAfterReconnect() async {
    try {
      logger.debug('🔄 [数据同步-会话] 开始重连后数据同步...');
      
      // 1. 等待离线消息同步完成
      // WebSocket重连后，服务器会自动推送离线消息到本地数据库
      logger.debug('⏳ [数据同步-会话] 等待离线消息同步完成...');
      
      // 监听离线消息同步完成的信号，最多等待5秒
      bool offlineMessagesSynced = false;
      late StreamSubscription messageSubscription;
      
      messageSubscription = _wsService.messageStream.listen((message) {
        if (message['type'] == 'offline_messages_saved' || 
            message['type'] == 'offline_group_messages_saved') {
          logger.debug('📥 [数据同步-会话] 检测到离线消息同步完成信号: ${message['type']}');
          offlineMessagesSynced = true;
          messageSubscription.cancel();
        }
      });
      
      // 等待离线消息同步完成或超时
      int waitTime = 0;
      while (!offlineMessagesSynced && waitTime < 5000) {
        await Future.delayed(const Duration(milliseconds: 100));
        waitTime += 100;
      }
      
      messageSubscription.cancel();
      
      if (offlineMessagesSynced) {
        logger.debug('✅ [数据同步-会话] 离线消息同步完成');
      } else {
        logger.debug('⏰ [数据同步-会话] 离线消息同步超时，继续刷新会话列表');
      }
      
      // 2. 清空聊天列表缓存并重新加载
      final chatListState = _chatListKey.currentState;
      if (chatListState != null) {
        // 调用聊天列表的缓存清空方法
        chatListState._invalidateCache();
        logger.debug('🗑️ [数据同步-会话] 已清空聊天列表缓存');
        
        // 重新加载聊天列表数据（此时本地数据库已包含最新的离线消息）
        await chatListState._loadRecentContacts();
        logger.debug('✅ [数据同步-会话] 聊天列表数据重新加载完成');
      }
      
      // 3. 等待UI完全渲染完成后才隐藏"正在刷新..."提示
      logger.debug('🎨 [UI渲染-会话] 等待会话列表UI完全渲染完成...');
      
      // 使用WidgetsBinding确保UI渲染完成
      if (mounted) {
        await WidgetsBinding.instance.endOfFrame;
        
        // 额外等待一帧，确保ListView完全构建完成
        await Future.delayed(const Duration(milliseconds: 100));
        
        // 确保UI完全渲染后才隐藏刷新提示
        if (mounted) {
          setState(() {
            // 这里不需要设置任何状态，只是触发一次渲染检查
          });
          
          // 再等待一帧确保setState完成
          await WidgetsBinding.instance.endOfFrame;
          
          logger.debug('✅ [UI渲染-会话] 会话列表UI渲染完成，可以隐藏刷新提示');
        }
      }
      
      logger.debug('✅ [数据同步-会话] 重连后数据同步和UI渲染完成');
    } catch (e) {
      logger.error('❌ [数据同步-会话] 重连后数据同步失败', error: e);
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

    // 设置来电回调
    _agoraService.onIncomingCall = (userId, displayName, callType) {
      logger.debug('📞 Agora 来电回调被触发 - 用户: $displayName ($userId)');
      // 显示来电界面
      _showIncomingCallDialog(userId, displayName, callType);
    };

    // 🔴 修复：设置群组来电回调
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
          // 显示群组来电界面
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

    // 设置通话结束回调
    _agoraService.onCallEnded = (int callDuration) {
      logger.debug('📞 [Mobile] 通话结束回调被触发，时长: $callDuration 秒');

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
        if (_isShowingIncomingCallDialog) {
          setState(() {
            _isShowingIncomingCallDialog = false;
          });
          try {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          } catch (e) {
            logger.debug('⚠️ [Mobile] 关闭来电对话框失败: $e');
          }
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
        // ⚠️ 注意：如果通话是从 mobile_chat_page 发起的，消息会在聊天页面发送，这里不应该重复发送
        if (callDuration > 0) {
          // 🔴 修复：从 agoraService 读取最后的群组ID和通话类型
          // 因为从 mobile_chat_page 发起的群组通话，mobile_home_page 的标志可能未设置
          final lastGroupId = _agoraService.lastGroupId;
          final lastCallType = _agoraService.lastCallType;

          logger.debug('🎯 [Mobile] 检查通话类型:');
          logger.debug('  - _isInGroupCall: $_isInGroupCall');
          logger.debug('  - _currentGroupCallId: $_currentGroupCallId');
          logger.debug('  - lastGroupId (from service): $lastGroupId');
          logger.debug('  - lastCallType (from service): $lastCallType');

          // 优先使用 agoraService 中保存的 groupId（支持从 chat_page 发起的群组通话）
          final effectiveGroupId = lastGroupId ?? _currentGroupCallId;
          final effectiveCallType =
              lastCallType ?? _currentCallType ?? CallType.voice;

          // 🔴 关键修复：只有在主页发起的群组通话才在这里发送消息
          // 如果是从聊天页面发起的（_isInGroupCall=false 但有 lastGroupId），
          // 消息应该由聊天页面发送，这里不要重复发送
          final isInitiatedFromHome =
              _isInGroupCall && _currentGroupCallId != null;

          if (effectiveGroupId != null &&
              effectiveGroupId > 0 &&
              isInitiatedFromHome) {
            // 群组通话：不发送群组消息，由服务器端统一处理
            logger.debug('📞 [Mobile] 群组通话结束，服务器端将处理通话时长消息');
          } else if (effectiveGroupId != null &&
              effectiveGroupId > 0 &&
              !isInitiatedFromHome) {
            // 从聊天页面发起的群组通话，由聊天页面负责发送消息
            logger.debug('🎯 [Mobile] 从聊天页面发起的群组通话，跳过发送（由聊天页面处理）');
          } else if (_currentCallUserId != null && _currentCallUserId != 0) {
            // 一对一通话：发送私聊消息
            logger.debug('🎯 [Mobile] 发送一对一通话结束消息，时长: $callDuration 秒');
            await _sendCallEndedMessage(
              _currentCallUserId!,
              callDuration,
              effectiveCallType,
            );
            // 🔴 标记消息已发送，防止VoiceCallPage返回后重复发送
            _callEndedMessageSent = true;
          } else {
            logger.debug('🎯 [Mobile] 无有效的目标用户或群组，跳过发送消息');
          }
        }

        // 重置群组通话标志
        _isInGroupCall = false;
        _currentGroupCallId = null;
        _currentCallUserId = null;
        _currentCallType = null;

        logger.debug('🎯 [Mobile] ========== 延迟回调完成 ==========');
      });
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
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text('${callType == CallType.voice ? '语音' : '视频'}通话'),
          content: Text('$displayName 正在呼叫...'),
          actions: [
            TextButton(
              onPressed: () {
                logger.debug('🔴 用户点击拒接按钮');
                _stopRingtone(); // 停止响铃和震动
                Navigator.of(context).pop();

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
                final navigatorContext = Navigator.of(context).context;
                Navigator.of(context).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    logger.debug('🟢 准备接听通话...');
                    await _agoraService.acceptCall();
                    logger.debug('🟢 通话已接听');

                    if (mounted) {
                      logger.debug('🟢 准备打开通话页面');
                      // 在本地尝试获取主叫头像，用于通话页面展示
                      String? callerAvatar;
                      try {
                        if (currentUserId != null) {
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
                        }
                      } catch (e) {
                        logger.debug(
                          '⚠️ [MobileHomePage] 获取本地主叫头像失败: $e',
                        );
                      }

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
                            _agoraService.onCallStateChanged?.call(
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
                          final returnedCallType =
                              result['callType'] as CallType?;
                          await _sendCallRejectedMessage(
                            userId,
                            returnedCallType ?? callType,
                          );
                        } else if (result['callCancelled'] == true) {
                          // 对方取消了通话
                          setState(() {
                            _showCallFloatingButton = false;
                          });
                          final returnedCallType =
                              result['callType'] as CallType?;
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
                          // 🔴 修复：检查消息是否已在onCallEnded回调中发送，避免重复发送
                          if (!_callEndedMessageSent) {
                            final callDuration =
                                result['callDuration'] as int? ?? 0;
                            final returnedCallType =
                                result['callType'] as CallType?;
                            await _sendCallEndedMessage(
                              userId,
                              callDuration,
                              returnedCallType ?? callType,
                            );
                          } else {
                            logger.debug('🎯 [Mobile] 通话结束消息已在onCallEnded中发送，跳过重复发送');
                          }
                          // 重置标志
                          _callEndedMessageSent = false;
                        }
                      }
                    }
                  }
                });
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
      builder: (context) {
        return AlertDialog(
          title: Text('${callType == CallType.voice ? '群组语音' : '群组视频'}通话'),
          content: Text('$effectiveDisplayName 邀请你加入群组通话 (${members.length}人)'),
          actions: [
            TextButton(
              onPressed: () {
                logger.debug('🔴 用户拒绝群组通话');
                _stopRingtone(); // 停止响铃和震动
                Navigator.of(context).pop();

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
                final navigatorContext = Navigator.of(context).context;
                Navigator.of(context).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    logger.debug('🟢 准备接听通话...');
                    await _agoraService.acceptCall();
                    logger.debug('🟢 通话已接听');

                    if (mounted) {
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
                            _floatingGroupCallUserIds =
                                memberUserIds; // 保存群组成员ID
                            _floatingGroupCallDisplayNames =
                                memberDisplayNames; // 保存群组成员显示名称
                          });

                          // 🔴 修复：延迟触发 onCallStateChanged，等通话页面完全 dispose
                          // 延迟时间增加到600ms，确保通话页面完全dispose并恢复监听器
                          Future.delayed(const Duration(milliseconds: 600), () {
                            logger.debug(
                              '📱 [Mobile] 🔥 延迟触发 onCallStateChanged 通知其他页面（群组通话）',
                            );
                            _agoraService.onCallStateChanged?.call(
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
                            final callDuration =
                                result['callDuration'] as int? ?? 0;
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

  /// 发送通话拒绝消息
  Future<void> _sendCallRejectedMessage(
    int targetUserId,
    CallType callType,
  ) async {
    try {
      // 发送给对方的消息内容（接收方拒绝，发送给发起方显示"对方已拒绝"）
      final contentToSend = '对方已拒绝';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_rejected_video'
          : 'call_rejected';

      logger.debug('📞 [Mobile] 发送通话拒绝消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 消息类型: $messageType');

      // 发送消息
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


  /// 发送通话取消消息
  Future<void> _sendCallCancelledMessage(
    int targetUserId,
    CallType callType, {
    bool isCaller = true,
  }) async {
    try {
      // 发送给对方的消息内容
      // 如果是发起方取消，发送给对方显示"对方已取消"
      // 如果是接收方收到取消通知，发送给对方显示"已取消"
      final contentToSend = isCaller ? '对方已取消' : '已取消';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_cancelled_video'
          : 'call_cancelled';

      logger.debug('📞 [Mobile] 发送通话取消消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为发起方: $isCaller');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');
      logger.debug('  - 消息类型: $messageType');

      // 发送消息
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      logger.debug('✅ [Mobile] 通话取消消息已发送');

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
                      // 🔴 修复：检查消息是否已在onCallEnded回调中发送，避免重复发送
                      if (_callEndedMessageSent) {
                        logger.debug('🎯 [Mobile] 通话结束消息已在onCallEnded中发送，跳过重复发送');
                        _callEndedMessageSent = false;
                      } else {
                        // 正常结束通话
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

  // 公开的刷新方法，供外部调用
  void refresh() {
    logger.debug('🔄 外部调用刷新最近联系人列表');
    _invalidateCache(); // 清除缓存
    _loadRecentContacts();
  }

  // 🔴 新增：使缓存失效
  void _invalidateCache() {
    MobileHomePage._cachedContacts = null;
    MobileHomePage._cacheTimestamp = null;
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
            break;
          case 'group_message':
            // 接收到群组消息
            logger.debug('📱 处理群组消息');
            _handleGroupMessage(data['data']);
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
          case 'offline_messages_saved':
            // 离线私聊消息已保存，刷新会话列表
            logger.debug('📱 离线私聊消息已保存，刷新会话列表');
            await _loadRecentContacts();
            break;
          case 'offline_group_messages_saved':
            // 离线群组消息已保存，刷新会话列表
            logger.debug('📱 离线群组消息已保存，刷新会话列表');
            await _loadRecentContacts();
            break;
          case 'delete_message':
            // 处理删除消息通知（例如删除"加入通话"按钮）
            logger.debug('📱 处理删除消息通知，刷新会话列表');
            // 刷新会话列表，因为最新消息可能已变化
            await _loadRecentContacts();
            break;
          case 'message_sent':
            // 处理消息发送成功确认（主要用于通话拒绝消息的保存）
            logger.debug('📱 收到消息发送确认，处理数据库保存');
            await _handleMessageSentInChatList(data);
            break;
          default:
            logger.debug('📱 忽略消息类型: $type');
            break;
        }
      },
      onError: (error) {
        logger.error('❌ WebSocket消息流错误: $error');
      },
    );

    logger.debug('✅ 移动端聊天列表 WebSocket 监听器已设置');
  }

  /// 处理消息发送成功确认（聊天列表版本）
  /// 注意：这个方法处理所有消息的server_id更新
  /// 如果是在聊天对话框内发送的，会由聊天对话框页面自己处理，这里跳过
  Future<void> _handleMessageSentInChatList(Map<String, dynamic> data) async {
    try {
      logger.debug('📨 [聊天列表] 收到消息发送确认');
      
      // 🔴 关键检查：如果聊天对话框页面正在打开，由聊天对话框处理，这里跳过
      if (MobileChatPage.isChatPageOpen) {
        logger.debug('! [聊天列表] 聊天对话框页面正在打开，由聊天对话框处理，跳过');
        return;
      }
      
      final messageData = data['data'] as Map<String, dynamic>?;
      if (messageData == null) {
        logger.debug('⚠️ [聊天列表] 消息数据为空，跳过处理');
        return;
      }

      final messageId = messageData['message_id'] as int?;
      logger.debug('📨 [聊天列表] 消息ID: $messageId');

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
          logger.debug('✅ [聊天列表] 已更新消息server_id: $messageId');
        }
      }
      
      // 刷新聊天列表以显示最新消息
      await _loadRecentContacts();
      logger.debug('✅ [聊天列表] 聊天列表已刷新');

    } catch (e) {
      logger.error('❌ [聊天列表] 处理消息发送确认失败: $e');
    }
  }

  /// 保存最近的通话相关消息（聊天列表版本）
  Future<void> _saveRecentCallMessageInChatList({int? serverMessageId}) async {
    try {
      final wsService = WebSocketService();
      
      // 获取WebSocket服务中的临时消息
      final pendingMessages = wsService.getPendingPrivateMessages();
      
      if (pendingMessages.isEmpty) {
        logger.debug('⚠️ [聊天列表] 没有待保存的临时消息');
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
        logger.debug('💾 [聊天列表] 通话消息已保存到数据库 - receiverId: $receiverId, messageId: $serverMessageId');
      } else {
        logger.debug('⚠️ [聊天列表] 未找到待保存的通话消息');
      }
    } catch (e) {
      logger.error('❌ [聊天列表] 保存通话消息失败: $e');
    }
  }

  Future<void> _loadRecentContacts() async {
    try {
      // 🔴 直接获取数据并更新，不显示加载动画
      final response = await MessageService().getRecentContacts();
      final contactsData = response['data']?['contacts'] as List?;
      final contacts = (contactsData ?? [])
          .map((json) => RecentContactModel.fromJson(json as Map<String, dynamic>))
          .toList();

      if (mounted) {
        setState(() {
          _recentContacts = contacts;
          _isFirstLoad = false; // 🔴 标记已完成首次加载
          _error = null;
        });

        // 🔴 更新缓存
        MobileHomePage._cachedContacts = List.from(contacts);
        MobileHomePage._cacheTimestamp = DateTime.now();
        logger.debug('💾 缓存已更新 (${contacts.length}条，已过滤文件传输助手)');
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

  /// 🔴 更新单个会话的最新消息
  /// 退出聊天页面时调用，只更新该会话而不重新加载整个列表
  Future<void> _updateSingleContact(int contactId, bool isGroup) async {
    try {
      logger.debug('🔄 开始更新单个会话: contactId=$contactId, isGroup=$isGroup');
      
      // 🔴 修复：重新加载置顶状态（因为可能在聊天页面修改了置顶状态）
      await _loadPreferences();
      
      // 1. 清空该会话的缓存
      MobileChatPage.clearCache(isGroup: isGroup, id: contactId);
      logger.debug('🗑️ 已清空会话缓存');
      
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
          lastMessage = _formatMessagePreview(msg.messageType, msg.content);
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
          lastMessage = _formatMessagePreview(msg.messageType, msg.content);
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
          setState(() {
            final contact = _recentContacts[contactIndex];
            final updatedContact = contact.copyWith(
              lastMessage: lastMessage,
              lastMessageTime: lastMessageTime,
            );
            
            // 直接在原位置更新，不移动位置
            _recentContacts[contactIndex] = updatedContact;
            
            logger.debug('✅ 已更新会话内容，保持原位置: "$lastMessage"');
          });
        } else {
          // 🔴 没有最新消息（清空聊天记录后），保留会话但将最新消息置空
          setState(() {
            final contact = _recentContacts[contactIndex];
            final updatedContact = contact.copyWith(
              lastMessage: '', // 最新消息置空
              lastMessageTime: DateTime.now().toIso8601String(), // 更新时间为当前时间
            );
            
            // 直接在原位置更新，不移动位置
            _recentContacts[contactIndex] = updatedContact;
            
            logger.debug('✅ 已清空会话的最新消息但保留会话在列表中');
          });
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
      final aTime = DateTime.tryParse(a.lastMessageTime ?? '') ?? DateTime(1970);
      final bTime = DateTime.tryParse(b.lastMessageTime ?? '') ?? DateTime(1970);
      return bTime.compareTo(aTime); // 降序：最新的在前
    });

    // 6. 合并列表：顶置的在前，非顶置的在后
    final result = <RecentContactModel>[];
    result.addAll(pinnedList.map((e) => e.key));
    result.addAll(unpinnedList);

    // 🔍 调试：打印排序后的前5个会话
    logger.debug('📊 [移动端排序] 排序后的会话列表（前${result.length > 5 ? 5 : result.length}个）:');
    for (int i = 0; i < result.length && i < 5; i++) {
      final contact = result[i];
      final isPinned = i < pinnedList.length;
      logger.debug('  ${i + 1}. ${isPinned ? "[置顶]" : ""}${contact.isGroup ? "[群组]" : "[私聊]"} ${contact.displayName} - 最后消息时间: ${contact.lastMessageTime}');
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

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
                : _filteredContacts.isEmpty
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
                      itemCount: _filteredContacts.length,
                      itemBuilder: (context, index) {
                        final contact = _filteredContacts[index];
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
                logger.debug('✅ 已清除联系人 ${contact.displayName} 的未读计数');
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
                    // 未读消息气泡（左上角）
                    if (contact.unreadCount > 0)
                      Positioned(
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
                                  contact.unreadCount >= 100
                                      ? '99+'
                                      : contact.unreadCount.toString(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    height: 1.0,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
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
                      Text(
                        contact.lastMessage,
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
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
        // 1. user-{inviteCode} - 用户邀请码
        // 2. group-{groupId} - 群组ID
        // 3. youdu://user/{username} - 用户名
        // 4. youdu://group/{groupId} - 群组ID
        if (result.startsWith('user-')) {
          // 用户邀请码格式
          final inviteCode = result.substring('user-'.length);
          _handleAddContactByInviteCode(inviteCode);
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

  // 通过邀请码添加联系人
  void _handleAddContactByInviteCode(String inviteCode) async {
    try {
      logger.debug('📞 [扫码添加] 通过邀请码添加: $inviteCode');
      
      // 跳转到添加个人页面
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AddFriendFromQRPage(
              inviteCode: inviteCode,
            ),
          ),
        );
      }
    } catch (e) {
      logger.error('处理邀请码失败: $e');
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

      // 🚫 APP在前台时不显示应用内弹窗
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

      // 判断是否是当前用户发送的消息
      final currentUserId = await Storage.getUserId();
      final isMyMessage = currentUserId != null && senderId == currentUserId;
      logger.debug(
        '📨 消息发送者判断 - 当前用户ID: $currentUserId, 发送者ID: $senderId, 是否是我的消息: $isMyMessage',
      );

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
        setState(() {
          final contact = _recentContacts[contactIndex];
          final oldUnreadCount = contact.unreadCount;
          final newUnreadCount = oldUnreadCount + 1;

          // 格式化消息预览
          final formattedMessage = _formatMessagePreview(messageType, content);

          // 🔴 时区处理：本地数据库存储的时间已经是上海时区，直接使用
          String lastMessageTime = createdAt ?? DateTime.now().toIso8601String();

          // 更新联系人信息（包括头像）
          final senderAvatar = messageData['sender_avatar'] as String?;
          final updatedContact = contact.copyWith(
            unreadCount: newUnreadCount,
            lastMessage: formattedMessage,
            lastMessageTime: lastMessageTime,
            avatar: senderAvatar, // 更新发送者头像
          );

          // 移除旧的联系人
          _recentContacts.removeAt(contactIndex);

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

          _recentContacts.insert(targetIndex, updatedContact);

          logger.debug('✅ 已更新联系人 - 未读数: $oldUnreadCount -> $newUnreadCount');
          
          // 🔴 更新缓存
          MobileHomePage._cachedContacts = List.from(_recentContacts);
          MobileHomePage._cacheTimestamp = DateTime.now();
          logger.debug('💾 缓存已更新（私聊消息更新）');
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
          final formattedMessage = _formatMessagePreview(messageType, content);
          
          // 🔴 时区处理：本地数据库存储的时间已经是上海时区，直接使用
          String lastMessageTime = createdAt ?? DateTime.now().toIso8601String();
          
          // 创建新的联系人条目
          final newContact = RecentContactModel(
            type: 'user', // 明确指定为用户类型
            userId: senderId,
            username: senderName,
            fullName: senderName,
            avatar: senderAvatar,
            lastMessage: formattedMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: isMyMessage ? 0 : 1, // 自己发送的消息未读数为0
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
          logger.debug('💾 缓存已更新（新联系人添加）');
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

      // 🔴 检测是否是群组创建/邀请的系统消息
      if (messageType == 'system' && 
          (content.contains('群组已创建') || 
           content.contains('创建新群组') || 
           content.contains('您已被邀请加入群组'))) {
        logger.debug('🆕 检测到群组创建/邀请消息，立即刷新会话列表和通讯录群组缓存: $content');
        
        // 1. 清除通讯录群组缓存并刷新
        MobileContactsPage.clearCacheAndRefresh();
        
        // 2. 立即刷新会话列表（如果用户在会话页面）
        await _loadRecentContacts();
        logger.debug('✅ 会话列表已刷新，新群组已显示');
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
        setState(() {
          final contact = _recentContacts[contactIndex];
          final oldUnreadCount = contact.unreadCount;
          final isDoNotDisturb = contact.doNotDisturb;

          // 如果群组设置了消息免打扰，未读数固定为1（只显示红点，不显示具体数量）
          // 否则正常累加未读数
          final newUnreadCount = isDoNotDisturb ? 1 : (oldUnreadCount + 1);

          // 格式化消息预览
          final formattedMessage = _formatMessagePreview(messageType, content);

          logger.debug(
            '📊 群组消息未读数更新：原未读数=$oldUnreadCount, 新未读数=$newUnreadCount, 免打扰=$isDoNotDisturb',
          );

          // 更新群组信息
          final updatedContact = contact.copyWith(
            unreadCount: newUnreadCount,
            lastMessage: formattedMessage,
            lastMessageTime: createdAt ?? DateTime.now().toIso8601String(),
          );

          // 移除旧的群组
          _recentContacts.removeAt(contactIndex);

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

          _recentContacts.insert(targetIndex, updatedContact);

          logger.debug('✅ 已更新群组 - 未读数: $oldUnreadCount -> $newUnreadCount');
          
          // 🔴 更新缓存
          MobileHomePage._cachedContacts = List.from(_recentContacts);
          MobileHomePage._cacheTimestamp = DateTime.now();
          logger.debug('💾 缓存已更新（群组消息更新）');
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
              final formattedMessage = _formatMessagePreview(
                messageType,
                content,
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
                logger.debug('💾 缓存已更新（新群组添加）');
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
  String _formatMessagePreview(String messageType, String content) {
    switch (messageType) {
      case 'image':
        return '[图片]';
      case 'file':
        return '[文件]';
      case 'voice':
        return '[语音]';
      case 'video':
        return '[视频]';
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
