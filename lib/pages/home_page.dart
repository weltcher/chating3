import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:extended_text_field/extended_text_field.dart';
import 'package:extended_text/extended_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_webview;
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/user_profile_menu_with_api.dart';
import '../widgets/user_info_dialog_simple.dart';
import '../widgets/edit_profile_dialog.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/video_upload_service.dart';
import '../services/message_service.dart';
import '../services/local_database_service.dart';
import '../services/app_initialization_service.dart';
import '../config/feature_config.dart';
import '../constants/upload_limits.dart';
import '../utils/storage.dart';
import '../utils/emoji_text_span_builder.dart';
import '../utils/permission_helper_impl.dart';
import '../utils/auto_download_debug.dart';
import '../utils/app_localizations.dart';
import '../models/user_model.dart';
import '../models/contact_model.dart';
import '../models/recent_contact_model.dart';
import '../models/message_model.dart';
import '../models/group_model.dart';
import '../models/online_notification_model.dart';
import '../widgets/create_group_dialog.dart';
import 'mobile_contacts_page.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/mention_member_picker.dart';
import '../widgets/group_call_member_picker.dart';
import '../widgets/message_notification_popup.dart';
import '../widgets/voice_message_bubble.dart';
import 'group_video_call_page.dart';
import 'todo_page.dart';
import 'qr_scanner_page.dart';

// WebRTC 功能模块 - 通过实现选择器自动切换真实实现或存根实现

// 使用 Agora 服务替代 WebRTC
import '../services/agora_service.dart';
import '../services/native_call_service.dart';
import 'voice_call_page.dart';
import '../utils/logger.dart';
import '../utils/responsive_helper.dart';
import '../utils/sort_helper.dart';
import 'mobile_home_page.dart';
import '../services/update_checker.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    // 使用响应式布局，移动端显示MobileHomePage，桌面端显示DesktopHomePage
    return ResponsiveLayout(
      mobile: const MobileHomePage(),
      desktop: const DesktopHomePage(),
    );
  }
}

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({super.key});

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> with WindowListener {
  int _selectedMenuIndex = 0; // 0: 消息, 1: 通讯录, 2: 资讯, 3: 待办
  int _selectedChatIndex = 0; // 当前选中的对话（已废弃，保留用于兼容）
  String? _selectedChatKey; // 当前选中的会话唯一标识（user_123 或 group_456）
  int _selectedContactIndex = -1; // 当前选中的联系人分组，-1表示未选择
  Map<String, dynamic>? _selectedPerson; // 当前选中的具体人员
  String _userStatus = 'online'; // 用户状态：online, busy, away, offline
  String _userDisplayName = ''; // 用户显示名称（姓名或用户名）
  String _username = ''; // 用户名（用于生成头像文字）
  String? _userFullName; // 用户昵称（full_name）
  String? _userAvatar; // 用户头像URL
  bool _isLoadingUserInfo = true; // 是否正在加载用户信息
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription<Map<String, dynamic>>?
  _messageSubscription; // WebSocket消息订阅
  // 条件初始化 Agora 服务（替代 WebRTC）
  late final AgoraService? _agoraService = FeatureConfig.enableWebRTC
      ? AgoraService()
      : null;

  // 来电对话框状态
  bool _isShowingIncomingCallDialog = false; // 是否正在显示来电对话框
  int? _pendingIncomingCallUserId; // 待显示的通话用户ID
  String? _pendingIncomingCallDisplayName; // 待显示的通话用户显示名
  CallType? _pendingIncomingCallType; // 待显示的通话类型
  AudioPlayer? _ringtonePlayer; // 来电铃声播放器
  Timer? _vibrationTimer; // 震动定时器
  final AudioPlayer _audioPlayer = AudioPlayer(); // 音频播放器（用于播放新消息提示音）

  // 通话悬浮按钮状态
  bool _showCallFloatingButton = false; // 是否显示通话悬浮按钮
  bool _isShowingVoiceCallDialog = false; // 是否正在显示语音通话对话框（防止失去焦点时自动关闭）
  int? _currentCallUserId = null; // 当前通话的用户ID
  String? _currentCallDisplayName = null; // 当前通话的用户显示名
  CallType? _currentCallType = null; // 当前通话类型
  bool _isInGroupCall = false; // 当前是否在群组通话中
  int? _currentGroupCallId = null; // 当前群组通话的群组ID（如果是从群聊发起）
  double _floatingButtonX = 0; // 悬浮按钮X坐标（从右边算起）
  double _floatingButtonY = 0; // 悬浮按钮Y坐标（从下边算起）

  // 文件选择器状态（使用全局变量，在 edit_profile_dialog.dart 中定义）

  // 最近发送的临时消息ID（用于错误时标记失败状态）
  int? _lastSentTempMessageId;

  // 联系人相关状态
  List<ContactModel> _contacts = []; // 联系人列表
  bool _isLoadingContacts = false; // 是否正在加载联系人
  String? _contactsError; // 联系人加载错误信息
  // 群组相关状态
  List<GroupModel> _groups = []; // 群组列表
  bool _isLoadingGroups = false; // 是否正在加载群组
  String? _groupsError; // 群组加载错误信息
  GroupModel? _selectedGroup; // 当前选中的群组
  // 群通知相关状态
  List<Map<String, dynamic>> _pendingGroupMembers = []; // 待审核的群组成员列表
  bool _isLoadingPendingMembers = false; // 是否正在加载待审核成员
  String? _pendingMembersError; // 待审核成员加载错误信息
  // 常用相关状态
  String?
  _selectedFavoriteCategory; // 选中的常用分类：'contacts', 'groups', 'notifications'
  List<dynamic> _favoriteContacts = []; // 常用联系人列表
  List<dynamic> _favoriteGroups = []; // 常用群组列表
  List<dynamic> _onlineNotifications = []; // 上线提醒列表
  bool _isLoadingFavorites = false; // 是否正在加载常用数据

  // 最近联系人相关状态
  List<RecentContactModel> _recentContacts = []; // 最近联系人列表
  bool _isLoadingRecentContacts = false; // 是否正在加载最近联系人
  String? _recentContactsError; // 最近联系人加载错误信息
  
  // 首次同步数据状态
  bool _isSyncingData = false; // 是否正在同步数据
  String? _syncStatusMessage; // 同步状态消息
  final TextEditingController _searchController =
      TextEditingController(); // 搜索框控制器
  String _searchText = ''; // 当前搜索文本

  // 头像缓存（用于群聊消息中显示最新头像）
  final Map<int, String?> _avatarCache = {}; // userId -> avatarUrl
  // 已标记为已读的联系人/群组集合（用于防止刷新时重新显示未读气泡）
  // key格式：'user_123' 或 'group_456'
  final Set<String> _markedAsReadContacts = {};
  // 🔴 记录通过WebSocket设置的用户状态（完全信任WebSocket，不被API覆盖）
  // key: userId, value: WebSocket设置的状态（online/offline）
  final Map<int, String> _websocketUserStatus = {};
  Timer? _searchDebounceTimer; // 搜索防抖定时器
  Timer? _messageScrollTimer; // 消息列表自动滚动定时器
  bool _isUserScrolling = false; // 用户是否手动向上滚动（用于暂停自动滚动）
  double _lastScrollPosition = 0.0; // 上次滚动位置（用于检测用户是否向上滚动）
  // 联系人状态同步定时器
  Timer? _statusSyncTimer; // 联系人状态同步定时器（每3秒同步一次）
  // 自动离线定时器相关状态
  Timer? _autoOfflineTimer; // 自动离线定时器（鼠标键盘无操作N分钟后触发）
  DateTime? _lastResetTime; // 上次重置定时器的时间（用于防抖）
  DateTime _lastActivityTime = DateTime.now(); // 最后一次用户活动时间
  // 搜索联系人相关状态
  List<RecentContactModel> _searchResults = []; // 搜索结果列表
  bool _isSearching = false; // 是否正在搜索
  String? _searchError; // 搜索错误信息

  // 通讯录搜索相关状态
  final TextEditingController _contactSearchController = TextEditingController(); // 通讯录搜索框控制器
  String _contactSearchKeyword = ''; // 通讯录搜索关键词

  // 消息历史相关状态
  List<MessageModel> _messages = []; // 当前选中联系人的消息列表
  bool _isLoadingMessages = false; // 是否正在加载消息
  String? _messagesError; // 消息加载错误信息
  bool _isScrollingToBottom = false; // 是否正在滚动到底部（用于隐藏消息避免闪烁）
  int? _currentChatUserId; // 当前聊天的用户ID或群组ID
  bool _isCurrentChatGroup = false; // 当前聊天是否为群组
  final Set<int> _removedGroupIds = {}; // 已被移除的群组ID集合
  int _currentUserId = 0; // 当前登录用户的ID
  String? _token; // 当前登录用户的token（在内存中保存，避免被其他窗口覆盖）
  final TextEditingController _messageInputController =
      TextEditingController(); // 消息输入框控制器
  final ScrollController _messageScrollController =
      ScrollController(); // 消息列表滚动控制器
  final GlobalKey _messageListBottomKey = GlobalKey(); // 消息列表底部锚点Key
  String _previousInputText = ''; // 记录上一次的输入文本，用于检测删除操作
  bool _isSendingMessage = false; // 是否正在发送消息
  bool _isSendingCallMessage =
      false; // 是否正在发送通话相关消息（call_ended、call_rejected 或 call_cancelled）
  final FocusNode _messageInputFocusNode = FocusNode(); // 输入框焦点节点
  // 正在输入相关状态
  bool _isOtherTyping = false; // 对方是否正在输入
  Timer? _typingTimer; // 正在输入消息的防抖定时器
  Timer? _otherTypingTimer; // 对方正在输入提示的自动隐藏定时器
  // 图片上传相关状态
  final List<File> _selectedImageFiles = []; // 选中的图片文件列表
  bool _isUploadingImage = false; // 是否正在上传图片

  // 文件上传相关状态
  final List<File> _selectedFiles = []; // 选中的文件列表
  bool _isUploadingFile = false; // 是否正在上传文件

  // 视频上传相关状态
  final List<File> _selectedVideoFiles = []; // 选中的视频文件列表
  bool _isUploadingVideo = false; // 是否正在上传视频

  // 上传进度消息映射（临时消息ID -> 文件路径）
  final Map<int, String> _uploadProgressMessages = {};
  int _tempMessageIdCounter = -1; // 临时消息ID计数器（使用负数避免与真实ID冲突）

  // 引用消息相关状态
  MessageModel? _quotedMessage; // 被引用的消息

  // 转发相关状态
  List<int> _selectedForwardContacts = []; // 选中的转发联系人ID列表

  // 多选模式相关状态
  bool _isMultiSelectMode = false; // 是否处于多选模式
  final Set<int> _selectedMessageIds = {}; // 选中的消息ID集合

  // 聊天记录筛选面板相关状态
  bool _showFilterPanel = false; // 是否显示筛选面板
  int _selectedFilterTab = 0; // 选中的筛选标签：0=全部，1=文件
  List<MessageModel> _filteredMessages = []; // 筛选后的消息列表
  final TextEditingController _messageSearchController =
      TextEditingController(); // 消息搜索框控制器
  String _messageSearchKeyword = ''; // 消息搜索关键字
  int? _highlightedMessageId; // 高亮显示的消息ID
  Timer? _highlightTimer; // 高亮取消定时器
  // WebView 相关状态 - 多标签页支持
  final List<_BrowserTab> _tabs = [];
  int _currentTabIndex = 0;
  final TextEditingController _urlController = TextEditingController();
  bool _canGoBack = false;
  bool _canGoForward = false;

  // @功能相关状态
  bool _showMentionPicker = false; // 是否显示成员选择器
  List<GroupMemberForMention> _groupMembers = []; // 当前群组成员列表
  List<int> _mentionedUserIds = []; // 被@的用户ID列表
  String _mentionText = ''; // @文本内容（用于显示）
  OverlayEntry? _mentionOverlay; // 成员选择器浮层
  String? _currentUserGroupRole; // 当前用户在群组中的角色（owner/admin/member）
  bool get _isWindows => !kIsWeb && Platform.isWindows;
  _BrowserTab? get _currentTab =>
      _tabs.isEmpty ? null : _tabs[_currentTabIndex];

  @override
  void initState() {
    super.initState();
    logger.debug('🚀 HomePage initState - 开始初始化');

    // 添加窗口监听器（仅限桌面平台）
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.addListener(this);
    }

    // 调用异步初始化方法
    _initialize();

    logger.debug('🚀 HomePage initState - 同步部分完成');

    // 监听搜索框变化 - 实时搜索（带防抖）
    _searchController.addListener(() {
      final searchText = _searchController.text;

      // 取消之前的防抖定时器
      _searchDebounceTimer?.cancel();

      // 立即更新搜索文本状态
      setState(() {
        _searchText = searchText;
        // 如果搜索框为空，立即清空搜索结果并重新加载最近联系人
        if (_searchText.isEmpty) {
          _searchResults = [];
          _searchError = null;
          _isSearching = false;
        } else {
          // 显示加载状态
          _isSearching = true;
        }
      });

      // 如果搜索框为空，立即重新加载最近联系人
      if (searchText.isEmpty) {
        _loadRecentContacts();
        return;
      }

      // 设置新的防抖定时器（300ms延迟）
      _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        // 确保使用最新的搜索文本进行搜索
        if (_searchController.text.isNotEmpty) {
          _searchContacts(_searchController.text);
        }
      });
    });

    // 启动消息列表自动滚动定时器，每隔1500毫秒检查一次
    _messageScrollTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      timer,
    ) {
      _checkAndScrollToBottom();
    });

    // 添加滚动监听器，检测用户是否手动向上滚动
    _messageScrollController.addListener(() {
      if (!_messageScrollController.hasClients) return;

      final currentPosition = _messageScrollController.position.pixels;
      final maxScroll = _messageScrollController.position.maxScrollExtent;
      const threshold = 10.0; // 10像素的阈值

      // 如果用户滚动到底部，重新启用自动滚动
      if (currentPosition >= maxScroll - threshold) {
        if (_isUserScrolling) {
          logger.debug('📜 用户滚动到底部，重新启用自动滚动');
          _isUserScrolling = false;
        }
      } else {
        // 如果用户向上滚动（当前位置小于上次位置），标记为用户手动滚动
        if (currentPosition < _lastScrollPosition - threshold) {
          // 用户向上滚动，暂停自动滚动
          if (!_isUserScrolling) {
            logger.debug('📜 检测到用户手动向上滚动，暂停自动滚动');
            _isUserScrolling = true;
          }
        }
      }

      // 更新上次滚动位置
      _lastScrollPosition = currentPosition;
    });
  }

  // 统一的初始化方法，按正确顺序执行异步操作
  Future<void> _initialize() async {
    try {
      // 0. 清除头像缓存（确保切换账号后不会显示旧头像）
      _avatarCache.clear();
      logger.debug('🗑️ 已清除头像缓存');
      
      // 1. 首先加载token到内存
      await _loadToken();

      // 2. 加载用户信息和用户ID（可以并行）
      await Future.wait([_loadUserInfo(), _loadCurrentUserId()]);

      // 3. 重新初始化日志系统（使用用户ID）
      if (_currentUserId > 0) {
        await logger.init(userId: _currentUserId.toString());
        logger.info('📝 日志系统已重新初始化，用户ID: $_currentUserId');
      }

      // 3.5. 🔴 执行应用初始化（首次安装时同步历史消息和收藏数据）
      logger.debug('🚀 HomePage _initialize - 开始执行应用初始化服务');
      await AppInitializationService().initialize(
        onSyncStatusChanged: (isSyncing, message) {
          if (mounted) {
            setState(() {
              _isSyncingData = isSyncing;
              _syncStatusMessage = message;
            });
            
            // 🔴 同步完成后刷新最近联系人列表
            if (!isSyncing && message == null) {
              logger.debug('✅ [同步完成] 刷新最近联系人列表');
              _loadRecentContacts();
            }
          }
        },
      );
      logger.debug('✅ HomePage _initialize - 应用初始化服务完成');

      // 4. 初始化WebSocket连接
      await _initWebSocket();

      // 5. 初始化Agora服务（需要在用户ID加载完成后）
      await _initWebRTC();

      // 5.5. 初始化原生来电服务（仅Android）
      _initNativeCallService();

      // 6. 创建第一个浏览器标签
      // 🔴 临时禁用WebView自动创建，以排查窗口拦截问题
      // _addNewTab('https://mil.ifeng.com/');

      // 7. 加载最近联系人列表
      logger.debug('🚀 HomePage _initialize - 准备加载最近联系人列表');
      await _loadRecentContacts();

      // 7.5. 加载联系人和群通知数据（用于显示通讯录红色气泡）
      await Future.wait([_loadContacts(), _loadPendingGroupMembers()]);

      // 8. 自动选择第一个最近联系人并滚动到底部
      if (_recentContacts.isNotEmpty) {
        final firstContact = _recentContacts[0];
        final hasUnreadMessages = firstContact.unreadCount > 0;

        // 生成第一个联系人的唯一标识
        final firstContactKey = Storage.generateContactKey(
          isGroup: firstContact.isGroup,
          id: firstContact.isGroup
              ? (firstContact.groupId ?? firstContact.userId)
              : firstContact.userId,
        );

        setState(() {
          _selectedChatIndex = 0;
          _selectedChatKey = firstContactKey; // 🔧 修复：设置唯一标识
          _isCurrentChatGroup = firstContact.isGroup;

          // 如果第一个联系人有未读消息，立即清除UI上的未读计数（不显示红色气泡）
          if (hasUnreadMessages) {
            _recentContacts[0] = _recentContacts[0].copyWith(unreadCount: 0);

            // 🔧 修复：将该联系人添加到已读集合中
            _markedAsReadContacts.add(firstContactKey);
          }
        });

        // 🔧 修复：如果第一个联系人是群组，先加载群组详细信息（包括群公告）
        final firstGroupId = _resolveGroupId(firstContact);
        if (firstGroupId != null) {
          await _loadGroupDetail(firstGroupId);
        }

        // 加载该联系人或群组的消息历史
        final chatId = _resolveChatId(firstContact);
        // 检查是否是文件传输助手
        if (firstContact.isFileAssistant || chatId == 0) {
          await _loadFileAssistantMessages();
        } else {
          await _loadMessageHistory(chatId, isGroup: firstContact.isGroup);
        }

        // 如果第一个联系人有未读消息，标记为已读（这会同步到服务器并刷新联系人列表）
        if (hasUnreadMessages) {
          if (firstContact.isGroup) {
            await _markGroupMessagesAsRead(chatId);
          } else {
            await _markMessagesAsRead(chatId);
          }
        }

        // 滚动到底部
        _scrollToBottom(animated: false);
      }

      // 9. 打印自动下载设置状态（调试用）
      AutoDownloadDebug.debugSettings();

      // 10. 初始化自动离线定时器
      await _initAutoOfflineTimer();

      // 11. 启动联系人状态同步定时器
      _startStatusSyncTimer();

      // 12. 登录后检查更新（异步执行，不阻塞主流程）
      if (mounted) {
        UpdateChecker().checkAfterLogin(context);
      }
    } catch (e) {
      logger.debug('❌ HomePage 初始化失败: $e');
    }
  }

  // 加载当前用户ID
  // 加载token到内存（避免被其他窗口覆盖）
  Future<void> _loadToken() async {
    try {
      _token = await Storage.getToken();
      if (_token != null && _token!.isNotEmpty) {
        logger.debug('✅ Token已加载到内存');
      } else {
        logger.debug('⚠️ Token为空，用户未登录');
        // Token为空时，跳转到登录页面
        _redirectToLogin('Token为空');
      }
    } catch (e) {
      logger.debug('❌ 加载Token失败: $e');
      // Token加载失败时，跳转到登录页面
      _redirectToLogin('Token加载失败');
    }
  }

  // 跳转到登录页面
  void _redirectToLogin(String reason) {
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  Future<void> _loadCurrentUserId() async {
    try {
      if (_token != null && _token!.isNotEmpty) {
        final response = await ApiService.getUserProfile(token: _token!);
        if (response['code'] == 0 && response['data'] != null) {
          final userData = response['data']['user'];
          setState(() {
            _currentUserId = userData['id'] as int;
          });
        } else {
          logger.debug('⚠️ 获取用户信息失败，Token可能已过期');
          // Token可能已过期，跳转到登录页面
          _redirectToLogin('Token已过期');
        }
      }
    } catch (e) {
      _redirectToLogin('API调用失败');
    }
  }

  /// 获取群组ID，兼容缺失 groupId 时使用 userId 作为兜底
  int? _resolveGroupId(RecentContactModel contact) {
    if (!contact.isGroup) return null;
    if (contact.groupId != null) return contact.groupId;
    if (contact.userId != 0) return contact.userId;
    return null;
  }

  /// 获取聊天ID（群聊返回群ID，私聊返回用户ID）
  int _resolveChatId(RecentContactModel contact) {
    final groupId = _resolveGroupId(contact);
    return contact.isGroup ? (groupId ?? contact.userId) : contact.userId;
  }

  @override
  void dispose() {
    // 清除头像缓存（确保关闭应用时清理所有缓存数据）
    _avatarCache.clear();
    logger.debug('🗑️ 应用关闭时已清除头像缓存');
    
    // 移除窗口监听器（仅限桌面平台）
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.removeListener(this);
    }
    _messageSubscription?.cancel(); // 取消WebSocket消息订阅
    _wsService.disconnect();
    // 停止响铃和震动
    _stopRingtone();
    _searchDebounceTimer?.cancel(); // 取消搜索防抖定时器
    _messageScrollTimer?.cancel(); // 取消消息列表自动滚动定时器
    _highlightTimer?.cancel(); // 取消高亮定时器
    _statusSyncTimer?.cancel(); // 取消联系人状态同步定时器
    _autoOfflineTimer?.cancel(); // 取消自动离线定时器
    _typingTimer?.cancel(); // 取消正在输入消息的防抖定时器
    _otherTypingTimer?.cancel(); // 取消对方正在输入提示的自动隐藏定时器
    _searchController.dispose();
    _contactSearchController.dispose(); // 通讯录搜索控制器
    _messageInputController.dispose();
    _messageScrollController.dispose();
    _messageInputFocusNode.dispose();
    _messageSearchController.dispose(); // 释放消息搜索框控制器
    _urlController.dispose();
    // 释放所有标签页的WebView控制器
    for (var tab in _tabs) {
      if (_isWindows && tab.windowsController != null) {
        tab.windowsController!.dispose();
      }
    }
    super.dispose();
  }

  // ============ WindowListener 接口实现 ============

  @override
  void onWindowFocus() {
    // 如果有待显示的通话对话框，显示它
    if (_pendingIncomingCallUserId != null &&
        _pendingIncomingCallDisplayName != null &&
        _pendingIncomingCallType != null &&
        !_isShowingIncomingCallDialog) {
      final userId = _pendingIncomingCallUserId!;
      final displayName = _pendingIncomingCallDisplayName!;
      final callType = _pendingIncomingCallType!;

      // 清除待显示的通话信息
      _pendingIncomingCallUserId = null;
      _pendingIncomingCallDisplayName = null;
      _pendingIncomingCallType = null;

      // 显示对话框
      _showIncomingCallDialog(userId, displayName, callType);
    }
  }

  @override
  void onWindowBlur() {
    _closeAllDialogs();
  }

  @override
  void onWindowMinimize() {
    _closeAllDialogs();
  }

  @override
  void onWindowRestore() {
  }

  @override
  void onWindowMaximize() {
  }

  @override
  void onWindowUnmaximize() {
  }

  // 关闭所有打开的对话框
  void _closeAllDialogs() {
    if (!mounted) return;

    // 获取通话状态
    final callState = _agoraService?.callState;

    // 检查导航栈状态
    try {
      final navigator = Navigator.of(context);
      // 获取当前路由信息
      final route = ModalRoute.of(context);
    } catch (e) {
      logger.debug('🪟 检查导航栈状态时出错: $e');
    }

    // 如果正在显示来电对话框，不关闭它
    if (_isShowingIncomingCallDialog) {
      logger.debug('🔔 正在显示来电对话框，跳过关闭');
      return;
    }

    // 如果正在显示语音通话对话框，不关闭它（防止失去焦点时自动关闭）
    if (_isShowingVoiceCallDialog) {
      logger.debug('📱 正在显示语音通话对话框，跳过关闭（防止失去焦点时自动关闭）');
      return;
    }

    // 如果正在通话中（calling、ringing、connected），不关闭对话框
    if (callState == CallState.calling ||
        callState == CallState.ringing ||
        callState == CallState.connected) {
      logger.debug('📞 正在通话中（状态: $callState），跳过关闭对话框');
      return;
    }

    // 如果有通话悬浮按钮，说明有正在进行的通话，不关闭对话框
    if (_showCallFloatingButton) {
      logger.debug('📱 有通话悬浮按钮，跳过关闭对话框');
      return;
    }

    // 如果文件选择器正在打开，不关闭对话框（避免关闭编辑个人资料弹窗）
    if (getFilePickerOpen()) {
      logger.debug('📂 文件选择器正在打开，跳过关闭对话框');
      return;
    }

    // 如果文件选择器刚关闭（5秒内），也不关闭对话框（给文件选择器返回的时间）
    final pickerOpenTime = getFilePickerOpenTime();
    if (pickerOpenTime != null) {
      final timeSinceClose = DateTime.now().difference(pickerOpenTime);
      if (timeSinceClose.inSeconds < 5) {
        logger.debug('📂 文件选择器刚关闭（${timeSinceClose.inSeconds}秒前），跳过关闭对话框');
        return;
      }
    }

    try {
      Navigator.of(context).popUntil((route) {
        final shouldPop = route.isFirst || route.settings.name == '/home';
        return shouldPop;
      });
    } catch (e) {
      logger.debug('⚠️ 关闭对话框时出错: $e');
    }
  }

  // ============ End WindowListener 接口实现 ============

  // 初始化自动离线定时器
  Future<void> _initAutoOfflineTimer() async {
    // 读取设置
    final enabled = await Storage.getIdleStatusEnabled();
    final minutes = await Storage.getIdleMinutes();

    if (!enabled) {
      // 如果关闭了功能，取消现有的定时器
      _autoOfflineTimer?.cancel();
      return;
    }

    // 更新最后活动时间为当前时间
    _lastActivityTime = DateTime.now();

    // 启动定时任务
    _startAutoOfflineTimer(minutes);
  }

  // 启动自动离线定时器
  void _startAutoOfflineTimer(int minutes) {
    // 先取消之前的定时器
    _autoOfflineTimer?.cancel();

    // 创建新的定时器
    _autoOfflineTimer = Timer(Duration(minutes: minutes), () async {

      // 1. 先检查开关是否还打开着
      final enabled = await Storage.getIdleStatusEnabled();
      if (!enabled) {
        logger.debug('  ⚠️ 自动离线开关已关闭，跳过处理');
        return;
      }

      // 2. 检查设置的分钟数（可能已经被修改）
      final configuredMinutes = await Storage.getIdleMinutes();

      // 3. 检查距离最后活动的实际时间
      final now = DateTime.now();
      final timeSinceLastActivity = now.difference(_lastActivityTime);
      final minutesSinceLastActivity = timeSinceLastActivity.inMinutes;

      // 4. 判断是否真的满足自动离线的条件
      if (minutesSinceLastActivity < configuredMinutes) {
        return;
      }

      // 5. 满足条件，执行自动离线
      await _sendOfflineStatus();
    });
  }

  // 发送离线状态到服务器
  Future<void> _sendOfflineStatus() async {
    try {
      // 检查当前状态，如果已经是离线状态，则不需要重复发
      if (_userStatus == 'offline') {
        return;
      }

      // 通过WebSocket发送离线状态
      final success = await _wsService.sendStatusChange('offline');

      if (success) {
        // 更新本地状
        setState(() {
          _userStatus = 'offline';
        });
      } else {
        logger.debug('  ❌ 发送离线状态失败');
      }
    } catch (e) {
      logger.debug('  ❌ 发送离线状态异常: $e');
    }
  }

  // 重置自动离线定时器（当检测到鼠标键盘活动时调用）
  Future<void> _resetAutoOfflineTimer() async {
    // 读取设置
    final enabled = await Storage.getIdleStatusEnabled();
    if (!enabled) {
      return;
    }

    final minutes = await Storage.getIdleMinutes();

    // 重新启动定时
    _startAutoOfflineTimer(minutes);
  }

  // 记录用户活动（在用户操作时调用，重置自动离线定时器）
  void _recordUserActivity() {
    final now = DateTime.now();

    // 更新最后活动时
    _lastActivityTime = now;

    // 防抖：如果距离上次重置不秒，则跳过定时器重置
    if (_lastResetTime != null &&
        now.difference(_lastResetTime!).inSeconds < 5) {
      return;
    }

    _lastResetTime = now;

    // 重置自动离线定时器
    _resetAutoOfflineTimer();
  }

  // 初始化WebSocket连接
  Future<void> _initWebSocket() async {
    // 确保token已加载
    if (_token == null || _token!.isEmpty) {
      logger.debug('⚠️ Token未加载，等待加载...');
      // 等待token加载
      await Future.delayed(const Duration(milliseconds: 100));
      if (_token == null || _token!.isEmpty) {
        logger.debug('Token加载失败，无法连接WebSocket');
        // Token无效，跳转到登录页面
        _redirectToLogin('WebSocket连接失败-Token无效');
        return;
      }
    }

    // 连接WebSocket，使用内存中的token
    final connected = await _wsService.connect(token: _token);
    if (connected) {
      // 取消旧的订阅（如果存在）
      await _messageSubscription?.cancel();

      // 设置被踢下线回调
      _wsService.onForcedLogout = (message) {
        logger.debug('🚫 [强制登出] 收到被踢下线通知，准备跳转到登录页面');
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
          _currentUserId = 0;
          
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
        logger.debug('🚫 [消息错误] 收到消息发送错误: $errorType - $errorMessage');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      };

      // 监听消息并保存订阅引用
      logger.debug('📱 PC端开始监听WebSocket消息');
      _messageSubscription = _wsService.messageStream.listen(
        (message) {
          _handleWebSocketMessage(message);
        },
        onError: (error) {
          logger.debug('❌ WebSocket消息流错误: $error');
        },
        onDone: () {
          logger.debug('🔌 WebSocket消息流已关闭');
        },
        cancelOnError: false,
      );

      // 连接成功后，发送在线状态
      try {
        await _wsService.sendStatusChange('online');
        logger.debug('✅ WebSocket连接成功，已发送在线状态');
      } catch (e) {
        logger.debug('⚠️ 发送在线状态失败: $e');
      }
    }
  }

  // 初始化Agora（替代WebRTC）
  Future<void> _initWebRTC() async {
    // 只在启用 WebRTC 功能时初始化
    if (!FeatureConfig.enableWebRTC || _agoraService == null) {
      logger.debug(
        '📞 Agora 功能已禁用 - enableWebRTC: ${FeatureConfig.enableWebRTC}, service: ${_agoraService != null}',
      );
      return;
    }

    logger.debug('📞 开始初始化 Agora 服务，当前用户ID: $_currentUserId');

    // 初始化 Agora 服务
    await _agoraService!.initialize(_currentUserId);

    // 设置来电回调
    _agoraService.onIncomingCall = (userId, displayName, callType) {
      logger.debug('📞 Agora 来电回调被触发 - 用户: $displayName ($userId)');
      // 保存待显示的通话信息
      setState(() {
        _pendingIncomingCallUserId = userId;
        _pendingIncomingCallDisplayName = displayName;
        _pendingIncomingCallType = callType;
      });
      // 显示来电界面
      _showIncomingCallDialog(userId, displayName, callType);
    };

    // 设置群组来电回调
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

    // 设置通话结束回调
    _agoraService.onCallEnded = (int callDuration) {
      // logger.debug('🎯 ========== Agora onCallEnded 回调被触发 ==========');
      // logger.debug('🎯 当前 mounted: $mounted');
      // logger.debug(
      //   '🎯 当前 _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
      // );
      // logger.debug('🎯 当前 _showCallFloatingButton: $_showCallFloatingButton');
      // logger.debug('🎯 接收到的通话时长: $callDuration 秒');

      // 延迟一小段时间，确保通话页面（VoiceCallPage）先关闭
      // 然后再关闭来电对话框和悬浮按钮
      // logger.debug('🎯 设置300ms延迟...');
      Future.delayed(const Duration(milliseconds: 300), () {
        // logger.debug('🎯 ========== 延迟300ms后执行 ==========');
        // logger.debug('🎯 mounted: $mounted');
        // logger.debug(
        //   '🎯 _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
        // );

        if (mounted) {
          logger.debug('🎯 准备调用 _closeIncomingCallDialogIfShowing()');
          _closeIncomingCallDialogIfShowing();
          // logger.debug('🎯 _closeIncomingCallDialogIfShowing() 已返回');

          // 关闭悬浮按钮（如果正在显示）
          if (_showCallFloatingButton) {
            // logger.debug('🎯 关闭通话悬浮按钮');
            setState(() {
              _showCallFloatingButton = false;
            });
          }

          // 🔴 修复：根据是否为群组通话发送不同的消息
          // callDuration > 0 表示通话真正连接过
          if (callDuration > 0) {
            if (_isInGroupCall && _currentGroupCallId != null) {
              // 群组通话：发送群组消息
              // logger.debug('🎯 检测到群组通话，发送群组消息');
              // logger.debug(
              //   '🎯 群组ID: $_currentGroupCallId, 时长: $callDuration 秒',
              // );
              // 🔴 修复：移除客户端发送群组通话时长消息的逻辑
              // 群组通话时长消息由服务器端统一处理（只有最后一个成员离开时才发送）
              logger.debug('📞 [PC] 群组通话结束，服务器端将处理通话时长消息');
            } else if (_currentCallUserId != null && _currentCallUserId != 0) {
              // 一对一通话或无群组ID的群组通话：发送一对一消息
              // logger.debug(
              //   '🎯 发送通话结束消息，时长: $callDuration 秒，目标用户: $_currentCallUserId',
              // );
              _sendCallEndedMessage(_currentCallUserId!, callDuration);
            } else {
              // logger.debug('🎯 无有效的目标用户或群组，跳过发送消息');
            }
          } else {
            // logger.debug('🎯 通话未连接或被拒绝，不发送通话结束消息（时长: $callDuration 秒）');
          }

          // 重置群组通话标志
          _isInGroupCall = false;
          _currentGroupCallId = null;
        } else {
          // logger.debug('🎯 未 mounted，跳过');
        }
        // logger.debug('🎯 ========== 延迟回调完成 ==========');
      });
      logger.debug('🎯 ========== onCallEnded 回调完成 ==========');
    };

    // 设置错误回调
    _agoraService.onError = (error) {
      logger.debug('Agora 错误: $error');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));

      // 如果对方拒绝了通话,发送通话拒绝消息
      // 注意：这里需要确保双方都能发送拒绝消息
      // 优先使用 _currentCallUserId，如果没有则使用 agoraService 中的 currentCallUserId
      int? targetUserId = _currentCallUserId;
      if (targetUserId == null || targetUserId == 0) {
        // 尝试从 agoraService 获取当前通话用户ID
        targetUserId = _agoraService.currentCallUserId;
      }

      if (error == '对方拒绝了通话' && targetUserId != null && targetUserId != 0) {
        logger.debug('📞 对方拒绝了通话，发送拒绝消息给: $targetUserId');
        // 发起方收到拒绝通知，显示"对方已拒绝"
        _sendCallRejectedMessage(targetUserId, isRejecter: false);
      }
    };

    logger.debug('Agora 服务初始化完成，来电回调已设置');
  }

  // 初始化原生来电服务（仅Android）
  void _initNativeCallService() {
    if (!Platform.isAndroid) {
      logger.debug('⚠️ 原生来电服务仅支持 Android 平台');
      return;
    }

    logger.debug('📱 开始初始化原生来电服务...');
    logger.debug('📱 当前 mounted 状态: $mounted');
    logger.debug('📱 当前用户ID: $_currentUserId');

    // 初始化原生来电服务并设置回调
    NativeCallService().initialize(
      onIncomingCall: (callData) {
        logger.debug('═══════════════════════════════════════');
        logger.debug('📲 [NativeCallService] 收到来自原生层的来电通知!');
        logger.debug('📲 原始数据: $callData');
        logger.debug('═══════════════════════════════════════');

        final callerName = callData['callerName'] as String?;
        final callerId = callData['callerId'] as int?;
        final callType = callData['callType'] as String?;
        final channelName = callData['channelName'] as String?;
        final isGroupCall = callData['isGroupCall'] as bool? ?? false;
        final groupId = callData['groupId'] as int?;
        final membersJson = callData['members'] as String?;

        logger.debug('📋 解析后的数据:');
        logger.debug('  - callerName: $callerName (${callerName.runtimeType})');
        logger.debug('  - callerId: $callerId (${callerId.runtimeType})');
        logger.debug('  - callType: $callType (${callType.runtimeType})');
        logger.debug('  - channelName: $channelName (${channelName.runtimeType})');
        logger.debug('  - isGroupCall: $isGroupCall (${isGroupCall.runtimeType})');
        logger.debug('  - groupId: $groupId');
        logger.debug('  - membersJson: $membersJson');

        if (callerName == null || callerId == null || callType == null) {
          logger.debug('❌ 来电数据不完整，跳过处理');
          logger.debug('   缺失的字段: ${callerName == null ? "callerName " : ""}${callerId == null ? "callerId " : ""}${callType == null ? "callType" : ""}');
          return;
        }

        // 根据通话类型转换
        final type = callType == 'video' ? CallType.video : CallType.voice;

        logger.debug('📞 准备显示应用内来电弹窗:');
        logger.debug('  - 来电者: $callerName');
        logger.debug('  - 来电者ID: $callerId');
        logger.debug('  - 通话类型: $callType -> $type');
        logger.debug('  - 是否群组: $isGroupCall');
        logger.debug('  - 频道名称: $channelName');
        logger.debug('  - Widget mounted: $mounted');
        logger.debug('  - _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog');

        // 显示应用内来电对话框
        if (mounted) {
          logger.debug('✅ Widget已挂载，准备显示来电对话框...');
          
          // 使用 SchedulerBinding 确保在下一帧执行
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isShowingIncomingCallDialog) {
              if (isGroupCall && groupId != null && membersJson != null) {
                // 群组通话
                logger.debug('🎯 执行显示群组来电对话框...');
                
                // 解析成员列表JSON
                try {
                  final membersData = (json.decode(membersJson) as List)
                      .map((e) => e as Map<String, dynamic>)
                      .toList();
                  
                  logger.debug('🎯 解析到 ${membersData.length} 个成员');
                  _showIncomingGroupCallDialog(
                    callerId,
                    callerName,
                    type,
                    membersData,
                    groupId,
                  );
                  logger.debug('🎯 _showIncomingGroupCallDialog 调用完成');
                } catch (e) {
                  logger.debug('❌ 解析成员列表失败: $e');
                  // 回退到单人通话弹窗
                  _showIncomingCallDialog(callerId, callerName, type);
                }
              } else {
                // 单人通话
                logger.debug('🎯 执行显示单人来电对话框...');
                _showIncomingCallDialog(callerId, callerName, type);
                logger.debug('🎯 _showIncomingCallDialog 调用完成');
              }
            } else {
              logger.debug('⚠️ 跳过显示: mounted=$mounted, _isShowingIncomingCallDialog=$_isShowingIncomingCallDialog');
            }
          });
        } else {
          logger.debug('❌ Widget未挂载，无法显示来电对话框');
        }
        
        logger.debug('═══════════════════════════════════════');
      },
    );

    logger.debug('✅ 原生来电服务初始化完成');
    logger.debug('✅ 回调监听器已设置');
  }

  // ============ 浏览器相关方法 ============

  // 添加新标签页
  void _addNewTab(String url) {
    final tab = _BrowserTab(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      title: '加载..',
    );

    setState(() {
      _tabs.add(tab);
      _currentTabIndex = _tabs.length - 1;
    });

    _urlController.text = url;
    _initializeWebViewForTab(tab);
  }

  // 为标签页初始化WebView
  Future<void> _initializeWebViewForTab(_BrowserTab tab) async {
    if (_isWindows) {
      await _initializeWindowsWebView(tab);
    } else {
      _initializeMobileWebView(tab);
    }
  }

  Future<void> _initializeWindowsWebView(_BrowserTab tab) async {
    try {
      final controller = win_webview.WebviewController();
      await controller.initialize();

      controller.loadingState.listen((state) async {
        if (_currentTab?.id == tab.id) {
          setState(() {
            tab.isLoading = state == win_webview.LoadingState.loading;
          });

          // 页面加载完成后注入JavaScript
          if (state == win_webview.LoadingState.navigationCompleted) {
            await _injectWindowsNewWindowHandler(tab);
          }
        }
      });

      controller.url.listen((url) {
        if (_currentTab?.id == tab.id) {
          setState(() {
            tab.url = url;
            _urlController.text = url;
          });
        }
      });

      // 监听标题变化
      controller.title.listen((title) {
        setState(() {
          tab.title = title.isEmpty ? '新标签页' : title;
        });
      });

      tab.windowsController = controller;

      // 设置缩放因子以适应窗口宽度，避免水平滚动条
      await controller.setZoomFactor(0.75);

      await controller.loadUrl(tab.url);

      if (_currentTab?.id == tab.id) {
        setState(() {
          _canGoBack = true;
          _canGoForward = true;
        });
      }
    } catch (e) {
      logger.debug('⚠️ Windows WebView 初始化失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('WebView 初始化失败: $e\n\n提示：请确保系统已安装 WebView2 Runtime'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 8),
          ),
        );
      }
      // 标记为初始化失败
      tab.windowsController = null;
    }
  }

  // 为Windows WebView注入新窗口拦截脚本和CSS样式
  Future<void> _injectWindowsNewWindowHandler(_BrowserTab tab) async {
    if (tab.windowsController == null) return;

    try {
      final script = '''
        (function() {
          // 隐藏水平滚动          document.body.style.overflowX = 'hidden';
          document.documentElement.style.overflowX = 'hidden';
          
          // 保存原始的window.open函数
          window._originalOpen = window.open;
          
          // 重写window.open函数
          window.open = function(url, target, features) {
            // 拦截并通过修改location来告诉Flutter打开新标签页
            console.log('Intercepted window.open: ' + url);
            // 由于webview_windows的限制，我们在当前页面显示提示
            if (url && url !== '') {
              var fullUrl = new URL(url, window.location.href).href;
              alert('检测到新窗口请求：' + fullUrl + '\\n\\n请使用右键菜单中的"在新标签页中打开"或手动复制URL到地址栏');
            }
            return { closed: false, close: function() {} };
          };
          
          // 拦截target="_blank"的链接
          document.addEventListener('click', function(e) {
            var target = e.target;
            while (target && target.tagName !== 'A') {
              target = target.parentElement;
            }
            if (target && target.tagName === 'A') {
              var href = target.getAttribute('href');
              var targetAttr = target.getAttribute('target');
              if (targetAttr === '_blank' && href) {
                e.preventDefault();
                // 在当前标签页打开
                window.location.href = href;
              }
            }
          }, true);
        })();
      ''';

      await tab.windowsController!.executeScript(script);
    } catch (e) {
      // 忽略注入错误
      logger.debug('Failed to inject new window handler: $e');
    }
  }

  void _initializeMobileWebView(_BrowserTab tab) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (_currentTab?.id == tab.id) {
              setState(() {
                tab.isLoading = true;
                tab.url = url;
                _urlController.text = url;
              });
            }
          },
          onPageFinished: (String url) async {
            if (_currentTab?.id == tab.id) {
              setState(() {
                tab.isLoading = false;
              });
              _updateNavigationState();

              // 获取页面标题
              try {
                final title = await tab.mobileController?.getTitle();
                setState(() {
                  tab.title = title ?? '新标签页';
                });
              } catch (e) {
                // 忽略错误
              }

              // 注入JavaScript来拦截新窗口打开
              _injectNewWindowHandler(tab);
            }
          },
          onWebResourceError: (WebResourceError error) {
            if (mounted && _currentTab?.id == tab.id) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('加载失败: ${error.description}'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            // 允许导航
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(tab.url));

    tab.mobileController = controller;
  }

  // 注入JavaScript来拦截window.open
  void _injectNewWindowHandler(_BrowserTab tab) {
    if (tab.mobileController == null) return;

    final script = '''
      // 保存原始的window.open函数
      window._originalOpen = window.open;
      
      // 重写window.open函数
      window.open = function(url, target, features) {
        // 通过postMessage发送打开新标签的请求
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('openNewTab', url || '');
        } else {
          // 发送消息到Flutter
          window.parent.postMessage({type: 'openNewTab', url: url || ''}, '*');
        }
        // 返回一个空对象，防止原窗口继续执行
        return { closed: false, close: function() {} };
      };
      
      // 拦截target="_blank"的链接
      document.addEventListener('click', function(e) {
        var target = e.target;
        while (target && target.tagName !== 'A') {
          target = target.parentElement;
        }
        if (target && target.tagName === 'A') {
          var href = target.getAttribute('href');
          var targetAttr = target.getAttribute('target');
          if (targetAttr === '_blank' && href) {
            e.preventDefault();
            if (window.flutter_inappwebview) {
              window.flutter_inappwebview.callHandler('openNewTab', href);
            } else {
              window.parent.postMessage({type: 'openNewTab', url: href}, '*');
            }
          }
        }
      }, true);
    ''';

    tab.mobileController!.runJavaScript(script);

    // 添加JavaScript通道来接收消息
    tab.mobileController!.addJavaScriptChannel(
      'FlutterBrowser',
      onMessageReceived: (JavaScriptMessage message) {
        // 在新标签页中打开URL
        _addNewTab(message.message);
      },
    );
  }

  Future<void> _updateNavigationState() async {
    if (_currentTab == null) return;

    if (_isWindows) {
      setState(() {
        _canGoBack = true;
        _canGoForward = true;
      });
    } else if (_currentTab!.mobileController != null) {
      final canGoBack = await _currentTab!.mobileController!.canGoBack();
      final canGoForward = await _currentTab!.mobileController!.canGoForward();
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    }
  }

  void _loadUrl() {
    if (_currentTab == null) return;

    String url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入网址'), backgroundColor: Colors.orange),
      );
      return;
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
      _urlController.text = url;
    }

    try {
      _currentTab!.url = url;
      if (_isWindows && _currentTab!.windowsController != null) {
        _currentTab!.windowsController!.loadUrl(url);
      } else if (_currentTab!.mobileController != null) {
        _currentTab!.mobileController!.loadRequest(Uri.parse(url));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无效的网址: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _goBack() async {
    if (_currentTab == null) return;

    if (_isWindows && _currentTab!.windowsController != null) {
      try {
        await _currentTab!.windowsController!.goBack();
      } catch (e) {
        // 忽略错误
      }
    } else if (_currentTab!.mobileController != null) {
      if (await _currentTab!.mobileController!.canGoBack()) {
        await _currentTab!.mobileController!.goBack();
        _updateNavigationState();
      }
    }
  }

  void _goForward() async {
    if (_currentTab == null) return;

    if (_isWindows && _currentTab!.windowsController != null) {
      try {
        await _currentTab!.windowsController!.goForward();
      } catch (e) {
        // 忽略错误
      }
    } else if (_currentTab!.mobileController != null) {
      if (await _currentTab!.mobileController!.canGoForward()) {
        await _currentTab!.mobileController!.goForward();
        _updateNavigationState();
      }
    }
  }

  void _reload() {
    if (_currentTab == null) return;

    if (_isWindows && _currentTab!.windowsController != null) {
      _currentTab!.windowsController!.reload();
    } else if (_currentTab!.mobileController != null) {
      _currentTab!.mobileController!.reload();
    }
  }

  // 切换标签
  void _switchTab(int index) {
    setState(() {
      _currentTabIndex = index;
      _urlController.text = _tabs[index].url;
    });
    _updateNavigationState();
  }

  // 关闭标签
  void _closeTab(int index) {
    if (_tabs.length == 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('至少需要保留一个标签页'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final tab = _tabs[index];

    // 释放资源
    if (_isWindows && tab.windowsController != null) {
      tab.windowsController!.dispose();
    }

    setState(() {
      _tabs.removeAt(index);
      if (_currentTabIndex >= _tabs.length) {
        _currentTabIndex = _tabs.length - 1;
      }
      _urlController.text = _currentTab?.url ?? '';
    });

    _updateNavigationState();
  }

  /// 开始播放来电铃声和震动
  void _startRingtone() async {
    try {
      // 播放铃声
      _ringtonePlayer = AudioPlayer();
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop); // 循环播放
      await _ringtonePlayer!.play(AssetSource('mp3/wait.mp3'));
      logger.debug('🔔 开始播放来电铃声');

      // PC端也使用震动（如果支持）
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

  // 显示来电对话
  void _showIncomingCallDialog(
    int userId,
    String displayName,
    CallType callType,
  ) {
    logger.debug('🔔 ========== 显示来电对话框 ==========');
    logger.debug('🔔 用户ID: $userId, 名称: $displayName, 类型: $callType');
    logger.debug('🔔 当前标志状态: $_isShowingIncomingCallDialog');

    // 🔴 防止重复显示对话框
    if (_isShowingIncomingCallDialog) {
      logger.debug('⚠️ 对话框已在显示中，跳过重复调用');
      return;
    }

    // 如果显示名称为空，使用默认值
    final effectiveDisplayName = displayName.isEmpty ? 'Unknown' : displayName;

    // 标记对话框正在显示，并保存通话类型
    setState(() {
      _isShowingIncomingCallDialog = true;
      // 清除待显示的通话信息
      _pendingIncomingCallUserId = null;
      _pendingIncomingCallDisplayName = null;
      _pendingIncomingCallType = null;
      // 🔴 修复：立即设置当前通话类型，用于拒接时发送正确的消息
      _currentCallType = callType;
    });

    // 开始播放铃声和震动
    _startRingtone();

    logger.debug('🔔 已设置 _isShowingIncomingCallDialog = true');
    logger.debug('🔔 准备调用 showDialog...');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        logger.debug('🔔 AlertDialog builder 被调用');
        return AlertDialog(
          title: Text('${callType == CallType.voice ? '语音' : '视频'}通话'),
          content: Text('$effectiveDisplayName 正在呼叫..'),
          actions: [
            TextButton(
              onPressed: () {
                logger.debug('🔴 ========== 用户点击拒接按钮 ==========');
                logger.debug('🔴 当前 mounted: $mounted');
                logger.debug(
                  '🔴 _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
                );

                _stopRingtone(); // 停止响铃和震动

                // 保存对话框 context
                final dialogContext = context;
                logger.debug('🔴 已保存 dialogContext');

                // 🔴 关键：在同步代码中立即关闭对话框
                logger.debug('🔴 准备调用 Navigator.pop()...');
                Navigator.of(dialogContext).pop();
                logger.debug('🔴 已调用 Navigator.pop()');

                // 使用 Future 异步执行拒绝操作
                Future.microtask(() async {
                  logger.debug('🔴 开始执行拒绝通话操作');
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    await _agoraService.rejectCall();
                    logger.debug('🔴 拒绝通话操作完成');
                  }
                  // 发送通话拒绝消息（接收方拒绝，显示"已拒绝"）
                  await _sendCallRejectedMessage(userId, isRejecter: true);
                });
              },
              child: const Text('拒接'),
            ),
            ElevatedButton(
              onPressed: () {
                logger.debug('🟢 ========== 用户点击接听按钮 ==========');
                logger.debug('🟢 当前 mounted: $mounted');
                logger.debug(
                  '🟢 _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
                );

                _stopRingtone(); // 停止响铃和震动

                // 🔴 修复：保存HomePage的根context引用，避免异步操作中context失效
                final rootContext = this.context;
                final dialogContext = context;
                logger.debug('🟢 已保存 rootContext 和 dialogContext');

                // 🔴 关键：在同步代码中立即关闭对话框
                logger.debug('🟢 准备调用 Navigator.pop()...');
                Navigator.of(dialogContext).pop();
                logger.debug('🟢 已调用 Navigator.pop()');

                // 使用 Future 异步执行后续操作
                Future.microtask(() async {
                  logger.debug('🟢 开始异步操作');

                  // 先接听通话
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    logger.debug('🟢 准备接听通话...');
                    await _agoraService.acceptCall();
                    logger.debug('🟢 通话已接听');
                  }

                  // 导航到通话页面（使用保存的 HomePage 的 context）
                  if (FeatureConfig.enableWebRTC && mounted) {
                    logger.debug('🟢 【步骤1】先渲染最小化按钮，验证通过后再进入通话页面');

                    // 保存当前通话信息
                    _currentCallUserId = userId;
                    _currentCallDisplayName = displayName;
                    _currentCallType = callType;

                    // 步骤1: 预先渲染最小化按钮，测试是否能正常显示
                    logger.debug('🔘 设置最小化按钮状态...');
                    setState(() {
                      _showCallFloatingButton = true;
                      _floatingButtonX = 0;
                      _floatingButtonY = 0;
                    });
                    logger.debug('🔘 setState 完成');

                    // 步骤2: 等待下一帧渲染完成
                    await Future.delayed(const Duration(milliseconds: 100));

                    // 步骤3: 验证最小化按钮是否成功渲染
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _showCallFloatingButton) {
                        logger.debug('✅ 最小化按钮渲染验证成功');
                      } else {
                        logger.debug('❌ 最小化按钮渲染验证失败');
                        logger.debug('  - mounted: $mounted');
                        logger.debug(
                          '  - _showCallFloatingButton: $_showCallFloatingButton',
                        );
                      }
                    });

                    // 等待验证完成
                    await Future.delayed(const Duration(milliseconds: 200));

                    // 步骤4: 检查验证结果并决定是否进入通话页面
                    if (!mounted) {
                      logger.debug('❌ Widget已销毁，取消进入通话页面');
                      return;
                    }

                    if (!_showCallFloatingButton) {
                      logger.debug('❌ 最小化按钮无法展示，显示错误提示');
                      if (mounted) {
                        ScaffoldMessenger.of(rootContext).showSnackBar(
                          const SnackBar(
                            content: Text('无法加载通话控制按钮，请重试'),
                            backgroundColor: Colors.red,
                            duration: Duration(seconds: 3),
                          ),
                        );
                        // 清理状态
                        setState(() {
                          _showCallFloatingButton = false;
                        });
                      }
                      return;
                    }

                    logger.debug('✅ 最小化按钮验证成功，准备进入通话页面');

                    // 步骤5: 隐藏最小化按钮，进入通话页面
                    setState(() {
                      _showCallFloatingButton = false;
                    });

                    // 等待状态更新
                    await Future.delayed(const Duration(milliseconds: 50));

                    logger.debug('🟢 准备打开通话页面');

                    final result = await Navigator.of(rootContext).push(
                      MaterialPageRoute(
                        builder: (ctx) => VoiceCallPage(
                          targetUserId: userId,
                          targetDisplayName: displayName,
                          isIncoming: true,
                          callType: callType,
                          currentUserId: _currentUserId, // 🔴 修复：传递当前用户ID
                        ),
                      ),
                    );
                    logger.debug('🟢 通话页面已打开');

                    // 如果返回结果要求显示悬浮按钮
                    if (result is Map && result['showFloatingButton'] == true) {
                      // 🔴 修复：从AgoraService中获取最小化通话的信息
                      if (_agoraService != null && _agoraService!.isCallMinimized) {
                        logger.debug('📱 从AgoraService获取最小化通话信息');
                        setState(() {
                          _showCallFloatingButton = true;
                          _currentCallUserId = _agoraService!.minimizedCallUserId;
                          _currentCallDisplayName = _agoraService!.minimizedCallDisplayName;
                          _currentCallType = _agoraService!.minimizedCallType;
                          _floatingButtonX = 0;
                          _floatingButtonY = 0;
                        });
                        logger.debug('📱 已更新最小化按钮状态');
                      } else {
                        logger.debug('⚠️ AgoraService中没有最小化通话信息');
                        setState(() {
                          _showCallFloatingButton = true;
                          _floatingButtonX = 0;
                          _floatingButtonY = 0;
                        });
                      }
                      logger.debug('📱 显示通话悬浮按钮');
                    } else {
                      // 通话正常结束，清除状态
                      setState(() {
                        _showCallFloatingButton = false;
                      });

                      // 🔴 修复：移除重复的消息发送，消息已在 onCallEnded 回调中统一发送
                      // 通话结束消息会在 onCallEnded 回调中发送，这里只需处理状态
                      // if (result is Map && result['callEnded'] == true) {
                      //   final callDuration = result['callDuration'] as int? ?? 0;
                      //   await _sendCallEndedMessage(userId, callDuration);
                      // }

                      // 如果通话被拒绝，发送通话拒绝消息（接收方拒绝，显示"已拒绝"）
                      if (result is Map && result['callRejected'] == true) {
                        // 从返回值中获取通话类型
                        final returnedCallType =
                            result['callType'] as CallType?;
                        if (returnedCallType != null) {
                          _currentCallType = returnedCallType;
                        }
                        await _sendCallRejectedMessage(
                          userId,
                          isRejecter: true,
                        );
                      }
                      // 如果通话被取消，发送通话取消消息（接收方收到取消通知，显示"对方已取消"）
                      else if (result is Map &&
                          result['callCancelled'] == true) {
                        // 从返回值中获取通话类型
                        final returnedCallType =
                            result['callType'] as CallType?;
                        if (returnedCallType != null) {
                          _currentCallType = returnedCallType;
                        }
                        await _sendCallCancelledMessage(
                          userId,
                          isCaller: false,
                        );
                      }
                    }
                  } else {
                    logger.debug('🟢 无法打开通话页面 - mounted: $mounted');
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
      logger.debug('🔔 ========== showDialog.then 回调被触发 ==========');
      logger.debug('🔔 对话框已关闭（通过某种方式）');
      logger.debug('🔔 当前 mounted: $mounted');
      logger.debug(
        '🔔 当前 _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
      );

      // 对话框关闭时（无论什么原因），清除状态
      if (mounted) {
        logger.debug('🔔 设置 _isShowingIncomingCallDialog = false');
        setState(() {
          _isShowingIncomingCallDialog = false;
        });
        // 确保对话框关闭时停止响铃和震动
        _stopRingtone();
        logger.debug('🔔 已更新状态');
      } else {
        logger.debug('🔔 未 mounted，跳过状态更新');
      }
      logger.debug('🔔 ========== showDialog.then 完成 ==========');
    });
  }

  // 显示群组来电对话框
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
    logger.debug('🔔 当前用户ID: $_currentUserId');
    logger.debug('🔔 当前标志状态: $_isShowingIncomingCallDialog');

    // 🔴 防止重复显示对话框
    if (_isShowingIncomingCallDialog) {
      logger.debug('⚠️ 对话框已在显示中，跳过重复调用');
      return;
    }

    final rootContext = context;

    // 如果显示名称为空，使用默认值
    final effectiveDisplayName = displayName.isEmpty ? 'Unknown' : displayName;

    // 标记对话框正在显示
    setState(() {
      _isShowingIncomingCallDialog = true;
    });

    // 开始播放铃声和震动
    _startRingtone();

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
                final dialogContext = context;
                Navigator.of(dialogContext).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    await _agoraService.rejectCall();
                  }
                });
              },
              child: const Text('拒接'),
            ),
            ElevatedButton(
              onPressed: () {
                logger.debug('🟢 用户接听群组通话');
                _stopRingtone(); // 停止响铃和震动
                final dialogContext = context;
                Navigator.of(dialogContext).pop();

                Future.microtask(() async {
                  if (FeatureConfig.enableWebRTC && _agoraService != null) {
                    await _agoraService.acceptCall();
                  }

                  if (FeatureConfig.enableWebRTC && mounted) {
                    logger.debug('🟢 mounted检查通过，开始导航');
                    // 保存当前通话信息
                    _currentCallUserId = userId;
                    _currentCallDisplayName = displayName;
                    _currentCallType = callType;
                    _isInGroupCall = true; // 标记为群组通话
                    _currentGroupCallId = groupId; // 保存群组ID（来自来电通知）

                    // 提取成员的用户ID和显示名称列表
                    final memberUserIds = members
                        .map((m) => m['user_id'] as int)
                        .toList();
                    final memberDisplayNames = members.map((m) {
                      // 对于当前用户，显示名称应该显示"我"
                      if (m['user_id'] == _currentUserId) {
                        return '我';
                      }
                      return m['display_name'] as String;
                    }).toList();

                    logger.debug('🟢 【步骤1】先渲染最小化按钮，验证通过后再进入通话页面');

                    // 步骤1: 预先渲染最小化按钮，测试是否能正常显示
                    logger.debug('🔘 设置最小化按钮状态...');
                    setState(() {
                      _showCallFloatingButton = true;
                      _currentCallUserId = userId;
                      _currentCallDisplayName = displayName;
                      _currentCallType = callType;
                      _floatingButtonX = 0;
                      _floatingButtonY = 0;
                    });
                    logger.debug('🔘 setState 完成');

                    // 步骤2: 等待渲染完成并验证
                    await Future.delayed(const Duration(milliseconds: 300));

                    // 步骤4: 检查验证结果并决定是否进入通话页面
                    if (!mounted) {
                      logger.debug('❌ Widget已销毁，取消进入通话页面');
                      return;
                    }

                    if (!_showCallFloatingButton) {
                      logger.debug('❌ 最小化按钮无法展示，显示错误提示');
                      if (mounted) {
                        ScaffoldMessenger.of(rootContext).showSnackBar(
                          const SnackBar(
                            content: Text('无法加载通话控制按钮，请重试'),
                            backgroundColor: Colors.red,
                            duration: Duration(seconds: 3),
                          ),
                        );
                        // 清理状态
                        setState(() {
                          _showCallFloatingButton = false;
                        });
                      }
                      return;
                    }

                    logger.debug('✅ 最小化按钮验证成功，准备进入通话页面');
                    logger.debug('🟢 准备打开群组通话页面');
                    logger.debug('🟢 成员ID列表: $memberUserIds');
                    logger.debug('🟢 成员显示名称: $memberDisplayNames');

                    // 步骤5: 隐藏最小化按钮，进入通话页面
                    setState(() {
                      _showCallFloatingButton = false;
                    });

                    // 等待状态更新
                    await Future.delayed(const Duration(milliseconds: 50));

                    logger.debug('🟢 开始执行Navigator.push');
                    final result = await Navigator.of(rootContext).push(
                      MaterialPageRoute(
                        builder: (ctx) => callType == CallType.voice
                            ? VoiceCallPage(
                                targetUserId: userId,
                                targetDisplayName: displayName,
                                isIncoming: true,
                                callType: callType,
                                groupCallUserIds: memberUserIds,
                                groupCallDisplayNames: memberDisplayNames,
                                currentUserId: _currentUserId,
                                groupId: groupId,
                              )
                            : GroupVideoCallPage(
                                targetUserId: userId,
                                targetDisplayName: displayName,
                                isIncoming: true,
                                groupCallUserIds: memberUserIds,
                                groupCallDisplayNames: memberDisplayNames,
                                currentUserId: _currentUserId,
                                groupId: groupId,
                              ),
                      ),
                    );
                    logger.debug('🟢 Navigator.push完成，返回结果: $result');

                    // 处理通话页面返回结果
                    if (result is Map && result['showFloatingButton'] == true) {
                      // 🔴 修复：从AgoraService中获取最小化通话的信息
                      if (_agoraService != null && _agoraService!.isCallMinimized) {
                        logger.debug('📱 从AgoraService获取最小化通话信息');
                        setState(() {
                          _showCallFloatingButton = true;
                          _currentCallUserId = _agoraService!.minimizedCallUserId;
                          _currentCallDisplayName = _agoraService!.minimizedCallDisplayName;
                          _currentCallType = _agoraService!.minimizedCallType;
                          _floatingButtonX = 0;
                          _floatingButtonY = 0;
                        });
                        logger.debug('📱 已更新最小化按钮状态:');
                        logger.debug('  - callUserId: $_currentCallUserId');
                        logger.debug('  - callDisplayName: $_currentCallDisplayName');
                        logger.debug('  - callType: $_currentCallType');
                      } else {
                        logger.debug('⚠️ AgoraService中没有最小化通话信息');
                        setState(() {
                          _showCallFloatingButton = true;
                          _floatingButtonX = 0;
                          _floatingButtonY = 0;
                        });
                      }
                    } else if (result is Map && result['callEnded'] == true) {
                      final callDuration = result['callDuration'] as int? ?? 0;
                      logger.debug('🟢 群组通话结束，时长: $callDuration 秒');
                      setState(() {
                        _showCallFloatingButton = false;
                      });
                      
                      // 🔴 修复：接听方挂断通话后不重新加载消息，避免覆盖内存中的消息
                      logger.debug('📞 接听方挂断群组通话，消息已通过WebSocket添加，无需重新加载');
                    } else if (result is Map &&
                        result['callCancelled'] == true) {
                      logger.debug('🟢 群组通话已取消（对方未接听）');
                      setState(() {
                        _showCallFloatingButton = false;
                      });
                    } else if (result is Map &&
                        result['callRejected'] == true) {
                      logger.debug('🟢 群组通话被拒绝');
                      setState(() {
                        _showCallFloatingButton = false;
                      });
                    } else {
                      logger.debug('🟢 返回结果未匹配任何已知类型: $result');
                      setState(() {
                        _showCallFloatingButton = false;
                      });
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

  // 关闭来电对话框（如果正在显示）
  void _closeIncomingCallDialogIfShowing() {
    logger.debug(
      '💫 ========== _closeIncomingCallDialogIfShowing 被调用 ==========',
    );
    logger.debug('💫 当前标志: $_isShowingIncomingCallDialog');
    logger.debug('💫 mounted: $mounted');

    if (_isShowingIncomingCallDialog && mounted) {
      logger.debug('💫 条件满足，准备关闭对话框');

      // 先标记状态为false，防止重复关闭
      logger.debug('💫 设置 _isShowingIncomingCallDialog = false');
      setState(() {
        _isShowingIncomingCallDialog = false;
      });
      logger.debug('💫 状态已更新');

      // 尝试关闭对话框（可能已经被按钮关闭了，这里作为备用）
      try {
        logger.debug('💫 检查 canPop()...');
        final canPop = Navigator.of(context).canPop();
        logger.debug('💫 canPop 结果: $canPop');

        // 检查是否还有对话框可以关闭
        if (canPop) {
          logger.debug('💫 准备执行 Navigator.pop()...');
          Navigator.of(context).pop();
          logger.debug('💫 已执行 Navigator.pop()');
        } else {
          logger.debug('💫 没有对话框可关闭（可能已被按钮关闭）');
        }
      } catch (e) {
        logger.debug('💫 ⚠️ 关闭对话框失败: $e');
        logger.debug('💫 错误堆栈: ${StackTrace.current}');
      }
    } else {
      logger.debug('💫 不满足关闭条件');
      logger.debug(
        '💫 - _isShowingIncomingCallDialog: $_isShowingIncomingCallDialog',
      );
      logger.debug('💫 - mounted: $mounted');
    }
    logger.debug(
      '💫 ========== _closeIncomingCallDialogIfShowing 完成 ==========',
    );
  }

  // 显示群组语音通话成员选择弹窗
  Future<void> _showGroupCallMemberPicker(RecentContactModel contact) async {
    if (!_isCurrentChatGroup || _currentChatUserId == null) {
      return;
    }

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 显示加载对话框
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // 获取群组详情
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: _currentChatUserId!,
      );

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0 && response['data'] != null) {
        // 🔐 权限检查：只有群主和管理员可以发起群组语音通话
        final memberRole = response['data']['member_role'] as String?;
        logger.debug('🔐 [群组语音通话权限检查] 当前用户角色: $memberRole');
        
        if (memberRole != 'owner' && memberRole != 'admin') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('只有群主和管理员可以发起群组语音通话'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          logger.debug('❌ [群组语音通话权限检查] 用户角色为 $memberRole，无权发起通话');
          return;
        }
        
        logger.debug('✅ [群组语音通话权限检查] 用户是 $memberRole，允许发起通话');

        final membersData = response['data']['members'] as List?;
        if (membersData == null || membersData.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('群组暂无成员')));
          }
          return;
        }

        // 转换为 GroupCallMember 列表（排除自己）
        final members = membersData
            .where((m) => m['user_id'] != _currentUserId)
            .map((m) {
              final fullName = m['full_name'] as String?;
              final username = m['username'] as String?;
              final avatar = m['avatar'] as String?;
              return GroupCallMember(
                userId: m['user_id'] as int,
                fullName: (fullName != null && fullName.isNotEmpty)
                    ? fullName
                    : 'Unknown',
                username: (username != null && username.isNotEmpty)
                    ? username
                    : 'unknown',
                avatar: avatar,
              );
            })
            .toList();

        if (members.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('群组暂无其他成员')));
          }
          return;
        }

        if (!mounted) return;

        // 显示成员选择弹窗
        showDialog(
          context: context,
          builder: (context) => GroupCallMemberPicker(
            members: members,
            currentUserId: _currentUserId,
            onConfirm: (selectedUserIds) async {
              logger.debug('🎯 [HomePage.onConfirm] onConfirm回调被调用');
              logger.debug(
                '🎯 [HomePage.onConfirm] 接收到的选中用户ID: $selectedUserIds',
              );
              logger.debug(
                '🎯 [HomePage.onConfirm] 用户数量: ${selectedUserIds.length}',
              );

              if (selectedUserIds.isEmpty) {
                logger.debug('🎯 [HomePage.onConfirm] ⚠️ 选中用户列表为空，直接返回');
                return;
              }

              // 检查 WebRTC 功能是否启用
              logger.debug(
                '🎯 [HomePage.onConfirm] 检查WebRTC功能状态: ${FeatureConfig.enableWebRTC}',
              );
              if (!FeatureConfig.enableWebRTC) {
                logger.debug('🎯 [HomePage.onConfirm] ⚠️ WebRTC功能未启用');
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('语音通话功能未启用')));
                }
                return;
              }

              // 请求麦克风权限
              logger.debug('🎯 [HomePage.onConfirm] 开始请求麦克风权限...');
              final status = await Permission.microphone.request();
              logger.debug(
                '🎯 [HomePage.onConfirm] 麦克风权限请求结果: ${status.isGranted}',
              );
              if (!status.isGranted) {
                logger.debug('🎯 [HomePage.onConfirm] ⚠️ 麦克风权限被拒绝');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('需要麦克风权限才能进行语音通话')),
                  );
                }
                return;
              }

              // 获取所有选中成员的显示名称
              logger.debug('🎯 [HomePage.onConfirm] 开始获取选中成员的显示名称...');
              final selectedDisplayNames = selectedUserIds.map((userId) {
                // 如果是当前用户，使用"我"作为显示名称
                if (userId == _currentUserId) {
                  logger.debug(
                    '🎯 [HomePage.onConfirm] userId=$userId 是当前用户，使用"我"作为显示名',
                  );
                  return '我';
                }
                // 从members列表中查找对应成员
                final member = members.firstWhere(
                  (m) => m.userId == userId,
                  orElse: () {
                    logger.debug(
                      '🎯 [HomePage.onConfirm] ⚠️ 未找到userId=$userId的成员信息',
                    );
                    return GroupCallMember(
                      userId: userId,
                      fullName: 'Unknown',
                      username: 'unknown',
                    );
                  },
                );
                return member.displayText;
              }).toList();
              logger.debug(
                '🎯 [HomePage.onConfirm] 选中成员的显示名称: $selectedDisplayNames',
              );

              // 发起群组语音通话
              logger.debug('🎯 [HomePage.onConfirm] 准备调用 _startGroupVoiceCall');
              await _startGroupVoiceCall(selectedUserIds, selectedDisplayNames);
              logger.debug('🎯 [HomePage.onConfirm] _startGroupVoiceCall 调用完成');
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] as String? ?? '获取群组成员失败'),
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('显示群组语音通话成员选择弹窗失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载群组成员失败: $e')));
      }
    }
  }

  // 发起群组语音通话
  Future<void> _startGroupVoiceCall(
    List<int> userIds,
    List<String> displayNames,
  ) async {
    if (!mounted) {
      logger.debug('📞 ⚠️ 页面未mounted，直接返回');
      return;
    }

    // 过滤掉当前用户，只保留其他成员
    logger.debug('📞 开始过滤成员...');
    final otherUserIds = <int>[];
    final otherDisplayNames = <String>[];
    for (int i = 0; i < userIds.length; i++) {
      if (userIds[i] != _currentUserId) {
        otherUserIds.add(userIds[i]);
        if (i < displayNames.length) {
          otherDisplayNames.add(displayNames[i]);
        }
      }
    }

    logger.debug('📞 过滤后的成员:');
    logger.debug('  - 其他成员数量: ${otherUserIds.length}');
    logger.debug('  - 其他成员ID列表: $otherUserIds');
    logger.debug('  - 其他成员名称列表: $otherDisplayNames');

    // 检查是否至少有一个其他成员
    if (otherUserIds.isEmpty) {
      logger.debug('📞 ⚠️ 没有其他成员可以呼叫');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请至少选择一个其他成员')));
      }
      return;
    }

    // 使用第一个其他成员作为主要通话对象（兼容性）
    final firstUserId = otherUserIds.first;
    final firstDisplayName = otherDisplayNames.first;
    logger.debug(
      '📞 主要通话对象: userId=$firstUserId, displayName=$firstDisplayName',
    );

    // 保存当前通话信息
    _currentCallUserId = firstUserId;
    _currentCallDisplayName = firstDisplayName;
    _currentCallType = CallType.voice;
    _isInGroupCall = true; // 标记为群组通话
    _currentGroupCallId = _isCurrentChatGroup
        ? _currentChatUserId
        : null; // 如果从群聊发起，保存群组ID
    logger.debug('📞 已保存当前通话信息到状态变量');
    logger.debug('📞 群组通话标志: $_isInGroupCall, 群组ID: $_currentGroupCallId');

    // 调用服务器API发起群组通话
    logger.debug('📞 准备调用服务器API发起群组通话...');
    try {
      // 🔴 修复：确保 AgoraService 已初始化
      if (!FeatureConfig.enableWebRTC || _agoraService == null) {
        throw Exception('Agora 服务未启用');
      }

      // 🔴 修复：确保 Agora 已完成用户ID初始化
      if (_agoraService!.myUserId == null || _agoraService!.myUserId == 0) {
        logger.debug('📞 ⚠️ Agora 用户ID未初始化，重新初始化...');
        if (_currentUserId != null) {
          await _agoraService!.initialize(_currentUserId);
          logger.debug('📞 ✅ Agora 重新初始化完成，用户ID: ${_agoraService!.myUserId}');
        } else {
          throw Exception('当前用户ID为空，无法初始化 Agora 服务');
        }
      }

      logger.debug('📞 Agora 用户ID验证通过: ${_agoraService!.myUserId}');

      final userToken = await Storage.getToken();
      if (userToken == null) {
        throw Exception('用户未登录');
      }

      // 调用群组通话API
      logger.debug('🔍 [home_page] _currentGroupCallId: $_currentGroupCallId');
      logger.debug('🔍 [home_page] _selectedGroup?.id: ${_selectedGroup?.id}');
      logger.debug('🔍 [home_page] 准备调用 ApiService.initiateGroupCall，参数: calleeIds=$otherUserIds, callType=voice, groupId=$_currentGroupCallId');
      final callData = await ApiService.initiateGroupCall(
        token: userToken,
        calleeIds: otherUserIds, // 只传递其他成员的ID，不包括当前用户
        callType: 'voice',
        groupId: _currentGroupCallId, // 使用_currentGroupCallId而不是_selectedGroup?.id
      );
      logger.debug('🔍 [home_page] ApiService.initiateGroupCall 调用完成，返回数据: $callData');

      logger.debug('📞 服务器返回群组通话数据:');
      logger.debug('  - 频道名称: ${callData['channel_name']}');
      logger.debug('  - 成员数量: ${(callData['members'] as List).length}');

      // 设置 AgoraService 的频道信息（群组通话）
      logger.debug('📞 准备设置群组通话频道信息...');
      _agoraService!.setGroupCallChannel(
        callData['channel_name'],
        callData['token'],
        CallType.voice,
        groupId: _currentGroupCallId,
      );
      logger.debug('📞 ✅ 群组通话频道信息已设置（状态由VoiceCallPage管理）');

      // 🔴 发送群组通话发起消息
      if (_currentGroupCallId != null) {
        await _sendGroupCallInitiatedMessage(
          _currentGroupCallId!,
          CallType.voice,
        );
      }

      // 从服务器返回的成员信息中提取显示名称
      final serverMembers = (callData['members'] as List)
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();

      // 构建成员ID和显示名称列表（按服务器返回的顺序）
      final memberUserIds = serverMembers
          .map((m) => m['user_id'] as int)
          .toList();
      final memberDisplayNames = serverMembers.map((m) {
        // 对于当前用户，显示名称为"我"
        if (m['user_id'] == _currentUserId) {
          return '我';
        }
        return m['display_name'] as String;
      }).toList();

      // 为群组成员构建头像URL列表（PC端发起场景）
      final List<String?> memberAvatarUrls = [];
      try {
        final db = LocalDatabaseService();
        logger.debug('📞 [HomePage] 开始构建群组通话成员头像列表');
        logger.debug('📞 [HomePage] 成员数量: ${memberUserIds.length}, currentUserId: $_currentUserId');
        for (final uid in memberUserIds) {
          String? avatarUrl;
          if (uid == _currentUserId) {
            // 当前用户使用本地存储的头像
            avatarUrl = await Storage.getAvatar();
            logger.debug('📞 [HomePage] 成员$uid是当前用户，使用Storage头像: $avatarUrl');
          } else {
            final snapshot = await db.getContactSnapshot(
              ownerId: _currentUserId!,
              contactId: uid,
              contactType: 'user',
            );
            if (snapshot == null) {
              logger.debug('📞 [HomePage] 成员$uid在contact_snapshots中未找到记录，使用空头像');
            } else {
              logger.debug('📞 [HomePage] 成员$uid命中contact_snapshots，avatar=${snapshot['avatar']}');
            }
            avatarUrl = snapshot?['avatar']?.toString();
          }
          logger.debug('📞 [HomePage] 成员$uid最终使用头像: $avatarUrl');
          memberAvatarUrls.add(avatarUrl);
        }
        logger.debug('📞 [HomePage] 群组通话成员头像列表构建完成，长度: ${memberAvatarUrls.length}');
      } catch (e) {
        logger.debug('⚠️ [HomePage] 构建群组成员头像列表失败: $e');
        while (memberAvatarUrls.length < memberUserIds.length) {
          memberAvatarUrls.add(null);
        }
      }

      logger.debug('📞 最终成员列表:');
      logger.debug('  - 成员ID: $memberUserIds');
      logger.debug('  - 显示名称: $memberDisplayNames');

      // 使用 showDialog 显示通话页面
      logger.debug('📞 准备调用 showDialog 显示通话页面...');
      logger.debug('📞 VoiceCallPage 参数:');
      logger.debug('  - targetUserId: $firstUserId');
      logger.debug('  - targetDisplayName: $firstDisplayName');
      logger.debug('  - isIncoming: false');
      logger.debug('  - callType: ${CallType.voice}');
      logger.debug('  - groupCallUserIds: $memberUserIds');
      logger.debug('  - groupCallDisplayNames: $memberDisplayNames');
      logger.debug('  - currentUserId: $_currentUserId');

      logger.debug('📞 开始调用 showDialog...');
      // 设置标志：正在显示语音通话对话框
      setState(() {
        _isShowingVoiceCallDialog = true;
      });
      final result =
          await showDialog(
            context: context,
            barrierDismissible: true,
            builder: (context) {
              logger.debug('📞 [showDialog.builder] builder被调用');
              logger.debug('📞 [showDialog.builder] 准备创建 VoiceCallPage');
              final page = VoiceCallPage(
                targetUserId: firstUserId,
                targetDisplayName: firstDisplayName,
                isIncoming: false,
                callType: CallType.voice,
                // 传递服务器返回的所有成员（包括当前用户自己），用于界面显示
                groupCallUserIds: memberUserIds,
                groupCallDisplayNames: memberDisplayNames,
                groupCallAvatarUrls: memberAvatarUrls,
                currentUserId: _currentUserId,
                groupId: _currentChatUserId, // 传递群组ID
              );
              logger.debug('📞 [showDialog.builder] VoiceCallPage已创建，准备返回');
              return page;
            },
          ).then((value) {
            logger.debug('📞 [showDialog.then] showDialog返回，result: $value');
            // 清除标志：语音通话对话框已关闭
            setState(() {
              _isShowingVoiceCallDialog = false;
            });
            // 处理返回结果
            if (value is Map && value['callEnded'] == true) {
              logger.debug('📞 [showDialog.then] 通话已结束');
              return {'callEnded': true, 'callDuration': value['callDuration']};
            }
            if (value is Map && value['callRejected'] == true) {
              logger.debug('📞 [showDialog.then] 通话被拒绝');
              return {'callRejected': true};
            }
            if (value is Map && value['callCancelled'] == true) {
              logger.debug('📞 [showDialog.then] 通话被取消');
              return {'callCancelled': true};
            }
            if (value == null ||
                (value is Map && value['showFloatingButton'] != true)) {
              logger.debug('📞 [showDialog.then] 返回值为null或需要显示浮动按钮');
              return {'showFloatingButton': true};
            }
            logger.debug('📞 [showDialog.then] 直接返回值: $value');
            return value;
          });

      logger.debug('📞 showDialog调用完成，result: $result');

      // 处理返回结果
      logger.debug('📞 开始处理返回结果...');
      if (result is Map && result['showFloatingButton'] == true) {
        logger.debug('📞 设置显示浮动按钮');
        // 🔴 修复：从AgoraService中获取最小化通话的信息
        if (_agoraService != null && _agoraService!.isCallMinimized) {
          logger.debug('📱 从AgoraService获取最小化通话信息');
          setState(() {
            _showCallFloatingButton = true;
            _currentCallUserId = _agoraService!.minimizedCallUserId;
            _currentCallDisplayName = _agoraService!.minimizedCallDisplayName;
            _currentCallType = _agoraService!.minimizedCallType;
          });
          logger.debug('📱 已更新最小化按钮状态');
        } else {
          logger.debug('⚠️ AgoraService中没有最小化通话信息');
          setState(() {
            _showCallFloatingButton = true;
          });
        }
      } else       if (result is Map && result['callEnded'] == true) {
        final callDuration = result['callDuration'] as int? ?? 0;
        logger.debug('📞 群组通话已结束，时长: $callDuration 秒');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话结束后不重新加载消息，因为通话结束消息已通过WebSocket实时添加
        // 重新加载会导致服务器已删除的join_voice_button消息从列表中消失
        logger.debug('📞 群组通话结束，通话消息已通过WebSocket添加，无需重新加载');
      } else if (result is Map && result['callCancelled'] == true) {
        logger.debug('📞 群组通话已取消（对方未接听）');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话取消后不重新加载消息，避免覆盖内存中的消息
        logger.debug('📞 群组通话取消，消息已通过WebSocket处理，无需重新加载');
      } else if (result is Map && result['callRejected'] == true) {
        logger.debug('📞 群组通话被拒绝');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话拒绝后不重新加载消息，避免覆盖内存中的消息
        logger.debug('📞 群组通话拒绝，消息已通过WebSocket处理，无需重新加载');
      } else {
        logger.debug('📞 返回结果未匹配任何已知类型: $result');
      }

      logger.debug('📞 ========== _startGroupVoiceCall 正常结束 ==========');
    } catch (e, stackTrace) {
      logger.debug('📞 ========== _startGroupVoiceCall 异常 ==========');
      logger.debug('📞 ❌ 发起群组语音通话时出错: $e');
      logger.debug('📞 ❌ 堆栈跟踪: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发起群组语音通话失败: $e')));
      }
    }
  }

  // 显示群组视频通话成员选择弹窗
  Future<void> _showGroupVideoCallMemberPicker(
    RecentContactModel contact,
  ) async {
    if (!_isCurrentChatGroup || _currentChatUserId == null) {
      return;
    }

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 显示加载对话框
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // 获取群组详情
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: _currentChatUserId!,
      );

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0 && response['data'] != null) {
        // 🔐 权限检查：只有群主和管理员可以发起群组视频通话
        final memberRole = response['data']['member_role'] as String?;
        logger.debug('🔐 [群组视频通话权限检查] 当前用户角色: $memberRole');
        
        if (memberRole != 'owner' && memberRole != 'admin') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('只有群主和管理员可以发起群组视频通话'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          logger.debug('❌ [群组视频通话权限检查] 用户角色为 $memberRole，无权发起通话');
          return;
        }
        
        logger.debug('✅ [群组视频通话权限检查] 用户是 $memberRole，允许发起通话');

        final membersData = response['data']['members'] as List?;
        if (membersData == null || membersData.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('群组暂无成员')));
          }
          return;
        }

        // 转换为 GroupCallMember 列表（排除自己）
        final members = membersData
            .where((m) => m['user_id'] != _currentUserId)
            .map((m) {
              final fullName = m['full_name'] as String?;
              final username = m['username'] as String?;
              final avatar = m['avatar'] as String?;
              return GroupCallMember(
                userId: m['user_id'] as int,
                fullName: (fullName != null && fullName.isNotEmpty)
                    ? fullName
                    : 'Unknown',
                username: (username != null && username.isNotEmpty)
                    ? username
                    : 'unknown',
                avatar: avatar,
              );
            })
            .toList();

        if (members.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('群组暂无其他成员')));
          }
          return;
        }

        // 显示成员选择对话框
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (context) => GroupCallMemberPicker(
            members: members,
            currentUserId: _currentUserId,
            onConfirm: (selectedUserIds) async {
              logger.debug('🎯 [HomePage.onConfirm] 准备调用 _startGroupVideoCall');

              // 获取选中成员的显示名称
              final selectedDisplayNames = selectedUserIds.map((userId) {
                final member = members.firstWhere(
                  (m) => m.userId == userId,
                  orElse: () => GroupCallMember(
                    userId: userId,
                    fullName: 'Unknown',
                    username: 'unknown',
                  ),
                );
                return member.displayText;
              }).toList();

              await _startGroupVideoCall(selectedUserIds, selectedDisplayNames);
              logger.debug('🎯 [HomePage.onConfirm] _startGroupVideoCall 调用完成');
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] as String? ?? '获取群组成员失败'),
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('显示群组视频通话成员选择弹窗失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载群组成员失败: $e')));
      }
    }
  }

  // 发起群组视频通话
  Future<void> _startGroupVideoCall(
    List<int> userIds,
    List<String> displayNames,
  ) async {
    if (!mounted) {
      logger.debug('📹 ⚠️ 页面未mounted，直接返回');
      return;
    }

    // 检查WebRTC 功能是否启用
    if (!FeatureConfig.enableWebRTC) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视频通话功能未启用')));
      }
      return;
    }

    // 请求麦克风和摄像头权限
    final micStatus = await Permission.microphone.request();
    final cameraStatus = await Permission.camera.request();

    if (!micStatus.isGranted || !cameraStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('需要麦克风和摄像头权限才能进行视频通话')));
      }
      return;
    }

    // 过滤掉当前用户，只保留其他成员
    logger.debug('📹 开始过滤成员...');
    final otherUserIds = <int>[];
    final otherDisplayNames = <String>[];
    for (int i = 0; i < userIds.length; i++) {
      if (userIds[i] != _currentUserId) {
        otherUserIds.add(userIds[i]);
        if (i < displayNames.length) {
          otherDisplayNames.add(displayNames[i]);
        }
      }
    }

    logger.debug('📹 过滤后的成员:');
    logger.debug('  - 其他成员数量: ${otherUserIds.length}');
    logger.debug('  - 其他成员ID列表: $otherUserIds');
    logger.debug('  - 其他成员名称列表: $otherDisplayNames');

    if (otherUserIds.isEmpty) {
      logger.debug('📹 ⚠️ 没有其他成员，无法发起群组视频通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有可通话的成员')));
      }
      return;
    }

    try {
      // 保存当前通话信息
      logger.debug('📹 保存当前通话信息前:');
      logger.debug('  - _currentCallUserId: $_currentCallUserId');
      logger.debug('  - _currentCallDisplayName: $_currentCallDisplayName');
      logger.debug('  - _currentCallType: $_currentCallType');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');

      _currentCallUserId = otherUserIds.first; // 使用第一个成员作为主要通话对象
      _currentCallDisplayName = otherDisplayNames.first;
      _currentCallType = CallType.video;
      _isInGroupCall = true; // 标记为群组通话
      _currentGroupCallId = _isCurrentChatGroup
          ? _currentChatUserId
          : null; // 如果从群聊发起，保存群组ID

      logger.debug('📹 保存当前通话信息后:');
      logger.debug('  - 群组通话标志: $_isInGroupCall, 群组ID: $_currentGroupCallId');
      logger.debug('  - _currentCallUserId: $_currentCallUserId');
      logger.debug('  - _currentCallDisplayName: $_currentCallDisplayName');
      logger.debug('  - _currentCallType: $_currentCallType');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');

      logger.debug('📹 准备打开群组视频通话页面，传递参数:');
      logger.debug('  - targetUserId: ${otherUserIds.first}');
      logger.debug('  - targetDisplayName: ${otherDisplayNames.first}');
      logger.debug('  - isIncoming: false');
      logger.debug('  - callType: CallType.video');
      logger.debug('  - groupCallUserIds: $otherUserIds');
      logger.debug('  - groupCallDisplayNames: $otherDisplayNames');
      logger.debug('  - currentUserId: $_currentUserId');
      logger.debug('  - groupId: $_currentChatUserId');

      // 在导航前设置悬浮按钮状态，防止窗口失去焦点时通话页面被关闭
      logger.debug('📹 导航到 GroupVideoCallPage 前:');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');
      logger.debug('  - mounted: $mounted');

      // 设置悬浮按钮状态，防止窗口失去焦点时通话页面被关闭
      setState(() {
        _showCallFloatingButton = true;
        _floatingButtonX = 0;
        _floatingButtonY = 0;
      });
      logger.debug(
        '📹 导航前已设置 _showCallFloatingButton: $_showCallFloatingButton',
      );

      // 先发起群组通话API调用
      logger.debug('📹 发起群组视频通话API调用...');

      // 🔴 修复：确保 AgoraService 已初始化
      if (!FeatureConfig.enableWebRTC || _agoraService == null) {
        throw Exception('Agora 服务未启用');
      }

      // 🔴 修复：确保 Agora 已完成用户ID初始化
      if (_agoraService!.myUserId == null || _agoraService!.myUserId == 0) {
        logger.debug('📹 ⚠️ Agora 用户ID未初始化，重新初始化...');
        if (_currentUserId != null) {
          await _agoraService!.initialize(_currentUserId);
          logger.debug('📹 ✅ Agora 重新初始化完成，用户ID: ${_agoraService!.myUserId}');
        } else {
          throw Exception('当前用户ID为空，无法初始化 Agora 服务');
        }
      }

      logger.debug('📹 Agora 用户ID验证通过: ${_agoraService!.myUserId}');

      final userToken = await Storage.getToken();
      if (userToken == null) {
        logger.debug('📹 ⚠️ 用户token为空，无法发起群组视频通话');
        return;
      }

      logger.debug('🔍 [home_page] 准备调用 ApiService.initiateGroupCall，参数: calleeIds=$otherUserIds, callType=video, groupId=$_currentGroupCallId');
      final callData = await ApiService.initiateGroupCall(
        token: userToken,
        calleeIds: otherUserIds, // 只传递其他成员的ID，不包括当前用户
        callType: 'video',
        groupId: _currentGroupCallId, // 使用_currentGroupCallId而不是_selectedGroup?.id
      );
      logger.debug('🔍 [home_page] ApiService.initiateGroupCall 调用完成，返回数据: $callData');

      logger.debug('📹 服务器返回群组通话数据:');
      logger.debug('  - 频道名称: ${callData['channel_name']}');
      logger.debug('  - 成员数量: ${(callData['members'] as List).length}');

      // 设置 AgoraService 的频道信息（群组通话）
      _agoraService!.setGroupCallChannel(
        callData['channel_name'],
        callData['token'],
        CallType.video,
        groupId: _currentGroupCallId,
      );
      logger.debug('📹 ✅ 群组视频通话频道信息已设置');

      // 🔴 发送群组通话发起消息
      if (_currentGroupCallId != null) {
        await _sendGroupCallInitiatedMessage(
          _currentGroupCallId!,
          CallType.video,
        );
      }

      // 从服务器返回的成员信息中提取显示名称
      final serverMembers = (callData['members'] as List)
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();

      // 构建成员ID和显示名称列表（按服务器返回的顺序）
      final memberUserIds = serverMembers
          .map((m) => m['user_id'] as int)
          .toList();
      final memberDisplayNames = serverMembers.map((m) {
        // 对于当前用户，显示名称为"我"
        if (m['user_id'] == _currentUserId) {
          return '我';
        }
        return m['display_name'] as String;
      }).toList();

      logger.debug('📹 最终成员列表:');
      logger.debug('  - 成员ID: $memberUserIds');
      logger.debug('  - 显示名称: $memberDisplayNames');

      final result = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => GroupVideoCallPage(
            targetUserId: otherUserIds.first,
            targetDisplayName: otherDisplayNames.first,
            isIncoming: false,
            groupCallUserIds: memberUserIds, // 使用服务器返回的成员列表
            groupCallDisplayNames: memberDisplayNames, // 使用服务器返回的显示名称
            currentUserId: _currentUserId,
            groupId: _currentChatUserId,
          ),
        ),
      );

      logger.debug('📹 从 GroupVideoCallPage 返回后:');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');
      logger.debug('  - mounted: $mounted');

      // 处理返回结果
      logger.debug('📹 开始处理返回结果...');
      logger.debug('📹 返回结果类型: ${result.runtimeType}');
      logger.debug('📹 返回结果内容: $result');

      if (result is Map && result['showFloatingButton'] == true) {
        logger.debug('📹 通话页面要求显示悬浮按钮（用户最小化了通话）');
        // 悬浮按钮已经在导航前设置为true，这里只需要确认状态
        logger.debug('📹 当前 _showCallFloatingButton: $_showCallFloatingButton');
      } else       if (result is Map && result['callEnded'] == true) {
        final callDuration = result['callDuration'] as int? ?? 0;
        logger.debug('📹 群组视频通话已结束，时长: $callDuration 秒');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话结束后不重新加载消息，因为通话结束消息已通过WebSocket实时添加
        logger.debug('📹 群组视频通话结束，通话消息已通过WebSocket添加，无需重新加载');
      } else if (result is Map && result['callCancelled'] == true) {
        logger.debug('📹 群组视频通话已取消（对方未接听）');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话取消后不重新加载消息，避免覆盖内存中的消息
        logger.debug('📹 群组视频通话取消，消息已通过WebSocket处理，无需重新加载');
      } else if (result is Map && result['callRejected'] == true) {
        logger.debug('📹 群组视频通话被拒绝');
        setState(() {
          _showCallFloatingButton = false;
        });
        
        // 🔴 修复：通话拒绝后不重新加载消息，避免覆盖内存中的消息
        logger.debug('📹 群组视频通话拒绝，消息已通过WebSocket处理，无需重新加载');
      } else {
        logger.debug('📹 返回结果未匹配任何已知类型: $result');
        logger.debug('📹 可能是页面被意外关闭，保持当前状态');
        logger.debug('📹 当前 _showCallFloatingButton: $_showCallFloatingButton');
      }

      // 清理通话信息
      logger.debug('📹 清理通话信息前:');
      logger.debug('  - _currentCallUserId: $_currentCallUserId');
      logger.debug('  - _currentCallDisplayName: $_currentCallDisplayName');
      logger.debug('  - _currentCallType: $_currentCallType');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');

      if (mounted) {
        _currentCallUserId = null;
        _currentCallDisplayName = null;
        _currentCallType = null;
      }

      logger.debug('📹 清理通话信息后:');
      logger.debug('  - _currentCallUserId: $_currentCallUserId');
      logger.debug('  - _currentCallDisplayName: $_currentCallDisplayName');
      logger.debug('  - _currentCallType: $_currentCallType');
      logger.debug('  - _showCallFloatingButton: $_showCallFloatingButton');
      logger.debug('  - _floatingButtonX: $_floatingButtonX');
      logger.debug('  - _floatingButtonY: $_floatingButtonY');

      logger.debug('📹 ========== _startGroupVideoCall 正常结束 ==========');
    } catch (e, stackTrace) {
      logger.debug('📹 ========== _startGroupVideoCall 异常 ==========');
      logger.debug('📹 ❌ 发起群组视频通话时出错: $e');
      logger.debug('📹 ❌ 堆栈跟踪: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发起群组视频通话失败: $e')));
      }
    }
  }

  // 发起语音通话
  Future<void> _startVoiceCall(RecentContactModel contact) async {
    // 调试信息：打印联系人信息
    logger.debug('📞 准备发起语音通话:');
    logger.debug('  - 联系人类 ${contact.type}');
    logger.debug('  - 联系userId: ${contact.userId}');
    logger.debug('  - 联系username: ${contact.username}');
    logger.debug('  - 联系人显示名: ${contact.displayName}');
    logger.debug('  - 当前用户 ID: $_currentUserId');

    // 检查是否在给自己打电话
    if (contact.userId == _currentUserId) {
      logger.debug('检测到联系userId 等于当前用户 ID，阻止通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('不能给自己打电话')));
      }
      return;
    }

    // 🔴 检查好友关系（前端限制）
    final contactModel = _contacts.firstWhere(
      (c) => c.friendId == contact.userId,
      orElse: () => ContactModel(
        relationId: 0,
        userId: 0,
        friendId: contact.userId,
        username: contact.username,
        avatar: '',
        status: 'offline',
        createdAt: DateTime.now(),
        isDeleted: true, // 默认标记为已删除（找不到联系人）
      ),
    );

    // 检查是否被删除
    if (contactModel.isDeleted) {
      logger.debug('📞 ⚠️ 该联系人已被删除，无法发起语音通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(
          content: Text('该联系人已被删除，无法发起通话'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    // 检查是否被拉黑
    if (contactModel.isBlocked || contactModel.isBlockedByMe) {
      logger.debug('📞 ⚠️ 该联系人已被拉黑，无法发起语音通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(
          content: Text('该联系人已被拉黑，无法发起通话'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    // 检WebRTC 功能是否启用
    if (!FeatureConfig.enableWebRTC) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('语音通话功能未启用')));
      }
      return;
    }

    // 请求麦克风权
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('需要麦克风权限才能进行语音通话')));
      }
      return;
    }

    // 导航到通话页面
    if (mounted) {
      // 保存当前通话信息
      _currentCallUserId = contact.userId;
      _currentCallDisplayName = contact.displayName;
      _currentCallType = CallType.voice;

      // 在进入通话页面前，尽量获取最新头像
      String? avatarForCall = contact.avatar;
      try {
        final token = await Storage.getToken();
        if (token != null && token.isNotEmpty) {
          final userInfo = await ApiService.getUserInfo(
            contact.userId,
            token: token,
          );
          if (userInfo['code'] == 0) {
            final data = userInfo['data'];
            final serverAvatar = data['avatar']?.toString();
            logger.debug('📞 [_startVoiceCall] getUserInfo 返回头像: $serverAvatar');
            if (serverAvatar != null && serverAvatar.isNotEmpty) {
              avatarForCall = serverAvatar;
            }
          }
        }
      } catch (e) {
        logger.debug('📞 [_startVoiceCall] 获取用户头像用于语音通话时出错: $e');
      }

      // 使用 showDialog 显示通话页面，点击外部区域时最小化而不是关闭
      // 设置标志：正在显示语音通话对话框
      setState(() {
        _isShowingVoiceCallDialog = true;
      });
      final result =
          await showDialog(
            context: context,
            barrierDismissible: true, // 允许点击外部区域关闭
            builder: (context) => VoiceCallPage(
              targetUserId: contact.userId,
              targetDisplayName: contact.displayName,
              targetAvatar: avatarForCall,
              isIncoming: false,
              callType: CallType.voice,
              currentUserId: _currentUserId, // 🔴 修复：传递当前用户ID
            ),
          ).then((value) {
            // 清除标志：语音通话对话框已关闭
            setState(() {
              _isShowingVoiceCallDialog = false;
            });
            // 如果通话已结束，不显示悬浮按钮
            if (value is Map && value['callEnded'] == true) {
              return {'callEnded': true, 'callDuration': value['callDuration']};
            }
            // 如果通话被拒绝，返回拒绝状态
            if (value is Map && value['callRejected'] == true) {
              return {'callRejected': true};
            }
            // 如果通话被取消，返回取消状态
            if (value is Map && value['callCancelled'] == true) {
              return {'callCancelled': true};
            }
            // 当对话框被关闭时（无论是通过点击外部区域还是其他方式），
            // 如果通话还在进行中，返回结果要求显示悬浮按钮
            if (value == null ||
                (value is Map && value['showFloatingButton'] != true)) {
              // 如果 VoiceCallPage 没有返回 showFloatingButton，说明可能是点击外部区域关闭的
              // 此时应该显示悬浮按钮（最小化）
              return {'showFloatingButton': true};
            }
            return value;
          });

      // 如果返回结果要求显示悬浮按钮
      if (result is Map && result['showFloatingButton'] == true) {
        setState(() {
          _showCallFloatingButton = true;
          // 重置悬浮按钮位置（设为0，下次build时会自动计算默认位置）
          _floatingButtonX = 0;
          _floatingButtonY = 0;
        });
        logger.debug('📱 显示通话悬浮按钮');
      } else {
        // 通话正常结束，清除状态
        setState(() {
          _showCallFloatingButton = false;
        });

        // 🔴 修复：移除重复的消息发送，消息已在 onCallEnded 回调中统一发送
        // 通话结束消息会在 onCallEnded 回调中发送，这里只需处理状态
        // if (result is Map && result['callEnded'] == true) {
        //   final callDuration = result['callDuration'] as int? ?? 0;
        //   await _sendCallEndedMessage(contact.userId, callDuration);
        // }

        // 如果通话被拒绝，发送通话拒绝消息（发起方收到拒绝通知，显示"对方已拒绝"）
        if (result is Map && result['callRejected'] == true) {
          // 从返回值中获取通话类型
          final returnedCallType = result['callType'] as CallType?;
          if (returnedCallType != null) {
            _currentCallType = returnedCallType;
          }
          await _sendCallRejectedMessage(contact.userId, isRejecter: false);
        }
        // 如果通话被取消，发送通话取消消息（发起方取消，显示"已取消"）
        else if (result is Map && result['callCancelled'] == true) {
          // 从返回值中获取通话类型
          final returnedCallType = result['callType'] as CallType?;
          if (returnedCallType != null) {
            _currentCallType = returnedCallType;
          }
          await _sendCallCancelledMessage(contact.userId, isCaller: true);
        }
      }
    }
  }

  // 发起视频通话
  Future<void> _startVideoCall(RecentContactModel contact) async {
    // 调试信息：打印联系人信息
    logger.debug('📹 ========== 点击视频通话按钮 ==========');
    logger.debug('📹 准备发起视频通话:');
    logger.debug('  - 联系人类型: ${contact.type}');
    logger.debug('  - 联系人userId: ${contact.userId}');
    logger.debug('  - 联系人username: ${contact.username}');
    logger.debug('  - 联系人显示名: ${contact.displayName}');
    logger.debug('  - 当前用户 ID: $_currentUserId');

    // 检查是否在给自己打电话
    if (contact.userId == _currentUserId) {
      logger.debug('检测到联系userId 等于当前用户 ID，阻止通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('不能给自己打电话')));
      }
      return;
    }

    // 🔴 检查好友关系（前端限制）
    final contactModel = _contacts.firstWhere(
      (c) => c.friendId == contact.userId,
      orElse: () => ContactModel(
        relationId: 0,
        userId: 0,
        friendId: contact.userId,
        username: contact.username,
        avatar: '',
        status: 'offline',
        createdAt: DateTime.now(),
        isDeleted: true, // 默认标记为已删除（找不到联系人）
      ),
    );

    // 检查是否被删除
    if (contactModel.isDeleted) {
      logger.debug('📹 ⚠️ 该联系人已被删除，无法发起视频通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(
          content: Text('该联系人已被删除，无法发起通话'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    // 检查是否被拉黑
    if (contactModel.isBlocked || contactModel.isBlockedByMe) {
      logger.debug('📹 ⚠️ 该联系人已被拉黑，无法发起视频通话');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(
          content: Text('该联系人已被拉黑，无法发起通话'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    // 检WebRTC 功能是否启用
    if (!FeatureConfig.enableWebRTC) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视频通话功能未启用')));
      }
      return;
    }

    // 请求麦克风和摄像头权
    final micStatus = await Permission.microphone.request();
    final cameraStatus = await Permission.camera.request();

    if (!micStatus.isGranted || !cameraStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('需要麦克风和摄像头权限才能进行视频通话')));
      }
      return;
    }

    // 导航到通话页面
    if (mounted) {
      // 保存当前通话信息
      _currentCallUserId = contact.userId;
      _currentCallDisplayName = contact.displayName;
      _currentCallType = CallType.video;

      // 📝 日志：打印即将传递的参数
      logger.debug('📹 准备打开通话页面，传递参数:');
      logger.debug('  - targetUserId: ${contact.userId}');
      logger.debug('  - targetDisplayName: ${contact.displayName}');
      logger.debug('  - isIncoming: false');
      logger.debug('  - callType: CallType.video');
      logger.debug('  - _currentCallType 已设置为: $_currentCallType');

      final result = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => VoiceCallPage(
            targetUserId: contact.userId,
            targetDisplayName: contact.displayName,
            isIncoming: false,
            callType: CallType.video,
            currentUserId: _currentUserId, // 🔴 修复：传递当前用户ID
          ),
        ),
      );

      // 如果返回结果要求显示悬浮按钮
      if (result is Map && result['showFloatingButton'] == true) {
        setState(() {
          _showCallFloatingButton = true;
          // 重置悬浮按钮位置（设为0，下次build时会自动计算默认位置）
          _floatingButtonX = 0;
          _floatingButtonY = 0;
        });
        logger.debug('📱 显示通话悬浮按钮');
      } else {
        // 通话正常结束，清除状态
        setState(() {
          _showCallFloatingButton = false;
        });

        // 🔴 修复：移除重复的消息发送，消息已在 onCallEnded 回调中统一发送
        // 通话结束消息会在 onCallEnded 回调中发送，这里只需处理状态
        // if (result is Map && result['callEnded'] == true) {
        //   final callDuration = result['callDuration'] as int? ?? 0;
        //   await _sendCallEndedMessage(contact.userId, callDuration);
        // }

        // 如果通话被拒绝，发送通话拒绝消息（发起方收到拒绝通知，显示"对方已拒绝"）
        if (result is Map && result['callRejected'] == true) {
          await _sendCallRejectedMessage(contact.userId, isRejecter: false);
        }
        // 如果通话被取消，发送通话取消消息（发起方取消，显示"已取消"）
        else if (result is Map && result['callCancelled'] == true) {
          await _sendCallCancelledMessage(contact.userId, isCaller: true);
        }
      }
    }
  }

  // 更新筛选后的消息列
  void _updateFilteredMessages() {
    setState(() {
      List<MessageModel> tempMessages;

      // 第一步：根据标签筛
      if (_selectedFilterTab == 0) {
        // 全部消息
        tempMessages = List.from(_messages);
      } else if (_selectedFilterTab == 1) {
        // 仅文件类型的消息
        tempMessages = _messages
            .where(
              (msg) =>
                  msg.messageType == 'image' ||
                  msg.messageType == 'file' ||
                  msg.messageType == 'video',
            )
            .toList();
      } else {
        tempMessages = List.from(_messages);
      }

      // 第二步：根据搜索关键字筛
      if (_messageSearchKeyword.isNotEmpty) {
        final keyword = _messageSearchKeyword.toLowerCase();
        _filteredMessages = tempMessages.where((msg) {
          // 搜索消息内容
          if (msg.content.toLowerCase().contains(keyword)) {
            return true;
          }
          // 搜索发送者名
          if (msg.senderName.toLowerCase().contains(keyword)) {
            return true;
          }
          return false;
        }).toList();
      } else {
        _filteredMessages = tempMessages;
      }
    });
  }

  // 处理WebSocket消息
  void _handleWebSocketMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;

    logger.debug('🖥️ [PC端] 收到WebSocket消息 - 类型: $type, 数据: ${message['data']}');

    switch (type) {
      case 'message':
        // 接收到新消息
        _handleNewMessage(message['data']);
        break;
      case 'offline_messages':
        // 接收到离线消息列
        final offlineMsgs = message['data'] as List<dynamic>?;
        logger.debug('📨 [诊断] 收到离线私聊消息: ${offlineMsgs?.length ?? 0} 条');
        if (offlineMsgs != null && offlineMsgs.isNotEmpty) {
          logger.debug('📨 [诊断] 第一条离线消息: ${offlineMsgs.first}');
          logger.debug('⚠️ [诊断] 离线消息未处理，将不会保存到本地数据库');
        }
        // TODO: 批量显示离线消息
        break;
      case 'offline_group_messages':
        // 接收到离线群组消息
        final groupData = message['data'] as Map<String, dynamic>?;
        final groupId = groupData?['group_id'];
        final groupMsgs = groupData?['messages'] as List<dynamic>?;
        logger.debug('📨 [诊断] 收到群组 $groupId 的离线消息: ${groupMsgs?.length ?? 0} 条');
        if (groupMsgs != null && groupMsgs.isNotEmpty) {
          logger.debug('📨 [诊断] 第一条群组离线消息: ${groupMsgs.first}');
          logger.debug('⚠️ [诊断] 群组离线消息未处理，将不会保存到本地数据库');
        }
        break;
      case 'message_sent':
        // 消息发送成功确
        logger.debug('消息发送成 ${message['data']}');
        // 可以用真实的消息ID更新临时消息
        _handleMessageSentConfirmation(message['data']);
        break;
      case 'status_change':
        // 接收到联系人状态变更消
        _handleStatusChange(message['data']);
        break;
      case 'online_notification':
        // 接收到联系人上线通知
        _handleOnlineNotification(message['data']);
        break;
      case 'offline_notification':
        // 接收到联系人离线通知
        _handleOfflineNotification(message['data']);
        break;
      case 'status_change_success':
        // 状态变更成功确
        logger.debug('状态变更成 ${message['data']}');
        break;
      case 'status_change_error':
        // 状态变更失
        logger.debug('状态变更失 ${message['data']}');
        break;
      case 'message_recalled':
        // 消息被撤
        _handleMessageRecalled(message['data']);
        break;
      case 'group_message':
        // 接收到群组消
        _handleGroupMessage(message);
        break;
      case 'delete_message':
        // 收到删除消息通知
        _handleDeleteMessageNotification(message['data']);
        break;
      case 'group_call_notification':
        // 接收到群组通话通知
        _handleGroupCallNotification(message['data']);
        break;
      case 'group_call_member_left':
        // 接收到群组通话成员离开通知
        _handleGroupCallMemberLeft(message['data']);
        break;
      case 'group_message_sent':
        // 群组消息发送成功确认
        logger.debug('群组消息发送成功确认: ${message['data']}');
        _handleGroupMessageSentConfirmation(message['data']);
        break;
      case 'group_message_error':
        // 群组消息发送错误
        _handleGroupMessageError(message['data']);
        break;
      case 'message_error':
        // 私聊消息发送错误（如被拉黑、被删除等）
        _handleMessageError(message['data']);
        break;
      case 'avatar_updated':
        // 用户头像更新通知
        _handleAvatarUpdated(message['data']);
        break;
      case 'group_info_updated':
        // 群组信息更新通知
        _handleGroupInfoUpdated(message['data']);
        break;
      case 'group_nickname_updated':
        // 群组昵称更新通知
        _handleGroupNicknameUpdated(message['data']);
        break;
      case 'contact_request':
        // 接收到联系人请求通知
        unawaited(_handleContactRequest(message['data']));
        break;
      case 'contact_status_changed':
        // 收到联系人状态变更通知（审核通过/拒绝）
        unawaited(_handleContactStatusChanged(message['data']));
        break;
      case 'typing_indicator':
        // 接收到正在输入指示器
        _handleTypingIndicator(message['data']);
        break;
      case 'pending_group_member':
        // 接收到待审核群成员通知
        _handlePendingGroupMemberNotification(message['data']);
        break;
      case 'contact_blocked':
        // 接收到被拉黑通知
        _handleContactBlocked(message['data']);
        break;
      case 'contact_deleted':
        // 接收到被删除通知
        _handleContactDeleted(message['data']);
        break;
      case 'contact_unblocked':
        // 接收到被恢复通知
        _handleContactUnblocked(message['data']);
        break;
      case 'read_receipt':
        // 🔴 修复：接收到已读回执
        _handleReadReceipt(message['data']);
        break;
      default:
        logger.debug('未知消息类型: $type');
    }
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
    bool isGroup = false,
    int? contactId,
  }) async {
    // 🚫 PC端新消息弹窗已屏蔽 - 如需启用请移除下面的return语句
    return;
    
    try {
      // 检查是否开启了新消息弹窗
      final popupEnabled = await Storage.getNewMessagePopupEnabled();
      if (!popupEnabled) {
        logger.debug('🔇 新消息弹窗已关闭，不显示');
        return;
      }

      // 检查widget是否还在树中
      if (!mounted) return;

      // 显示弹窗
      MessageNotificationPopup.show(
        context: context,
        title: title,
        message: message,
        avatar: avatar,
        isGroup: isGroup,
        onTap: () {
          // 点击弹窗后跳转到对应的聊天页面
          if (contactId != null) {
            if (isGroup) {
              // 跳转到群聊
              _openGroupChat(contactId);
            } else {
              // 跳转到私聊
              _openPrivateChat(contactId);
            }
          }
        },
      );

      logger.debug('🔔 显示消息通知弹窗: $title - $message');
    } catch (e) {
      logger.error('显示消息通知弹窗失败: $e');
    }
  }

  // 打开私聊页面
  void _openPrivateChat(int userId) {
    try {
      // 直接加载该用户的聊天记录
      _loadMessageHistory(userId, isGroup: false);
    } catch (e) {
      logger.error('打开私聊页面失败: $e');
    }
  }

  // 打开群聊页面
  void _openGroupChat(int groupId) {
    try {
      // 直接加载该群组的聊天记录
      _loadMessageHistory(groupId, isGroup: true);
    } catch (e) {
      logger.error('打开群聊页面失败: $e');
    }
  }

  // 处理接收到的新消息
  Future<void> _handleNewMessage(dynamic data) async {
    try {
      if (data == null) return;

      // 检widget 是否还在树中
      if (!mounted) return;

      final messageData = data as Map<String, dynamic>;
      final senderId = messageData['sender_id'] as int?;
      final receiverId = messageData['receiver_id'] as int?;
      final senderAvatar = messageData['sender_avatar'] as String?;
      final receiverAvatar = messageData['receiver_avatar'] as String?;
      final content = messageData['content'] as String?;
      final messageType = messageData['message_type'] as String? ?? 'text';
      final fileName = messageData['file_name'] as String?;
      final quotedMessageId = messageData['quoted_message_id'] as int?;
      final quotedMessageContent =
          messageData['quoted_message_content'] as String?;
      final createdAt = messageData['created_at'] as String?;

      logger.debug('');
      logger.debug('============ [前端消息路由] 收到新消============');
      logger.debug('📩 发送者ID: $senderId');
      logger.debug('📩 接收者ID: $receiverId');
      logger.debug('📩 当前用户ID: $_currentUserId');
      logger.debug('📩 当前聊天用户ID: $_currentChatUserId');
      logger.debug('📩 消息类型: $messageType');
      logger.debug('📩 内容: $content');
      if (fileName != null) {
        logger.debug('📎 文件 $fileName');
      }
      if (quotedMessageId != null) {
        logger.debug(
          '💬 引用消息ID: $quotedMessageId, 引用内容: $quotedMessageContent',
        );
      }
      logger.debug('==================================================');
      logger.debug('');

      if (senderId == null || content == null) {
        logger.debug('消息数据不完整');
        return;
      }

      // 检查并恢复被删除的会话（等待完成，确保恢复后再处理消息）
      final restored = await _checkAndRestoreDeletedChat(isGroup: false, id: senderId);
      if (restored) {
        logger.debug('✅ 会话已恢复并重新加载，现在继续处理当前消息以确保显示在列表中');
        // 播放新消息提示音
        if (senderId != _currentUserId) {
          _playNewMessageSound();
        }
        // 🔴 不再直接返回，继续处理当前消息，确保消息能正确显示在最近联系人列表中
      }

      // 判断消息是否来自当前正在聊天的联系人
      if (_currentChatUserId != null && senderId == _currentChatUserId) {
        // 🔴 修复：过滤掉对方推送的通话结束消息
        // 因为本地已经创建了通话结束消息，不需要显示对方推送的
        final isCallEndedMessage =
            messageType == 'call_ended' || messageType == 'call_ended_video';

        if (isCallEndedMessage) {
          // logger.debug('📞 过滤对方推送的通话结束消息: $messageType, 内容: $content');
          // 虽然不显示在消息列表，但仍需要更新最近联系人列表
          setState(() {
            final contactIndex = _recentContacts.indexWhere(
              (contact) => !contact.isGroup && contact.userId == senderId,
            );

            if (contactIndex != -1) {
              final formattedMessage = _formatMessagePreviewForRecentContact(
                messageType,
                content,
              );
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    lastMessage: formattedMessage,
                    lastMessageTime:
                        createdAt ?? DateTime.now().toIso8601String(),
                  );

              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);

                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }
            }
          });

          // 自动标记为已读（因为用户正在查看这个聊天窗口）
          _markMessagesAsRead(senderId);
          // logger.debug('✅ 已过滤通话结束消息但仍标记为已读: $content');

          return; // 不添加到消息列表
        }

        // 创建消息模型（使用fromJson自动解析所有字段）
        final newMessage = MessageModel.fromJson(messageData);

        // 添加到消息列表
        setState(() {
          _messages.add(newMessage);

          // 同时更新最近联系人列表中的最后消息和最后消息时间
          final contactIndex = _recentContacts.indexWhere(
            (contact) => !contact.isGroup && contact.userId == senderId,
          );

          if (contactIndex != -1) {
            // 更新最后消息和最后消息时间（不增加未读数，因为用户正在查看）
            // 根据消息类型格式化显示内容
            final formattedMessage = _formatMessagePreviewForRecentContact(
              messageType,
              content,
            );
            
            // 🔴 如果消息内容是【已通过】或【已驳回】，将联系人状态标记为在线
            String? updatedStatus;
            if (content == '【已通过】' || content == '【已驳回】') {
              updatedStatus = 'online';
              logger.debug('🟢 收到审核结果消息，将联系人 $senderId 状态标记为在线');
            }
            
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(
                  lastMessage: formattedMessage,
                  lastMessageTime:
                      createdAt ?? DateTime.now().toIso8601String(),
                  status: updatedStatus, // 如果是审核消息，更新状态
                  avatar: senderAvatar, // 更新发送者头像
                );

            // 将该联系人移到列表顶部（保持最新消息在顶部）
            if (contactIndex != 0) {
              final contact = _recentContacts.removeAt(contactIndex);
              _recentContacts.insert(0, contact);

              // 如果移动的是当前选中的联系人，更新索引
              if (_selectedChatIndex == contactIndex) {
                _selectedChatIndex = 0;
              } else if (_selectedChatIndex < contactIndex) {
                // 如果当前选中的在被移动项之前，索引需要加1
                _selectedChatIndex++;
              }
            }

            logger.debug('✅ 已更新最近联系人列表中的私聊最后消息');
          }
        });

        // 收到新消息，重新启用自动滚动定时器
        if (_isUserScrolling) {
          logger.debug('📜 收到新消息，重新启用自动滚动');
          _isUserScrolling = false;
          _lastScrollPosition = 0.0; // 重置滚动位置记录
        }

        // 滚动到底部
        _scrollToBottom();

        // 自动标记为已读（因为用户正在查看这个聊天窗口）
        _markMessagesAsRead(senderId);

        // 检查是否需要自动下载文件
        _autoDownloadFileIfNeeded(newMessage);

        logger.debug('✅ 收到并显示新消息: $content，已自动标记为已读');
      } else {
        // 消息来自其他联系人或者还没打开聊天窗口，更新最近联系人列表
        logger.debug('💬 收到其他联系人的消息，发送者ID: $senderId，更新最近联系人列表');

        // 检查是否是自己发送的消息
        bool isSelfMessage = senderId == _currentUserId;
        if (isSelfMessage) {
          logger.debug('✅ 收到自己发送的私聊消息，不增加未读计数，不播放提示音');

          // 先检查联系人是否在列表中（查找接收者，因为最近联系人列表显示的是对方信息）
          final contactIndex = _recentContacts.indexWhere(
            (contact) => !contact.isGroup && contact.userId == receiverId,
          );

          if (contactIndex != -1) {
            // 联系人在列表中，只更新最后消息和时间，不增加未读数
            setState(() {
              // 根据消息类型格式化显示内容
              final formattedMessage = _formatMessagePreviewForRecentContact(
                messageType,
                content,
              );
              
              // 🔴 如果消息内容是【已通过】或【已驳回】，将联系人状态标记为在线
              String? updatedStatus;
              if (content == '【已通过】' || content == '【已驳回】') {
                updatedStatus = 'online';
                logger.debug('🟢 收到审核结果消息（自己发送），将联系人 $receiverId 状态标记为在线');
              }
              
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    lastMessage: formattedMessage,
                    lastMessageTime:
                        createdAt ?? DateTime.now().toIso8601String(),
                    status: updatedStatus, // 如果是审核消息，更新状态
                    avatar: receiverAvatar, // 更新接收者头像
                  );

              // 将该联系人移到列表顶部
              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);

                // 如果移动的是当前选中的联系人，更新索引
                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }

              logger.debug('✅ 已更新自己发送的私聊消息');
            });
          } else {
            // 联系人不在列表中，创建新的联系人条目并添加到列表顶部
            logger.debug('⚠️ 联系人不在最近联系人列表中，创建新条目');
            
            // 获取接收者信息
            if (receiverId == null) {
              logger.debug('⚠️ 接收者ID为null，无法创建联系人条目');
              return;
            }
            final senderName = messageData['sender_name'] as String? ?? '未知用户';
            final receiverName = messageData['receiver_name'] as String? ?? '未知用户';
            
            setState(() {
              final formattedMessage = _formatMessagePreviewForRecentContact(
                messageType,
                content,
              );
              
              // 创建新的联系人条目
              final newContact = RecentContactModel(
                type: 'user', // 明确指定为用户类型
                userId: receiverId,
                username: receiverName,
                fullName: receiverName,
                avatar: receiverAvatar,
                lastMessage: formattedMessage,
                lastMessageTime: createdAt ?? DateTime.now().toIso8601String(),
                unreadCount: 0, // 自己发送的消息，未读数为0
                status: 'offline',
              );
              
              // 添加到列表顶部
              _recentContacts.insert(0, newContact);
              
              // 更新选中索引
              if (_selectedChatIndex >= 0) {
                _selectedChatIndex++;
              }
              
              logger.debug('✅ 已创建新的联系人条目并添加到列表');
            });
          }

          // 自己发送的消息处理完成，直接返回，不播放提示音
          return;
        }

        // 先检查联系人是否在列表中
        final contactIndex = _recentContacts.indexWhere(
          (contact) => !contact.isGroup && contact.userId == senderId,
        );

        if (contactIndex != -1) {
          // 联系人在列表中，更新未读计数和最后消息
          setState(() {
            int oldUnreadCount = _recentContacts[contactIndex].unreadCount;
            int newUnreadCount = oldUnreadCount + 1;

            // 🔧 修复：有新消息了，从已读集合中移除
            final contactKey = 'user_$senderId';
            if (_markedAsReadContacts.remove(contactKey)) {
              logger.debug('🔧 修复：收到新消息，已将 $contactKey 从已读集合中移除');
            }

            // 根据消息类型格式化显示内容
            final formattedMessage = _formatMessagePreviewForRecentContact(
              messageType,
              content,
            );
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(
                  unreadCount: newUnreadCount,
                  lastMessage: formattedMessage,
                  lastMessageTime:
                      createdAt ?? DateTime.now().toIso8601String(),
                  avatar: senderAvatar, // 更新发送者头像
                );

            // 将该联系人移到列表顶部
            final contact = _recentContacts.removeAt(contactIndex);
            _recentContacts.insert(0, contact);

            // 如果移动的是当前选中的联系人，更新索引
            if (_selectedChatIndex == contactIndex) {
              _selectedChatIndex = 0;
            } else if (_selectedChatIndex < contactIndex) {
              // 如果当前选中的在被移动项之前，索引需要加1
              _selectedChatIndex++;
            }

            logger.debug('已更新私聊未读数 ${_recentContacts[0].unreadCount}');
          });

          // 播放新消息提示音（有新未读消息，且不是自己发送的）
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final senderName = messageData['sender_name'] as String? ?? senderId.toString();
          final formattedMessage = _formatMessagePreviewForRecentContact(messageType, content);
          _showMessageNotificationPopup(
            title: senderName,
            message: formattedMessage,
            avatar: senderAvatar,
            isGroup: false,
            contactId: senderId,
          );
        } else {
          // 联系人不在列表中，创建新的联系人条目并添加到列表顶部
          logger.debug('⚠️ 联系人不在最近联系人列表中，创建新条目');
          
          setState(() {
            final formattedMessage = _formatMessagePreviewForRecentContact(
              messageType,
              content,
            );
            
            // 检查senderId是否为null
            if (senderId == null) {
              logger.debug('⚠️ 发送者ID为null，无法创建联系人条目');
              return;
            }
            
            final senderName = messageData['sender_name'] as String? ?? senderId.toString();
            
            // 创建新的联系人条目
            final newContact = RecentContactModel(
              type: 'user', // 明确指定为用户类型
              userId: senderId,
              username: senderName,
              fullName: senderName,
              avatar: senderAvatar,
              lastMessage: formattedMessage,
              lastMessageTime: createdAt ?? DateTime.now().toIso8601String(),
              unreadCount: 1, // 新消息，未读数为1
              status: 'offline',
            );
            
            // 添加到列表顶部
            _recentContacts.insert(0, newContact);
            
            // 更新选中索引
            if (_selectedChatIndex >= 0) {
              _selectedChatIndex++;
            }
            
            logger.debug('✅ 已创建新的联系人条目并添加到列表');
          });

          // 播放新消息提示音（有新未读消息，且不是自己发送的）
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final senderName = messageData['sender_name'] as String? ?? senderId.toString();
          final formattedMessage = _formatMessagePreviewForRecentContact(messageType, content);
          _showMessageNotificationPopup(
            title: senderName,
            message: formattedMessage,
            avatar: senderAvatar,
            isGroup: false,
            contactId: senderId,
          );
        }
      }
    } catch (e) {
      logger.debug('❌ 处理新消息失败: $e');
    }
  }

  // 处理消息发送成功确
  void _handleMessageSentConfirmation(dynamic data) async {
    try {
      if (data == null) return;

      // 检widget 是否还在树中
      if (!mounted) return;

      final confirmData = data as Map<String, dynamic>;
      final messageId = confirmData['message_id'] as int?;

      if (messageId != null) {
        // 可以用真实的消息ID更新临时消息（ID的消息）
        setState(() {
          final index = _messages.indexWhere((msg) => msg.id == 0);
          if (index != -1) {
            final oldMsg = _messages[index];
            _messages[index] = MessageModel(
              id: messageId,
              senderId: oldMsg.senderId,
              receiverId: oldMsg.receiverId,
              senderName: oldMsg.senderName,
              receiverName: oldMsg.receiverName,
              senderAvatar: oldMsg.senderAvatar,
              receiverAvatar: oldMsg.receiverAvatar,
              senderNickname: oldMsg.senderNickname,
              senderFullName: oldMsg.senderFullName,
              receiverFullName: oldMsg.receiverFullName,
              content: oldMsg.content,
              messageType: oldMsg.messageType,
              fileName: oldMsg.fileName, // 保留文件
              quotedMessageId: oldMsg.quotedMessageId, // 保留引用消息ID
              quotedMessageContent: oldMsg.quotedMessageContent, // 保留引用消息内容
              isRead: oldMsg.isRead,
              createdAt: oldMsg.createdAt,
            );

            logger.debug(
              '🔄 更新临时消息ID: 0 $messageId, 类型: ${oldMsg.messageType}, 引用内容: ${oldMsg.quotedMessageContent}',
            );
          }
        });
        
        // 🔴 关键修复：保存消息到本地数据库
        if (_currentChatUserId != null) {
          logger.debug('💾 [PC端] 收到message_sent确认，准备保存消息到本地数据库 - receiverId: $_currentChatUserId, messageId: $messageId');
          await _wsService.saveRecentPendingMessage(_currentChatUserId!, serverMessageId: messageId);
          logger.debug('✅ [PC端] 消息已保存到本地数据库');
          
          // 🔴 PC端优化：不刷新整个最近联系人列表，消息已通过WebSocket实时更新
          // 最近联系人的lastMessage和lastMessageTime会在_handleNewMessage中自动更新
          logger.debug('📝 [PC端] 消息已保存，跳过刷新最近联系人列表（已通过WebSocket更新）');
        }
      }
    } catch (e) {
      logger.debug('处理消息确认失败: $e');
    }
  }

  // 处理消息撤回通知
  void _handleMessageRecalled(dynamic data) {
    try {
      if (data == null) return;

      // 检widget 是否还在树中
      if (!mounted) return;

      final recallData = data as Map<String, dynamic>;
      final messageId = recallData['message_id'] as int?;

      if (messageId == null) {
        logger.debug('撤回消息数据不完');
        return;
      }

      logger.debug('↩️ 收到消息撤回通知 - 消息ID: $messageId');
      logger.debug('📋 当前消息列表包含 ${_messages.length} 条消息');
      logger.debug('🔍 消息列表中的所有消息ID: ${_messages.map((m) => m.id).toList()}');

      // 更新消息状态为已撤回，而不是删
      setState(() {
        final index = _messages.indexWhere((msg) => msg.id == messageId);
        logger.debug('🔎 查找消息索引结果: $index');
        if (index != -1) {
          final oldMessage = _messages[index];
          logger.debug('找到消息，准备更新为已撤回状态');
          // 创建一个新的消息对象，标记为已撤回
          _messages[index] = MessageModel(
            id: oldMessage.id,
            senderId: oldMessage.senderId,
            receiverId: oldMessage.receiverId,
            senderName: oldMessage.senderName,
            receiverName: oldMessage.receiverName,
            senderAvatar: oldMessage.senderAvatar,
            receiverAvatar: oldMessage.receiverAvatar,
            senderNickname: oldMessage.senderNickname,
            senderFullName: oldMessage.senderFullName,
            receiverFullName: oldMessage.receiverFullName,
            content: oldMessage.content,
            messageType: oldMessage.messageType,
            fileName: oldMessage.fileName,
            quotedMessageId: oldMessage.quotedMessageId,
            quotedMessageContent: oldMessage.quotedMessageContent,
            status: 'recalled', // 标记为已撤回
            isRead: oldMessage.isRead,
            createdAt: oldMessage.createdAt,
            readAt: oldMessage.readAt,
          );
          logger.debug('消息已更新为撤回状态');
        } else {
          logger.debug('未找到要撤回的消息ID: $messageId');
        }
      });

      // 显示提示
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('对方撤回了一条消息')));
      }

      // 不再刷新整个最近联系人列表，只更新最后消息显示
      // 如果被撤回的消息是最后一条消息，UI上会显示为已撤回状态
      // 注意：这里不刷新列表可以避免闪烁，撤回的消息已经在消息列表中更新为撤回状态
      logger.debug('💡 消息撤回已处理，不刷新最近联系人列表');
    } catch (e) {
      logger.debug('处理消息撤回失败: $e');
    }
  }

  // 处理联系人状态变
  void _handleStatusChange(dynamic data) {
    try {
      if (data == null) return;

      // 检widget 是否还在树中
      if (!mounted) return;

      final statusData = data as Map<String, dynamic>;
      final userId = statusData['user_id'] as int?;
      final newStatus = statusData['status'] as String?;

      if (userId == null || newStatus == null) {
        logger.debug('状态变更数据不完整');
        return;
      }

      logger.debug('📡 收到状态变更通知 - 用户ID: $userId, 新状 $newStatus');
      
      // 🔴 记录WebSocket设置的状态，API查询将完全使用此状态
      _websocketUserStatus[userId] = newStatus;
      logger.debug(
        '🔒 [WebSocket优先] 已记录用户 $userId 的状态: $newStatus（API将使用此状态）',
      );

      setState(() {
        // 更新最近联系人列表中的状
        for (int i = 0; i < _recentContacts.length; i++) {
          if (_recentContacts[i].userId == userId) {
            _recentContacts[i] = _recentContacts[i].copyWith(status: newStatus);
            logger.debug('已更新最近联系人列表中用$userId 的状态为 $newStatus');
            break;
          }
        }

        // 更新搜索结果列表中的状
        for (int i = 0; i < _searchResults.length; i++) {
          if (_searchResults[i].userId == userId) {
            _searchResults[i] = _searchResults[i].copyWith(status: newStatus);
            logger.debug('已更新搜索结果中用户 $userId 的状态为 $newStatus');
            break;
          }
        }

        // 更新联系人列表中的状
        for (int i = 0; i < _contacts.length; i++) {
          if (_contacts[i].friendId == userId) {
            _contacts[i] = _contacts[i].copyWith(status: newStatus);
            logger.debug('已更新联系人列表中用$userId 的状态为 $newStatus');
            break;
          }
        }
      });
    } catch (e) {
      logger.debug('处理状态变更失 $e');
    }
  }

  // 处理上线通知
  void _handleOnlineNotification(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final notificationData = data as Map<String, dynamic>;
      final userId = notificationData['user_id'] as int?;

      if (userId == null) {
        logger.debug('上线通知数据不完整');
        return;
      }

      logger.debug('📢 收到上线通知 - 用户ID: $userId');

      // 🔴 记录WebSocket设置的状态
      _websocketUserStatus[userId] = 'online';
      logger.debug('🔒 [WebSocket优先] 已记录用户 $userId 上线状态（API将使用此状态）');

      // 保存上线提醒到本地存储
      _saveOnlineNotification(notificationData);

      // 更新用户状态为在线
      setState(() {
        // 更新最近联系人列表中的状
        for (int i = 0; i < _recentContacts.length; i++) {
          if (_recentContacts[i].userId == userId) {
            _recentContacts[i] = _recentContacts[i].copyWith(status: 'online');
            logger.debug('已更新最近联系人列表中用$userId 的状态为 online');
            break;
          }
        }

        // 更新搜索结果列表中的状
        for (int i = 0; i < _searchResults.length; i++) {
          if (_searchResults[i].userId == userId) {
            _searchResults[i] = _searchResults[i].copyWith(status: 'online');
            logger.debug('已更新搜索结果中用户 $userId 的状态为 online');
            break;
          }
        }

        // 更新联系人列表中的状
        for (int i = 0; i < _contacts.length; i++) {
          if (_contacts[i].friendId == userId) {
            _contacts[i] = _contacts[i].copyWith(status: 'online');
            logger.debug('已更新联系人列表中用$userId 的状态为 online');
            break;
          }
        }
      });
    } catch (e) {
      logger.debug('处理上线通知失败: $e');
    }
  }

  // 保存上线提醒到本地存
  Future<void> _saveOnlineNotification(Map<String, dynamic> data) async {
    try {
      final notification = OnlineNotificationModel.fromJson(data);
      
      // 检查是否开启了该用户的上线提醒
      final currentUserId = _currentUserId;
      if (currentUserId == null) return;
      
      final prefs = await SharedPreferences.getInstance();
      final key = 'online_notification_${currentUserId}_${notification.userId}';
      final isEnabled = prefs.getBool(key) ?? false;
      
      // 只有开启了上线提醒的用户才保存到列表中
      if (isEnabled) {
        await Storage.addOnlineNotification(notification);
        logger.debug('上线提醒已保存到本地存储 - 用户: ${notification.displayName}');
        
        // 更新UI中的上线提醒列表
        if (mounted) {
          setState(() {
            // 移除旧的通知（如果存在）
            _onlineNotifications.removeWhere((n) => n.userId == notification.userId);
            // 添加新的通知到列表顶部
            _onlineNotifications.insert(0, notification);
          });
        }
      } else {
        logger.debug('用户 ${notification.displayName} 未开启上线提醒，跳过保存');
      }
    } catch (e) {
      logger.debug('保存上线提醒失败: $e');
    }
  }

  // 处理离线通知
  void _handleOfflineNotification(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final notificationData = data as Map<String, dynamic>;
      final userId = notificationData['user_id'] as int?;

      if (userId == null) {
        logger.debug('离线通知数据不完整');
        return;
      }

      logger.debug('📴 收到离线通知 - 用户ID: $userId');

      // 🔴 记录WebSocket设置的状态
      _websocketUserStatus[userId] = 'offline';
      logger.debug('🔒 [WebSocket优先] 已记录用户 $userId 离线状态（API将使用此状态）');

      // 从本地存储中删除该用户的上线提醒
      _removeOnlineNotification(userId);

      // 更新用户状态为离线
      setState(() {
        // 更新最近联系人列表中的状
        for (int i = 0; i < _recentContacts.length; i++) {
          if (_recentContacts[i].userId == userId) {
            _recentContacts[i] = _recentContacts[i].copyWith(status: 'offline');
            logger.debug('已更新最近联系人列表中用$userId 的状态为 offline');
            break;
          }
        }

        // 更新搜索结果列表中的状
        for (int i = 0; i < _searchResults.length; i++) {
          if (_searchResults[i].userId == userId) {
            _searchResults[i] = _searchResults[i].copyWith(status: 'offline');
            logger.debug('已更新搜索结果中用户 $userId 的状态为 offline');
            break;
          }
        }

        // 更新联系人列表中的状
        for (int i = 0; i < _contacts.length; i++) {
          if (_contacts[i].friendId == userId) {
            _contacts[i] = _contacts[i].copyWith(status: 'offline');
            logger.debug('已更新联系人列表中用$userId 的状态为 offline');
            break;
          }
        }

        // 如果当前正在查看上线提醒列表，从UI列表中移
        _onlineNotifications.removeWhere((n) => n.userId == userId);
      });
    } catch (e) {
      logger.debug('处理离线通知失败: $e');
    }
  }

  // 从本地存储中删除上线提醒
  Future<void> _removeOnlineNotification(int userId) async {
    try {
      await Storage.removeOnlineNotification(userId);
      logger.debug('已从上线提醒列表中删除用$userId');
    } catch (e) {
      logger.debug('删除上线提醒失败: $e');
    }
  }

  // 显示消息右键菜单
  void _showMessageContextMenu(
    BuildContext context,
    MessageModel message,
    Offset position,
  ) {
    // 判断是否是自己发送的消息
    final isSelf = message.senderId == _currentUserId;

    // 计算消息发送时间与当前时间的差
    final now = DateTime.now();
    final diff = now.difference(message.createdAt);
    final canRecallSelf = diff.inMinutes < 3; // 自己的消息3分钟内可以撤回

    // 判断是否是群主/管理员（在群组中）
    final isGroupAdmin =
        _isCurrentChatGroup &&
        (_currentUserGroupRole == 'owner' || _currentUserGroupRole == 'admin');

    // 判断是否可以撤回：
    // 1. 自己的消息，3分钟内可以撤回
    // 2. 群主/管理员可以随时撤回群组内任何人的消息（无时间限制）
    final canRecall = isSelf ? canRecallSelf : isGroupAdmin;

    // 调试日志
    logger.debug(
      '右键菜单判断 - isSelf: $isSelf, isGroup: $_isCurrentChatGroup, role: $_currentUserGroupRole, canRecallSelf: $canRecallSelf, isGroupAdmin: $isGroupAdmin, canRecall: $canRecall',
    );

    // 构建菜单项列
    final menuItems = <PopupMenuEntry<String>>[
      // 另存为（仅对图片、视频、文件类型显示）
      if (message.messageType == 'image' ||
          message.messageType == 'video' ||
          message.messageType == 'file')
        PopupMenuItem(
          value: 'saveAs',
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: const SizedBox(
            width: 80,
            child: Center(child: Text('另存', style: TextStyle(fontSize: 14))),
          ),
        ),
      // 复制
      PopupMenuItem(
        value: 'copy',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('复制', style: TextStyle(fontSize: 14))),
        ),
      ),
      // 引用
      PopupMenuItem(
        value: 'quote',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('引用', style: TextStyle(fontSize: 14))),
        ),
      ),
      // 转发
      PopupMenuItem(
        value: 'forward',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('转发', style: TextStyle(fontSize: 14))),
        ),
      ),
      // 收藏
      PopupMenuItem(
        value: 'favorite',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('收藏', style: TextStyle(fontSize: 14))),
        ),
      ),
      // 多选
      PopupMenuItem(
        value: 'multiSelect',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('多选', style: TextStyle(fontSize: 14))),
        ),
      ),
      // 撤回（自己的消息3分钟内可撤回；群主/管理员可随时撤回群组内任何人的消息）
      if (canRecall)
        PopupMenuItem(
          value: 'recall',
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: const SizedBox(
            width: 80,
            child: Center(child: Text('撤回', style: TextStyle(fontSize: 14))),
          ),
        ),
      // 删除（所有消息都可以删除，只是自己看不见
      PopupMenuItem(
        value: 'delete',
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const SizedBox(
          width: 80,
          child: Center(child: Text('删除', style: TextStyle(fontSize: 14))),
        ),
      ),
    ];

    showMenu(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: menuItems,
    ).then((value) {
      if (value != null) {
        switch (value) {
          case 'saveAs':
            _handleSaveAsMessage(message);
            break;
          case 'copy':
            _handleCopyMessage(message);
            break;
          case 'quote':
            _handleQuoteMessage(message);
            break;
          case 'forward':
            _handleForwardMessage(message);
            break;
          case 'favorite':
            _handleFavoriteMessage(message);
            break;
          case 'multiSelect':
            _handleMultiSelectMode();
            break;
          case 'recall':
            _handleRecallMessage(message);
            break;
          case 'delete':
            _handleDeleteMessage(message);
            break;
        }
      }
    });
  }

  // 处理引用消息
  void _handleQuoteMessage(MessageModel message) {
    setState(() {
      _quotedMessage = message;
    });
    // 聚焦到输入框
    _messageInputFocusNode.requestFocus();
  }

  // 处理转发消息
  void _handleForwardMessage(MessageModel message) async {
    _showForwardDialog(message);
  }

  // 显示转发弹窗
  Future<void> _showForwardDialog(MessageModel message) async {
    setState(() {
      _selectedForwardContacts = [];
    });

    try {
      // 每次打开转发弹窗时，实时从服务器获取已通过审核的联系人和群组
      final token = _token;
      if (token == null || token.isEmpty) {
        logger.debug('未登录，无法加载联系人和群组用于转发');
        _redirectToLogin('加载联系人失败-未登录');
        return;
      }

      // 并行请求：已通过审核的联系人 + 已通过审核的群组
      final results = await Future.wait([
        ApiService.getContacts(token: token),
        ApiService.getUserGroups(token: token),
      ]);

      final contactsResponse = results[0] as Map<String, dynamic>;
      final groupsResponse = results[1] as Map<String, dynamic>;

      if ((contactsResponse['code'] != 0 && contactsResponse['code'] != 200) ||
          contactsResponse['data'] == null) {
        final msg = contactsResponse['message'] ?? '获取联系人失败';
        logger.debug('加载联系人失败: $msg');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('加载联系人失败: $msg')),
          );
        }
        return;
      }

      // getContacts 返回的数据结构：{ code, data: { contacts: [...], total } }
      final contactsData =
          (contactsResponse['data']?['contacts'] as List?) ?? const [];

      // 只保留已通过审核的好友（ContactModel.isApproved）
      final approvedContacts = contactsData
          .map((json) => ContactModel.fromJson(json as Map<String, dynamic>))
          .where((c) => c.isApproved && !c.isDeleted)
          .toList();

      // 处理群组：只使用服务器返回的已加入群组列表
      List<RecentContactModel> groupContacts = [];
      if ((groupsResponse['code'] == 0 || groupsResponse['code'] == 200) &&
          groupsResponse['data'] != null) {
        final groupsData = groupsResponse['data']['groups'] as List?;
        if (groupsData != null) {
          groupContacts = groupsData.map((g) {
            final map = g as Map<String, dynamic>;
            final groupId = map['id'] as int;
            final groupName = (map['name']?.toString() ?? '').trim();
            final avatar = map['avatar']?.toString();
            return RecentContactModel.group(
              groupId: groupId,
              groupName: groupName.isNotEmpty ? groupName : '群聊$groupId',
              avatar: avatar,
            );
          }).toList();
        }
      }

      // 将通过审核的好友转换为 RecentContactModel
      final userContacts = approvedContacts.map((c) {
        final displayName = c.displayName;
        return RecentContactModel(
          type: 'user',
          userId: c.friendId,
          username: c.username,
          fullName: displayName,
          avatar: c.avatar.isNotEmpty ? c.avatar : null,
          lastMessageTime: DateTime.now().toIso8601String(),
          lastMessage: '',
          unreadCount: 0,
          status: c.status,
        );
      }).toList();

      // 合并用户和群组，作为转发候选列表
      var recentContacts = <RecentContactModel>[];
      recentContacts.addAll(userContacts);
      recentContacts.addAll(groupContacts);

      // 应用置顶和删除等偏好设置，保持与最近联系人列表一致的顺序和过滤
      recentContacts = await _applyContactPreferences(recentContacts);

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => _ForwardDialog(
          currentUserId: _currentChatUserId,
          recentContacts: recentContacts,
          onConfirm: (selectedUserIds) {
            _forwardMessageToContacts(message, selectedUserIds);
          },
        ),
      );
    } catch (e) {
      logger.error('加载最近联系人用于转发失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载最近联系人失败: $e')),
        );
      }
    }
  }

  // 转发消息到选中的联系人
  Future<void> _forwardMessageToContacts(
    MessageModel message,
    List<int> contactIds,
  ) async {
    try {
      int successCount = 0;

      for (final contactId in contactIds) {
        final success = await _wsService.sendMessage(
          receiverId: contactId,
          content: message.content,
          messageType: message.messageType,
          fileName: message.fileName,
        );

        if (success) {
          successCount++;
          logger.debug('成功转发消息给联系人 ID: $contactId');
        }
      }

      // 转发成功后刷新最近联系人列表，确保转发的联系人显示在列表
      if (successCount > 0) {
        await _loadRecentContacts();
        logger.debug('🔄 已刷新最近联系人列表，转发成功数: $successCount');
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('成功转发$successCount 位联系人')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('转发失败: $e')));
      }
    }
  }

  // 处理收藏消息
  void _handleFavoriteMessage(MessageModel message) async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      final response = await ApiService.createFavorite(
        token: token,
        messageId: message.id,
        serverMessageId: message.serverId,
        content: message.content,
        messageType: message.messageType,
        senderId: message.senderId,
        senderName: message.senderName,
        fileName: message.fileName,
      );

      if (mounted) {
        if (response['code'] == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '已保存到收藏')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '收藏失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('收藏消息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('收藏失败: $e')));
      }
    }
  }

  // 处理多选模
  void _handleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = true;
      _selectedMessageIds.clear();
    });
  }

  // 处理复制消息
  void _handleCopyMessage(MessageModel message) async {
    try {
      // 根据消息类型获取要复制的内容
      String copyText = '';
      if (message.messageType == 'text' || message.messageType == 'quoted') {
        copyText = message.content;
      } else if (message.messageType == 'image') {
        copyText = message.content; // 图片URL
      } else if (message.messageType == 'file') {
        copyText = message.fileName ?? message.content; // 文件名或URL
      }

      if (copyText.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法复制此消息')));
        }
        return;
      }

      // 复制到剪贴板
      await Clipboard.setData(ClipboardData(text: copyText));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
      }
    } catch (e) {
      logger.debug('复制失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('复制失败: $e')));
      }
    }
  }

  // 处理另存为消
  void _handleSaveAsMessage(MessageModel message) async {
    try {
      // 获取文件URL
      final fileUrl = message.content;
      if (fileUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('文件URL为空')));
        }
        return;
      }

      // 获取默认文件
      String defaultFileName = '未知文件';
      if (message.messageType == 'file') {
        defaultFileName = message.fileName ?? '未知文件';
        if (defaultFileName == '未知文件' && fileUrl.isNotEmpty) {
          // 从URL提取文件
          final urlParts = fileUrl.split('/');
          if (urlParts.isNotEmpty) {
            final lastPart = urlParts.last;
            // 去掉时间戳前缀（格式：时间戳_文件名）
            if (lastPart.contains('_')) {
              final nameParts = lastPart.split('_');
              if (nameParts.length > 1) {
                defaultFileName = nameParts.sublist(1).join('_');
              } else {
                defaultFileName = lastPart;
              }
            } else {
              defaultFileName = lastPart;
            }
          }
        }
      } else if (message.messageType == 'image') {
        // 从URL提取图片文件
        final urlParts = fileUrl.split('/');
        if (urlParts.isNotEmpty) {
          defaultFileName = urlParts.last;
        } else {
          defaultFileName =
              'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
        }
      } else if (message.messageType == 'video') {
        // 从URL提取视频文件
        final urlParts = fileUrl.split('/');
        if (urlParts.isNotEmpty) {
          defaultFileName = urlParts.last;
        } else {
          defaultFileName =
              'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        }
      }

      logger.debug('📥 准备另存- 文件 $defaultFileName, URL: $fileUrl');

      // 打开文件保存对话
      final String? outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: defaultFileName,
      );

      if (outputPath == null) {
        logger.debug('📥 用户取消了保存操作');
        return;
      }

      logger.debug('📥 用户选择的保存路 $outputPath');

      // 显示下载进度提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('正在下载...'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      // 下载文件
      final response = await http.get(Uri.parse(fileUrl));

      if (response.statusCode == 200) {
        // 保存文件
        final file = File(outputPath);
        await file.writeAsBytes(response.bodyBytes);

        logger.debug('文件保存成功: $outputPath');

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('文件已保存至: $outputPath')));
        }
      } else {
        throw Exception('下载失败，HTTP状态码: ${response.statusCode}');
      }
    } catch (e) {
      logger.debug('另存为失 $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  // 处理撤回消息
  void _handleRecallMessage(MessageModel message) async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 确认撤回
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('撤回消息'),
          content: Text(
            _isCurrentChatGroup
                ? '确定要撤回这条消息吗？群组内所有成员都将看不到此消息'
                : '确定要撤回这条消息吗？双方都将看不到此消息',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('撤回'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      final response = await ApiService.recallMessage(
        token: token,
        messageId: message.id,
      );

      if (mounted) {
        if (response['code'] == 0) {
          // 更新本地消息状态为已撤回，而不是删
          setState(() {
            final index = _messages.indexWhere((msg) => msg.id == message.id);
            if (index != -1) {
              // 创建一个新的消息对象，标记为已撤回
              _messages[index] = MessageModel(
                id: message.id,
                senderId: message.senderId,
                receiverId: message.receiverId,
                senderName: message.senderName,
                receiverName: message.receiverName,
                senderAvatar: message.senderAvatar,
                receiverAvatar: message.receiverAvatar,
                senderNickname: message.senderNickname,
                senderFullName: message.senderFullName,
                receiverFullName: message.receiverFullName,
                content: message.content,
                messageType: message.messageType,
                fileName: message.fileName,
                quotedMessageId: message.quotedMessageId,
                quotedMessageContent: message.quotedMessageContent,
                status: 'recalled', // 标记为已撤回
                isRead: message.isRead,
                createdAt: message.createdAt,
                readAt: message.readAt,
              );
            }
          });

          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('消息已撤回')));

          // 刷新最近联系人列表，以便更新最新消息显示
          // 如果被撤回的消息是最后一条消息，最近联系人列表中的最新消息应该显示"此消息已被撤销"
          _loadRecentContacts();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '撤回失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('撤回消息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('撤回失败: $e')));
      }
    }
  }

  /// 自动下载文件（如果满足条件）
  Future<void> _autoDownloadFileIfNeeded(MessageModel message) async {
    logger.debug(
      '🔍 检查是否需要自动下- 消息ID: ${message.id}, 类型: ${message.messageType}, 文件 ${message.fileName}',
    );

    try {
      // 1. 检查消息类型是否是文件、图片或视频
      if (message.messageType != 'file' &&
          message.messageType != 'image' &&
          message.messageType != 'video') {
        logger.debug('⚠️ 消息类型不是文件/图片/视频，跳过自动下载');
        return;
      }

      logger.debug('消息类型符合条件: ${message.messageType}');

      // 2. 检查自动下载开关是否打开
      final autoDownloadEnabled = await Storage.getAutoDownloadEnabled();
      logger.debug('🔧 自动下载开关状 $autoDownloadEnabled');

      if (!autoDownloadEnabled) {
        logger.debug('⚠️ 自动下载未开始');
        return;
      }

      // 3. 获取文件存储路径
      final storagePath = await Storage.getFileStoragePath();
      logger.debug('📂 文件存储路径: $storagePath');

      if (storagePath == null || storagePath.isEmpty) {
        logger.debug('⚠️ 未设置文件存储路径');
        return;
      }

      // 4. 检查文件大小限
      final autoDownloadSizeMB = await Storage.getAutoDownloadSizeMB();
      logger.debug('📏 自动下载大小限制: ${autoDownloadSizeMB}MB');

      final fileUrl = message.content;
      logger.debug('🔗 文件URL: $fileUrl');

      // 获取文件大小（通过HEAD请求
      try {
        final headResponse = await http.head(Uri.parse(fileUrl));
        final contentLength = headResponse.headers['content-length'];

        if (contentLength != null) {
          final fileSizeBytes = int.parse(contentLength);
          final fileSizeMB = fileSizeBytes / (1024 * 1024);

          if (fileSizeMB > autoDownloadSizeMB) {
            logger.debug(
              '⚠️ 文件大小 ${fileSizeMB.toStringAsFixed(2)}MB 超过限制 ${autoDownloadSizeMB}MB',
            );
            return;
          }

          logger.debug('文件大小 ${fileSizeMB.toStringAsFixed(2)}MB 符合自动下载条件');
        }
      } catch (e) {
        logger.debug('⚠️ 获取文件大小失败: $e，继续下载文件');
      }

      // 5. 构建保存路径：存储路联系人ID/文件
      final contactId = message.senderId;
      final contactDir = path.join(storagePath, contactId.toString());

      // 确保联系人目录存
      final directory = Directory(contactDir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        logger.debug('📁 创建联系人目 $contactDir');
      }

      // 6. 确定文件名
      String fileName;
      if (message.fileName != null && message.fileName!.isNotEmpty) {
        fileName = message.fileName!;
      } else {
        // 从URL提取文件名
        final urlParts = fileUrl.split('/');
        if (urlParts.isNotEmpty) {
          fileName = urlParts.last;
        } else {
          // 根据消息类型生成默认文件名
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          if (message.messageType == 'image') {
            fileName = 'image_$timestamp.jpg';
          } else if (message.messageType == 'video') {
            fileName = 'video_$timestamp.mp4';
          } else {
            fileName = 'file_$timestamp';
          }
        }
      }

      // 7. 构建完整文件路径
      final filePath = path.join(contactDir, fileName);

      // 检查文件是否已存在，如果存在则添加序号
      String finalFilePath = filePath;
      int counter = 1;
      while (await File(finalFilePath).exists()) {
        final extension = path.extension(fileName);
        final baseName = path.basenameWithoutExtension(fileName);
        finalFilePath = path.join(contactDir, '$baseName($counter)$extension');
        counter++;
      }

      logger.debug('📥 开始自动下载文件: $fileUrl');
      logger.debug('💾 保存路径: $finalFilePath');

      // 8. 下载文件
      final response = await http.get(Uri.parse(fileUrl));

      if (response.statusCode == 200) {
        // 保存文件
        final file = File(finalFilePath);
        await file.writeAsBytes(response.bodyBytes);

        logger.debug('文件自动下载成功: $finalFilePath');

        // 显示提示（可选）
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('文件已自动下载: $fileName'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        logger.debug('下载失败，HTTP状态码: ${response.statusCode}');
      }
    } catch (e) {
      logger.debug('自动下载文件失败: $e');
    }
  }

  // 处理删除消息
  void _handleDeleteMessage(MessageModel message) async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 确认删除
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除消息'),
          content: const Text('确定要删除这条消息吗？仅自己不可见，对方仍可看到'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      final response = await ApiService.deleteMessage(
        token: token,
        messageId: message.id,
      );

      if (mounted) {
        if (response['code'] == 0) {
          // 从本地列表中移除消息
          setState(() {
            _messages.removeWhere((msg) => msg.id == message.id);
          });

          // 刷新最近联系人列表，以更新最新消息显示
          _loadRecentContacts();

          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('消息已删除')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '删除失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('删除消息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  // 获取引用消息的预览文
  String _getQuotedMessagePreview(MessageModel message) {
    if (message.messageType == 'image') {
      return '[图片]';
    } else if (message.messageType == 'file') {
      return '[文件] ${message.fileName ?? "未知文件"}';
    } else if (message.messageType == 'quoted') {
      // 如果引用的是引用消息，只返回回复内容，不包含被引用部
      return message.content;
    } else {
      return message.content;
    }
  }

  // 根据消息类型格式化最近联系人列表中的消息预览
  String _formatMessagePreviewForRecentContact(
    String? messageType,
    String? content,
  ) {
    if (messageType == null) {
      return content ?? '';
    }
    switch (messageType) {
      case 'image':
        return '[图片]';
      case 'video':
        return '[视频]';
      case 'file':
        return '[文件]';
      case 'voice':
        return '[语音]';
      default:
        // 检测是否为纯表情消息（格式：[emotion:xxx.png]）
        // 移除所有表情标记后，如果剩余内容为空，则说明是纯表情消息
        if (content != null && content.contains('[emotion:')) {
          final withoutEmotions = content
              .replaceAll(RegExp(r'\[emotion:[^\]]+\.png\]'), '')
              .trim();
          if (withoutEmotions.isEmpty) {
            return '[表情]';
          }
        }
        // 检测是否为URL（可能是头像或图片链接）
        if (content != null && (content.startsWith('http://') || content.startsWith('https://'))) {
          // 检查是否是图片URL
          if (content.contains('.png') || content.contains('.jpg') || 
              content.contains('.jpeg') || content.contains('.gif') ||
              content.contains('.webp')) {
            return '[图片]';
          }
          return '[链接]';
        }
        return content ?? '';
    }
  }

  // 加载用户信息
  Future<void> _loadUserInfo() async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingUserInfo = false;
        });
        return;
      }

      // 调用API获取用户信息
      final response = await ApiService.getUserProfile(token: token);

      if (response['code'] == 0 && response['data'] != null) {
        final userData = response['data']['user'];
        final user = UserModel.fromJson(userData);

        setState(() {
          _userStatus = user.status;
          _userDisplayName = user.fullName ?? user.username;
          _username = user.username; // 保存username用于生成头像文字
          _userFullName = user.fullName; // 保存fullName
          _userAvatar = user.avatar.isNotEmpty ? user.avatar : null;
          _isLoadingUserInfo = false;
        });
      } else {
        setState(() {
          _isLoadingUserInfo = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingUserInfo = false;
      });
    }
  }

  // 加载最近联系人列表
  Future<void> _loadRecentContacts() async {
    logger.debug('🔄 开始加载最近联系人列表');
    setState(() {
      _isLoadingRecentContacts = true;
      _recentContactsError = null;
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        logger.debug('未登录，无法加载最近联系人');
        // 未登录时，跳转到登录页面
        _redirectToLogin('加载最近联系人失败-未登录');
        return;
      }

      final response = await MessageService().getRecentContacts();
      if (response['code'] == 0 && response['data'] != null) {
        final contactsData = response['data']['contacts'] as List?;
        var contacts = (contactsData ?? [])
            .map(
              (json) =>
                  RecentContactModel.fromJson(json as Map<String, dynamic>),
            )
            .toList();

        logger.debug('加载最近联系人成功，共 ${contacts.length} 个联系人');

        // 应用置顶和删除配置
        contacts = await _applyContactPreferences(contacts);

        // 异步更新联系人头像（不阻塞UI）
        _updateContactAvatarsAsync();
        logger.debug('应用偏好设置后，剩余 ${contacts.length} 个联系人');

        // 批量查询用户实时在线状态
        await _fetchOnlineStatuses(contacts);

        // 如果当前有选中的聊天，需要在新列表中找到该联系人的位置并更新索引
        if (_currentChatUserId != null) {
          final currentContactIndex = contacts.indexWhere(
            (contact) => _isCurrentChatGroup
                ? (contact.isGroup && contact.groupId == _currentChatUserId)
                : (!contact.isGroup && contact.userId == _currentChatUserId),
          );
          if (currentContactIndex != -1) {
            logger.debug(
              '🔄 更新选中索引: $_selectedChatIndex -> $currentContactIndex',
            );
            setState(() {
              _recentContacts = contacts;
              _selectedChatIndex = currentContactIndex;
              _isLoadingRecentContacts = false;

              // 确保当前正在查看的联系人/群组的未读计数为0（因为用户正在查看）
              if (_recentContacts[currentContactIndex].unreadCount > 0) {
                _recentContacts[currentContactIndex] =
                    _recentContacts[currentContactIndex].copyWith(
                      unreadCount: 0,
                    );
                logger.debug(
                  '✅ 当前正在查看${_isCurrentChatGroup ? "群组" : "联系人"}，已清除未读计数',
                );
              }

              // 🔧 修复：检查所有已标记为已读的联系人，确保未读数为0
              for (int i = 0; i < _recentContacts.length; i++) {
                final contact = _recentContacts[i];
                final contactKey = contact.isGroup
                    ? 'group_${contact.groupId}'
                    : 'user_${contact.userId}';

                if (_markedAsReadContacts.contains(contactKey) &&
                    contact.unreadCount > 0) {
                  _recentContacts[i] = _recentContacts[i].copyWith(
                    unreadCount: 0,
                  );
                  logger.debug(
                    '🔧 修复：${contact.isGroup ? "群组" : "联系人"} $contactKey 已标记为已读，清除未读计数（原未读数：${contact.unreadCount}）',
                  );
                }
              }
            });
          } else {
            // 当前聊天的联系人不在列表中了（可能被删除
            logger.debug('⚠️ 当前聊天联系人不在新列表中');
            setState(() {
              _recentContacts = contacts;
              _isLoadingRecentContacts = false;

              // 🔧 修复：检查所有已标记为已读的联系人，确保未读数为0
              for (int i = 0; i < _recentContacts.length; i++) {
                final contact = _recentContacts[i];
                final contactKey = contact.isGroup
                    ? 'group_${contact.groupId}'
                    : 'user_${contact.userId}';

                if (_markedAsReadContacts.contains(contactKey) &&
                    contact.unreadCount > 0) {
                  _recentContacts[i] = _recentContacts[i].copyWith(
                    unreadCount: 0,
                  );
                  logger.debug(
                    '🔧 修复：${contact.isGroup ? "群组" : "联系人"} $contactKey 已标记为已读，清除未读计数（原未读数：${contact.unreadCount}）',
                  );
                }
              }
            });
          }
        } else {
          setState(() {
            _recentContacts = contacts;
            _isLoadingRecentContacts = false;

            // 🔧 修复：检查所有已标记为已读的联系人，确保未读数为0
            for (int i = 0; i < _recentContacts.length; i++) {
              final contact = _recentContacts[i];
              final contactKey = contact.isGroup
                  ? 'group_${contact.groupId}'
                  : 'user_${contact.userId}';

              if (_markedAsReadContacts.contains(contactKey) &&
                  contact.unreadCount > 0) {
                _recentContacts[i] = _recentContacts[i].copyWith(
                  unreadCount: 0,
                );
                logger.debug(
                  '🔧 修复：${contact.isGroup ? "群组" : "联系人"} $contactKey 已标记为已读，清除未读计数（原未读数：${contact.unreadCount}）',
                );
              }
            }
          });

          // 只在初次加载且没有当前聊天用户时，自动选择第一个联系人
          logger.debug(
            '📊 检查是否自动选择: contacts.length=${contacts.length}, _selectedMenuIndex=$_selectedMenuIndex',
          );
          if (contacts.isNotEmpty && _selectedMenuIndex == 0) {
            final firstContact = contacts[0];
            final hasUnreadMessages = firstContact.unreadCount > 0;
            logger.debug(
              '🎯 自动选择第一个联系人: ${firstContact.displayName} (ID: ${firstContact.userId}), 类型: ${firstContact.isGroup ? "群组" : "私聊"}, 未读 ${firstContact.unreadCount}',
            );
            setState(() {
              _selectedChatIndex = 0;
              _isCurrentChatGroup = firstContact.isGroup;

              // 如果第一个联系人有未读消息，立即清除UI上的未读计数（不显示红色气泡）
              if (hasUnreadMessages) {
                _recentContacts[0] = _recentContacts[0].copyWith(
                  unreadCount: 0,
                );

                // 🔧 修复：将该联系人添加到已读集合中
                final contactKey = firstContact.isGroup
                    ? 'group_${firstContact.groupId}'
                    : 'user_${firstContact.userId}';
                _markedAsReadContacts.add(contactKey);

                logger.debug('📧 第一个联系人有未读消息，已清除UI上的未读计数');
                logger.debug('🔧 修复：已将 $contactKey 添加到已读集合');
              }
            });

            // 🔧 修复：如果第一个联系人是群组，先加载群组详细信息（包括群公告）
            final firstGroupId = _resolveGroupId(firstContact);
            if (firstGroupId != null) {
              await _loadGroupDetail(firstGroupId);
            }

            // 根据联系人类型调用正确的加载方法
            final chatId = _resolveChatId(firstContact);
            await _loadMessageHistory(chatId, isGroup: firstContact.isGroup);

            // 如果第一个联系人有未读消息，自动标记为已读（这会同步到服务器并刷新联系人列表）
            if (hasUnreadMessages) {
              logger.debug('📧 第一个联系人有未读消息，正在标记为已读');
              if (firstContact.isGroup) {
                await _markGroupMessagesAsRead(chatId);
              } else {
                await _markMessagesAsRead(chatId);
              }
              logger.debug('✅ 第一个联系人的未读消息已标记为已读');
            }
          } else {
            logger.debug(
              '⚠️ 不满足自动选择条件: isEmpty=${contacts.isEmpty}, menuIndex=$_selectedMenuIndex',
            );
          }
        }
      } else {
        logger.debug('API返回错误: ${response['message']}');
        setState(() {
          _isLoadingRecentContacts = false;
          _recentContactsError = response['message'] ?? '加载最近联系人失败';
        });
      }
    } catch (e) {
      logger.debug('加载最近联系人异常: $e');
      setState(() {
        _isLoadingRecentContacts = false;
        _recentContactsError = '加载最近联系人失败: $e';
      });
      logger.debug('加载最近联系人失败: $e');
    }
  }

  /// 异步更新联系人头像（不阻塞UI）
  /// 为最近联系人列表中的每个用户获取最新的头像信息
  Future<void> _updateContactAvatarsAsync() async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) return;

      // 获取需要更新的用户ID列表（排除群组和文件助手）
      final userIds = _recentContacts
          .where((contact) => !contact.isGroup && !contact.isFileAssistant)
          .map((contact) => contact.userId)
          .toSet()
          .toList();

      if (userIds.isEmpty) {
        logger.debug('🎭 没有需要更新头像的用户');
        return;
      }

      logger.debug('🎭 开始异步更新 ${userIds.length} 个用户的头像');

      // 异步获取每个用户的最新信息
      for (final userId in userIds) {
        try {
          final response = await ApiService.getUserByID(
            token: token,
            userId: userId,
          );

          if (response['code'] == 0 && response['data'] != null) {
            final userData = response['data']['user'];
            final newAvatar = userData['avatar'] as String?;

            // 更新头像缓存
            if (newAvatar != null && newAvatar.isNotEmpty) {
              _avatarCache[userId] = newAvatar;

              // 更新最近联系人列表中的头像
              if (mounted) {
                setState(() {
                  for (int i = 0; i < _recentContacts.length; i++) {
                    if (!_recentContacts[i].isGroup &&
                        _recentContacts[i].userId == userId) {
                      _recentContacts[i] = _recentContacts[i].copyWith(
                        avatar: newAvatar,
                      );
                      final avatarPreview = newAvatar.length > 50
                          ? '${newAvatar.substring(0, 50)}...'
                          : newAvatar;
                      logger.debug('🎭 已更新用户 $userId 的头像: $avatarPreview');
                    }
                  }
                });
              }
            }
          }
        } catch (e) {
          logger.debug('🎭 更新用户 $userId 头像失败: $e');
          // 继续处理下一个用户
        }
      }

      logger.debug('🎭 头像更新完成');
    } catch (e) {
      logger.debug('🎭 异步更新头像异常: $e');
    }
  }

  // 搜索联系- 实时从服务器获取，不使用缓存
  Future<void> _searchContacts(String keyword) async {
    if (keyword.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    // 保存当前搜索关键词，用于验证结果是否仍然有效
    final currentKeyword = keyword.trim();

    setState(() {
      _isSearching = true;
      _searchError = null;
      // 立即清空之前的搜索结果，确保不显示旧数据
      _searchResults = [];
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        // 只有当搜索关键词仍然匹配时才更新状
        if (_searchController.text.trim() == currentKeyword) {
          setState(() {
            _isSearching = false;
            _searchError = '未登录';
          });
        }
        return;
      }

      // 调用API搜索联系- 每次都从服务器获取最新数
      final response = await ApiService.searchContacts(
        token: token,
        keyword: currentKeyword,
      );

      // 检查搜索关键词是否仍然匹配（用户可能已经输入了新的内容
      if (_searchController.text.trim() != currentKeyword) {
        logger.debug('搜索关键词已变化，忽略此次搜索结果');
        return;
      }

      if (response['code'] == 0 && response['data'] != null) {
        final contactsData = response['data']['contacts'] as List?;
        final contacts = (contactsData ?? [])
            .map(
              (json) =>
                  RecentContactModel.fromJson(json as Map<String, dynamic>),
            )
            .toList();

        setState(() {
          _searchResults = contacts;
          _isSearching = false;
        });
      } else {
        setState(() {
          _isSearching = false;
          _searchError = response['message'] ?? '搜索失败';
        });
      }
    } catch (e) {
      // 只有当搜索关键词仍然匹配时才更新错误状
      if (_searchController.text.trim() == currentKeyword) {
        setState(() {
          _isSearching = false;
          _searchError = '搜索失败: $e';
        });
      }
      logger.debug('搜索联系人失败 $e');
    }
  }

  // 刷新当前聊天的消息列表
  Future<void> _refreshCurrentChatMessages() async {
    if (_currentChatUserId == null) {
      logger.debug('📞 无法刷新消息：当前聊天用户ID为空');
      return;
    }
    
    logger.debug('📞 开始刷新当前聊天消息 - 用户ID: $_currentChatUserId, 是否群组: $_isCurrentChatGroup');
    
    try {
      // 重新加载当前聊天的消息历史
      await _loadMessageHistory(_currentChatUserId!, isGroup: _isCurrentChatGroup);
      logger.debug('📞 当前聊天消息刷新完成');
    } catch (e) {
      logger.debug('📞 刷新当前聊天消息失败: $e');
    }
  }

  // 🔴 新增：自动点击群组会话子项
  Future<void> _autoClickGroupConversation(int groupId) async {
    try {
      logger.debug('📞 [自动点击] 开始查找群组$groupId的会话项');
      
      // 在最近联系人列表中查找对应的群组
      int? targetIndex;
      for (int i = 0; i < _recentContacts.length; i++) {
        final contact = _recentContacts[i];
        if (contact.isGroup && (contact.groupId == groupId || contact.userId == groupId)) {
          targetIndex = i;
          logger.debug('📞 [自动点击] 找到群组$groupId，索引: $i');
          break;
        }
      }
      
      if (targetIndex == null) {
        logger.debug('📞 [自动点击] 未找到群组$groupId的会话项');
        return;
      }
      
      // 延迟执行，确保通话页面完全关闭
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (!mounted) {
        logger.debug('📞 [自动点击] Widget已销毁，取消自动点击');
        return;
      }
      
      logger.debug('📞 [自动点击] 开始模拟点击群组$groupId的会话项');
      
      final contact = _recentContacts[targetIndex];
      final hasUnreadMessages = contact.unreadCount > 0;
      final contactId = _resolveChatId(contact);

      setState(() {
        _selectedChatIndex = targetIndex!;
        _isCurrentChatGroup = contact.isGroup;
        _isOtherTyping = false;

        // 如果联系人有未读消息，立即清除UI上的未读计数
        if (hasUnreadMessages) {
          _recentContacts[targetIndex!] = _recentContacts[targetIndex].copyWith(
            unreadCount: 0,
            hasMentionedMe: false,
          );

          final contactKey = contact.isGroup
              ? 'group_${contact.groupId}'
              : 'user_${contact.userId}';
          _markedAsReadContacts.add(contactKey);
        }
      });

      // 如果有未读消息，调用服务器API标记为已读
      if (hasUnreadMessages) {
        if (contact.isGroup) {
          _markGroupMessagesAsRead(contactId);
        } else {
          _markMessagesAsRead(contactId);
        }
      }

      // 如果是群组聊天，加载群组详细信息
      final groupIdToLoad = _resolveGroupId(contact);
      if (groupIdToLoad != null) {
        await _loadGroupDetail(groupIdToLoad);
      }

      // 加载该群组的消息历史
      if (contact.isFileAssistant || contactId == 0) {
        _loadFileAssistantMessages();
      } else {
        _loadMessageHistory(contactId, isGroup: contact.isGroup);
      }
      
      logger.debug('📞 [自动点击] 群组$groupId会话项点击完成，对话框将自动刷新');
    } catch (e) {
      logger.debug('📞 [自动点击] 自动点击群组会话项失败: $e');
    }
  }

  // 加载消息历史记录
  Future<void> _loadMessageHistory(
    int userId, {
    bool isGroup = false,
    int retryCount = 0,
  }) async {
    final chatType = isGroup ? '群组' : '用户';
    final retryInfo = retryCount > 0 ? ' (重试 $retryCount/1)' : '';

    // 切换聊天对象时，重置滚动状态
    _isUserScrolling = false;
    _lastScrollPosition = 0.0;

    setState(() {
      _isLoadingMessages = true;
      _messagesError = null;
      _currentChatUserId = userId;
      _isCurrentChatGroup = isGroup;
      _isOtherTyping = false; // 切换聊天对象时清除"对方正在输入"状态
      // 如果不是群组，清空群组角色
      if (!isGroup) {
        _currentUserGroupRole = null;
      }
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingMessages = false;
          _messagesError = '未登录';
        });
        return;
      }

      // 从本地数据库获取消息（增加pageSize以加载更多消息）
      final messageService = MessageService();
      final messages = isGroup
          ? await messageService.getGroupMessageList(
              groupId: userId,
              pageSize: 200, // 增加到200条，确保加载所有最近消息
            )
          : await messageService.getMessages(
              contactId: userId,
              pageSize: 200, // 增加到200条，确保加载所有最近消息
            );
      // 如果是群组，获取当前用户在群组中的角色
      if (isGroup) {
        try {
          final groupResponse = await ApiService.getGroupDetail(
            token: token,
            groupId: userId,
          );
          if (groupResponse['code'] == 0 && groupResponse['data'] != null) {
            final memberRole = groupResponse['data']['member_role'] as String?;
            logger.debug('获取群组角色成功: $memberRole');
            setState(() {
              _currentUserGroupRole = memberRole;
            });
          }
        } catch (e) {
          logger.debug('获取群组角色失败: $e');
        }
      }

      // 设置消息并标记正在滚动到底部（隐藏消息列表避免闪烁）
      setState(() {
        _messages = messages;
        _isLoadingMessages = false; // 取消加载状态，让列表渲染
        _isScrollingToBottom = true; // 标记正在滚动，隐藏消息
      });

      // 检查并处理未读消息：如果已经在聊天记录对话中，自动清除未读计数并标记为已读
      final contactIndex = _recentContacts.indexWhere(
        (contact) => isGroup
            ? (contact.isGroup && contact.groupId == userId)
            : (!contact.isGroup && contact.userId == userId),
      );

      if (contactIndex != -1) {
        final contact = _recentContacts[contactIndex];
        if (contact.unreadCount > 0) {
          logger.debug('📧 检测到未读消息（${contact.unreadCount}条），正在清除UI未读计数并标记为已读');
          // 立即清除UI上的未读计数（不显示红色气泡）
          setState(() {
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(unreadCount: 0);

            // 🔧 修复：将该联系人添加到已读集合中
            final contactKey = isGroup ? 'group_$userId' : 'user_$userId';
            _markedAsReadContacts.add(contactKey);
          });
          // 标记消息为已读（同步到本地数据库）
          if (isGroup) {
            _markGroupMessagesAsRead(userId);
          } else {
            _markMessagesAsRead(userId);
          }
        }
      }

      // 在下一帧立即跳转到底部
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        if (_messageScrollController.hasClients) {
          // 立即跳转到最大滚动位置
          final maxScroll = _messageScrollController.position.maxScrollExtent;
          _messageScrollController.jumpTo(maxScroll);

        }

        // 滚动完成后显示消息列表
        if (mounted) {
          setState(() {
            _isScrollingToBottom = false;
          });
        }
      });
    } catch (e) {
      // 如果加载失败且还没重试过，自动重试一次
      if (retryCount < 1) {
        await Future.delayed(const Duration(seconds: 1));
        // 检查是否还在同一个聊天窗口（避免用户已切换到其他对话）
        if (mounted &&
            _currentChatUserId == userId &&
            _isCurrentChatGroup == isGroup) {
          return _loadMessageHistory(
            userId,
            isGroup: isGroup,
            retryCount: retryCount + 1,
          );
        }
      }

      setState(() {
        _isLoadingMessages = false;
        _messagesError = '加载消息失败: $e';
      });
      logger.debug('加载$chatType消息历史失败: $e');
    }
  }

  // 确保文件传输助手存在于最近联系人列表中
  Future<void> _ensureFileAssistantInRecentContacts() async {
    try {
      if (_currentUserId == null) {
        logger.debug('⚠️ 用户ID为空，无法确保文件传输助手在最近联系人列表中');
        return;
      }

      // 🔴 步骤1：检查文件传输助手是否被标记为已删除，如果是则恢复它
      final contactKey = Storage.generateContactKey(
        isGroup: false,
        id: _currentUserId!,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 文件传输助手已被删除，现在恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ 文件传输助手已恢复');
        
        // 重新加载最近联系人列表，确保文件传输助手显示出来
        _loadRecentContacts();
      }

      final localDb = LocalDatabaseService();
      
      // 🔴 步骤2：检查是否已有文件传输助手消息
      final existingMessages = await localDb.getFileAssistantMessages(
        userId: _currentUserId!,
        limit: 1,
      );
      
      if (existingMessages.isEmpty) {
        // 如果没有消息记录，创建一个占位消息
        final now = DateTime.now();
        final placeholderMessage = {
          'user_id': _currentUserId!,
          'content': '欢迎使用文件传输助手',
          'message_type': 'text',
          'sender_id': _currentUserId!,
          'receiver_id': _currentUserId!,
          'sender_name': _username ?? '',
          'receiver_name': '文件传输助手',
          'sender_avatar': _userAvatar ?? '',
          'receiver_avatar': '',
          'created_at': now.toIso8601String(),
          'is_read': true,
          'status': 'normal',
        };
        
        await localDb.insertFileAssistantMessage(placeholderMessage);
        logger.debug('✅ 已创建文件传输助手占位消息，将出现在最近联系人列表中');
        
        // 刷新最近联系人列表以显示文件传输助手
        _loadRecentContacts();
      } else {
        logger.debug('✅ 文件传输助手已存在消息记录');
      }
    } catch (e) {
      logger.error('确保文件传输助手在最近联系人列表中失败: $e');
      // 即使失败也不影响打开文件传输助手
    }
  }

  // 加载文件传输助手消息
  Future<void> _loadFileAssistantMessages({int retryCount = 0}) async {
    final retryInfo = retryCount > 0 ? ' (重试 $retryCount/1)' : '';
    logger.debug('📜 开始加载文件传输助手消息$retryInfo');
    setState(() {
      _isLoadingMessages = true;
      _messagesError = null;
      _currentChatUserId = 0; // 使用0表示文件助手
      _isCurrentChatGroup = false;
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingMessages = false;
          _messagesError = '未登录';
        });
        return;
      }

      // 调用文件助手API
      final response = await ApiService.getFileAssistantMessages(
        token: token,
        page: 1,
        pageSize: 50,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final messagesData = response['data']['messages'] as List?;

        // 将文件助手消息转换为MessageModel格式
        final messages = (messagesData ?? []).map((json) {
          final faMsg = json as Map<String, dynamic>;
          return MessageModel(
            id: faMsg['id'] as int,
            senderId: _currentUserId,
            receiverId: _currentUserId,
            senderName: _username,
            receiverName: '文件传输助手',
            senderFullName: _userFullName,
            content: faMsg['content'] as String,
            messageType: faMsg['message_type'] as String? ?? 'text',
            fileName: faMsg['file_name'] as String?,
            quotedMessageId: faMsg['quoted_message_id'] as int?,
            quotedMessageContent: faMsg['quoted_message_content'] as String?,
            status: faMsg['status'] as String? ?? 'normal',
            isRead: true,
            createdAt: DateTime.parse(faMsg['created_at'] as String),
          );
        }).toList();

        logger.debug('加载文件助手消息成功，共 ${messages.length} 条消息');
        setState(() {
          _messages = messages;
          _isLoadingMessages = false;
        });

        // 直接跳转到底部，不使用动
        _scrollToBottom(animated: false);
      } else {
        // 如果加载失败且还没重试过，自动重试一次
        if (retryCount < 1) {
          logger.debug('⚠️ 加载文件助手消息失败，1秒后自动重试...');
          await Future.delayed(const Duration(seconds: 1));
          // 检查是否还在文件助手窗口
          if (mounted && _currentChatUserId == 0) {
            return _loadFileAssistantMessages(retryCount: retryCount + 1);
          }
        }

        setState(() {
          _isLoadingMessages = false;
          _messagesError = response['message'] ?? '加载消息失败';
        });
      }
    } catch (e) {
      // 如果加载失败且还没重试过，自动重试一次
      if (retryCount < 1) {
        logger.debug('⚠️ 加载文件助手消息异常: $e，1秒后自动重试...');
        await Future.delayed(const Duration(seconds: 1));
        // 检查是否还在文件助手窗口
        if (mounted && _currentChatUserId == 0) {
          return _loadFileAssistantMessages(retryCount: retryCount + 1);
        }
      }

      setState(() {
        _isLoadingMessages = false;
        _messagesError = '加载消息失败: $e';
      });
      logger.debug('加载文件助手消息失败: $e');
    }
  }

  // 发送通话结束消息
  Future<void> _sendCallEndedMessage(int targetUserId, int callDuration) async {
    if (_token == null || targetUserId == 0) {
      return;
    }

    // 🔴 修复：如果通话时长是 0，说明通话没有真正进行（可能是被拒绝或取消），不应该发送通话结束消息
    if (callDuration <= 0) {
      // logger.debug('📞 通话时长是 0，不发送通话结束消息');
      return;
    }

    try {
      // 标记正在发送通话相关消息
      _isSendingCallMessage = true;

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
      final callTypeStr = (_currentCallType == CallType.video)
          ? 'video'
          : 'voice';

      // 📝 日志：打印发送通话结束消息的参数
      // logger.debug('📞 准备发送通话结束消息:');
      // logger.debug('  - 目标用户ID: $targetUserId');
      // logger.debug('  - 通话时长: $durationText');
      // logger.debug(
      //   '  - 通话类型: $callTypeStr (${_currentCallType == CallType.video ? "视频" : "语音"})',
      // );

      // 根据通话类型确定消息类型
      final messageType = (_currentCallType == CallType.video)
          ? 'call_ended_video'
          : 'call_ended';

      // 发送通话结束消息
      final success = await _wsService.sendMessage(
        receiverId: targetUserId,
        content: durationText,
        messageType: messageType,
        callType: callTypeStr,
      );

      if (success) {
        logger.debug(
          '✅ 通话结束消息已发送: $durationText, 类型: $callTypeStr, messageType: $messageType',
        );

        // 🔴 修复：在本地创建通话结束消息，显示在自己的消息侧（对话框右边）
        if (_currentChatUserId == targetUserId) {
          // 创建临时消息对象并添加到列表（乐观更新UI）
          final tempMessage = MessageModel(
            id: 0, // 临时ID，等待服务器确认后更新
            senderId: _currentUserId,
            receiverId: targetUserId,
            senderName: _username,
            receiverName: '',
            senderAvatar: _userAvatar,
            receiverAvatar: null,
            senderFullName: _userFullName,
            content: durationText,
            messageType: messageType,
            callType: callTypeStr,
            isRead: false,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(tempMessage);
          });

          // 滚动到底部
          _scrollToBottom();

          // logger.debug('📞 已在对话框中添加通话结束消息: $durationText');
        }
      } else {
        // logger.debug('⚠️ 发送通话结束消息失败');
      }

      // 延迟一小段时间后清除标志，确保错误消息能够被正确处理
      Future.delayed(const Duration(milliseconds: 500), () {
        _isSendingCallMessage = false;
      });
    } catch (e) {
      // logger.debug('⚠️ 发送通话结束消息异常: $e');
      _isSendingCallMessage = false;
    }
  }

  // 发送群组通话发起消息
  Future<void> _sendGroupCallInitiatedMessage(
    int groupId,
    CallType callType,
  ) async {
    if (_token == null || groupId == 0) {
      return;
    }

    try {
      final callTypeText = callType == CallType.video ? '视频' : '语音';
      final content = '$_userDisplayName 发起了${callTypeText}通话';

      logger.debug('📞 准备发送群组通话发起消息:');
      logger.debug('  - 群组ID: $groupId');
      logger.debug('  - 内容: $content');

      // 不再由客户端发送通话发起消息，改由服务器端统一发送 join_voice_button 或 join_video_button 消息
      // final success = await _wsService.sendGroupMessage(
      //   groupId: groupId,
      //   content: content,
      //   messageType: 'call_initiated', // 通话发起消息类型（会显示在中间）
      // );

      logger.debug('✅ [PC端] 群组通话发起，服务器端将发送按钮消息');

      // 不再在本地添加消息，让服务器端统一处理
      // if (_isCurrentChatGroup && _currentChatUserId == groupId) {
      //   final newMessage = MessageModel(
      //     id: DateTime.now().millisecondsSinceEpoch, // 临时ID
      //     senderId: _currentUserId,
      //     receiverId: groupId,
      //     senderName: _userDisplayName.isNotEmpty ? _userDisplayName : _username,
      //     receiverName: '',
      //     senderAvatar: null,
      //     receiverAvatar: null,
      //     content: content,
      //     messageType: 'call_initiated', // 通话发起消息类型（会显示在中间）
      //     isRead: false,
      //     createdAt: DateTime.now(),
      //   );

      //   setState(() {
      //     _messages.add(newMessage);
      //   });

      //   // 滚动到底部
      //   _scrollToBottom();
      //   logger.debug('📞 已在群组对话框中添加通话发起消息');
      // }
    } catch (e) {
      logger.debug('⚠️ 发送群组通话发起消息异常: $e');
    }
  }

  // 发送群组通话结束消息
  Future<void> _sendGroupCallEndedMessage(int groupId, int callDuration) async {
    if (_token == null || groupId == 0) {
      return;
    }

    // 如果通话时长是 0，说明通话没有真正进行，不应该发送消息
    if (callDuration <= 0) {
      // logger.debug('📞 通话时长是 0，不发送群组通话结束消息');
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

      // 发送群组消息
      final success = await _wsService.sendGroupMessage(
        groupId: groupId,
        content: content,
        messageType: 'call_ended', // 通话结束消息类型（会显示在中间）
      );

      if (success) {
        // logger.debug('✅ 群组通话结束消息已发送');

        // 如果当前正在查看该群组，在本地创建消息
        if (_currentChatUserId == groupId && _isCurrentChatGroup) {
          final tempMessage = MessageModel(
            id: 0,
            senderId: 0, // 系统消息
            receiverId: groupId,
            senderName: '',
            receiverName: '',
            senderAvatar: null,
            receiverAvatar: null,
            content: content,
            messageType: 'call_ended', // 通话结束消息类型（会显示在中间）
            isRead: false,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(tempMessage);
          });

          // 滚动到底部
          _scrollToBottom();

          // logger.debug('📞 已在群组对话框中添加通话结束消息');
        }
      } else {
        // logger.debug('⚠️ 发送群组通话结束消息失败');
      }
    } catch (e) {
      // logger.debug('⚠️ 发送群组通话结束消息异常: $e');
    }
  }

  // 发送通话拒绝消息
  // isRejecter: true 表示是拒绝方（接收方），false 表示是发起方（收到拒绝通知）
  Future<void> _sendCallRejectedMessage(
    int targetUserId, {
    bool isRejecter = true,
  }) async {
    if (_token == null || targetUserId == 0) {
      return;
    }

    try {
      // 标记正在发送通话相关消息
      _isSendingCallMessage = true;

      // 🔴 修复：发送给对方的消息内容应该是对方看到的文本
      // 如果是接收方拒绝，发送给发起方的消息应该是"对方已拒绝"
      // 如果是发起方收到拒绝通知，发送给接收方的消息应该是"已拒绝"（这种情况不应该发生，但保留逻辑）
      final contentToSend = isRejecter ? '对方已拒绝' : '已拒绝';

      // 根据通话类型确定消息类型
      final messageType = (_currentCallType == CallType.video)
          ? 'call_rejected_video'
          : 'call_rejected';

      // 📝 日志：打印发送通话拒绝消息的参数
      logger.debug('📞 准备发送通话拒绝消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为拒绝方: $isRejecter');
      logger.debug(
        '  - 通话类型: ${_currentCallType == CallType.video ? "视频" : "语音"})',
      );
      logger.debug('  - 消息类型: $messageType');

      // 发送通话拒绝消息给对方
      final success = await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      if (success) {
        logger.debug('✅ 通话拒绝消息已发送给对方: $contentToSend, 类型: $messageType');

        // 🔴 修复：如果是接收方拒绝通话，需要在接收方的对话框中显示"已拒绝"的消息
        if (isRejecter && _currentChatUserId == targetUserId) {
          // 创建临时消息对象并添加到列表（乐观更新UI）
          final tempMessage = MessageModel(
            id: 0, // 临时ID，等待服务器确认后更新
            senderId: _currentUserId,
            receiverId: targetUserId,
            senderName: _username,
            receiverName: '',
            senderAvatar: _userAvatar,
            receiverAvatar: null,
            senderFullName: _userFullName,
            content: '已拒绝',
            messageType: messageType,
            isRead: false,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(tempMessage);
          });

          // 滚动到底部
          _scrollToBottom();

          logger.debug('📞 已在接收方对话框中添加"已拒绝"消息');
        }
        // 🔴 修复：如果是发起方收到拒绝通知，需要在发起方的对话框中显示"对方已拒绝"的消息
        else if (!isRejecter && _currentChatUserId == targetUserId) {
          // 创建临时消息对象并添加到列表（乐观更新UI）
          final tempMessage = MessageModel(
            id: 0, // 临时ID，等待服务器确认后更新
            senderId: _currentUserId,
            receiverId: targetUserId,
            senderName: _username,
            receiverName: '',
            senderAvatar: _userAvatar,
            receiverAvatar: null,
            senderFullName: _userFullName,
            content: '对方已拒绝',
            messageType: messageType,
            isRead: false,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(tempMessage);
          });

          // 滚动到底部
          _scrollToBottom();

          logger.debug('📞 已在发起方对话框中添加"对方已拒绝"消息');
        }
      } else {
        logger.debug('⚠️ 发送通话拒绝消息失败');
      }

      // 延迟一小段时间后清除标志，确保错误消息能够被正确处理
      Future.delayed(const Duration(milliseconds: 500), () {
        _isSendingCallMessage = false;
      });
    } catch (e) {
      logger.debug('⚠️ 发送通话拒绝消息异常: $e');
      _isSendingCallMessage = false;
    }
  }

  // 发送通话取消消息
  // isCaller: true 表示是发起方，false 表示是接收方
  Future<void> _sendCallCancelledMessage(
    int targetUserId, {
    bool isCaller = true,
  }) async {
    if (_token == null || targetUserId == 0) {
      return;
    }

    try {
      // 标记正在发送通话相关消息
      _isSendingCallMessage = true;

      // 🔴 修复：发送给对方的消息内容应该是对方看到的文本
      // 如果是发起方取消，发送给对方的内容应该是"对方已取消"
      // 如果是接收方收到取消通知，发送给对方的内容应该是"已取消"（这种情况不应该发生，但保留逻辑）
      final contentToSend = isCaller ? '对方已取消' : '已取消';

      // 根据通话类型确定消息类型
      final messageType = (_currentCallType == CallType.video)
          ? 'call_cancelled_video'
          : 'call_cancelled';

      // 📝 日志：打印发送通话取消消息的参数
      logger.debug('📞 准备发送通话取消消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为发起方: $isCaller');
      logger.debug(
        '  - 通话类型: ${_currentCallType == CallType.video ? "视频" : "语音"})',
      );
      logger.debug('  - 消息类型: $messageType');

      // 发送通话取消消息给对方
      final success = await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      if (success) {
        logger.debug('✅ 通话取消消息已发送给对方: $contentToSend, 类型: $messageType');

        // 🔴 修复：如果是发起方取消通话，需要在发起方的对话框中显示"已取消"的消息
        if (isCaller && _currentChatUserId == targetUserId) {
          // 创建临时消息对象并添加到列表（乐观更新UI）
          final tempMessage = MessageModel(
            id: 0, // 临时ID，等待服务器确认后更新
            senderId: _currentUserId,
            receiverId: targetUserId,
            senderName: _username,
            receiverName: '',
            senderAvatar: _userAvatar,
            receiverAvatar: null,
            senderFullName: _userFullName,
            content: '已取消',
            messageType: messageType,
            isRead: false,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(tempMessage);
          });

          // 滚动到底部
          _scrollToBottom();

          logger.debug('📞 已在发起方对话框中添加"已取消"消息');
        }
      } else {
        logger.debug('⚠️ 发送通话取消消息失败');
      }

      // 延迟一小段时间后清除标志，确保错误消息能够被正确处理
      Future.delayed(const Duration(milliseconds: 500), () {
        _isSendingCallMessage = false;
      });
    } catch (e) {
      logger.debug('⚠️ 发送通话取消消息异常: $e');
      _isSendingCallMessage = false;
    }
  }

  // 发送消息（文本或图片）
  Future<bool> _sendMessage({
    String? imageUrl,
    String messageType = 'text',
    String? fileName,
    bool autoScroll = true, // 是否自动滚动到底部
    int? tempMessageId, // 临时消息ID，用于替换加载消息
  }) async {
    String content;

    if (messageType == 'image' && imageUrl != null) {
      content = imageUrl;
    } else if (messageType == 'file' && imageUrl != null) {
      content = imageUrl;
    } else if (messageType == 'video' && imageUrl != null) {
      content = imageUrl;
    } else {
      content = _messageInputController.text.trim();
      if (content.isEmpty || _currentChatUserId == null) {
        return false;
      }
    }

    if (_currentChatUserId == null) {
      return false;
    }

    if (_isSendingMessage) {
      return false; // 防止重复发
    }

    setState(() {
      _isSendingMessage = true;
    });

    try {
      // 获取引用信息
      // 🔴 使用serverId（服务器ID）而不是本地ID，确保接收方能找到被引用的消息
      final quotedId = _quotedMessage?.serverId ?? _quotedMessage?.id;
      final quotedContent = _quotedMessage != null
          ? _getQuotedMessagePreview(_quotedMessage!)
          : null;

      // 如果有引用消息且是文本类型，将消息类型设置为 quoted
      String finalMessageType = messageType;
      if (_quotedMessage != null && messageType == 'text') {
        finalMessageType = 'quoted';
        logger.debug(
          '📝 发送引用消- 原消息ID: ${_quotedMessage!.id}, 引用内容: $quotedContent',
        );
      }

      logger.debug(
        '📤 发送消- 类型: $finalMessageType, 内容: $content, 是否群组: $_isCurrentChatGroup',
      );

      bool success;

      // 判断是否为文件助
      if (_currentChatUserId == 0) {
        // 文件助手消息通过HTTP API发
        logger.debug('📤 发送消息到文件助手 - 类型: $finalMessageType, 内容: $content');

        final token = _token;
        if (token == null || token.isEmpty) {
          setState(() {
            _isSendingMessage = false;
          });
          return false;
        }

        try {
          final response = await ApiService.sendFileAssistantMessage(
            token: token,
            content: content,
            messageType: finalMessageType,
            fileName: fileName,
            quotedMessageId: quotedId,
            quotedMessageContent: quotedContent,
          );

          success = response['code'] == 0;

          if (success) {
            // 创建新消息并添加到列
            final messageData = response['data'] as Map<String, dynamic>;
            final newMessage = MessageModel(
              id: messageData['id'] as int,
              senderId: _currentUserId,
              receiverId: _currentUserId,
              senderName: _username,
              receiverName: '文件传输助手',
              senderFullName: _userFullName,
              content: content,
              messageType: finalMessageType,
              fileName: fileName,
              quotedMessageId: quotedId,
              quotedMessageContent: quotedContent,
              status: 'normal',
              isRead: true,
              createdAt: DateTime.parse(messageData['created_at'] as String),
            );

            setState(() {
              // 如果有临时消息ID，替换它；否则添加新消息
              if (tempMessageId != null) {
                _replaceProgressMessage(tempMessageId, newMessage);
              } else {
                _messages.add(newMessage);
              }
              _isSendingMessage = false;
              // 清空输入框和引用消息
              if (messageType == 'text' || finalMessageType == 'quoted') {
                _messageInputController.clear();
              }
              _quotedMessage = null;
            });

            // 发送方也需要滚动到底部，显示刚发送的消息
            if (autoScroll) {
              _scrollToBottom();
            }
            logger.debug('文件助手消息发送成功');

            // 刷新最近联系人列表
            _loadRecentContacts();

            // 文件助手处理完成，直接返回，不走后面的通用逻辑
            return true;
          }
        } catch (e) {
          logger.debug('发送文件助手消息失 $e');
          success = false;
        }

        // 如果文件助手发送失败，重置状态并返回
        setState(() {
          _isSendingMessage = false;
        });
        return false;
      } else if (_isCurrentChatGroup) {
        // 检查是否已被移除群组
        if (_currentChatUserId != null &&
            _removedGroupIds.contains(_currentChatUserId)) {
          setState(() {
            _isSendingMessage = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('您已被移除群组'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return false;
        }

        // 群组消息：在发送之前创建临时消息（参考APP端实现）
        final messageId = tempMessageId ?? DateTime.now().millisecondsSinceEpoch;
        _lastSentTempMessageId = messageId; // 保存临时ID用于错误处理
        
        logger.debug('');
        logger.debug('========== 发送群组@消息调试信息 ==========');
        logger.debug('📤 发送群组消息');
        logger.debug('📤 群组ID: $_currentChatUserId');
        logger.debug('📤 临时ID: $messageId');
        logger.debug('📤 @文本: $_mentionText');
        logger.debug('📤 @的用户ID列表: $_mentionedUserIds');
        logger.debug('📤 消息内容: $content');
        logger.debug('=====================================');
        logger.debug('');

        // 创建临时消息并添加到列表
        final tempMessage = MessageModel(
          id: messageId,
          senderId: _currentUserId,
          receiverId: _currentChatUserId!,
          senderName: _username,
          receiverName: '',
          senderAvatar: _userAvatar,
          receiverAvatar: null,
          senderFullName: _userFullName,
          content: content,
          messageType: finalMessageType,
          fileName: fileName,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
          mentionedUserIds: _mentionedUserIds.isNotEmpty
              ? _mentionedUserIds
              : null,
          mentions: _mentionText.isNotEmpty ? _mentionText : null,
          isRead: false,
          createdAt: DateTime.now(),
          status: 'sent', // 初始状态为已发送，错误时会更新为failed
        );

        logger.debug('➕ [发送群组消息] 先在UI中添加消息 - 临时ID: $messageId, 已保存用于错误追踪');
        
        setState(() {
          if (tempMessageId != null) {
            _replaceProgressMessage(tempMessageId, tempMessage);
          } else {
            _messages.add(tempMessage);
          }
        });

        // 然后发送WebSocket消息
        success = await _wsService.sendGroupMessage(
          groupId: _currentChatUserId!,
          content: content,
          messageType: finalMessageType,
          fileName: fileName,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
          mentionedUserIds: _mentionedUserIds.isNotEmpty
              ? _mentionedUserIds
              : null,
          mentions: _mentionText.isNotEmpty ? _mentionText : null,
        );
      } else {
        // 在发送之前创建临时消息（参考APP端实现）
        final messageId = tempMessageId ?? DateTime.now().millisecondsSinceEpoch;
        _lastSentTempMessageId = messageId; // 保存临时ID用于错误处理
        
        final tempMessage = MessageModel(
          id: messageId,
          senderId: _currentUserId,
          receiverId: _currentChatUserId!,
          senderName: _username,
          receiverName: '',
          senderAvatar: _userAvatar,
          receiverAvatar: null,
          senderFullName: _userFullName,
          content: content,
          messageType: finalMessageType,
          fileName: fileName,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
          mentionedUserIds: _mentionedUserIds.isNotEmpty
              ? _mentionedUserIds
              : null,
          mentions: _mentionText.isNotEmpty ? _mentionText : null,
          isRead: false,
          createdAt: DateTime.now(),
          status: 'sent', // 初始状态为已发送，错误时会更新为failed
        );

        logger.debug(
          '➕ [发送消息] 先在UI中添加消息 - 临时ID: $messageId, 已保存用于错误追踪',
        );
        
        setState(() {
          if (tempMessageId != null) {
            _replaceProgressMessage(tempMessageId, tempMessage);
          } else {
            _messages.add(tempMessage);
          }
        });
        
        // 私聊消息通过WebSocket发
        success = await _wsService.sendMessage(
          receiverId: _currentChatUserId!,
          content: content,
          messageType: finalMessageType,
          fileName: fileName,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
        );
      }

      if (success) {
        // 如果是文本消息或引用消息，清空输入框和引用消
        if (messageType == 'text' || finalMessageType == 'quoted') {
          _messageInputController.clear();
        }

        setState(() {
          _isSendingMessage = false;
          // 清空引用消息和@信息
          _quotedMessage = null;
          _mentionedUserIds = [];
          _mentionText = '';

          // 立即更新最近联系人列表中的最后消息（乐观更新）
          if (_isCurrentChatGroup) {
            // 群组消息
            final contactIndex = _recentContacts.indexWhere(
              (contact) =>
                  contact.isGroup && contact.groupId == _currentChatUserId,
            );
            if (contactIndex != -1) {
              // 根据消息类型格式化显示内容
              final formattedMessage = _formatMessagePreviewForRecentContact(
                finalMessageType,
                content,
              );
              // 确保未读计数为0（因为发送者正在查看该群组）
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    lastMessage: formattedMessage,
                    lastMessageTime: DateTime.now().toIso8601String(),
                    unreadCount: 0, // 发送者正在查看，未读计数应为0
                  );
              // 将该群组移到列表顶部
              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);
                // 如果移动的是当前选中的联系人，更新索引
                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }
              logger.debug(
                '✅ 发送群组消息时已清除未读计数（发送者正在查看）: groupId=$_currentChatUserId',
              );
            }
          } else {
            // 私聊消息
            final contactIndex = _recentContacts.indexWhere(
              (contact) =>
                  !contact.isGroup && contact.userId == _currentChatUserId,
            );
            if (contactIndex != -1) {
              // 根据消息类型格式化显示内容
              final formattedMessage = _formatMessagePreviewForRecentContact(
                finalMessageType,
                content,
              );
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    lastMessage: formattedMessage,
                    lastMessageTime: DateTime.now().toIso8601String(),
                  );
              // 将该联系人移到列表顶部
              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);
                // 如果移动的是当前选中的联系人，更新索引
                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }
            }
          }
        });

        // PC端优化：不刷新整个最近联系人列表，消息发送时已通过WebSocket回传更新
        // _loadRecentContacts();

        // 发送方也需要滚动到底部，显示刚发送的消息
        if (autoScroll) {
          _scrollToBottom();
        }
        return true;
      } else {
        setState(() {
          _isSendingMessage = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('发送失败，请重试')));
        }
        return false;
      }
    } catch (e) {
      setState(() {
        _isSendingMessage = false;
      });
      logger.debug('发送消息失败 $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败 $e')));
      }
      return false;
    }
  }

  // 选择图片（支持多选）
  Future<void> _pickImage() async {
    try {
      // 请求存储权限
      final status = await Permission.storage.request();

      // Android 13+ 需要请求媒体权限
      if (!status.isGranted) {
        final mediaStatus = await Permission.photos.request();
        if (!mediaStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('需要存储权限才能选择图片')));
          }
          return;
        }
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true, // 允许多
        withData: false, // 禁用自动压缩，避免权限问题
        allowCompression: false, // 禁用压缩
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          // 将新选择的图片添加到列表
          for (var file in result.files) {
            if (file.path != null) {
              _selectedImageFiles.add(File(file.path!));
            }
          }
        });
      }
    } catch (e) {
      logger.debug('选择图片失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择图片失败: $e')));
      }
    }
  }

  // 发送消息（同时发送图片、文件和文本
  Future<void> _sendMessageWithImage() async {
    if (_currentChatUserId == null) {
      return;
    }

    final textContent = _messageInputController.text.trim();
    final hasImages = _selectedImageFiles.isNotEmpty;
    final hasVideos = _selectedVideoFiles.isNotEmpty;
    final hasFiles = _selectedFiles.isNotEmpty;
    final hasText = textContent.isNotEmpty;

    // 如果既没有图片、视频、文件也没有文本，不发
    if (!hasImages && !hasVideos && !hasFiles && !hasText) {
      return;
    }

    try {
      final token = _token;
      if (token == null) {
        throw Exception('未登录');
      }

      // 1. 先发送所有图片（如果有）
      if (hasImages) {
        setState(() {
          _isUploadingImage = true;
        });

        // 循环上传并发送所有图片
        for (var imageFile in _selectedImageFiles) {
          final fileSize = await imageFile.length();
          if (fileSize > kMaxImageUploadBytes) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('图片大小不能超过32MB')),
              );
            }
            continue;
          }

          // 先创建加载消息
          final fileName = path.basename(imageFile.path);
          final tempId = _addUploadProgressMessage(fileName, 'image');

          try {
            // 上传图片到OSS
            final response = await ApiService.uploadImage(
              token: token,
              filePath: imageFile.path,
            );

            if (response['code'] == 0 && response['data'] != null) {
              final imageUrl = response['data']['url'];

              // 发送图片消息
              final success = await _sendMessage(
                imageUrl: imageUrl,
                messageType: 'image',
                autoScroll: false, // 图片发送时不滚动
                tempMessageId: tempId, // 传递临时消息ID用于替换
              );

              if (!success) {
                // 发送失败，移除加载消息
                _removeProgressMessage(tempId);
              }
            } else {
              // 上传失败，移除加载消息
              _removeProgressMessage(tempId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(response['message'] ?? '图片上传失败')),
                );
              }
              setState(() {
                _isUploadingImage = false;
              });
              return; // 某张图片上传失败就不继续
            }
          } catch (e) {
            // 异常处理，移除加载消息
            _removeProgressMessage(tempId);
            throw e;
          }
        }

        setState(() {
          _isUploadingImage = false;
          _selectedImageFiles.clear(); // 清空已发送的图片
        });
      }

      // 2. 再发送所有视频（如果有）
      if (hasVideos) {
        setState(() {
          _isUploadingVideo = true;
        });

        // 循环上传并发送所有视频（使用分片上传）
        for (var videoFile in _selectedVideoFiles) {
          final fileSize = await videoFile.length();
          if (fileSize > kMaxVideoUploadBytes) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('视频大小不能超过500MB')),
              );
            }
            continue;
          }

          // 先创建加载消息
          final fileName = path.basename(videoFile.path);
          final tempId = _addUploadProgressMessage(fileName, 'video');

          try {
            // 使用分片上传视频到OSS
            final result = await VideoUploadService.uploadVideo(
              token: token,
              filePath: videoFile.path,
            );

            final videoUrl = result['url'] as String;

            // 发送视频消息
            final success = await _sendMessage(
              imageUrl: videoUrl,
              messageType: 'video',
              autoScroll: false, // 视频发送时不滚动
              tempMessageId: tempId, // 传递临时消息ID用于替换
            );

            if (!success) {
              // 发送失败，移除加载消息
              _removeProgressMessage(tempId);
            }
          } catch (e) {
            // 上传失败，移除加载消息
            _removeProgressMessage(tempId);
            logger.debug('❌ 视频上传失败: $e');
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('视频上传失败: $e')));
            }
            setState(() {
              _isUploadingVideo = false;
            });
            return; // 某个视频上传失败就不继续
          }
        }

        setState(() {
          _isUploadingVideo = false;
          _selectedVideoFiles.clear(); // 清空已发送的视频
        });
      }

      // 3. 再发送所有文件（如果有）
      if (hasFiles) {
        setState(() {
          _isUploadingFile = true;
        });

        // 循环上传并发送所有文件
        for (var file in _selectedFiles) {
          final fileSize = await file.length();
          if (fileSize > kMaxFileUploadBytes) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('文件大小不能超过1GB')),
              );
            }
            continue;
          }

          // 先创建加载消息
          final fileName = path.basename(file.path);
          final tempId = _addUploadProgressMessage(fileName, 'file');

          try {
            // 上传文件到OSS
            final response = await ApiService.uploadFile(
              token: token,
              filePath: file.path,
            );

            if (response['code'] == 0 && response['data'] != null) {
              final fileUrl = response['data']['url'];
              final uploadedFileName = response['data']['file_name'];

              // 发送文件消息
              final success = await _sendMessage(
                imageUrl: fileUrl,
                messageType: 'file',
                fileName: uploadedFileName,
                autoScroll: false, // 文件发送时不滚动
                tempMessageId: tempId, // 传递临时消息ID用于替换
              );

              if (!success) {
                // 发送失败，移除加载消息
                _removeProgressMessage(tempId);
              }
            } else {
              // 上传失败，移除加载消息
              _removeProgressMessage(tempId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(response['message'] ?? '文件上传失败')),
                );
              }
              setState(() {
                _isUploadingFile = false;
              });
              return; // 某个文件上传失败就不继续
            }
          } catch (e) {
            // 异常处理，移除加载消息
            _removeProgressMessage(tempId);
            throw e;
          }
        }

        setState(() {
          _isUploadingFile = false;
          _selectedFiles.clear(); // 清空已发送的文件
        });
      }

      // 4. 最后发送文本（如果有）
      if (hasText) {
        await _sendMessage(
          messageType: 'text',
          autoScroll: false, // 文本发送时不滚动
        );
      }

      // 5. 所有内容发送完毕后，发送方也需要滚动到底部
      if (hasImages || hasVideos || hasFiles || hasText) {
        _scrollToBottom();
      }
    } catch (e) {
      setState(() {
        _isUploadingImage = false;
        _isUploadingVideo = false;
        _isUploadingFile = false;
        _isSendingMessage = false;
      });
      logger.debug('发送失 $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失 $e')));
      }
    }
  }

  // 删除指定索引的图
  void _removeImage(int index) {
    setState(() {
      if (index >= 0 && index < _selectedImageFiles.length) {
        _selectedImageFiles.removeAt(index);
      }
    });
  }

  // 选择视频（支持多选）
  Future<void> _pickVideo() async {
    try {
      // 请求存储权限
      final status = await Permission.storage.request();

      // Android 13+ 需要请求媒体权限
      if (!status.isGranted) {
        final mediaStatus = await Permission.videos.request();
        if (!mediaStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('需要存储权限才能选择视频')));
          }
          return;
        }
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true, // 允许多选
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          // 将新选择的视频添加到列表
          for (var file in result.files) {
            if (file.path != null) {
              _selectedVideoFiles.add(File(file.path!));
            }
          }
        });
      }
    } catch (e) {
      logger.debug('选择视频失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择视频失败: $e')));
      }
    }
  }

  // 检测文件类型
  String _getFileType(String filePath) {
    final ext = filePath.toLowerCase().split('.').last;
    // 图片格式
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(ext)) {
      return 'image';
    }
    // 视频格式
    if ([
      'mp4',
      'avi',
      'mov',
      'wmv',
      'flv',
      'mkv',
      'webm',
      'm4v',
      '3gp',
    ].contains(ext)) {
      return 'video';
    }
    // 其他文件
    return 'file';
  }

  // 创建并添加上传加载消息
  int _addUploadProgressMessage(String fileName, String messageType) {
    final tempId = _tempMessageIdCounter--;
    final progressMessage = MessageModel(
      id: tempId,
      senderId: _currentUserId,
      receiverId: _currentChatUserId!,
      senderName: _userDisplayName,
      receiverName: _isCurrentChatGroup ? '' : _getReceiverName(),
      senderAvatar: _userAvatar,
      content: '', // 加载消息不需要内容
      messageType: 'upload_progress', // 特殊的消息类型
      fileName: fileName,
      status: messageType, // 用status字段存储实际的文件类型
      isRead: true,
      createdAt: DateTime.now(),
    );

    setState(() {
      _messages.add(progressMessage);
      _uploadProgressMessages[tempId] = fileName;
    });

    // 滚动到底部显示加载消息
    _scrollToBottom();

    return tempId;
  }

  // 替换加载消息为实际消息
  void _replaceProgressMessage(int tempId, MessageModel realMessage) {
    final index = _messages.indexWhere((msg) => msg.id == tempId);
    logger.debug(
      '替换进度消息 - tempId: $tempId, 找到索引: $index, 真实消息ID: ${realMessage.id}',
    );
    if (index != -1) {
      setState(() {
        _messages[index] = realMessage;
        _uploadProgressMessages.remove(tempId);
      });
    } else {
      logger.debug('❌ 未找到要替换的进度消息，tempId: $tempId');
      // 如果没找到要替换的消息，直接添加新消息
      setState(() {
        _messages.add(realMessage);
        _uploadProgressMessages.remove(tempId);
      });
    }
  }

  // 移除加载消息（上传失败时）
  void _removeProgressMessage(int tempId) {
    setState(() {
      _messages.removeWhere((msg) => msg.id == tempId);
      _uploadProgressMessages.remove(tempId);
    });
  }

  // 获取接收者名称
  String _getReceiverName() {
    if (_isCurrentChatGroup) {
      return _selectedGroup?.name ?? '';
    } else {
      // 从最近联系人中获取接收者名称
      final recentContact = _recentContacts.firstWhere(
        (contact) => !contact.isGroup && contact.userId == _currentChatUserId,
        orElse: () => RecentContactModel(
          userId: _currentChatUserId!,
          username: '',
          fullName: '未知用户',
          lastMessage: '',
          lastMessageTime: DateTime.now().toIso8601String(),
          unreadCount: 0,
        ),
      );
      return recentContact.fullName;
    }
  }

  // 🔴 新增：重新打开最小化的通话
  Future<void> _reopenMinimizedCall() async {
    try {
      logger.debug('📞 [重新打开通话] 用户点击"通话中..."按钮');
      
      if (_agoraService == null || !_agoraService!.isCallMinimized) {
        logger.debug('❌ [重新打开通话] 没有最小化的通话');
        return;
      }
      
      // 从AgoraService获取最小化通话的信息
      final callUserId = _agoraService!.minimizedCallUserId;
      final callDisplayName = _agoraService!.minimizedCallDisplayName;
      final callType = _agoraService!.minimizedCallType;
      final isGroupCall = _agoraService!.isMinimizedGroupCall;
      final groupId = _agoraService!.minimizedGroupId;
      final groupCallUserIds = _agoraService!.minimizedGroupCallUserIds;
      final groupCallDisplayNames = _agoraService!.minimizedGroupCallDisplayNames;
      
      logger.debug('📞 [重新打开通话] 通话信息:');
      logger.debug('  - callUserId: $callUserId');
      logger.debug('  - callDisplayName: $callDisplayName');
      logger.debug('  - callType: $callType');
      logger.debug('  - isGroupCall: $isGroupCall');
      logger.debug('  - groupId: $groupId');
      logger.debug('  - groupCallUserIds: $groupCallUserIds');
      
      if (callType == CallType.video) {
        // 重新打开视频通话
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupVideoCallPage(
              targetUserId: callUserId ?? 0,
              targetDisplayName: callDisplayName ?? 'Unknown',
              isIncoming: false, // 重新进入不算来电
              groupCallUserIds: groupCallUserIds,
              groupCallDisplayNames: groupCallDisplayNames,
              currentUserId: _currentUserId,
              groupId: groupId,
            ),
          ),
        );
      } else {
        // 重新打开语音通话
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => VoiceCallPage(
              targetUserId: callUserId ?? 0,
              targetDisplayName: callDisplayName ?? 'Unknown',
              isIncoming: false, // 重新进入不算来电
              groupCallUserIds: groupCallUserIds,
              groupCallDisplayNames: groupCallDisplayNames,
              currentUserId: _currentUserId,
              groupId: groupId,
            ),
          ),
        );
      }
      logger.debug('✅ [重新打开通话] 已重新打开通话页面');
    } catch (e) {
      logger.debug('❌ [重新打开通话] 错误: $e');
      _showSnackBar('重新打开通话失败: $e');
    }
  }

  // 处理加入群组通话
  Future<void> _handleJoinGroupCall(MessageModel message) async {
    try {
      logger.debug('📞 [PC端-加入通话] 用户点击加入通话按钮');
      
      // 检查必要参数
      if (message.channelName == null || message.channelName!.isEmpty) {
        logger.debug('❌ [PC端-加入通话] channelName为空');
        _showSnackBar('通话信息不完整，无法加入');
        return;
      }

      // 🔴 修复：检查是否已在其他通话中 - 如果是，提示错误
      if (_agoraService?.isMinimized == true) {
        logger.debug('⚠️ [PC端-加入通话] 已在其他通话中');
        _showSnackBar('您已在其他通话中，请先挂断当前通话');
        return;
      }

      final token = await Storage.getToken();
      
      if (token == null) {
        logger.debug('❌ [PC端-加入通话] token为空');
        _showSnackBar('登录信息已过期，请重新登录');
        return;
      }

      logger.debug('📞 [PC端-加入通话] 准备加入: channel=${message.channelName}, callType=${message.callType}');

      // 调用acceptGroupCall API，加入通话
      final acceptResponse = await ApiService.acceptGroupCall(
        token: token,
        channelName: message.channelName!,
      );
      logger.debug('✅ [PC端-加入通话] API调用成功');
      logger.debug('📞 [PC端-加入通话] 获取到频道信息: ${acceptResponse['channel_name']}');
      logger.debug('📞 [PC端-加入通话] 获取到Token: ${acceptResponse['token']?.toString().substring(0, 20)}...');

      // 获取群组成员信息（如果是群聊）
      List<int>? groupCallUserIds;
      List<String>? groupCallDisplayNames;
      
      if (_isCurrentChatGroup && _currentChatUserId != null) {
        try {
          final response = await ApiService.getGroupDetail(
            token: token,
            groupId: _currentChatUserId!,
          );
          
          if (response['code'] == 0 && response['data'] != null) {
            final members = response['data']['members'] as List<dynamic>?;
            if (members != null) {
              groupCallUserIds = [];
              groupCallDisplayNames = [];
              for (var member in members) {
                final userId = member['user_id'] as int?;
                final fullName = member['full_name'] as String?;
                final username = member['username'] as String?;
                if (userId != null) {
                  groupCallUserIds.add(userId);
                  groupCallDisplayNames.add(fullName?.isNotEmpty == true ? fullName! : (username ?? 'User$userId'));
                }
              }
              logger.debug('📞 [PC端-加入通话] 获取到群组成员: ${groupCallUserIds.length}人');
            }
          }
        } catch (e) {
          logger.debug('⚠️ [PC端-加入通话] 获取群组成员失败: $e');
        }
      }

      // 🔴 新增：设置AgoraService的频道信息（主动加入通话时需要）
      // 使用acceptGroupCall API返回的频道信息和Token
      if (_agoraService?.currentChannelName == null) {
        final callType = message.callType == 'video' ? CallType.video : CallType.voice;
        _agoraService?.setGroupCallChannel(
          acceptResponse['channel_name'] ?? message.channelName!,
          acceptResponse['token'] ?? '', // 使用API返回的Token
          callType,
          groupId: _isCurrentChatGroup ? _currentChatUserId : null,
          memberUserIds: groupCallUserIds,
          memberDisplayNames: groupCallDisplayNames,
        );
        logger.debug('✅ [PC端-加入通话] 已设置AgoraService频道信息');
      }

      // 导航到通话页面
      final callType = message.callType == 'video' ? CallType.video : CallType.voice;
      
      if (callType == CallType.video) {
        // 视频通话
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupVideoCallPage(
              targetUserId: message.senderId,
              targetDisplayName: message.displaySenderName,
              isIncoming: true,
              groupCallUserIds: groupCallUserIds,
              groupCallDisplayNames: groupCallDisplayNames,
              currentUserId: _currentUserId,
              groupId: _isCurrentChatGroup ? _currentChatUserId : null,
            ),
          ),
        );
      } else {
        // 语音通话 - 修复：主动加入通话应该设置为 isIncoming: false
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => VoiceCallPage(
              targetUserId: message.senderId,
              targetDisplayName: message.displaySenderName,
              isIncoming: false, // 🔴 修复：主动加入通话，不是来电
              groupCallUserIds: groupCallUserIds,
              groupCallDisplayNames: groupCallDisplayNames,
              currentUserId: _currentUserId,
              groupId: _isCurrentChatGroup ? _currentChatUserId : null,
              isJoiningExistingCall: true, // 🔴 新增：标记为加入已存在的通话
            ),
          ),
        );
      }
      logger.debug('✅ [PC端-加入通话] 已导航到通话页面');
    } catch (e) {
      logger.debug('❌ [PC端-加入通话] 错误: $e');
      _showSnackBar('加入通话失败: $e');
    }
  }

  // 获取当前用户的头像文字（优先使用昵称）
  String _getUserAvatarText() {
    // 优先使用昵称（_userFullName），没有昵称才使用用户名（_username）
    final nameForAvatar = (_userFullName != null && _userFullName!.isNotEmpty)
        ? _userFullName!
        : (_username.isNotEmpty ? _username : '我');
    
    // 取后两个字符
    return nameForAvatar.length >= 2
        ? nameForAvatar.substring(nameForAvatar.length - 2)
        : nameForAvatar;
  }

  // 构建头像
  Widget _buildAvatar({
    required String avatarText,
    String? avatarUrl,
    required bool isOnline,
    double size = 40,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(4),
        color: const Color(0xFF4A90E2),
        image: avatarUrl != null && avatarUrl.isNotEmpty
            ? DecorationImage(image: NetworkImage(avatarUrl), fit: BoxFit.cover)
            : null,
      ),
      child: avatarUrl == null || avatarUrl.isEmpty
          ? Center(
              child: Text(
                avatarText,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
    );
  }

  // 构建上传进度内容
  Widget _buildUploadProgressContent(MessageModel message) {
    final fileType = message.status ?? 'file'; // status字段存储了实际的文件类型
    final fileName = message.fileName ?? '未知文件';

    Widget icon;
    String typeText;

    switch (fileType) {
      case 'image':
        icon = const Icon(Icons.image, color: Color(0xFF4A90E2), size: 40);
        typeText = '图片';
        break;
      case 'video':
        icon = const Icon(Icons.videocam, color: Color(0xFF4A90E2), size: 40);
        typeText = '视频';
        break;
      case 'file':
      default:
        icon = Icon(
          _getFileIcon(fileName),
          color: const Color(0xFF4A90E2),
          size: 40,
        );
        typeText = '文件';
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fileName,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF333333),
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        const Color(0xFF999999),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在上传$typeText...',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 选择文件（支持多选，自动检测图片和视频）
  Future<void> _pickFiles() async {
    try {
      // 请求存储权限
      final status = await Permission.storage.request();

      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('需要存储权限才能选择文件')));
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true, // 允许多选
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          // 根据文件类型分类添加到不同的列表
          for (var file in result.files) {
            if (file.path != null) {
              final fileType = _getFileType(file.path!);
              final fileObj = File(file.path!);

              if (fileType == 'image') {
                // 图片文件添加到图片列表
                _selectedImageFiles.add(fileObj);
              } else if (fileType == 'video') {
                // 视频文件添加到视频列表
                _selectedVideoFiles.add(fileObj);
              } else {
                // 其他文件添加到文件列表
                _selectedFiles.add(fileObj);
              }
            }
          }
        });
      }
    } catch (e) {
      logger.debug('选择文件失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件失败: $e')));
      }
    }
  }

  // 删除指定索引的视频
  void _removeVideo(int index) {
    setState(() {
      if (index >= 0 && index < _selectedVideoFiles.length) {
        _selectedVideoFiles.removeAt(index);
      }
    });
  }

  // 删除指定索引的文
  void _removeFile(int index) {
    setState(() {
      if (index >= 0 && index < _selectedFiles.length) {
        _selectedFiles.removeAt(index);
      }
    });
  }

  // 截图功能
  Future<void> _captureScreen() async {
    try {
      // 使用 screen_capturer 插件进行截图
      final screenCapturer = ScreenCapturer.instance;

      // 截取屏幕区域（会弹出选择区域的界面）
      final capturedData = await screenCapturer.capture(
        mode: CaptureMode.region, // 区域截图模式
        imagePath: null, // 不保存到文件，直接获取数
        copyToClipboard: false, // 我们手动复制到剪贴板
      );

      if (capturedData != null && capturedData.imageBytes != null) {
        // 将截图数据写入临时文
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final tempFile = File('${tempDir.path}/screenshot_$timestamp.png');
        await tempFile.writeAsBytes(capturedData.imageBytes!);

        // 将截图复制到剪贴
        await Pasteboard.writeImage(capturedData.imageBytes!);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('截图已复制到剪贴板，请按 Ctrl+V 粘贴到输入框'),
              duration: Duration(seconds: 2),
            ),
          );
        }

        // 聚焦到输入框，方便用户粘
        _messageInputFocusNode.requestFocus();
      }
    } catch (e) {
      logger.debug('截图失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('截图失败: $e')));
      }
    }
  }

  // 从剪贴板粘贴内容（支持图片和文本
  Future<bool> _pasteFromClipboard() async {
    try {
      // 首先尝试读取图片
      final imageBytes = await Pasteboard.image;

      if (imageBytes != null && imageBytes.isNotEmpty) {
        // 粘贴图片
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final tempFile = File('${tempDir.path}/paste_$timestamp.png');
        await tempFile.writeAsBytes(imageBytes);

        setState(() {
          _selectedImageFiles.add(tempFile);
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('图片已粘贴到输入框'),
              duration: Duration(seconds: 1),
            ),
          );
        }
        return true; // 已处理
      }

      // 如果没有图片，尝试读取文
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData != null &&
          clipboardData.text != null &&
          clipboardData.text!.isNotEmpty) {
        // 粘贴文本到输入框
        final text = clipboardData.text!;
        final currentText = _messageInputController.text;
        final selection = _messageInputController.selection;

        // 获取当前光标位置
        final cursorPosition = selection.baseOffset;

        // 在光标位置插入文
        final newText =
            currentText.substring(0, cursorPosition) +
            text +
            currentText.substring(selection.extentOffset);

        _messageInputController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: cursorPosition + text.length,
          ),
        );

        return true; // 已处理
      }

      // 剪贴板中既没有图片也没有文本
      return false;
    } catch (e) {
      logger.debug('粘贴失败: $e');
      return false;
    }
  }

  // 获取文件图标
  IconData _getFileIcon(String fileName) {
    final ext = fileName.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'txt':
        return Icons.text_snippet;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
        return Icons.audio_file;
      default:
        return Icons.insert_drive_file;
    }
  }

  // 构建语音消息气泡（PC端）
  Widget _buildVoiceMessageBubble(MessageModel message, bool isSelf) {
    final duration = message.voiceDuration ?? 0;
    
    // 打印日志定位问题
    logger.debug('🎵 [语音气泡] message.id: ${message.id}, voiceDuration: ${message.voiceDuration}, duration: $duration');
    
    // 使用完整的 VoiceMessageBubble 组件，支持播放功能
    return VoiceMessageBubble(
      url: message.content,
      duration: duration,
      isMe: isSelf,
    );
  }

  // 格式化语音时长
  String _formatVoiceDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '$minutes:${secs.toString().padLeft(2, '0')}';
    }
    return '$secs"';
  }

  // 显示对方的用户信
  Future<void> _showOtherUserInfo(int userId) async {
    try {
      logger.debug('');
      logger.debug('============ [查看用户信息] ============');
      logger.debug('🔍 目标用户ID: $userId');
      logger.debug('🔍 是否群聊: $_isCurrentChatGroup');
      logger.debug('🔍 当前用户ID: $_currentUserId');
      logger.debug('🔍 当前聊天ID: $_currentChatUserId');
      logger.debug('=====================================');
      logger.debug('');

      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      // 如果是群聊，先获取最新的群组信息并检查权限
      if (_isCurrentChatGroup && _currentChatUserId != null) {
        try {
          logger.debug('📡 正在获取群组信息以检查权限...');

          // 调用API获取群组详细信息
          final groupResponse = await ApiService.getGroupDetail(
            token: token,
            groupId: _currentChatUserId!,
          );

          if (groupResponse['code'] == 0 && groupResponse['data'] != null) {
            final groupData =
                groupResponse['data']['group'] as Map<String, dynamic>?;
            final memberRole = groupResponse['data']['member_role'] as String?;

            if (groupData != null) {
              final ownerId = groupData['owner_id'] as int?;
              final memberViewPermission =
                  groupData['member_view_permission'] as bool? ?? true;

              logger.debug(
                '📊 群组信息: ownerId=$ownerId, memberViewPermission=$memberViewPermission, memberRole=$memberRole',
              );

              final currentUserId = _currentUserId;
              if (currentUserId > 0) {
                // 检查当前用户是否是群主
                final isOwner = ownerId == currentUserId;
                // 检查当前用户是否是管理员
                final isAdmin = memberRole == 'admin';

                // 如果不是群主也不是管理员，且群组关闭了成员查看权限，则不允许查看
                if (!isOwner && !isAdmin && !memberViewPermission) {
                  logger.debug(
                    '❌ 权限检查失败 - 当前用户ID: $currentUserId, 角色: $memberRole, 是群主: $isOwner, 是管理员: $isAdmin, 成员查看权限: $memberViewPermission',
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('群主已关闭群成员查看权限')),
                    );
                  }
                  return;
                }

                logger.debug(
                  '✅ 权限检查通过 - 当前用户ID: $currentUserId, 角色: $memberRole, 是群主: $isOwner, 是管理员: $isAdmin, 成员查看权限: $memberViewPermission',
                );
              }
            }
          } else {
            logger.debug('⚠️ 获取群组信息失败: ${groupResponse['message']}');
            // 获取群组信息失败，为了安全起见，禁止查看
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('获取群组信息失败，无法查看成员信息')),
              );
            }
            return;
          }
        } catch (e) {
          logger.debug('❌ 获取群组信息异常: $e');
          // 获取群组信息异常，为了安全起见，禁止查看
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('获取群组信息失败，无法查看成员信息')));
          }
          return;
        }
      }

      // 显示加载提示
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      // 调用API获取用户信息
      final response = await ApiService.getUserByID(
        token: token,
        userId: userId,
      );

      // 关闭加载提示
      if (mounted) Navigator.pop(context);

      if (response['code'] == 0 && response['data'] != null) {
        // 修正数据路径：后端返回的{ data: { user: {...} } }
        final userData = response['data']['user'];

        // 显示用户信息弹窗（不显示编辑按钮
        if (mounted) {
          UserInfoDialog.show(
            context,
            username: userData['username'] ?? '',
            userId: userId.toString(),
            status: userData['status'] ?? 'offline',
            token: _token ?? '', // 传递内存中的token
            fullName: userData['full_name'],
            gender: userData['gender'],
            workSignature: userData['work_signature'],
            department: userData['department'],
            position: userData['position'],
            region: userData['region'],
            showEditButton: false, // 查看别人资料时禁止编辑
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '获取用户信息失败')),
          );
        }
      }
    } catch (e) {
      // 关闭加载提示
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取用户信息失败: $e')));
      }
    }
  }

  // 标记消息为已读
  Future<void> _markMessagesAsRead(int senderID) async {
    try {
      final messageService = MessageService();
      await messageService.markMessagesAsRead(senderID);
      logger.debug('✅ 已标记与用户 $senderID 的消息为已读（本地数据库）');

      // 🔧 修复：将该用户添加到已读集合中
      _markedAsReadContacts.add('user_$senderID');
      logger.debug('🔧 修复：已将 user_$senderID 添加到已读集合');
      
      // 🔴 修复：发送已读回执给发送者
      if (!_isCurrentChatGroup && _currentChatUserId == senderID) {
        logger.debug('📖 [已读回执] 发送已读回执给发送者 $senderID');
        _wsService.sendReadReceiptForContact(senderID);
      }
      
      // 🔧 注意：不再自动刷新联系人列表，避免时序竞争问题
      // 未读数已在客户端通过 _markedAsReadContacts 机制保持为0
    } catch (e) {
      logger.debug('❌ 标记消息已读失败: $e');
    }
  }
  
  // 🔴 修复：处理已读回执
  void _handleReadReceipt(Map<String, dynamic> data) {
    final receiverId = data['receiver_id'] as int?;
    if (receiverId == null) return;
    
    logger.debug('📖 [已读回执] 收到已读回执 - 接收者ID: $receiverId');
    logger.debug('📖 [已读回执] 当前状态 - isGroup: $_isCurrentChatGroup, currentChatUserId: $_currentChatUserId, currentUserId: $_currentUserId');
    logger.debug('📖 [已读回执] 消息列表数量: ${_messages.length}');
    
    // 如果当前是一对一聊天，且接收者ID匹配当前聊天对象
    if (!_isCurrentChatGroup && _currentChatUserId == receiverId) {
      logger.debug('📖 [已读回执] 条件满足，开始批量更新消息');
      int updatedCount = 0;
      setState(() {
        // 批量更新所有发送给该接收者的未读消息为已读
        for (int i = 0; i < _messages.length; i++) {
          if (_messages[i].senderId == _currentUserId && 
              _messages[i].receiverId == receiverId && 
              !_messages[i].isRead) {
            updatedCount++;
            _messages[i] = MessageModel(
              id: _messages[i].id,
              senderId: _messages[i].senderId,
              receiverId: _messages[i].receiverId,
              senderName: _messages[i].senderName,
              receiverName: _messages[i].receiverName,
              senderAvatar: _messages[i].senderAvatar,
              receiverAvatar: _messages[i].receiverAvatar,
              senderNickname: _messages[i].senderNickname,
              senderFullName: _messages[i].senderFullName,
              receiverFullName: _messages[i].receiverFullName,
              content: _messages[i].content,
              messageType: _messages[i].messageType,
              fileName: _messages[i].fileName,
              quotedMessageId: _messages[i].quotedMessageId,
              quotedMessageContent: _messages[i].quotedMessageContent,
              status: _messages[i].status,
              mentionedUserIds: _messages[i].mentionedUserIds,
              mentions: _messages[i].mentions,
              callType: _messages[i].callType,
              channelName: _messages[i].channelName,
              isRead: true,
              createdAt: _messages[i].createdAt,
              readAt: DateTime.now(),
            );
          }
        }
      });
      logger.debug('✅ [已读回执] 已批量更新 $updatedCount 条消息为已读状态');
      
      // 🔴 修复：保存已读状态到本地数据库
      if (updatedCount > 0) {
        _saveReadStatusToDatabase(receiverId);
      }
    } else {
      logger.debug('⚠️ [已读回执] 条件不满足，未更新消息 - isGroup: $_isCurrentChatGroup, currentChatUserId: $_currentChatUserId, receiverId: $receiverId');
    }
  }
  
  // 🔴 修复：保存已读状态到本地数据库
  Future<void> _saveReadStatusToDatabase(int receiverId) async {
    try {
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) return;
      
      // 🔴 修复参数混乱：直接调用数据库服务，明确参数含义
      // 这里的逻辑是：标记"我(currentUserId)发送给receiverId"的消息为已读
      // 即：sender_id = currentUserId, receiver_id = receiverId 的消息标记为已读
      final localDb = LocalDatabaseService();
      await localDb.markMessagesAsRead(currentUserId, receiverId);
      logger.debug('💾 [已读回执] 已保存已读状态到本地数据库 - senderId: $currentUserId, receiverId: $receiverId');
    } catch (e) {
      logger.debug('💾 [已读回执] 保存已读状态到数据库失败: $e');
    }
  }

  // 标记群组消息为已读
  Future<void> _markGroupMessagesAsRead(int groupID) async {
    try {
      final currentUserId = await Storage.getUserId();
      if (currentUserId == null) {
        return;
      }

      final messageService = MessageService();
      // 获取群组所有未读消息并标记为已读
      final messages = await messageService.getGroupMessageList(
        groupId: groupID,
        pageSize: 1000,
      );
      for (var message in messages) {
        if (message.senderId != currentUserId) {
          await messageService.markGroupMessageAsRead(
            message.id!,
            currentUserId,
          );
        }
      }

      logger.debug('✅ 已标记群组 $groupID 的消息为已读（本地数据库）');
      // 🔧 修复：将该群组添加到已读集合中
      _markedAsReadContacts.add('group_$groupID');
      logger.debug('🔧 修复：已将 group_$groupID 添加到已读集合');
      // 🔧 注意：不再自动刷新联系人列表，避免时序竞争问题
      // 未读数已在客户端通过 _markedAsReadContacts 机制保持为0
    } catch (e) {
      logger.debug('❌ 标记群组消息已读失败: $e');
    }
  }

  // 检查并滚动到底部（定时器调用）
  void _checkAndScrollToBottom() {
    // 如果用户正在手动向上滚动，不执行自动滚动
    if (_isUserScrolling) {
      return;
    }

    // 如果没有消息列表或没有当前聊天用户，不执行任何操作
    if (_messages.isEmpty || _currentChatUserId == null) {
      return;
    }

    // 如果滚动控制器没有客户端，不执行任何操作
    if (!_messageScrollController.hasClients) {
      return;
    }

    // 检查是否已经到达底部（使用10像素的阈值，避免浮点数比较问题）
    final position = _messageScrollController.position;
    final maxScroll = position.maxScrollExtent;
    final currentScroll = position.pixels;
    const threshold = 10.0; // 10像素的阈值

    // 如果已经到达底部（当前滚动位置 >= 最大滚动位置 - 阈值），不执行任何操作
    if (currentScroll >= maxScroll - threshold) {
      return;
    }

    // 如果没有到达底部，则滚动到底部
    _messageScrollController.jumpTo(maxScroll);
  }

  // 滚动到底
  void _scrollToBottom({bool animated = true}) {
    // 使用 addPostFrameCallback 确保在界面渲染完成后再滚动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 单次延迟，等待消息渲染完成
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted) return;

        // 直接滚动到最大位置
        if (_messageScrollController.hasClients) {
          final maxScroll = _messageScrollController.position.maxScrollExtent;

          if (animated) {
            _messageScrollController.animateTo(
              maxScroll,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          } else {
            _messageScrollController.jumpTo(maxScroll);
          }
        }
      });
    });
  }

  // 滚动到指定消
  void _scrollToMessage(int messageId) {
    // 查找消息在列表中的索
    final index = _messages.indexWhere((msg) => msg.id == messageId);
    if (index == -1) {
      logger.debug('未找到消息ID: $messageId');
      return;
    }

    logger.debug('找到消息，索 $index, 总消息数: ${_messages.length}');

    // 取消之前的高亮定时器
    _highlightTimer?.cancel();

    // 设置高亮（不关闭筛选面板，允许用户继续点击其他搜索结果
    setState(() {
      _highlightedMessageId = messageId;
    });

    // 使用 addPostFrameCallback 确保在界面渲染完成后再滚
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted || !_messageScrollController.hasClients) return;

        // 计算滚动位置
        // 使用一个合理的估算值：每条消息平均高度50像素（包括间距、头像、气泡等
        final double estimatedItemHeight = 150.0;

        // 计算目标消息的位置（从列表顶部到目标消息顶部的距离）
        final double targetMessageOffset = index * estimatedItemHeight;

        // 获取最大可滚动距离
        final double maxScroll =
            _messageScrollController.position.maxScrollExtent;

        // 滚动到目标消息的位置，让消息显示在可视区域的顶部
        // 直接使用目标消息的偏移量作为滚动位置，使其与滚动条位置对
        final double scrollTo = targetMessageOffset.clamp(0.0, maxScroll);

        logger.debug('📍 滚动到位 $scrollTo (消息索引: $index, 最 $maxScroll)');

        // 执行滚动
        _messageScrollController.animateTo(
          scrollTo,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );

        // 2秒后取消高亮
        _highlightTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _highlightedMessageId = null;
            });
          }
        });
      });
    });
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

      // 自动刷新联系人列表，这样红色气泡会自动更新
      _loadContacts();
    } catch (e) {
      logger.debug('处理联系人请求通知失败: $e');
    }
  }

  Future<void> _recordPendingContact(int? contactUserId) async {
    if (contactUserId == null) return;
    try {
      final currentUserId = _currentUserId != 0
          ? _currentUserId
          : await Storage.getUserId();
      if (currentUserId == null || currentUserId == 0) return;
      await Storage.addPendingContact(currentUserId, contactUserId);
      logger.debug('📌 桌面端记录待审核联系人: $contactUserId');
    } catch (e) {
      logger.debug('桌面端记录待审核联系人失败: $e');
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

      // 自动刷新联系人列表，这样红色气泡会自动更新
      _loadContacts();

      // 获取当前用户ID，判断是发起人还是审核人
      final currentUserId = _currentUserId != 0
          ? _currentUserId
          : await Storage.getUserId();
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

  // 处理被拉黑通知
  void _handleContactBlocked(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final blockData = data as Map<String, dynamic>;
      final operatorId = blockData['operator_id'] as int?;
      final operatorName = blockData['operator_name'] as String?;
      final message = blockData['message'] as String?;

      logger.debug('🚫 收到被拉黑通知 - 操作者ID: $operatorId, 操作者: $operatorName, 消息: $message');

      // 更新本地联系人状态（对方拉黑了我）
      if (operatorId != null) {
        setState(() {
          final index = _contacts.indexWhere(
            (c) => c.friendId == operatorId,
          );
          if (index != -1) {
            _contacts[index] = _contacts[index].copyWith(
              isBlocked: true,          // 关系被拉黑
              blockedByUserId: operatorId,  // 是对方拉黑的
              isBlockedByMe: false,     // 不是我拉黑的，所以不显示"恢复"按钮
            );
            logger.debug('✅ 已更新联系人状态 - friendId: $operatorId, isBlocked: true, isBlockedByMe: false');
          } else {
            logger.debug('⚠️ 未找到联系人 - friendId: $operatorId');
          }
        });
      }

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

      logger.debug('🗑️ 收到被删除通知 - 操作者: $operatorName, 消息: $message');

      // 刷新联系人列表
      _loadContacts();

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
      final operatorId = unblockData['operator_id'] as int?;
      final operatorName = unblockData['operator_name'] as String?;
      final message = unblockData['message'] as String?;

      logger.debug('✅ 收到被恢复通知 - 操作者ID: $operatorId, 操作者: $operatorName, 消息: $message');

      // 更新本地联系人状态（对方恢复了我）
      if (operatorId != null) {
        setState(() {
          final index = _contacts.indexWhere(
            (c) => c.friendId == operatorId,
          );
          if (index != -1) {
            _contacts[index] = _contacts[index].copyWith(
              isBlocked: false,         // 关系不再被拉黑
              blockedByUserId: null,    // 清除拉黑操作人
              isBlockedByMe: false,     // 不是我拉黑的
            );
            logger.debug('✅ 已更新联系人状态 - friendId: $operatorId, isBlocked: false');
          } else {
            logger.debug('⚠️ 未找到联系人 - friendId: $operatorId');
          }
        });
      }

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

  // 处理待审核群成员通知
  void _handlePendingGroupMemberNotification(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final notificationData = data as Map<String, dynamic>;
      final groupId = notificationData['group_id'] as int?;
      final groupName = notificationData['group_name'] as String?;
      final operatorId = notificationData['operator_id'] as int?;
      final operatorName = notificationData['operator_name'] as String?;
      final newMemberId = notificationData['new_member_id'] as int?;
      final newMemberName = notificationData['new_member_name'] as String?;

      logger.debug(
        '👥 收到待审核群成员通知 - 群组ID: $groupId, 群组名称: $groupName, 操作者: $operatorName (ID: $operatorId), 新成员: $newMemberName (ID: $newMemberId)',
      );

      // 自动刷新待审核群成员列表，这样通讯录的红色气泡会自动更新
      _loadPendingGroupMembers();

      // 可选：显示一个提示消息
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

  // 加载联系人列表（从本地数据库的最近联系人中提取）
  Future<void> _loadContacts() async {
    // 🔴 防止重复调用：如果已经在加载中，直接返回
    if (_isLoadingContacts) {
      logger.debug('⏸️ [PC端] 联系人正在加载中，跳过重复调用');
      return;
    }

    setState(() {
      _isLoadingContacts = true;
      _contactsError = null;
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingContacts = false;
          _contactsError = '未登录';
        });
        return;
      }

      logger.debug('📡 从服务器API获取联系人列表（包括待审核）...');
      
      // 🔴 同时获取已通过的联系人和待审核的联系人请求
      final results = await Future.wait([
        ApiService.getContacts(token: token),
        ApiService.getPendingContactRequests(token: token),
      ]);
      
      final approvedResponse = results[0];
      final pendingResponse = results[1];
      
      logger.debug('📥 已通过联系人响应: code=${approvedResponse['code']}');
      logger.debug('📥 待审核联系人响应: code=${pendingResponse['code']}');

      final allContacts = <ContactModel>[];

      // 处理已通过的联系人
      if (approvedResponse['code'] == 0 && approvedResponse['data'] != null) {
        final contactsData = approvedResponse['data']['contacts'] as List?;
        final approvedContacts = (contactsData ?? [])
            .map((json) => ContactModel.fromJson(json as Map<String, dynamic>))
            .toList();
        allContacts.addAll(approvedContacts);
        logger.debug('✅ 已通过联系人: ${approvedContacts.length} 个');
      }

      // 处理待审核的联系人请求
      if (pendingResponse['code'] == 0 && pendingResponse['data'] != null) {
        final requestsData = pendingResponse['data']['requests'] as List?;
        final pendingContacts = (requestsData ?? [])
            .map((json) => ContactModel.fromJson(json as Map<String, dynamic>))
            .toList();
        allContacts.addAll(pendingContacts);
        logger.debug('✅ 待审核联系人: ${pendingContacts.length} 个');
      }

      // 同步待审核联系人到本地存储
      await Storage.syncPendingContactsFromModels(allContacts);

      setState(() {
        _contacts = allContacts;
        _isLoadingContacts = false;
      });

      logger.debug('✅ 成功从服务器加载联系人列表，共 ${allContacts.length} 个联系人');
    } catch (e) {
      setState(() {
        _isLoadingContacts = false;
        _contactsError = '加载联系人失败: $e';
      });
      logger.error('❌ 加载联系人失败: $e');
    }
  }

  // 处理联系人审核
  Future<void> _handleContactApproval(
    ContactModel contact,
    String approvalStatus,
  ) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    try {
      // 调用API更新审核状态
      final response = await ApiService.updateContactApprovalStatus(
        token: token,
        relationId: contact.relationId,
        approvalStatus: approvalStatus,
      );

      if (response['code'] == 0) {
        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(approvalStatus == 'approved' ? '已通过' : '已拒绝'),
            ),
          );
        }

        await Storage.removePendingContactForCurrentUser(contact.friendId);

        // 主动获取用户最新信息（包括头像）并更新缓存
        String? updatedAvatar;
        try {
          logger.debug('🎭 审核联系人后，获取用户 ${contact.friendId} 的最新信息');
          final userResponse = await ApiService.getUserByID(
            token: token,
            userId: contact.friendId,
          );
          
          if (userResponse['code'] == 0 && userResponse['data'] != null) {
            final userData = userResponse['data']['user'];
            updatedAvatar = userData['avatar'] as String?;
            
            // 更新头像缓存
            setState(() {
              _avatarCache[contact.friendId] = updatedAvatar;
            });
            logger.debug('✅ 已更新用户 ${contact.friendId} 的头像缓存: $updatedAvatar');
          }
        } catch (e) {
          logger.debug('⚠️ 获取用户最新信息失败: $e，继续刷新列表');
        }

        // 重新加载联系人列表
        await _loadContacts();
        
        // 重新加载会话列表，确保头像更新
        logger.debug('🔄 审核联系人后，刷新会话列表以更新头像');
        await _loadRecentContacts();
        
        // 如果获取到了最新头像，直接更新会话列表中的对应项
        if (updatedAvatar != null && mounted) {
          setState(() {
            for (int i = 0; i < _recentContacts.length; i++) {
              if (!_recentContacts[i].isGroup && 
                  _recentContacts[i].userId == contact.friendId) {
                _recentContacts[i] = _recentContacts[i].copyWith(
                  avatar: updatedAvatar,
                );
                logger.debug('✅ 已直接更新会话列表中用户 ${contact.friendId} 的头像');
                break;
              }
            }
          });
        }
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '操作失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('审核联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败: $e')));
      }
    }
  }

  // 拉黑联系人
  Future<void> _handleBlockContact(ContactModel contact) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    try {
      // 调用API拉黑联系人
      final response = await ApiService.blockContact(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        setState(() {
          final index = _contacts.indexWhere(
            (c) => c.relationId == contact.relationId,
          );
          if (index != -1) {
            _contacts[index] = _contacts[index].copyWith(
              isBlocked: true,
              isBlockedByMe: true,
              blockedByUserId: _currentUserId, // 设置拉黑操作人为当前用户
            );
          }
        });

        // 🔧 修复：拉黑不应该删除会话，本地状态已更新
        // 拉黑和删除是两个不同的操作：
        // - 拉黑：阻止对方发消息，但会话保留，显示"恢复"按钮
        // - 删除：从会话列表中移除
        // 不需要重新加载联系人列表，避免覆盖本地状态更新
        logger.debug('已拉黑联系人: ${contact.friendId}，本地状态已更新，会话保留');

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已拉黑联系人')));
        }
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '拉黑失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('拉黑联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拉黑失败: $e')));
      }
    }
  }

  // 恢复联系人（取消拉黑）
  Future<void> _handleUnblockContact(ContactModel contact) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    try {
      // 调用API恢复联系人
      final response = await ApiService.unblockContact(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        setState(() {
          final index = _contacts.indexWhere(
            (c) => c.relationId == contact.relationId,
          );
          if (index != -1) {
            _contacts[index] = _contacts[index].copyWith(
              isBlocked: false,
              isBlockedByMe: false,
              blockedByUserId: null, // 清除拉黑操作人
            );
          }
        });

        // 🔧 修复：不需要操作删除列表，因为拉黑不会添加到删除列表
        // 不需要重新加载联系人列表，避免覆盖本地状态更新
        logger.debug('已恢复联系人: ${contact.friendId}，本地状态已更新');

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已恢复联系人')));
        }
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '恢复失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('恢复联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
      }
    }
  }

  // 删除联系人
  Future<void> _handleDeleteContact(ContactModel contact) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除联系人 ${contact.displayName} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE53935),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      // 调用API删除联系人
      final response = await ApiService.deleteContactById(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        setState(() {
          final index = _contacts.indexWhere(
            (c) => c.relationId == contact.relationId,
          );
          if (index != -1) {
            _contacts[index] = _contacts[index].copyWith(isDeleted: true);
          }
        });

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已删除联系人')));
        }

        // 重新加载联系人列表（已删除的联系人会被过滤掉）
        await _loadContacts();
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '删除失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('删除联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  // 从通讯录跳转到消息页面并打开与指定联系人的聊
  Future<void> _openChatFromContacts(ContactModel contact) async {
    logger.debug(
      '📱 从通讯录打开聊天: ${contact.displayName} (ID: ${contact.friendId})',
    );

    // 🔴 打开聊天前，先检查并移除删除标记（如果存在）
    final contactKey = Storage.generateContactKey(
      isGroup: false,
      id: contact.friendId,
    );
    final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
    if (isDeleted) {
      logger.debug('🔄 [通讯录] 从已删除的会话打开聊天，移除删除标记: $contactKey');
      await Storage.removeDeletedChatForCurrentUser(contactKey);
    }

    // 1. 切换到消息页
    setState(() {
      _selectedMenuIndex = 0;
      _selectedContactIndex = -1; // 清除通讯录选中状
      _selectedPerson = null;
    });

    // 2. 重新加载最近联系人列表
    await _loadRecentContacts();

    // 3. 在最近联系人列表中查找该联系
    final contactIndex = _recentContacts.indexWhere(
      (c) => c.userId == contact.friendId,
    );

    if (contactIndex != -1) {
      // 联系人已在最近联系人列表中，直接选中
      logger.debug('联系人已在最近联系人列表中，索引: $contactIndex');
      setState(() {
        _selectedChatIndex = contactIndex;
        _isCurrentChatGroup = false;
      });
      // 加载消息历史
      _loadMessageHistory(contact.friendId, isGroup: false);
    } else {
      // 联系人不在最近联系人列表中，创建一个临时的最近联系人对象并添加到顶部
      logger.debug('ℹ️ 联系人不在最近联系人列表中，添加到顶部');
      final newRecentContact = RecentContactModel(
        type: 'user',
        userId: contact.friendId,
        username: contact.username,
        fullName: contact.fullName ?? contact.username,
        lastMessage: '',
        lastMessageTime: DateTime.now().toIso8601String(),
        unreadCount: 0,
        status: contact.status,
      );

      setState(() {
        // 将新联系人插入到列表顶部
        _recentContacts.insert(0, newRecentContact);
        _selectedChatIndex = 0;
        _isCurrentChatGroup = false;
      });

      // 加载消息历史
      _loadMessageHistory(contact.friendId, isGroup: false);
    }
  }

  // 从固定群组跳转到消息页面并打开群组聊天
  Future<void> _openChatFromGroup(GroupModel group) async {
    logger.debug('📱 从固定群组打开聊天: ${group.name} (ID: ${group.id})');

    // 🔴 打开群聊前，先检查并移除删除标记（如果存在）
    final contactKey = Storage.generateContactKey(
      isGroup: true,
      id: group.id,
    );
    final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
    if (isDeleted) {
      logger.debug('🔄 [通讯录] 从已删除的群聊打开聊天，移除删除标记: $contactKey');
      await Storage.removeDeletedChatForCurrentUser(contactKey);
    }

    // 1. 切换到消息页
    setState(() {
      _selectedMenuIndex = 0;
      _selectedContactIndex = -1; // 清除通讯录选中状
      _selectedPerson = null;
    });

    // 2. 重新加载最近联系人列表
    await _loadRecentContacts();

    // 3. 在最近联系人列表中查找该群组
    final groupIndex = _recentContacts.indexWhere(
      (c) => c.isGroup && c.groupId == group.id,
    );

    if (groupIndex != -1) {
      // 群组已在最近联系人列表中，直接选中
      logger.debug('群组已在最近联系人列表中，索引: $groupIndex');
      setState(() {
        _selectedChatIndex = groupIndex;
        _isCurrentChatGroup = true;
      });
      // 加载群组详细信息（包括群公告）
      await _loadGroupDetail(group.id);
      // 加载群组消息历史
      _loadMessageHistory(group.id, isGroup: true);
    } else {
      // 群组不在最近联系人列表中，创建一个临时的最近联系人对象并添加到顶部
      logger.debug('ℹ️ 群组不在最近联系人列表中，添加到顶部');
      final newRecentContact = RecentContactModel.group(
        groupId: group.id,
        groupName: group.name,
        avatar: group.avatar, // 传递群组头像
        lastMessage: '',
        lastMessageTime: DateTime.now().toIso8601String(),
        remark: group.remark, // 传递群组备注
      );

      setState(() {
        // 将新群组插入到列表顶部
        _recentContacts.insert(0, newRecentContact);
        _selectedChatIndex = 0;
        _isCurrentChatGroup = true;
      });

      // 加载群组详细信息（包括群公告）
      await _loadGroupDetail(group.id);
      // 加载群组消息历史
      _loadMessageHistory(group.id, isGroup: true);
    }
  }

  // 加载用户群组列表
  Future<void> _loadGroups() async {
    // 🔴 防止重复调用：如果已经在加载中，直接返回
    if (_isLoadingGroups) {
      logger.debug('⏸️ [PC端] 群组正在加载中，跳过重复调用');
      return;
    }

    setState(() {
      _isLoadingGroups = true;
      _groupsError = null;
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingGroups = false;
          _groupsError = '未登录';
        });
        return;
      }

      // 调用API获取群组列表
      final response = await ApiService.getUserGroups(token: token);

      if (response['code'] == 0 && response['data'] != null) {
        final groupsData = response['data']['groups'] as List?;
        final groups = (groupsData ?? [])
            .map((json) => GroupModel.fromJson(json as Map<String, dynamic>))
            .toList();

        setState(() {
          _groups = groups;
          _isLoadingGroups = false;
        });

        logger.debug('成功加载群组: ${groups.length} 个群组');
      } else {
        setState(() {
          _isLoadingGroups = false;
          _groupsError = response['message'] ?? '加载群组失败';
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingGroups = false;
        _groupsError = '加载群组失败: $e';
      });
      logger.debug('加载群组失败: $e');
    }
  }

  // 加载单个群组的详细信息（包括群公告）
  Future<void> _loadGroupDetail(int groupId) async {
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        return;
      }

      // 调用API获取群组详情
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: groupId,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final groupData = response['data']['group'] as Map<String, dynamic>;

        // 🔧 修复：从members列表中获取成员ID并填充到groupData中
        // 服务器返回的group对象中没有member_ids字段，需要从members列表中提取
        if (response['data']['members'] != null) {
          final members = response['data']['members'] as List;
          // 只统计已通过审核的成员（approval_status为'approved'）
          final approvedMembers = members.where((member) {
            final approvalStatus =
                member['approval_status'] as String? ?? 'approved';
            return approvalStatus == 'approved';
          }).toList();
          final memberIds = approvedMembers
              .map((m) => m['user_id'] as int)
              .toList();
          groupData['member_ids'] = memberIds;
        }

        final groupDetail = GroupModel.fromJson(groupData);

        // 更新 _groups 列表中的对应群组
        setState(() {
          final index = _groups.indexWhere((g) => g.id == groupId);
          if (index != -1) {
            _groups[index] = groupDetail;
          } else {
            // 如果群组不在列表中，添加它
            _groups.add(groupDetail);
          }
        });
        
      }
    } catch (e) {
      logger.debug('⚠️ 加载群组详情异常: $e');
    }
  }


  // 获取群组成员数量（只统计已通过审核的成员）
  Future<int> _getGroupMemberCount(int groupId) async {
    // 🔧 修复：不再使用本地的memberCount，因为它包含所有成员（包括待审核的）
    // 直接从API获取并过滤已审核的成员

    // 如果本地数据中成员数量为0或找不到群组，从API获取真实的成员数量
    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        return 0;
      }

      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: groupId,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final data = response['data'];
        final members = data['members'] as List?;
        if (members != null) {
          // 只统计已通过审核的成员（approval_status = 'approved'）
          // 排除待审核（pending）和已移除（rejected）的成员
          final approvedMembers = members.where((m) {
            final approvalStatus =
                m['approval_status'] as String? ?? 'approved';
            return approvalStatus == 'approved';
          }).toList();

          final memberCount = approvedMembers.length;
          // 更新本地群组数据中的成员数量（只更新已通过的成员）
          _updateGroupMemberIds(
            groupId,
            approvedMembers.map((m) => m['user_id'] as int).toList(),
          );
          return memberCount;
        }
      }
    } catch (e) {
      logger.debug('获取群组成员数量失败: $e');
    }

    return 0;
  }


  // 更新群组数据中的成员ID列表
  void _updateGroupMemberIds(int groupId, List<int> memberIds) {
    // 🔧 修复：移除setState()，避免FutureBuilder死循环
    // FutureBuilder会在Future完成时自动更新UI，不需要额外的setState
    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index != -1) {
      _groups[index] = _groups[index].copyWith(memberIds: memberIds);
    }
    // 如果当前选中的群组是这个群组，也更新它
    if (_selectedGroup != null && _selectedGroup!.id == groupId) {
      _selectedGroup = _selectedGroup!.copyWith(memberIds: memberIds);
    }
  }

  // 加载待审核的群组成员
  Future<void> _loadPendingGroupMembers() async {
    // 🔴 防止重复调用：如果已经在加载中，直接返回
    if (_isLoadingPendingMembers) {
      logger.debug('⏸️ [PC端] 待审核群成员正在加载中，跳过重复调用');
      return;
    }

    setState(() {
      _isLoadingPendingMembers = true;
      _pendingMembersError = null;
    });

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoadingPendingMembers = false;
          _pendingMembersError = '未登录';
        });
        return;
      }

      // 获取所有群组
      final groupsResponse = await ApiService.getUserGroups(token: token);
      if (groupsResponse['code'] != 0) {
        setState(() {
          _isLoadingPendingMembers = false;
          _pendingMembersError = groupsResponse['message'] ?? '加载群组失败';
        });
        return;
      }

      final groupsData = groupsResponse['data']['groups'] as List?;
      if (groupsData == null || groupsData.isEmpty) {
        setState(() {
          _pendingGroupMembers = [];
          _isLoadingPendingMembers = false;
        });
        return;
      }

      // 遍历每个群组，获取待审核成员
      final List<Map<String, dynamic>> allPendingMembers = [];

      for (var groupJson in groupsData) {
        final groupId = groupJson['id'] as int;
        final groupName = groupJson['name'] as String;

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

          // 获取群组的邀请确认状态
          final inviteConfirmation =
              groupData?['invite_confirmation'] as bool? ?? false;

          // 只有开启了"群聊邀请确认"的群组，且当前用户是群主或管理员时，才显示待审核成员
          if (inviteConfirmation &&
              (memberRole == 'owner' || memberRole == 'admin')) {
            if (members != null) {
              // 筛选出待审核的成员（approval_status = 'pending'）
              for (var member in members) {
                final approvalStatus =
                    member['approval_status'] as String? ?? 'approved';
                if (approvalStatus == 'pending') {
                  allPendingMembers.add({
                    'groupId': groupId,
                    'groupName': groupName,
                    'userId': member['user_id'],
                    'displayName':
                        member['full_name'] ?? member['username'] ?? '未知用户',
                    'avatar': member['avatar'],
                    'joinedAt': member['joined_at'],
                  });
                }
              }
            }
          }
        }
      }

      setState(() {
        _pendingGroupMembers = allPendingMembers;
        _isLoadingPendingMembers = false;
      });

      logger.debug('成功加载待审核群组成员: ${allPendingMembers.length} 个');
    } catch (e) {
      setState(() {
        _isLoadingPendingMembers = false;
        _pendingMembersError = '加载失败: $e';
      });
      logger.debug('加载待审核群组成员失败: $e');
    }
  }

  // 通过群组成员审核
  Future<void> _approveGroupMember(
    int groupId,
    int userId,
    String displayName,
    String groupName,
  ) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未登录'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    try {
      logger.debug(
        '通过群组成员审核: groupId=$groupId, userId=$userId, displayName=$displayName',
      );

      final response = await ApiService.approveGroupMember(
        token: token,
        groupId: groupId,
        userId: userId,
      );

      if (response['code'] == 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已通过')));
        }

        // 从待审核列表中移除该成员
        setState(() {
          _pendingGroupMembers.removeWhere(
            (m) => m['groupId'] == groupId && m['userId'] == userId,
          );
        });

        logger.debug('成功通过群组成员审核');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? '操作失败'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('通过群组成员审核失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 拒绝群组成员审核
  Future<void> _rejectGroupMember(
    int groupId,
    int userId,
    String displayName,
    String groupName,
  ) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未登录'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    try {
      logger.debug(
        '拒绝群组成员审核: groupId=$groupId, userId=$userId, displayName=$displayName',
      );

      final response = await ApiService.rejectGroupMember(
        token: token,
        groupId: groupId,
        userId: userId,
      );

      if (response['code'] == 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已拒绝')));
        }

        // 从待审核列表中移除该成员
        setState(() {
          _pendingGroupMembers.removeWhere(
            (m) => m['groupId'] == groupId && m['userId'] == userId,
          );
        });

        logger.debug('成功拒绝群组成员审核');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? '操作失败'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('拒绝群组成员审核失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 处理群组更新（备注等信息修改
  void _handleGroupUpdated(int groupId, String? remark) {
    logger.debug('📝 群组更新回调 - 群组ID: $groupId, 新备注: $remark');

    // 🔴 清除移动端群组缓存，确保下次加载时获取最新数据
    try {
      MobileContactsPage.clearCacheAndRefresh();
      logger.debug('🗑️ 已清除移动端群组缓存');
    } catch (e) {
      logger.debug('清除移动端群组缓存失败: $e');
    }

    // 如果群组被解散
    if (remark == 'GROUP_DISBANDED') {
      logger.debug('🗑️ 群组已被解散，从列表中删除');

      setState(() {
        // 从最近联系人列表中删除该群组
        _recentContacts.removeWhere(
          (contact) => contact.isGroup && contact.groupId == groupId,
        );

        // 如果当前正在查看被解散的群组，清空选中状态
        if (_selectedPerson != null &&
            _selectedPerson!['isGroup'] == true &&
            _selectedPerson!['groupId'] == groupId) {
          _selectedPerson = null;
          _messages.clear();
          _selectedChatIndex = 0;
          logger.debug('已清空当前选中的群组');
        }
      });

      // 重新加载群组列表
      _loadGroups();

      logger.debug('群组已从列表中删除');
      return;
    }

    // 如果用户退出群组
    if (remark == 'GROUP_LEFT') {
      logger.debug('🚪 用户已退出群组，从列表中删除');

      setState(() {
        // 从最近联系人列表中删除该群组
        _recentContacts.removeWhere(
          (contact) => contact.isGroup && contact.groupId == groupId,
        );

        // 如果当前正在查看已退出的群组，清空选中状态
        if (_selectedPerson != null &&
            _selectedPerson!['isGroup'] == true &&
            _selectedPerson!['groupId'] == groupId) {
          _selectedPerson = null;
          _messages.clear();
          _selectedChatIndex = 0;
          logger.debug('已清空当前选中的群组');
        }
      });

      // 重新加载群组列表
      _loadGroups();

      logger.debug('群组已从列表中删除');
      return;
    }

    // 🔧 修复：重新加载群组列表以获取最新的成员数据
    _loadGroups();

    // 刷新最近联系人列表以获取最新的群组信息（包括备注、免打扰状态等）
    _loadRecentContacts();

    logger.debug('群组信息已在页面上实时更新');
  }

  // 处理群组消息错误
  void _handleGroupMessageError(dynamic data) {
    if (data == null) return;
    if (!mounted) return;

    try {
      final errorData = data as Map<String, dynamic>;
      final error = errorData['error'] as String?;
      final groupId = _currentChatUserId;

      logger.debug('❌ 群组消息发送错误: $error');

      // 如果错误是"您不是该群组成员"或类似，标记为已移除
      if (error != null &&
          (error.contains('不是该群组成员') ||
              error.contains('已被移除') ||
              error.contains('移除群组'))) {
        if (groupId != null && _isCurrentChatGroup) {
          setState(() {
            _removedGroupIds.add(groupId);
          });
          logger.debug('📢 已标记群组为已移除状态: groupId=$groupId');
        }
      }

      // 通过保存的临时ID查找消息并更新状态为failed（参考APP端实现）
      if (_lastSentTempMessageId != null) {
        logger.debug('🚫 [群组消息错误] 最近发送的临时消息ID: $_lastSentTempMessageId');
        
        final failedMessageIndex = _messages.indexWhere((m) => m.id == _lastSentTempMessageId);
        
        if (failedMessageIndex != -1) {
          final failedMessage = _messages[failedMessageIndex];
          logger.debug('✅ [群组消息错误] 找到失败的消息 - ID: ${failedMessage.id}, 当前状态: ${failedMessage.status}');
          
          // 更新消息状态为failed
          setState(() {
            _messages[failedMessageIndex] = failedMessage.copyWith(status: 'failed');
            _isSendingMessage = false;
          });
          
          logger.debug('✅ [群组消息错误] 消息状态已更新为 "failed"，UI将重建并显示红色感叹号');
          
          // 清除临时ID
          _lastSentTempMessageId = null;
        } else {
          logger.debug('⚠️ [群组消息错误] 未在对话框中找到临时ID为 $_lastSentTempMessageId 的消息');
          setState(() {
            _isSendingMessage = false;
          });
        }
      } else {
        logger.debug('⚠️ [群组消息错误] 没有保存的临时消息ID，无法定位失败的消息');
        setState(() {
          _isSendingMessage = false;
        });
      }

      // 针对不同错误类型显示不同的提示消息
      String displayMessage = error ?? '发送消息失败';
      if (error != null && (error.contains('不是该群组成员') || error.contains('已被移除') || error.contains('移除群组'))) {
        displayMessage = '您已被移除群组';
      }

      // 显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMessage),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      logger.debug('处理群组消息错误失败: $e');
      // 确保即使出错也重置发送状态
      if (mounted) {
        setState(() {
          _isSendingMessage = false;
        });
      }
    }
  }

  // 处理私聊消息发送错误（如被拉黑、被删除等）
  void _handleMessageError(dynamic data) {
    if (data == null) return;
    if (!mounted) return;

    try {
      final errorData = data as Map<String, dynamic>;
      final errorMessage =
          errorData['error'] as String? ??
          errorData['message'] as String? ??
          '发送失败';

      logger.debug('🚫 [消息错误] 私聊消息发送失败: $errorMessage');

      // 如果正在发送通话相关消息（call_ended、call_rejected 或 call_cancelled），
      // 并且错误是"已被加入黑名单"或"已被删除"，则忽略这个错误
      // 因为通话相关的系统消息应该能够发送，不应该被黑名单拦截
      if (_isSendingCallMessage &&
          (errorMessage.contains('已被加入黑名单') || errorMessage.contains('已被删除'))) {
        logger.debug('📞 忽略通话相关消息的黑名单错误: $errorMessage');
        return;
      }

      // 通过保存的临时ID查找消息并更新状态为failed（参考APP端实现）
      if (_lastSentTempMessageId != null) {
        logger.debug('🚫 [消息错误] 最近发送的临时消息ID: $_lastSentTempMessageId');
        
        final failedMessageIndex = _messages.indexWhere((m) => m.id == _lastSentTempMessageId);
        
        if (failedMessageIndex != -1) {
          final failedMessage = _messages[failedMessageIndex];
          logger.debug('✅ [消息错误] 找到失败的消息 - ID: ${failedMessage.id}, 内容: "${failedMessage.content.substring(0, failedMessage.content.length > 30 ? 30 : failedMessage.content.length)}...", 当前状态: ${failedMessage.status}');
          
          // 更新消息状态为failed
          setState(() {
            _messages[failedMessageIndex] = failedMessage.copyWith(status: 'failed');
          });
          
          logger.debug('✅ [消息错误] 消息状态已更新为 "failed"，UI将重建并显示红色感叹号');
          
          // 清除临时ID
          _lastSentTempMessageId = null;
        } else {
          logger.debug('⚠️ [消息错误] 未在对话框中找到临时ID为 $_lastSentTempMessageId 的消息');
        }
      } else {
        logger.debug('⚠️ [消息错误] 没有保存的临时消息ID，无法定位失败的消息');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      logger.debug('处理私聊消息错误失败: $e');
    }
  }

  // 处理群组消息发送成功确认
  void _handleGroupMessageSentConfirmation(dynamic data) {
    if (data == null) return;
    if (!mounted) return;

    try {
      final confirmData = data as Map<String, dynamic>;
      final messageId = confirmData['message_id'] as int?;
      final groupId = confirmData['group_id'] as int?;
      final status = confirmData['status'] as String?;

      logger.debug(
        '✅ [群组消息确认] 收到发送确认 - MessageID: $messageId, GroupID: $groupId, Status: $status',
      );
      logger.debug('📌 [群组消息确认] 重要：发送者不会收到group_message推送，消息已通过乐观更新显示在群组对话框中');

      // 更新临时消息的ID（如果需要的话）
      // 这里可以用真实的消息ID替换临时ID为0的消息
      if (messageId != null &&
          _isCurrentChatGroup &&
          _currentChatUserId == groupId) {
        setState(() {
          final tempMessageIndex = _messages.indexWhere(
            (msg) => msg.id == 0 && msg.senderId == _currentUserId,
          );
          if (tempMessageIndex != -1) {
            final tempMessage = _messages[tempMessageIndex];
            // 创建新的消息对象，使用真实的消息ID
            _messages[tempMessageIndex] = MessageModel(
              id: messageId,
              senderId: tempMessage.senderId,
              receiverId: tempMessage.receiverId,
              senderName: tempMessage.senderName,
              receiverName: tempMessage.receiverName,
              senderAvatar: tempMessage.senderAvatar,
              receiverAvatar: tempMessage.receiverAvatar,
              senderNickname: tempMessage.senderNickname,
              content: tempMessage.content,
              messageType: tempMessage.messageType,
              fileName: tempMessage.fileName,
              quotedMessageId: tempMessage.quotedMessageId,
              quotedMessageContent: tempMessage.quotedMessageContent,
              status: tempMessage.status,
              mentionedUserIds: tempMessage.mentionedUserIds,
              mentions: tempMessage.mentions,
              isRead: tempMessage.isRead,
              createdAt: tempMessage.createdAt,
              readAt: tempMessage.readAt,
            );
            logger.debug('✅ 临时群组消息ID已更新: 0 -> $messageId');
          }

          // 确保未读计数为0（因为发送者正在查看该群组）
          final contactIndex = _recentContacts.indexWhere(
            (contact) => contact.isGroup && contact.groupId == groupId,
          );
          if (contactIndex != -1 &&
              _recentContacts[contactIndex].unreadCount > 0) {
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(unreadCount: 0);
            logger.debug('✅ 发送者正在查看群组，已清除未读计数: groupId=$groupId');
          }
        });
      }
    } catch (e) {
      logger.debug('处理群组消息发送确认失败: $e');
    }
  }

  // 处理群组通话通知
  void _handleGroupCallNotification(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final groupId = data['group_id'] as int?;
      final callType = data['call_type'] as String?;
      final channelName = data['channel_name'] as String?;
      final callerId = data['caller_id'] as int?;
      final callerName = data['caller_name'] as String?;
      final message = data['message'] as String?;
      final timestamp = data['timestamp'] as int?;

      logger.debug('📞 [群组通话通知] 收到通话通知 - 群组ID: $groupId, 通话类型: $callType, 频道: $channelName');
      logger.debug('📞 [群组通话通知] 发起人: $callerName ($callerId), 消息: $message');

      if (groupId == null || callType == null || channelName == null) {
        logger.debug('⚠️ [群组通话通知] 通话通知数据不完整');
        return;
      }

      // 如果当前正在查看该群组的聊天，显示通话通知
      if (_isCurrentChatGroup && _currentChatUserId == groupId) {
        // 在聊天界面显示通话通知（可以添加特殊的UI提示）
        logger.debug('📞 [群组通话通知] 当前正在查看群组 $groupId，显示通话通知');
        
        // 可以在这里添加特殊的UI提示，比如顶部横幅或弹窗
        if (mounted) {
          setState(() {
            // 可以添加一个通话状态指示器
          });
        }
      }

      // 更新最近联系人列表中的群组信息（显示通话状态）
      _updateRecentContactForCall(groupId, callType, callerName ?? '未知用户', message ?? '发起了通话');

    } catch (e) {
      logger.debug('❌ 处理群组通话通知失败: $e');
    }
  }

  // 更新最近联系人列表中的通话信息
  void _updateRecentContactForCall(int groupId, String callType, String callerName, String message) {
    try {
      if (!mounted) return;

      // 在最近联系人列表中更新该群组的最新消息显示
      setState(() {
        // 可以在这里更新UI，显示通话状态
        logger.debug('📞 [最近联系人] 更新群组 $groupId 的通话状态: $callType');
      });

    } catch (e) {
      logger.debug('❌ 更新最近联系人通话状态失败: $e');
    }
  }

  // 处理群组通话成员离开通知
  void _handleGroupCallMemberLeft(dynamic data) {
    try {
      if (data == null) return;
      if (!mounted) return;

      final leftUserId = data['left_user_id'] as int?;
      final leftDisplayName = data['left_display_name'] as String?;
      final channelName = data['channel_name'] as String?;

      logger.debug('📞 [群组通话成员离开] 收到成员离开通知 - 用户ID: $leftUserId, 名称: $leftDisplayName, 频道: $channelName');

      // 🔴 关键修复：强制刷新消息列表UI，确保"加入通话"按钮等UI元素能够正确更新
      // 当有成员离开通话时，需要刷新对话框以隐藏或更新相关按钮
      if (mounted && _messages.isNotEmpty) {
        setState(() {
          logger.debug('📞 [群组通话成员离开] 强制刷新UI以更新通话状态');
          // 通过修改_messages列表来触发UI重建，确保所有消息重新渲染
          _messages = List.from(_messages);
        });
      }

    } catch (e) {
      logger.debug('❌ 处理群组通话成员离开通知失败: $e');
    }
  }

  // 处理群组消息（WebSocket推送）
  Future<void> _handleGroupMessage(Map<String, dynamic> message) async {
    try {
      final data = message['data'] as Map<String, dynamic>?;
      final groupId = message['group_id'] as int?;

      if (data == null || groupId == null) {
        logger.debug('⚠️ 群组消息数据不完整');
        return;
      }

      if (!mounted) return;

      final messageId = data['id'] as int?;
      final senderId = data['sender_id'] as int?;
      final senderName = data['sender_name'] as String?;
      final senderAvatar = data['sender_avatar'] as String?;
      final content = data['content'] as String?;
      final messageType = data['message_type'] as String? ?? 'text';
      final fileName = data['file_name'] as String?;
      final quotedMessageId = data['quoted_message_id'] as int?;
      final quotedMessageContent = data['quoted_message_content'] as String?;
      final mentionedUserIds = (data['mentioned_user_ids'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList();
      final mentions = data['mentions'] as String?;
      final createdAt = data['created_at'] as String?;
      final callType = data['call_type'] as String?;  // 提取通话类型
      final channelName = data['channel_name'] as String?;  // 提取频道名称

      logger.debug(
        '📩 收到群组消息 - 群组ID: $groupId, 发送者ID: $senderId, 消息类型: $messageType, 内容: $content',
      );
      
      // 🔍 特别关注通话相关消息的字段
      if (messageType == 'call_initiated' || messageType == 'join_voice_button' || messageType == 'join_video_button' || messageType == 'call_ended' || messageType == 'call_ended_video') {
        logger.debug('📞 [通话消息-收到] messageType: $messageType, callType: $callType, channelName: $channelName');
        logger.debug('📞 [通话消息-收到] callType类型: ${callType.runtimeType}, channelName类型: ${channelName.runtimeType}');
        logger.debug('📞 [通话消息-收到] callType为空? ${callType == null || callType.isEmpty}, channelName为空? ${channelName == null || channelName.isEmpty}');
      }
      
      if (mentionedUserIds != null && mentionedUserIds.isNotEmpty) {
        logger.debug('📩 消息包含@: $mentions, 被@的用户IDs: $mentionedUserIds');
      }
      logger.debug(
        '📱 当前聊天群组ID: $_currentChatUserId, 是否群聊: $_isCurrentChatGroup',
      );

      if (senderId == null || content == null) {
        logger.debug('群组消息数据不完整');
        return;
      }

      // 处理系统消息
      if (messageType == 'system') {
        // 处理"您已被添加到群组"、"您已被邀请加入群组"、"创建新群组"的系统消息
        if (content == '您已被添加到群组' || 
            content.contains('您已被邀请加入群组') || 
            content.contains('创建新群组')) {
          logger.debug('📢 收到群组创建/邀请系统消息，确保群组在最近联系人列表中显示: $content');
          // 检查并恢复被删除的群组会话（等待完成，确保恢复后再检查列表）
          await _checkAndRestoreDeletedChat(isGroup: true, id: groupId);

          // 检查群组是否在最近联系人列表中
          final contactIndex = _recentContacts.indexWhere(
            (contact) => contact.isGroup && contact.groupId == groupId,
          );

          if (contactIndex == -1) {
            // 群组不在列表中，获取群组信息并添加到列表
            logger.debug('⚠️ 群组不在最近联系人列表中，获取群组信息并添加到列表');
            try {
              final token = _token;
              if (token != null && token.isNotEmpty) {
                // 获取群组详情
                final groupResponse = await ApiService.getGroupDetail(
                  token: token,
                  groupId: groupId,
                );

                if (groupResponse['code'] == 0 &&
                    groupResponse['data'] != null) {
                  final groupData =
                      groupResponse['data']['group'] as Map<String, dynamic>;
                  final groupName = groupData['name'] as String? ?? '未知群组';
                  final groupAvatar = groupData['avatar'] as String?; // 获取群组头像
                  final remark = groupData['remark'] as String?;
                  final doNotDisturb =
                      groupData['do_not_disturb'] as bool? ?? false;

                  // 根据消息类型格式化显示内容
                  final formattedMessage =
                      _formatMessagePreviewForRecentContact(
                        messageType,
                        content,
                      );

                  // 创建群组联系人
                  final groupContact =
                      RecentContactModel.group(
                        groupId: groupId,
                        groupName: groupName,
                        avatar: groupAvatar, // 传递群组头像
                        lastMessage: formattedMessage,
                        lastMessageTime:
                            createdAt ?? DateTime.now().toIso8601String(),
                        remark: remark,
                        doNotDisturb: doNotDisturb,
                      ).copyWith(
                        unreadCount: 1, // 系统消息也算未读
                        hasMentionedMe: false, // 系统消息不是@消息
                      );

                  setState(() {
                    // 将群组添加到列表顶部
                    _recentContacts.insert(0, groupContact);
                    // 如果之前有选中的联系人，索引需要加1
                    if (_selectedChatIndex >= 0) {
                      _selectedChatIndex++;
                    }
                  });

                  logger.debug('✅ 已将群组添加到最近联系人列表');

                  // 播放新消息提示音（有新未读消息）
                  _playNewMessageSound();
                }
              }
            } catch (e) {
              logger.debug('❌ 获取群组信息失败: $e');
            }
          } else {
            // 群组已在列表中，更新最后消息和时间，增加未读计数
            setState(() {
              final formattedMessage = _formatMessagePreviewForRecentContact(
                messageType,
                content,
              );
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    unreadCount: _recentContacts[contactIndex].unreadCount + 1,
                    lastMessage: formattedMessage,
                    lastMessageTime:
                        createdAt ?? DateTime.now().toIso8601String(),
                    hasMentionedMe: false, // 系统消息不是@消息
                  );

              // 将该群组移到列表顶部
              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);

                // 如果移动的是当前选中的联系人，更新索引
                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }
            });

            // 播放新消息提示音（有新未读消息）
            _playNewMessageSound();
          }
        }
        // 处理"您已被移除群组"的系统消息
        else if (content == '您已被移除群组') {
          logger.debug('📢 收到"您已被移除群组"系统消息，从群组成员中去除');
          // 标记该群组为已移除状态（存储在本地状态中）
          setState(() {
            _removedGroupIds.add(groupId);
          });

          // 如果当前正在查看该群组，显示提示
          if (_isCurrentChatGroup && _currentChatUserId == groupId) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('您已被移除群组'),
                  backgroundColor: Colors.orange,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }
        // 🔴 已删除：群组通话邀请成员的通知处理
        // 不再通过群组消息发送邀请通知，邀请消息由服务器API直接推送

        // 系统消息也需要显示在聊天窗口中（如果正在查看该群组）
        if (_isCurrentChatGroup && _currentChatUserId == groupId) {
          final newMessage = MessageModel(
            id: messageId ?? 0,
            senderId: senderId,
            receiverId: groupId,
            senderName: senderName ?? '系统',
            receiverName: '',
            senderAvatar: senderAvatar,
            receiverAvatar: null,
            senderNickname: null,
            content: content,
            messageType: messageType,
            fileName: fileName,
            quotedMessageId: quotedMessageId,
            quotedMessageContent: quotedMessageContent,
            mentionedUserIds: mentionedUserIds,
            mentions: mentions,
            callType: callType,  // 添加通话类型
            channelName: channelName,  // 添加频道名称
            isRead: true,
            createdAt: createdAt != null
                ? DateTime.parse(createdAt)
                : DateTime.now(),
          );

          // 🔍 验证MessageModel字段
          if (messageType == 'call_initiated' || messageType == 'join_voice_button' || messageType == 'call_ended' || messageType == 'call_ended_video') {
            logger.debug('✅ [MessageModel创建] messageType: ${newMessage.messageType}, callType: ${newMessage.callType}, channelName: ${newMessage.channelName}');
          }

          setState(() {
            _messages.add(newMessage);
          });

          _scrollToBottom();
        }

        // 系统消息处理完成，直接返回
        return;
      }

      // 检查并恢复被删除的群组会话（等待完成，确保恢复后再处理消息）
      final restored = await _checkAndRestoreDeletedChat(isGroup: true, id: groupId);
      if (restored) {
        logger.debug('✅ 群组会话已恢复并重新加载，现在继续处理当前消息以确保显示在列表中');
        // 播放新消息提示音（只有别人发送的消息才播放）
        if (senderId != _currentUserId) {
          _playNewMessageSound();
        }
        // 🔴 不再直接返回，继续处理当前消息，确保消息能正确显示在最近联系人列表中
      }

      // 判断是否是当前正在聊天的群组
      bool isCurrentGroupChat = _isCurrentChatGroup && _currentChatUserId == groupId;
      bool isCallMessage = messageType == 'join_voice_button' || messageType == 'join_video_button' || messageType == 'call_ended' || messageType == 'call_ended_video';
      
      if (isCurrentGroupChat || isCallMessage) {
        // 正在查看该群聊天窗口，或者是通话相关消息（需要特殊处理），直接显示消息
        final newMessage = MessageModel(
          id: messageId ?? 0,
          senderId: senderId,
          receiverId: groupId,
          senderName: senderName ?? '',
          receiverName: '',
          senderAvatar: senderAvatar,
          receiverAvatar: null,
          senderNickname: null,
          content: content,
          messageType: messageType,
          fileName: fileName,
          quotedMessageId: quotedMessageId,
          quotedMessageContent: quotedMessageContent,
          mentionedUserIds: mentionedUserIds,
          mentions: mentions,
          callType: callType,  // 添加通话类型
          channelName: channelName,  // 添加频道名称
          isRead: true,
          createdAt: createdAt != null
              ? DateTime.parse(createdAt)
              : DateTime.now(),
        );

        // 🔍 验证MessageModel字段（正在查看的群组）
        if (messageType == 'call_initiated' || messageType == 'join_voice_button' || messageType == 'join_video_button' || messageType == 'call_ended' || messageType == 'call_ended_video') {
          logger.debug('✅ [MessageModel创建-当前群组] messageType: ${newMessage.messageType}, callType: ${newMessage.callType}, channelName: ${newMessage.channelName}');
        }

        setState(() {
          // 只有在真正查看当前群组时才添加到消息列表
          if (isCurrentGroupChat) {
            _messages.add(newMessage);
            
            // 🔴 新增：如果是通话相关消息，强制刷新UI以确保按钮正确显示/隐藏
            if (messageType == 'call_ended' || messageType == 'call_ended_video') {
              logger.debug('📞 [PC-通话结束] 收到通话结束消息，强制刷新UI以隐藏加入按钮');
              // 通过修改_messages列表来触发UI重建，确保所有消息重新渲染
              _messages = List.from(_messages);
            } else if (messageType == 'join_voice_button' || messageType == 'join_video_button') {
              logger.debug('📞 [PC-通话发起] 收到通话发起消息，强制刷新UI以显示加入按钮');
              // 通过修改_messages列表来触发UI重建，确保按钮能够显示
              _messages = List.from(_messages);
            }
          } else if (isCallMessage) {
            logger.debug('📞 [PC-通话消息] 收到通话消息但不在群组聊天界面，仅更新最近联系人列表');
          }

          // 同时更新最近联系人列表中的最后消息和最后消息时间
          final contactIndex = _recentContacts.indexWhere(
            (contact) => contact.isGroup && contact.groupId == groupId,
          );

          if (contactIndex != -1) {
            // 更新最后消息和最后消息时间（不增加未读数，因为用户正在查看）
            // 根据消息类型格式化显示内容
            final formattedMessage = _formatMessagePreviewForRecentContact(
              messageType,
              content,
            );
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(
                  lastMessage: formattedMessage,
                  lastMessageTime:
                      createdAt ?? DateTime.now().toIso8601String(),
                  hasMentionedMe: false, // 用户正在查看，清除@标志
                );

            // 将该群组移到列表顶部（保持最新消息在顶部）
            if (contactIndex != 0) {
              final contact = _recentContacts.removeAt(contactIndex);
              _recentContacts.insert(0, contact);

              // 如果移动的是当前选中的联系人，更新索引
              if (_selectedChatIndex == contactIndex) {
                _selectedChatIndex = 0;
              } else if (_selectedChatIndex < contactIndex) {
                // 如果当前选中的在被移动项之前，索引需要加1
                _selectedChatIndex++;
              }
            }

            logger.debug('✅ 已更新最近联系人列表中的群组最后消息');
          }
        });

        // 收到新消息，重新启用自动滚动定时器
        if (_isUserScrolling) {
          logger.debug('📜 收到新群组消息，重新启用自动滚动');
          _isUserScrolling = false;
          _lastScrollPosition = 0.0; // 重置滚动位置记录
        }

        _scrollToBottom();

        // 检查是否需要自动下载文件
        _autoDownloadFileIfNeeded(newMessage);

        logger.debug('群组消息已显示在当前聊天窗口');
      } else {
        // 不是当前聊天的群组，更新最近联系人列表并增加未读计
        logger.debug('💬 收到其他群组的消息，更新未读计数');

        // 检查是否是自己发送的消息
        bool isSelfMessage = senderId == _currentUserId;
        if (isSelfMessage) {
          logger.debug('✅ 收到自己发送的群组消息，不增加未读计数，直接标记为已读');

          // 先检查群组是否在列表中
          final contactIndex = _recentContacts.indexWhere(
            (contact) => contact.isGroup && contact.groupId == groupId,
          );

          if (contactIndex != -1) {
            // 群组已在列表中，更新最后消息和时间，将未读计数设为0
            setState(() {
              // 根据消息类型格式化显示内容
              final formattedMessage = _formatMessagePreviewForRecentContact(
                messageType,
                content,
              );
              _recentContacts[contactIndex] = _recentContacts[contactIndex]
                  .copyWith(
                    unreadCount: 0, // 自己发送的消息，未读计数为0
                    lastMessage: formattedMessage,
                    lastMessageTime:
                        createdAt ?? DateTime.now().toIso8601String(),
                    hasMentionedMe: false, // 自己发送的消息，清除@标志
                  );

              // 将该群组移到列表顶部
              if (contactIndex != 0) {
                final contact = _recentContacts.removeAt(contactIndex);
                _recentContacts.insert(0, contact);

                // 如果移动的是当前选中的联系人，更新索引
                if (_selectedChatIndex == contactIndex) {
                  _selectedChatIndex = 0;
                } else if (_selectedChatIndex < contactIndex) {
                  _selectedChatIndex++;
                }
              }

              logger.debug('✅ 已更新自己发送的群组消息，未读计数已清零');
            });
          } else {
            // 群组不在列表中，获取群组信息并添加到列表（未读计数为0）
            logger.debug('⚠️ 群组不在最近联系人列表中，获取群组信息并添加到列表（自己发送的消息）');

            try {
              final token = _token;
              if (token != null && token.isNotEmpty) {
                // 获取群组详情
                final groupResponse = await ApiService.getGroupDetail(
                  token: token,
                  groupId: groupId,
                );

                if (groupResponse['code'] == 0 &&
                    groupResponse['data'] != null) {
                  final groupData =
                      groupResponse['data']['group'] as Map<String, dynamic>;
                  final groupName = groupData['name'] as String? ?? '未知群组';
                  final groupAvatar = groupData['avatar'] as String?; // 获取群组头像
                  final remark = groupData['remark'] as String?;
                  final doNotDisturb =
                      groupData['do_not_disturb'] as bool? ?? false;

                  // 根据消息类型格式化显示内容
                  final formattedMessage =
                      _formatMessagePreviewForRecentContact(
                        messageType,
                        content,
                      );

                  // 创建新的群组联系人并添加到列表顶部（未读计数为0）
                  final newContact =
                      RecentContactModel.group(
                        groupId: groupId,
                        groupName: groupName,
                        avatar: groupAvatar, // 传递群组头像
                        lastMessage: formattedMessage,
                        lastMessageTime:
                            createdAt ?? DateTime.now().toIso8601String(),
                        remark: remark,
                        doNotDisturb: doNotDisturb,
                      ).copyWith(
                        unreadCount: 0, // 自己发送的消息，未读计数为0
                        hasMentionedMe: false, // 自己发送的消息，清除@标志
                      );

                  if (mounted) {
                    setState(() {
                      // 将新群组添加到列表顶部
                      _recentContacts.insert(0, newContact);

                      // 如果当前选中的联系人索引需要更新
                      if (_selectedChatIndex >= 0) {
                        _selectedChatIndex++;
                      }

                      logger.debug('✅ 已将群组添加到最近联系人列表（自己发送的消息）: $groupName');
                    });
                  }
                } else {
                  // 获取群组详情失败，不刷新整个列表
                  logger.debug('⚠️ 获取群组详情失败（自己发送的消息），暂不处理');
                  // PC端优化：不刷新整个列表
                  // _loadRecentContacts();
                }
              } else {
                // 未登录，不刷新整个列表
                logger.debug('⚠️ 未登录（自己发送的消息），暂不处理');
                // PC端优化：不刷新整个列表
                // _loadRecentContacts();
              }
            } catch (e) {
              logger.debug('❌ 获取群组信息失败（自己发送的消息）: $e，暂不处理');
              // PC端优化：不刷新整个列表
              // 出错时回退到刷新整个列表
              // _loadRecentContacts();
            }
          }

          // 自己发送的消息处理完成，直接返回
          return;
        }

        // 检查是否@了自
        bool isMentionedMe = false;
        logger.debug('');
        logger.debug('========== @功能调试信息 ==========');
        logger.debug('📋 当前用户ID: $_currentUserId');
        logger.debug('📋 @文本内容: $mentions');
        logger.debug('📋 被@的用户ID列表: $mentionedUserIds');

        if (mentionedUserIds != null && mentionedUserIds.isNotEmpty) {
          logger.debug('📋 开始检查是否@了自..');
          logger.debug(
            '📋 mentionedUserIds类型: ${mentionedUserIds.runtimeType}',
          );
          logger.debug('📋 mentionedUserIds内容: ${mentionedUserIds.toString()}');
          logger.debug('📋 _currentUserId类型: ${_currentUserId.runtimeType}');
          logger.debug('📋 _currentUserId $_currentUserId');

          for (var id in mentionedUserIds) {
            logger.debug(
              '📋 检查ID: $id (类型: ${id.runtimeType}) == $_currentUserId ? ${id == _currentUserId}',
            );
          }

          isMentionedMe = mentionedUserIds.contains(_currentUserId);
          logger.debug('📋 contains()结果: $isMentionedMe');

          if (isMentionedMe) {
            logger.debug('消息@了我，未读数1');
          } else {
            logger.debug('消息没有@任何人');
          }
        } else {
          logger.debug('📋 mentionedUserIds为空或null，此消息没有@任何人');
        }
        logger.debug('==================================');
        logger.debug('');

        // 先检查群组是否在列表中
        final contactIndex = _recentContacts.indexWhere(
          (contact) => contact.isGroup && contact.groupId == groupId,
        );

        if (contactIndex != -1) {
          // 群组已在列表中，更新未读计数和最后消息
          setState(() {
            int oldUnreadCount = _recentContacts[contactIndex].unreadCount;
            bool isDoNotDisturb = _recentContacts[contactIndex].doNotDisturb;

            // 如果群组设置了消息免打扰，未读数固定为1（只显示红点，不显示具体数量）
            // 否则正常累加未读数
            int newUnreadCount = isDoNotDisturb ? 1 : (oldUnreadCount + 1);

            // 🔧 修复：有新消息了，从已读集合中移除
            final contactKey = 'group_$groupId';
            if (_markedAsReadContacts.remove(contactKey)) {
              logger.debug('🔧 修复：收到新消息，已将 $contactKey 从已读集合中移除');
            }

            logger.debug(
              '📊 未读数更新：原未读数=$oldUnreadCount, 新未读数=$newUnreadCount, 是否被@=$isMentionedMe, 免打扰=$isDoNotDisturb',
            );

            // 根据消息类型格式化显示内容
            final formattedMessage = _formatMessagePreviewForRecentContact(
              messageType,
              content,
            );
            _recentContacts[contactIndex] = _recentContacts[contactIndex]
                .copyWith(
                  unreadCount: newUnreadCount,
                  lastMessage: formattedMessage,
                  lastMessageTime:
                      createdAt ?? DateTime.now().toIso8601String(),
                  hasMentionedMe: isMentionedMe, // 设置是否被@的标志
                );

            logger.debug(
              '📊 更新后的联系人未读数: ${_recentContacts[contactIndex].unreadCount}',
            );

            // 将该群组移到列表顶部
            final contact = _recentContacts.removeAt(contactIndex);
            _recentContacts.insert(0, contact);

            // 如果移动的是当前选中的联系人，更新索引
            if (_selectedChatIndex == contactIndex) {
              _selectedChatIndex = 0;
            } else if (_selectedChatIndex < contactIndex) {
              // 如果当前选中的在被移动项之前，索引需要加1
              _selectedChatIndex++;
            }

            logger.debug('已更新群组未读数 ${_recentContacts[0].unreadCount}');
          });

          // 播放新消息提示音（有新未读消息）
          _playNewMessageSound();

          // 显示新消息通知弹窗
          final groupName = _recentContacts[0].groupName ?? _recentContacts[0].fullName;
          final groupAvatar = _recentContacts[0].avatar; // 使用群组头像
          final formattedMessage = _formatMessagePreviewForRecentContact(messageType, content);
          final displayMessage = senderName != null && senderName.isNotEmpty
              ? '$senderName: $formattedMessage'
              : formattedMessage;
          _showMessageNotificationPopup(
            title: groupName,
            message: displayMessage,
            avatar: groupAvatar, // 传递群组头像而不是发送者头像
            isGroup: true,
            contactId: groupId,
          );
        } else {
          // 群组不在列表中，获取群组信息并直接添加到列表
          logger.debug('⚠️ 群组不在最近联系人列表中，获取群组信息并添加到列表');

          try {
            final token = _token;
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

                // 根据消息类型格式化显示内容
                final formattedMessage = _formatMessagePreviewForRecentContact(
                  messageType,
                  content,
                );

                // 计算未读计数（如果被@了，可能需要特殊处理）
                int unreadCount = 1;
                if (isMentionedMe) {
                  // 如果被@了，未读数至少为1
                  unreadCount = 1;
                }
                if (doNotDisturb) {
                  // 如果设置了免打扰，未读数固定为1
                  unreadCount = 1;
                }

                // 创建新的群组联系人并添加到列表顶部
                final newContact =
                    RecentContactModel.group(
                      groupId: groupId,
                      groupName: groupName,
                      avatar: groupAvatar, // 传递群组头像
                      lastMessage: formattedMessage,
                      lastMessageTime:
                          createdAt ?? DateTime.now().toIso8601String(),
                      remark: remark,
                      doNotDisturb: doNotDisturb,
                    ).copyWith(
                      unreadCount: unreadCount,
                      hasMentionedMe: isMentionedMe, // 设置是否被@的标志
                    );

                if (mounted) {
                  setState(() {
                    // 将新群组添加到列表顶部
                    _recentContacts.insert(0, newContact);

                    // 如果当前选中的联系人索引需要更新
                    if (_selectedChatIndex >= 0) {
                      _selectedChatIndex++;
                    }

                    logger.debug('✅ 已将群组添加到最近联系人列表: $groupName');
                  });

                  // 播放新消息提示音（有新未读消息）
                  _playNewMessageSound();

                  // 显示新消息通知弹窗
                  final formattedMessage = _formatMessagePreviewForRecentContact(messageType, content);
                  final displayMessage = senderName != null && senderName.isNotEmpty
                      ? '$senderName: $formattedMessage'
                      : formattedMessage;
                  _showMessageNotificationPopup(
                    title: groupName,
                    message: displayMessage,
                    avatar: groupAvatar, // 使用群组头像而不是发送者头像
                    isGroup: true,
                    contactId: groupId,
                  );
                }
              } else {
                // 获取群组详情失败，不刷新整个列表
                logger.debug('⚠️ 获取群组详情失败（收到他人消息），暂不处理');
                // PC端优化：不刷新整个列表
                // _loadRecentContacts();

                // 播放新消息提示音（有新未读消息）
                _playNewMessageSound();
              }
            } else {
              // 未登录，不刷新整个列表
              logger.debug('⚠️ 未登录（收到他人消息），暂不处理');
              // PC端优化：不刷新整个列表
              // _loadRecentContacts();

              // 播放新消息提示音（有新未读消息）
              _playNewMessageSound();
            }
          } catch (e) {
            logger.debug('❌ 获取群组信息失败（收到他人消息）: $e，暂不处理');
            // PC端优化：不刷新整个列表
            // 出错时回退到刷新整个列表
            // _loadRecentContacts();

            // 播放新消息提示音（有新未读消息）
            _playNewMessageSound();
          }
        }
      }
    } catch (e) {
      logger.debug('处理群组消息失败: $e');
    }
  }

  // 处理删除消息通知（用于删除"加入通话"按钮等消息）
  void _handleDeleteMessageNotification(dynamic data) {
    if (data == null) return;
    if (!mounted) return;

    final messageId = data['message_id'] as int?;
    final groupId = data['group_id'] as int?;

    if (messageId == null) {
      logger.debug('⚠️ 删除消息通知缺少 message_id');
      return;
    }

    logger.debug('🗑️ 收到删除消息通知 - MessageID: $messageId, GroupID: $groupId');

    setState(() {
      // 🔴 修复：检查要删除的消息类型，如果是通话发起消息（join_voice_button/join_video_button），
      // 不删除，因为这是通话记录的一部分，用户需要看到"XX发起了语音通话"
      final messageToDelete = _messages.firstWhere(
        (msg) => msg.id == messageId,
        orElse: () => MessageModel(
          id: 0,
          senderId: 0,
          receiverId: 0,
          senderName: '',
          receiverName: '',
          content: '',
          messageType: '',
          isRead: true,
          createdAt: DateTime.now(),
        ),
      );
      
      if (messageToDelete.id != 0) {
        final messageType = messageToDelete.messageType;
        if (messageType == 'join_voice_button' || messageType == 'join_video_button') {
          logger.debug('📞 [删除消息] 检测到通话发起消息，保留不删除 - MessageType: $messageType, Content: ${messageToDelete.content}');
          // 不删除通话发起消息，保留通话记录
          return;
        }
      }
      
      // 从消息列表中删除对应的消息
      _messages.removeWhere((msg) => msg.id == messageId);
      logger.debug('✅ 已从消息列表删除消息 - MessageID: $messageId');
    });
  }

  // 显示群组信息弹窗
  void _showGroupInfoDialog() async {
    if (_currentChatUserId == null || !_isCurrentChatGroup) {
      logger.debug('⚠️ 当前不是群组聊天，无法显示群组信息');
      return;
    }

    // 先加载联系人列表
    await _loadContacts();

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 显示加载对话
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // 获取群组详情
      logger.debug('📡 开始获取群组详情 - 群组ID: $_currentChatUserId');
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: _currentChatUserId!,
      );

      logger.debug('📡 获取群组详情响应: code=${response['code']}, message=${response['message']}');

      // 关闭加载对话
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0 && response['data'] != null) {
        final groupData = response['data']['group'];
        final membersData = response['data']['members'] as List?;
        
        logger.debug('📡 群组数据: name=${groupData['name']}, avatar=${groupData['avatar']}');

        // 提取成员ID列表
        final memberIds = (membersData ?? [])
            .map((member) => member['user_id'] as int)
            .toList();

        // 将成员数据转换为Map列表
        final membersDataList = (membersData ?? [])
            .map((member) => member as Map<String, dynamic>)
            .toList();

        if (!mounted) return;

        // 使用自动重新打开的方式显示群组设置页面（处理FilePicker导致页面销毁的问题）
        await _openGroupSettingsPageWithAutoReopen(
          groupData: groupData,
          memberIds: memberIds,
          membersDataList: membersDataList,
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '获取群组信息失败')),
          );
        }
      }
    } catch (e) {
      // 关闭可能存在的加载对话框
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      logger.debug('获取群组信息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取群组信息失败: $e')));
      }
    }
  }

  // 从固定群组页面显示群组信息弹窗
  void _showGroupInfoDialogFromGroupId(int groupId) async {
    // 先加载联系人列表
    await _loadContacts();

    try {
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 显示加载对话
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // 获取群组详情
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: groupId,
      );

      // 关闭加载对话
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0 && response['data'] != null) {
        final groupData = response['data']['group'];
        final membersData = response['data']['members'] as List?;

        // 提取成员ID列表
        final memberIds = (membersData ?? [])
            .map((member) => member['user_id'] as int)
            .toList();

        // 将成员数据转换为Map列表
        final membersDataList = (membersData ?? [])
            .map((member) => member as Map<String, dynamic>)
            .toList();

        if (!mounted) return;

        // 使用自动重新打开的方式显示群组设置页面（处理FilePicker导致页面销毁的问题）
        await _openGroupSettingsPageWithAutoReopen(
          groupData: groupData,
          memberIds: memberIds,
          membersDataList: membersDataList,
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '获取群组信息失败')),
          );
        }
      }
    } catch (e) {
      // 关闭可能存在的加载对话框
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      logger.debug('获取群组信息失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取群组信息失败: $e')));
      }
    }
  }

  // 显示群管理弹窗
  void _showGroupManagementDialog(GroupModel group) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text(
              '群管理',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            content: Container(
              width: 400,
              constraints: const BoxConstraints(maxHeight: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 全体禁言开关
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.volume_off,
                        color: Color(0xFFFF9800),
                        size: 24,
                      ),
                    ),
                    title: const Text(
                      '全体禁言',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF333333),
                      ),
                    ),
                    subtitle: const Text(
                      '开启后普通成员无法发送消息',
                      style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    ),
                    trailing: Switch(
                      value: group.allMuted,
                      onChanged: (value) async {
                        try {
                          final token = _token;
                          if (token == null || token.isEmpty) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('未登录')),
                              );
                            }
                            return;
                          }

                          final response = await ApiService.updateGroupAllMuted(
                            token: token,
                            groupId: group.id,
                            allMuted: value,
                          );

                          if (response['code'] == 0) {
                            if (mounted) {
                              // 更新本地群组状态
                              final updatedGroup = group.copyWith(
                                allMuted: value,
                              );
                              // 更新群组列表
                              final groupIndex = _groups.indexWhere(
                                (g) => g.id == group.id,
                              );
                              if (groupIndex != -1) {
                                this.setState(() {
                                  _groups[groupIndex] = updatedGroup;
                                });
                              }
                              // 更新对话框中的状态
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(response['message'] ?? '设置成功'),
                                ),
                              );
                            }
                          } else {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(response['message'] ?? '设置失败'),
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          logger.debug('更新全体禁言状态失败: $e');
                          if (mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('设置失败: $e')));
                          }
                        }
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  // 群主管理权限转让
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F5FF),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.admin_panel_settings,
                        color: Color(0xFF4A90E2),
                        size: 24,
                      ),
                    ),
                    title: const Text(
                      '群主管理权限转让',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF333333),
                      ),
                    ),
                    subtitle: const Text(
                      '将群主权限转让给其他成员',
                      style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    ),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: Color(0xFFCCCCCC),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showTransferOwnershipDialog(group);
                    },
                  ),
                  const Divider(height: 1),
                  // 解散群聊
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEBEE),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.delete_outline,
                        color: Color(0xFFE53935),
                        size: 24,
                      ),
                    ),
                    title: const Text(
                      '解散该群聊',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFE53935),
                      ),
                    ),
                    subtitle: const Text(
                      '解散后该群聊将不再显示',
                      style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    ),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: Color(0xFFCCCCCC),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _handleDisbandGroup(group);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  '关闭',
                  style: TextStyle(color: Color(0xFF666666)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 解散群聊
  Future<void> _handleDisbandGroup(GroupModel group) async {
    // 弹出确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认解散'),
        content: const Text('确定要解散该群聊吗？解散后该群聊将不再显示，但数据仍会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE53935),
            ),
            child: const Text('确定解散'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // 获取token
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      // 调用API删除群组
      final response = await ApiService.deleteGroup(
        token: token,
        groupId: group.id,
      );

      if (response['code'] == 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该群聊已解散')));

          // 将解散的群组存储到本地Storage（最近联系人删除的群组）
          final userId = await Storage.getUserId();
          if (userId != null) {
            final contactKey = Storage.generateContactKey(
              isGroup: true,
              id: group.id,
            );
            await Storage.addDeletedChat(userId, contactKey);
            logger.debug('💾 已保存解散的群组到本地Storage（最近联系人删除）: groupId=${group.id}');
          }

          // 从最近联系人列表中删除该群组
          setState(() {
            _recentContacts.removeWhere(
              (contact) => contact.isGroup && contact.groupId == group.id,
            );

            // 如果当前正在查看被解散的群组，清空选中状态
            if (_selectedPerson != null &&
                _selectedPerson!['isGroup'] == true &&
                _selectedPerson!['groupId'] == group.id) {
              _selectedPerson = null;
              _messages.clear();
              _selectedChatIndex = 0;
            }
          });

          // 重新加载群组列表
          _loadGroups();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '解散失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('解散群组失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('解散失败: $e')));
      }
    }
  }

  // 显示群主权限转让对话框
  void _showTransferOwnershipDialog(GroupModel group) async {
    // 获取群成员列表（排除自己）
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    // 显示加载对话框
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 获取群组详情和成员列表
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: group.id,
      );

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] != 0 || response['data'] == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '获取群成员失败')),
          );
        }
        return;
      }

      final membersData = response['data']['members'] as List?;
      if (membersData == null || membersData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('群组暂无其他成员')));
        }
        return;
      }

      // 过滤掉自己，只显示其他成员
      final otherMembers = membersData
          .where((member) => member['user_id'] != _currentUserId)
          .toList();

      if (otherMembers.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('群组暂无其他成员')));
        }
        return;
      }

      // 显示成员选择对话框
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            '选择新群主',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          content: Container(
            width: 400,
            constraints: const BoxConstraints(maxHeight: 500),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: otherMembers.length,
              itemBuilder: (context, index) {
                final member = otherMembers[index];
                final userId = member['user_id'] as int;
                final nickname = member['nickname'] as String?;
                final displayName = nickname ?? '用户$userId';
                final avatarUrl = member['avatar'] as String?;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A90E2),
                      borderRadius: BorderRadius.circular(8),
                      image: avatarUrl != null && avatarUrl.isNotEmpty
                          ? DecorationImage(
                              image: NetworkImage(avatarUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: avatarUrl == null || avatarUrl.isEmpty
                        ? Center(
                            child: Text(
                              displayName.length >= 2
                                  ? displayName.substring(
                                      displayName.length - 2,
                                    )
                                  : displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                        : null,
                  ),
                  title: Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF333333),
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmTransferOwnership(group, userId, displayName);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '取消',
                style: TextStyle(color: Color(0xFF666666)),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      // 关闭可能存在的加载对话框
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      logger.debug('获取群成员失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取群成员失败: $e')));
      }
    }
  }

  // 确认转让群主权限
  void _confirmTransferOwnership(
    GroupModel group,
    int newOwnerId,
    String newOwnerName,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '确认转让',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        content: Text(
          '确定要将群主权限转让给 $newOwnerName 吗？\n\n转让后您将成为普通成员，无法撤销此操作。',
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF666666),
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Color(0xFF666666))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _executeTransferOwnership(group, newOwnerId);
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFF4D4F),
            ),
            child: const Text('确认转让'),
          ),
        ],
      ),
    );
  }

  // 执行转让群主权限
  void _executeTransferOwnership(GroupModel group, int newOwnerId) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    // 显示加载对话框
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final response = await ApiService.transferGroupOwnership(
        token: token,
        groupId: group.id,
        newOwnerId: newOwnerId,
      );

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('群主权限转让成功'),
              backgroundColor: Color(0xFF52C41A),
            ),
          );
        }

        // 刷新群组列表
        await _loadGroups();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '转让失败')),
          );
        }
      }
    } catch (e) {
      // 关闭可能存在的加载对话框
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      logger.debug('转让群主权限失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('转让失败: $e')));
      }
    }
  }

  // 显示创建群组对话
  void _showCreateGroupDialog({bool autoSelectCurrentChat = true}) async {
    // 先加载联系人列表
    await _loadContacts();

    if (!mounted) return;

    // 检查是否已经存在包含当前对话联系人的群
    Map<String, dynamic>? existingGroupData;
    List<int> existingMemberIds = [];

    if (autoSelectCurrentChat &&
        _currentChatUserId != null &&
        !_isCurrentChatGroup) {
      try {
        final token = _token;
        if (token != null && token.isNotEmpty) {
          // 获取当前用户的所有群
          final groupsResponse = await ApiService.getUserGroups(token: token);

          if (groupsResponse['code'] == 0 && groupsResponse['data'] != null) {
            final groups = groupsResponse['data']['groups'] as List?;

            if (groups != null) {
              // 查找包含当前对话联系人的群组
              for (var group in groups) {
                final groupId = group['id'] as int;

                // 获取群组详情和成员列
                final detailResponse = await ApiService.getGroupDetail(
                  token: token,
                  groupId: groupId,
                );

                if (detailResponse['code'] == 0 &&
                    detailResponse['data'] != null) {
                  final members = detailResponse['data']['members'] as List?;

                  if (members != null) {
                    final memberIds = members
                        .map((m) => m['user_id'] as int)
                        .toList();

                    // 检查是否包含当前对话的联系
                    if (memberIds.contains(_currentChatUserId)) {
                      existingGroupData = group;
                      existingMemberIds = memberIds
                          .where((id) => id != _currentUserId) // 排除当前用户
                          .toList();
                      logger.debug(
                        '找到已存在的群组: ${group['name']}, 成员: $existingMemberIds',
                      );
                      break;
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        logger.debug('检查已存在群组失败: $e');
      }
    }

    if (!mounted) return;

    // 使用全屏页面替代Dialog，解决FilePicker导致Dialog关闭的问题
    await _openCreateGroupPageWithAutoReopen(
      autoSelectCurrentChat: autoSelectCurrentChat,
      existingGroupData: existingGroupData,
      existingMemberIds: existingMemberIds,
    );
  }

  // 打开创建群组页面，并在页面被销毁后自动重新打开（处理FilePicker导致页面销毁的问题）
  Future<void> _openCreateGroupPageWithAutoReopen({
    bool autoSelectCurrentChat = false,
    Map<String, dynamic>? existingGroupData,
    List<int> existingMemberIds = const [],
  }) async {
    logger.debug('');
    logger.debug('========== [打开创建群组页面 - CreateGroupDialog] ==========');
    logger.debug('🚪 autoSelectCurrentChat: $autoSelectCurrentChat');
    logger.debug('🚪 existingGroupData: ${existingGroupData != null}');
    
    // 🔴 第一次打开时清空所有全局变量（避免显示上次的数据）
    logger.debug('🧹 清空全局变量（第一次打开）');
    cgdClearGlobalFormData();
    
    int loopCount = 0;
    while (true) {
      loopCount++;
      logger.debug('');
      logger.debug('🔄 [循环 $loopCount] 准备打开创建群组页面...');
      
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CreateGroupDialog(
            contacts: _contacts,
            currentUserId: _currentUserId,
            currentUserName: _userDisplayName,
            currentUserAvatar: _userAvatar ?? '',
            currentChatUserId: autoSelectCurrentChat ? _currentChatUserId : null,
            existingGroupData: existingGroupData,
            existingMemberIds: existingMemberIds,
            onCreateGroup: (group) {
              _handleGroupCreated(group);
            },
            onGroupUpdated: _handleGroupUpdated,
          ),
        ),
      );

      logger.debug('');
      logger.debug('🔙 [循环 $loopCount] 创建群组页面已关闭');
      logger.debug('🔙 返回结果: $result');
      logger.debug('🔙 mounted状态: $mounted');
      
      // 🔴 检查是否需要选择头像文件
      if (result == 'pick_avatar' && mounted) {
        logger.debug('📸 检测到需要选择头像文件');
        
        try {
          // 打开文件选择器
          logger.debug('📸 调用FilePicker...');
          final fileResult = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
            dialogTitle: '选择群组头像',
            withData: false,
            allowCompression: false,
          );
          
          logger.debug('📸 FilePicker返回');
          logger.debug('📸 fileResult是否为null: ${fileResult == null}');
          
          if (fileResult != null && fileResult.files.isNotEmpty && fileResult.files.first.path != null) {
            final selectedFile = File(fileResult.files.first.path!);
            logger.debug('✅ 已选择头像文件: ${selectedFile.path}');
            
            // 保存到 CreateGroupDialog 的全局变量
            cgdSetGlobalSelectedAvatar(selectedFile, null);
            logger.debug('✅ 已保存到全局变量');
          } else {
            logger.debug('⚠️ 未选择头像文件');
          }
        } catch (e) {
          logger.error('❌ 选择头像文件失败: $e');
        }
        
        // 重新打开页面
        logger.debug('🔄 准备重新打开创建群组页面...');
        await Future.delayed(const Duration(milliseconds: 100));
        continue; // 继续循环，重新打开页面
      }
      
      // 🔴 用户主动关闭页面，直接退出
      logger.debug('✅ 页面已关闭（result = $result），退出循环');
      break;
    }
    
    logger.debug('========== [创建群组页面流程结束] ==========');
    logger.debug('');
  }

  // 打开群组设置页面，并在页面被销毁后自动重新打开（处理FilePicker导致页面销毁的问题）
  Future<void> _openGroupSettingsPageWithAutoReopen({
    required Map<String, dynamic> groupData,
    required List<int> memberIds,
    required List<Map<String, dynamic>> membersDataList,
  }) async {
    logger.debug('');
    logger.debug('========== [打开群组设置页面 - CreateGroupDialog] ==========');
    logger.debug('📋 群组ID: ${groupData['id']}');
    logger.debug('📋 群组名称: ${groupData['name']}');
    logger.debug('📋 成员数量: ${memberIds.length}');
    
    // 🔴 第一次打开时清空所有全局变量（避免显示上次的数据）
    logger.debug('🧹 清空全局变量（第一次打开群组设置）');
    cgdClearGlobalFormData();
    
    int loopCount = 0;
    while (true) {
      loopCount++;
      logger.debug('');
      logger.debug('🔄 [循环 $loopCount] 准备打开群组设置页面...');
      
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CreateGroupDialog(
            contacts: _contacts,
            currentUserId: _currentUserId,
            currentUserName: _userDisplayName,
            currentUserAvatar: _userAvatar ?? '',
            existingGroupData: groupData,
            existingMemberIds: memberIds,
            existingMembersData: membersDataList,
            onCreateGroup: (group) {
              _handleGroupCreated(group);
            },
            onGroupUpdated: _handleGroupUpdated,
          ),
        ),
      );

      logger.debug('');
      logger.debug('🔙 [循环 $loopCount] 群组设置页面已关闭');
      logger.debug('🔙 返回结果: $result');
      logger.debug('🔙 mounted状态: $mounted');

      // 🔴 检查是否需要选择头像文件
      if (result == 'pick_avatar' && mounted) {
        logger.debug('📸 检测到需要选择头像文件');
        
        try {
          logger.debug('📸 调用FilePicker...');
          final fileResult = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
            dialogTitle: '选择群组头像',
            withData: false,
            allowCompression: false,
          );
          
          logger.debug('📸 FilePicker返回');
          logger.debug('📸 fileResult是否为null: ${fileResult == null}');
          
          if (fileResult != null && fileResult.files.isNotEmpty && fileResult.files.first.path != null) {
            final selectedFile = File(fileResult.files.first.path!);
            logger.debug('✅ 已选择头像文件: ${selectedFile.path}');
            cgdSetGlobalSelectedAvatar(selectedFile, null);
            logger.debug('✅ 已保存到全局变量');
          } else {
            logger.debug('⚠️ 未选择头像文件');
          }
        } catch (e) {
          logger.error('❌ 选择头像文件失败: $e');
        }
        
        logger.debug('🔄 准备重新打开群组设置页面...');
        await Future.delayed(const Duration(milliseconds: 100));
        continue; // 继续循环，重新打开页面
      }

      // 如果用户主动关闭（result != null），直接退出
      if (result != null) {
        logger.debug('✅ 用户主动关闭页面（result = $result），直接退出循环');
        // 如果退出群聊，刷新会话列表
        if (result == 'left' || result == true) {
          _loadRecentContacts();
        }
        break;
      }

      // 页面被系统关闭（result == null），直接退出
      logger.debug('⚠️ 页面被系统关闭（result = null），退出循环');
      break;
    }
    
    logger.debug('========== [群组设置页面流程结束] ==========');
    logger.debug('');
  }

  // 处理群组创建成功
  void _handleGroupCreated(GroupModel group) async {
    logger.debug('开始处理群组创建 ${group.name}, 群组ID: ${group.id}, 成员 ${group.memberIds.length}');

    try {
      // 🔴 修复：检查群组是否已经创建（有ID）
      // 如果群组已有ID，说明是从DesktopCreateGroupPage创建成功后回调过来的
      // 此时API已经调用过了，不需要再次调用，只需要处理后续逻辑
      if (group.id != null && group.id! > 0) {
        logger.debug('✅ 群组已创建（ID: ${group.id}），跳过API调用，直接处理后续逻辑');
        
        final createdGroupId = group.id!;
        final createdGroupName = group.name;
        
        // 🔴 关键修复：立即将当前用户添加到本地 group_members 表
        try {
          final currentUserId = await Storage.getUserId();
          if (currentUserId != null) {
            final localDb = LocalDatabaseService();
            await localDb.addGroupMember(createdGroupId, currentUserId, role: 'owner');
            logger.debug('✅ PC端：已将当前用户添加到本地group_members表: groupId=$createdGroupId, userId=$currentUserId');
          }
        } catch (e) {
          logger.error('❌ PC端：添加群组成员到本地数据库失败: $e');
        }

        // 自动选中这个群组并打开群聊界面
        setState(() {
          _selectedChatIndex = 0; // 新群组在列表顶部，索引为0
          _isCurrentChatGroup = true;
        });
        
        // 🔴 修复：等待系统消息保存到数据库
        // 服务器端通过 go 异步发送系统消息，需要等待一小段时间确保消息已保存
        logger.debug('⏳ 等待系统消息保存到数据库...');
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 加载群组消息历史（这会更新_currentChatUserId）
        await _loadMessageHistory(createdGroupId, isGroup: true);
        
        // 🔴 修复：如果加载的消息中没有系统消息，等待WebSocket消息到达后再重新加载
        bool hasSystemMessage = _messages.any((msg) => 
          msg.messageType == 'system' && 
          (msg.content.contains('创建新群组') || msg.content.contains('群组已创建'))
        );
        
        if (!hasSystemMessage) {
          logger.debug('⚠️ 未检测到系统消息，等待WebSocket消息到达...');
          // 等待WebSocket消息到达（最多等待2秒）
          int waitTime = 0;
          while (waitTime < 2000) {
            await Future.delayed(const Duration(milliseconds: 200));
            waitTime += 200;
            // 重新检查消息列表
            hasSystemMessage = _messages.any((msg) => 
              msg.messageType == 'system' && 
              (msg.content.contains('创建新群组') || msg.content.contains('群组已创建'))
            );
            if (hasSystemMessage) {
              logger.debug('✅ 系统消息已到达，重新加载消息历史');
              await _loadMessageHistory(createdGroupId, isGroup: true);
              break;
            }
          }
          
          if (!hasSystemMessage) {
            logger.debug('⚠️ 等待超时，系统消息可能还未到达，但继续显示聊天窗口');
          }
        }
        
        // 🔴 修复：在系统消息保存并加载后，刷新最近联系人列表，确保新群组显示在列表中
        // 此时系统消息已经保存到数据库，服务器返回的最近联系人列表会包含新群组
        logger.debug(
          '🔄 系统消息已保存，刷新最近联系人列表 - ID: $createdGroupId, 名称: $createdGroupName',
        );
        await _loadRecentContacts();
        
        // 刷新后，重新找到新群组在列表中的位置并更新选中索引
        final newGroupIndex = _recentContacts.indexWhere(
          (contact) => contact.isGroup && contact.groupId == createdGroupId,
        );
        if (newGroupIndex != -1) {
          setState(() {
            _selectedChatIndex = newGroupIndex;
          });
          logger.debug('✅ 已更新选中索引到新群组位置: $newGroupIndex');
        }

        logger.debug(
          '✅ 已自动切换到新创建的群组聊天窗口 - ID: $createdGroupId, 名称: $createdGroupName',
        );
        
        return; // 直接返回，不执行下面的API调用
      }

      // 如果群组没有ID，说明需要调用API创建
      logger.debug('群组没有ID，需要调用API创建');
      
      // 获取token
      final token = _token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('未登录，无法创建群组'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 调用API创建群组
      final response = await ApiService.createGroup(
        token: token,
        name: group.name,
        announcement: group.announcement,
        avatar: group.avatar, // 添加群头像参数
        memberIds: group.memberIds,
        nickname: group.nickname,
        remark: group.remark,
        doNotDisturb: group.doNotDisturb,
      );

      logger.debug('创建群组API响应: $response');

      if (response['code'] == 0) {
        // 创建成功 - 从响应中获取群组信息
        final groupData = response['data']['group'];
        final createdGroupId = groupData['id'] as int;
        final createdGroupName = groupData['name'] as String;
        final createdGroupAvatar = groupData['avatar'] as String?; // 获取群组头像
        final createdGroupRemark = group.remark; // 使用创建时输入的备注

        // 🔴 关键修复：立即将当前用户添加到本地 group_members 表
        try {
          final currentUserId = await Storage.getUserId();
          if (currentUserId != null) {
            final localDb = LocalDatabaseService();
            await localDb.addGroupMember(createdGroupId, currentUserId, role: 'owner');
            logger.debug('✅ PC端：已将当前用户添加到本地group_members表: groupId=$createdGroupId, userId=$currentUserId');
          }
        } catch (e) {
          logger.error('❌ PC端：添加群组成员到本地数据库失败: $e');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('群组"${group.name}"创建成功'),
              backgroundColor: Colors.green,
            ),
          );
        }

        // 自动选中这个群组并打开群聊界面
        setState(() {
          _selectedChatIndex = 0; // 新群组在列表顶部，索引为0
          _isCurrentChatGroup = true;
        });
        
        // 🔴 修复：等待系统消息保存到数据库
        // 服务器端通过 go 异步发送系统消息，需要等待一小段时间确保消息已保存
        logger.debug('⏳ 等待系统消息保存到数据库...');
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 加载群组消息历史（这会更新_currentChatUserId）
        await _loadMessageHistory(createdGroupId, isGroup: true);
        
        // 🔴 修复：如果加载的消息中没有系统消息，等待WebSocket消息到达后再重新加载
        bool hasSystemMessage = _messages.any((msg) => 
          msg.messageType == 'system' && 
          (msg.content.contains('创建新群组') || msg.content.contains('群组已创建'))
        );
        
        if (!hasSystemMessage) {
          logger.debug('⚠️ 未检测到系统消息，等待WebSocket消息到达...');
          // 等待WebSocket消息到达（最多等待2秒）
          int waitTime = 0;
          while (waitTime < 2000) {
            await Future.delayed(const Duration(milliseconds: 200));
            waitTime += 200;
            // 重新检查消息列表
            hasSystemMessage = _messages.any((msg) => 
              msg.messageType == 'system' && 
              (msg.content.contains('创建新群组') || msg.content.contains('群组已创建'))
            );
            if (hasSystemMessage) {
              logger.debug('✅ 系统消息已到达，重新加载消息历史');
              await _loadMessageHistory(createdGroupId, isGroup: true);
              break;
            }
          }
          
          if (!hasSystemMessage) {
            logger.debug('⚠️ 等待超时，系统消息可能还未到达，但继续显示聊天窗口');
          }
        }
        
        // 🔴 修复：在系统消息保存并加载后，刷新最近联系人列表，确保新群组显示在列表中
        // 此时系统消息已经保存到数据库，服务器返回的最近联系人列表会包含新群组
        logger.debug(
          '🔄 系统消息已保存，刷新最近联系人列表 - ID: $createdGroupId, 名称: $createdGroupName',
        );
        await _loadRecentContacts();
        
        // 刷新后，重新找到新群组在列表中的位置并更新选中索引
        final newGroupIndex = _recentContacts.indexWhere(
          (contact) => contact.isGroup && contact.groupId == createdGroupId,
        );
        if (newGroupIndex != -1) {
          setState(() {
            _selectedChatIndex = newGroupIndex;
          });
          logger.debug('✅ 已更新选中索引到新群组位置: $newGroupIndex');
        }

        logger.debug(
          '✅ 已自动切换到新创建的群组聊天窗口 - ID: $createdGroupId, 名称: $createdGroupName',
        );
      } else {
        // 创建失败
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('创建群组失败: ${response['message']}'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      logger.debug('创建群组失败: $e');
      // 提取友好的错误消息
      String errorMessage = e.toString();
      if (errorMessage.startsWith('Exception: ')) {
        errorMessage = errorMessage.substring(11); // 移除 "Exception: " 前缀
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // 显示二维码扫描器
  void _showQRCodeScanner() async {
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

        // 尝试解析二维码内        // 假设二维码格式为: youdu://user/{username} youdu://group/{groupId}
        if (result.startsWith('youdu://user/')) {
          final username = result.substring('youdu://user/'.length);
          _handleAddContactByUsername(username);
        } else if (result.startsWith('youdu://group/')) {
          final groupId = result.substring('youdu://group/'.length);
          _handleJoinGroupById(groupId);
        } else {
          // 如果不是特定格式，显示原始内
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('扫描结果: $result')));
        }
      }
    } catch (e) {
      logger.debug('扫描二维码失 $e');
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
    // 🔧 修复：安全地获取code和message，避免null值导致的错误
    final code = response['code'] ?? -1;
    final message = response['message']?.toString() ?? '添加失败';

    logger.debug('📞 [添加联系人响应] code=$code, message=$message');
    logger.debug('📞 [添加联系人响应] 完整响应: $response');

    switch (code) {
      case 0:
        // 成功发送（包括重新发送）
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('好友请求已发送')));
        // 🔧 修复：使用try-catch包裹刷新逻辑，避免刷新时的null错误
        if (_selectedContactIndex == 0) {
          try {
            _loadContacts();
          } catch (e, stackTrace) {
            logger.debug('❌ [添加联系人] 刷新联系人列表失败: $e');
            logger.debug('❌ [添加联系人] 堆栈跟踪: $stackTrace');
            // 即使刷新失败，也不影响用户体验，只记录日志
          }
        }
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
            action: SnackBarAction(
              label: '去查看',
              onPressed: () {
                // 导航到联系人申请页面
                setState(() {
                  _selectedMenuIndex = 1; // 切换到通讯录页
                  _selectedContactIndex = 1; // 切换到申请列表
                });
              },
            ),
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

  // 通过用户名添加联系人
  void _handleAddContactByUsername(String username) async {
    try {
      logger.debug('📞 [添加联系人] 开始添加: $username');
      
      final token = _token;
      if (token == null) {
        logger.debug('❌ [添加联系人] Token为空');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      logger.debug('📞 [添加联系人] 调用API...');
      final response = await ApiService.addContact(
        token: token,
        friendUsername: username,
      );

      logger.debug('✅ [添加联系人] API调用成功，准备处理响应');
      if (mounted) {
        _handleAddContactResponse(response, context);
      }
    } catch (e, stackTrace) {
      logger.debug('❌ [添加联系人] 失败');
      logger.debug('❌ [添加联系人] 错误类型: ${e.runtimeType}');
      logger.debug('❌ [添加联系人] 错误信息: $e');
      logger.debug('❌ [添加联系人] 堆栈跟踪: $stackTrace');
      
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('添加失败: $e')));
      }
    }
  }

  // 通过群组ID加入群组
  void _handleJoinGroupById(String groupId) {
    // TODO: 实现加入群组功能
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('加入群组: $groupId')));
  }

  // 显示添加联系人对话框
  void _showAddContactDialog() {
    final TextEditingController usernameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加联系人'),
        content: TextField(
          controller: usernameController,
          decoration: const InputDecoration(
            labelText: '好友用户名',
            hintText: '',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final username = usernameController.text.trim();
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);

              if (username.isEmpty) {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('请输入用户名')),
                );
                return;
              }

              navigator.pop();

              // 调用添加联系人API
              try {
                logger.debug('📞 [对话框添加联系人] 开始添加: $username');
                
                final token = _token;
                if (token == null) {
                  logger.debug('❌ [对话框添加联系人] Token为空');
                  if (mounted) {
                    scaffoldMessenger.showSnackBar(
                      const SnackBar(content: Text('未登录')),
                    );
                  }
                  return;
                }

                logger.debug('📞 [对话框添加联系人] 调用API...');
                final response = await ApiService.addContact(
                  token: token,
                  friendUsername: username,
                );

                logger.debug('✅ [对话框添加联系人] API调用成功，准备处理响应');
                if (mounted) {
                  _handleAddContactResponse(response, context);
                }
              } catch (e, stackTrace) {
                logger.debug('❌ [对话框添加联系人] 失败');
                logger.debug('❌ [对话框添加联系人] 错误类型: ${e.runtimeType}');
                logger.debug('❌ [对话框添加联系人] 错误信息: $e');
                logger.debug('❌ [对话框添加联系人] 堆栈跟踪: $stackTrace');
                
                if (mounted) {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text('添加失败: $e')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90E2),
              foregroundColor: Colors.white,
            ),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // 处理输入框文本变化，用于整体删除表情和检测@符号
  void _handleInputTextChanged(String newText) {
    if (_isCurrentChatGroup) {
      if (newText.isNotEmpty) {
        // 检测是否刚刚输入了@符号
        if (newText.endsWith('@') &&
            (newText.length == 1 || !_previousInputText.endsWith('@'))) {
          _showMentionMemberPicker();
        }
      }

      if (_showMentionPicker) {
        // 检查当前文本中是否还有@符号
        final int lastAtIndex = newText.lastIndexOf('@');
        if (lastAtIndex == -1) {
          // 没有@符号了，关闭弹窗
          _hideMentionPicker();
        } else {
          // 检查@符号后面是否还有空格（如果有空格说明已经选择完成，应该关闭弹窗）
          final textAfterAt = newText.substring(lastAtIndex);
          if (textAfterAt.contains(' ') && textAfterAt.indexOf(' ') > 1) {
            // @符号后有空格且不是紧跟着@，说明已经选择完成
            // 不关闭，因为用户可能继续输入其他内容后再次@
          }
        }
      }
    }

    // 检测是否是删除操作
    if (newText.length < _previousInputText.length) {
      int deletePos = -1;
      for (
        int i = 0;
        i < newText.length && i < _previousInputText.length;
        i++
      ) {
        if (newText[i] != _previousInputText[i]) {
          deletePos = i;
          break;
        }
      }

      if (deletePos == -1) {
        deletePos = newText.length;
      }

      final emotionPattern = RegExp(r'\[emotion:[^\]]+\]');
      final matches = emotionPattern.allMatches(_previousInputText);

      for (final match in matches) {
        final start = match.start;
        final end = match.end;

        if (deletePos >= start && deletePos <= end) {
          final correctedText =
              _previousInputText.substring(0, start) +
              _previousInputText.substring(end);

          _messageInputController.value = TextEditingValue(
            text: correctedText,
            selection: TextSelection.collapsed(offset: start),
          );

          // 更新 _previousInputText
          _previousInputText = correctedText;
          return;
        }
      }
    }

    // 更新 _previousInputText
    _previousInputText = newText;

    // 处理"正在输入"消息（仅在一对一私聊时）
    if (!_isCurrentChatGroup && _currentChatUserId != null) {
      // 取消之前的定时器
      _typingTimer?.cancel();

      if (newText.trim().isNotEmpty) {
        // 输入框不为空，发送"正在输入"消息（防抖：延迟500ms发送）
        _typingTimer = Timer(const Duration(milliseconds: 500), () {
          _wsService.sendTypingIndicator(
            receiverId: _currentChatUserId!,
            isTyping: true,
          );
        });
      } else {
        // 输入框为空，发送"停止输入"消息（立即发送，不需要防抖）
        _wsService.sendTypingIndicator(
          receiverId: _currentChatUserId!,
          isTyping: false,
        );
      }
    }
  }

  // ============ 头像更新功能 ============

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

      logger.debug('🎭 PC端收到头像更新通知 - 用户ID: $userId, 新头像: $newAvatar');

      // 1. 更新本地数据库中的头像信息
      final localDb = LocalDatabaseService();
      
      // 更新消息表中的头像
      final dbUpdatedCount = await localDb.updateUserAvatarInMessages(userId, newAvatar);
      logger.debug('🗄️ PC端消息表头像已更新 - 用户ID: $userId, 更新了 $dbUpdatedCount 条记录');
      
      // 🔴 关键修复：同时更新联系人快照表中的头像
      final snapshotUpdatedCount = await localDb.updateUserAvatarInContactSnapshots(userId, newAvatar);
      logger.debug('🗄️ PC端联系人快照头像已更新 - 用户ID: $userId, 更新了 $snapshotUpdatedCount 条快照记录');

      setState(() {
        // 2. 更新头像缓存（立即生效，用于群聊消息）
        _avatarCache[userId] = newAvatar;
        logger.debug('✅ 已更新头像缓存 - 用户ID: $userId');

        // 3. 如果是自己的头像更新，更新 _userAvatar
        if (userId == _currentUserId) {
          logger.debug('✅ 检测到自己的头像更新，更新 _userAvatar');
          _userAvatar = newAvatar;
        }

        // 4. 直接更新最近联系人列表中的头像（内存更新）
        bool updated = false;
        for (int i = 0; i < _recentContacts.length; i++) {
          if (_recentContacts[i].userId == userId && !_recentContacts[i].isGroup) {
            _recentContacts[i] = _recentContacts[i].copyWith(avatar: newAvatar);
            updated = true;
            logger.debug('✅ 已更新最近联系人列表内存中用户 $userId 的头像');
          }
        }

        // 5. 如果在群聊中，清空群组成员缓存，下次@时重新加载
        if (_groupMembers.isNotEmpty) {
          final memberExists = _groupMembers.any((m) => m.userId == userId);
          if (memberExists) {
            logger.debug('✅ 用户 $userId 在当前群组成员列表中，清空缓存');
            _groupMembers = [];
          }
        }
      });

      // 6. 重新从数据库加载会话列表（确保数据库中的头像也是最新的）
      logger.debug('🔄 重新从数据库加载会话列表，确保显示最新头像');
      await _loadRecentContacts();

      logger.debug('🎭 PC端头像更新处理完成（消息表+快照表+内存+会话列表）');
    } catch (e) {
      logger.debug('❌ PC端处理头像更新失败: $e');
    }
  }

  // 处理正在输入指示器
  void _handleTypingIndicator(dynamic data) {
    try {
      if (data == null) {
        return;
      }

      // 检查 widget 是否还在树中
      if (!mounted) {
        return;
      }

      final senderId = data['sender_id'] as int?;
      final isTyping = data['is_typing'] as bool? ?? false;

      if (senderId == null) {
        logger.debug('⚠️ 正在输入消息缺少sender_id');
        return;
      }

      // 只处理当前聊天对象的正在输入消息
      if (_currentChatUserId != senderId || _isCurrentChatGroup) {
        return;
      }

      logger.debug('⌨️ 收到正在输入指示器 - 发送者ID: $senderId, 正在输入: $isTyping');

      setState(() {
        _isOtherTyping = isTyping;
      });

      // 如果对方正在输入，设置自动隐藏定时器（3秒后自动隐藏）
      if (isTyping) {
        _otherTypingTimer?.cancel();
        _otherTypingTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _isOtherTyping = false;
            });
          }
        });
      } else {
        // 如果对方停止输入，立即隐藏
        _otherTypingTimer?.cancel();
      }
    } catch (e) {
      logger.debug('处理正在输入指示器失败: $e');
    }
  }

  // 处理群组信息更新通知
  void _handleGroupInfoUpdated(dynamic data) {
    try {
      if (data == null) {
        logger.debug('⚠️ 群组信息更新数据为空');
        return;
      }

      // 检查 widget 是否还在树中
      if (!mounted) {
        logger.debug('⚠️ Widget 已销毁，跳过群组信息更新');
        return;
      }

      final groupId = data['group_id'] as int?;
      final groupData = data['group'] as Map<String, dynamic>?;

      if (groupId == null || groupData == null) {
        logger.debug('⚠️ 群组信息更新消息缺少必要字段');
        return;
      }

      logger.debug('📢 收到群组信息更新通知 - 群组ID: $groupId, 数据: $groupData');

      setState(() {
        // 1. 更新最近联系人列表中的群组信息
        final recentIndex = _recentContacts.indexWhere(
          (contact) => contact.isGroup && contact.userId == groupId,
        );
        if (recentIndex != -1) {
          logger.debug('更新最近联系人列表中的群组信息');
          _recentContacts[recentIndex] = _recentContacts[recentIndex].copyWith(
            username: groupData['name'] as String?,
            fullName: groupData['name'] as String?,
            avatar: groupData['avatar'] as String?,
            groupName: groupData['name'] as String?,
          );
        }

        // 2. 更新群组列表中的群组信息
        final groupIndex = _groups.indexWhere((group) => group.id == groupId);
        if (groupIndex != -1) {
          logger.debug('更新群组列表中的群组信息');
          _groups[groupIndex] = _groups[groupIndex].copyWith(
            name: groupData['name'] as String?,
            announcement: groupData['announcement'] as String?,
            avatar: groupData.containsKey('avatar') ? groupData['avatar'] as String? : _groups[groupIndex].avatar,
            allMuted: groupData['all_muted'] as bool?,
            adminOnlyEditName: groupData['admin_only_edit_name'] as bool?,
            memberViewPermission: groupData['member_view_permission'] as bool?,
          );
          logger.debug(
            '✅ 群组列表已更新 - 群组ID: $groupId, avatar=${_groups[groupIndex].avatar}, memberViewPermission=${_groups[groupIndex].memberViewPermission}',
          );
        }

        // 3. 如果当前正在查看该群组，更新_selectedGroup
        if (_isCurrentChatGroup && _currentChatUserId == groupId) {
          logger.debug('当前正在查看该群组，更新选中的群组信息');
          if (_selectedGroup != null) {
            _selectedGroup = _selectedGroup!.copyWith(
              name: groupData['name'] as String?,
              announcement: groupData['announcement'] as String?,
              avatar: groupData.containsKey('avatar') ? groupData['avatar'] as String? : _selectedGroup!.avatar,
              allMuted: groupData['all_muted'] as bool?,
              adminOnlyEditName: groupData['admin_only_edit_name'] as bool?,
              memberViewPermission:
                  groupData['member_view_permission'] as bool?,
            );
            logger.debug(
              '✅ _selectedGroup 已更新，avatar=${_selectedGroup!.avatar}, memberViewPermission=${_selectedGroup!.memberViewPermission}',
            );
          }
        }
      });

    } catch (e) {
      logger.debug('处理群组信息更新失败: $e');
    }
  }

  // 处理群组昵称更新通知
  Future<void> _handleGroupNicknameUpdated(dynamic data) async {
    try {
      if (data == null) {
        logger.debug('⚠️ 群组昵称更新数据为空');
        return;
      }

      if (!mounted) {
        logger.debug('⚠️ Widget 已销毁，跳过群组昵称更新');
        return;
      }

      final groupId = data['group_id'] as int?;
      final userId = data['user_id'] as int?;
      final newNickname = data['new_nickname'] as String?;

      if (groupId == null || userId == null || newNickname == null) {
        logger.debug('⚠️ 群组昵称更新消息缺少必要字段');
        return;
      }

      logger.debug('👤 收到群组昵称更新通知 - 群组ID: $groupId, 用户ID: $userId, 新昵称: $newNickname');

      // WebSocketService已经更新了数据库，这里只需要刷新当前显示的消息
      // 如果当前正在查看该群组，需要重新加载消息以显示更新后的昵称
      if (_isCurrentChatGroup && _currentChatUserId == groupId) {
        logger.debug('当前正在查看该群组，重新加载消息');
        setState(() {
          // 触发消息列表重建，从数据库重新加载消息（已包含新昵称）
          _messages.clear();
          _messagesError = null;
        });
        await _loadMessageHistory(groupId, isGroup: true);
      }

      logger.debug('✅ 群组昵称更新处理完成');
    } catch (e) {
      logger.debug('❌ 处理群组昵称更新失败: $e');
    }
  }

  // ============ @功能相关方法 ============

  // 加载群组成员
  Future<void> _loadGroupMembers() async {
    if (!_isCurrentChatGroup || _currentChatUserId == null) {
      return;
    }

    try {
      final token = _token;
      if (token == null) return;

      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: _currentChatUserId!,
      );

      if (response['code'] == 0) {
        final data = response['data'];
        final members = data['members'] as List<dynamic>?;
        final memberRole = data['member_role'] as String?; // 获取当前用户的角色

        if (members != null) {
          setState(() {
            // 保存当前用户的角色
            _currentUserGroupRole = memberRole;
            logger.debug('当前用户在群组中的角色: $_currentUserGroupRole');

            _groupMembers = members
                .where((m) => m['user_id'] != _currentUserId) // 排除自己
                .map((m) {
                  final fullName = m['full_name'] as String?;
                  final username = m['username'] as String?;
                  return GroupMemberForMention(
                    userId: m['user_id'] as int,
                    fullName: (fullName != null && fullName.isNotEmpty)
                        ? fullName
                        : 'Unknown',
                    username: (username != null && username.isNotEmpty)
                        ? username
                        : 'unknown',
                  );
                })
                .toList();
          });
          logger.debug('加载群组成员成功: ${_groupMembers.length}人');
        }
      }
    } catch (e) {
      logger.debug('加载群组成员失败: $e');
    }
  }

  // 显示成员选择
  void _showMentionMemberPicker() async {
    // 如果成员列表为空，先加载
    if (_groupMembers.isEmpty) {
      await _loadGroupMembers();
    }

    if (_groupMembers.isEmpty) {
      logger.debug('⚠️ 群组成员列表为空，无法显示成员选择');
      return;
    }

    // 移除已存在的浮层
    _hideMentionPicker();

    // 获取输入框的渲染对象
    final RenderBox? renderBox =
        _messageInputFocusNode.context?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      logger.debug('⚠️ 无法获取输入框位置');
      return;
    }

    // 获取输入框在屏幕上的位置
    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    // 计算弹窗位置：在输入框上方，左侧对齐
    final double left = position.dx + 20; // 距离左边一点距
    final double bottom =
        MediaQuery.of(context).size.height - position.dy + 10; // 在输入框上方10px

    // 创建浮层
    _mentionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        bottom: bottom,
        child: Material(
          color: Colors.transparent,
          child: MentionMemberPicker(
            members: _groupMembers,
            onSelect: _onMemberSelected,
            currentUserRole: _currentUserGroupRole,
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_mentionOverlay!);
    setState(() {
      _showMentionPicker = true;
    });
  }

  // 隐藏成员选择
  void _hideMentionPicker() {
    if (_mentionOverlay != null) {
      _mentionOverlay!.remove();
      _mentionOverlay = null;
    }
    setState(() {
      _showMentionPicker = false;
    });
  }

  // 选择成员后的回调
  void _onMemberSelected(String mentionText, List<int> mentionedUserIds) {
    // 移除输入框中末尾的@符号
    String currentText = _messageInputController.text;
    if (currentText.endsWith('@')) {
      currentText = currentText.substring(0, currentText.length - 1);
    }

    // 插入@文本
    final newText = '$currentText$mentionText ';
    _messageInputController.text = newText;
    _messageInputController.selection = TextSelection.fromPosition(
      TextPosition(offset: newText.length),
    );

    // 保存被@的用户ID和文
    setState(() {
      _mentionedUserIds = mentionedUserIds;
      _mentionText = mentionText;
    });

    // 更新 _previousInputText
    _previousInputText = newText;

    // 隐藏选择
    _hideMentionPicker();

    // 让输入框重新获得焦点
    _messageInputFocusNode.requestFocus();

    logger.debug('选择了成 $mentionText, IDs: $mentionedUserIds');
  }

  // ============ @功能相关方法结束 ============
  // 显示表情选择器（无遮罩，定位在按钮附近）
  void _showEmojiPicker(BuildContext context) {
    // 获取所有表情图
    final List<String> emotions = [
      '1_Smile.png',
      '2_Grimace.png',
      '3_Drool.png',
      '4_Scowl.png',
      '5_CoolGuy.png',
      '6_Sob.png',
      '7_Shy.png',
      '8_Silent.png',
      '9_Sleep.png',
      '10_Cry.png',
      '11_Awkward.png',
      '12_Angry.png',
      '13_Tongue.png',
      '14_Grin.png',
      '15_Astonish.png',
      '16_Frown.png',
      '18_Shame.png',
      '19_Scream.png',
      '20_Puke.png',
      '21_Chuckle.png',
      '23_Slight.png',
      '24_Smug.png',
      '25_Hunger.png',
      '26_Drowsy.png',
      '28_Sweat.png',
      '29_Laugh.png',
      '31_Determined.png',
      '32_Scold.png',
      '33_Shocked.png',
      '34_Shhh.png',
      '37_Dizzy.png',
      '37_Toasted.png',
      '40_Bye.png',
      '42_NosePick.png',
      '43_Clap.png',
      '44_Embarrass.png',
      '45_Trick.png',
      '48_Yawn.png',
      '49_Pooh-pooh.png',
      '50_Shrunken.png',
      '51_TearingUp.png',
      '52_Sly.png',
      '53_Kiss.png',
      '55_Whimper.png',
      '57_Watermelon.png',
      '58_Beer.png',
      '59_Basketball.png',
      '60_Pingpong.png',
      '61_Coffee.png',
      '63_Pig.png',
      '64_Rose.png',
      '65_Wilt.png',
      '66_Lips.png',
      '67_Heart.png',
      '68_BrokenHeart.png',
      '69_Cake.png',
      '70_Lightning.png',
      '71_Bomb.png',
      '73_Football.png',
      '74_Ladybug.png',
      '76_Moon.png',
      '77_Sun.png',
      '78_Gift.png',
      '79_Hug.png',
      '80_ThumbsUp.png',
      '81_ThumbsDown.png',
      '82_Shake.png',
      '83_Peace.png',
      '84_Salute.png',
      '85_Beckon.png',
      '86_Fist.png',
      '87_Poor.png',
      '88_LoveYou.png',
      '89_NO.png',
      '90_OK.png',
      '106_Happy.png',
      '107_Awesome.png',
      '108_Peep.png',
      '109_Doge.png',
      '110_Doge2.png',
      '111_WaitAndSee.png',
      '112_Salute.png',
      '113_RaiseHands.png',
      '114_Coke.png',
      '115_MilkTea.png',
      '116_Drink Cola.png',
      '117_Yeah.png',
      '118_PushGlasses.png',
      '119_PinkCake.png',
      '120_WeWillSee.png',
      '121_Puzzled.png',
      '122_Flower.png',
      '123_RedPacket.png',
      '124_FingerHeart.png',
      '125_Puzzling.png',
      '126_Snort.png',
      '127_Speechless.png',
      '128_Oh.png',
      '132_Celebrating.png',
      '133_Please.png',
      '134_Firecracker.png',
      '135_Roger.png',
      '136_Respect.png',
      '138_Dark Circles.png',
      '139_CrazyBusy.png',
      '140_Jealous.png',
      '141_Baldness.png',
      '142_Cheers.png',
      '143_Shoot.png',
      '144_Congratulations.png',
      '145_Smugshrug.png',
      '147_Broadcast.png',
      '149_FacePalm.png',
      '150_LaughAndCry.png',
    ];

    // 获取按钮的位
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final offset = renderBox.localToGlobal(Offset.zero);

    // 创建 OverlayEntry
    late OverlayEntry overlayEntry;
    overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点击外部关闭弹窗
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                overlayEntry.remove();
              },
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
          ),
          // 表情选择器弹
          Positioned(
            left: offset.dx,
            top: offset.dy - 250, // 显示在按钮上
            child: GestureDetector(
              onTap: () {
                // 阻止事件冒泡到外层的 GestureDetector
              },
              behavior: HitTestBehavior.opaque,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 320, // 更小的宽
                  height: 240, // 更小的高
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5E5E5)),
                  ),
                  child: Column(
                    children: [
                      // 标题
                      Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Color(0xFFE5E5E5)),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '选择表情',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF333333),
                              ),
                            ),
                            InkWell(
                              onTap: () {
                                overlayEntry.remove();
                              },
                              child: const Icon(
                                Icons.close,
                                size: 18,
                                color: Color(0xFF666666),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 表情网格（可滚动
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 8, // 每行8个表
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                  childAspectRatio: 1,
                                ),
                            itemCount: emotions.length,
                            itemBuilder: (context, index) {
                              final emotionFile = emotions[index];
                              return InkWell(
                                onTap: () {
                                  // 选择表情后，插入到输入框
                                  final currentText =
                                      _messageInputController.text;
                                  var selection =
                                      _messageInputController.selection;

                                  // 如果 selection 无效（例如输入框没有焦点），设置为文本末尾
                                  if (!selection.isValid ||
                                      selection.start < 0) {
                                    selection = TextSelection.collapsed(
                                      offset: currentText.length,
                                    );
                                  }

                                  // 构建表情标记（使用[emotion:filename]格式
                                  final emotionTag = '[emotion:$emotionFile]';

                                  // 在当前光标位置插入表情标
                                  final newText =
                                      currentText.substring(
                                        0,
                                        selection.start,
                                      ) +
                                      emotionTag +
                                      currentText.substring(selection.end);

                                  _messageInputController
                                      .value = TextEditingValue(
                                    text: newText,
                                    selection: TextSelection.collapsed(
                                      offset:
                                          selection.start + emotionTag.length,
                                    ),
                                  );

                                  // 更新 _previousInputText，避免触发删除检
                                  _previousInputText = newText;

                                  // 让输入框获得焦点
                                  _messageInputFocusNode.requestFocus();

                                  overlayEntry.remove();
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: const Color(0xFFE5E5E5),
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: Image.asset(
                                    'assets/消息/emotion/$emotionFile',
                                    fit: BoxFit.contain,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Icon(
                                        Icons.emoji_emotions,
                                        size: 16,
                                        color: Color(0xFFCCCCCC),
                                      );
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // 添加Overlay
    Overlay.of(context).insert(overlayEntry);
  }

  // 获取状态对应的颜色
  // 格式化最近联系人的时间显
  String _formatMessageTime(String timeString) {
    try {
      // 尝试解析为DateTime，如果成功说明是ISO格式
      final messageTime = DateTime.parse(timeString);
      final now = DateTime.now();

      // 计算时间
      final difference = now.difference(messageTime);

      // 如果是今天的消息
      if (difference.inDays == 0 &&
          messageTime.year == now.year &&
          messageTime.month == now.month &&
          messageTime.day == now.day) {
        return '今天';
      }

      // 如果是昨天的消息
      final yesterday = now.subtract(const Duration(days: 1));
      if (messageTime.year == yesterday.year &&
          messageTime.month == yesterday.month &&
          messageTime.day == yesterday.day) {
        return '昨天';
      }

      // 其他日期，显月份+日期"格式
      return '${messageTime.month}月${messageTime.day}日';
    } catch (e) {
      // 如果解析失败，说明已经是格式化后的字符串（如"昨天"10-28"等）
      // 直接返回原始字符
      return timeString;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'online':
        return const Color(0xFF52C41A); // 绿色
      case 'busy':
        return const Color(0xFFFF4D4F); // 红色
      case 'away':
        return const Color(0xFFFAAD14); // 黄色
      case 'offline':
        return const Color(0xFFBFBFBF); // 灰色
      default:
        return const Color(0xFF52C41A); // 默认绿色
    }
  }

  @override
  Widget build(BuildContext context) {
    // 使用Listener监听鼠标和键盘事件，记录用户活动
    return Listener(
      onPointerDown: (_) => _recordUserActivity(), // 鼠标点击
      onPointerMove: (_) => _recordUserActivity(), // 鼠标移动
      child: Stack(
        children: [
          // 主页面内容
          FocusScope(
            onKey: (node, event) {
              // 键盘按下时记录活动
              _recordUserActivity();
              return KeyEventResult.ignored;
            },
            child: Scaffold(
              backgroundColor: const Color(0xFFF5F5F5),
              body: Row(
                children: [
                  // 左侧导航菜单
                  _buildLeftMenu(),
                  // 根据选中的菜单显示不同内
                  if (_selectedMenuIndex == 3)
                    // 待办页面占据全部剩余空间
                    const Expanded(child: TodoPage())
                  else if (_selectedMenuIndex == 2)
                    // 资讯页面占据全部剩余空间
                    _buildNewsPage()
                  else ...[
                    // 中间列表（根据选中的菜单显示不同内容）
                    _selectedMenuIndex == 1
                        ? _buildContactList()
                        : _buildConversationList(),
                    // 右侧内容区域（根据选中的菜单显示不同内容）
                    _selectedMenuIndex == 1
                        ? _buildContactDetailArea()
                        : _buildChatWindow(),
                  ],
                ],
              ),
            ),
          ),

          // 通话悬浮按钮
          if (_showCallFloatingButton) _buildCallFloatingButton(),
        ],
      ),
    );
  }

  // 通话悬浮按钮
  Widget _buildCallFloatingButton() {
    // 初始化默认位置（右侧，距离底部三分之一屏幕高度）
    if (_floatingButtonX == 0 && _floatingButtonY == 0) {
      final screenHeight = MediaQuery.of(context).size.height;
      _floatingButtonX = 20; // 距离右边20px
      _floatingButtonY = screenHeight / 3; // 距离底部三分之一屏幕高度
    }

    return Positioned(
      right: _floatingButtonX,
      bottom: _floatingButtonY,
      child: GestureDetector(
        onTap: () async {
          // 点击悬浮按钮，重新打开通话页面
          logger.debug('📱 点击悬浮按钮，重新打开通话页面');

          // 🔴 空安全检查
          if (_agoraService == null) {
            logger.debug('⚠️ AgoraService 为空，无法恢复通话');
            return;
          }

          logger.debug('📱 检查通话类型:');
          logger.debug(
            '  - minimizedIsGroupCall: ${_agoraService!.minimizedIsGroupCall}',
          );
          logger.debug(
            '  - minimizedGroupId: ${_agoraService!.minimizedGroupId}',
          );
          logger.debug(
            '  - currentGroupCallUserIds: ${_agoraService!.currentGroupCallUserIds}',
          );
          logger.debug(
            '  - currentGroupCallDisplayNames: ${_agoraService!.currentGroupCallDisplayNames}',
          );

          // 🔴 修复：判断是群组通话还是一对一通话，以及通话类型（语音/视频）
          final isGroupCall = _agoraService!.minimizedIsGroupCall;
          final callType = _agoraService!.minimizedCallType ?? CallType.voice;

          logger.debug('📱 准备恢复通话:');
          logger.debug('  - isGroupCall: $isGroupCall');
          logger.debug('  - callType: $callType');

          dynamic result;
          if (isGroupCall) {
            // 群组通话：根据通话类型打开对应页面
            logger.debug('📱 恢复群组通话');
            setState(() {
              _isShowingVoiceCallDialog = true;
            });
            
            if (callType == CallType.video) {
              // 群组视频通话
              logger.debug('📱 打开群组视频通话页面');
              result = await showDialog(
                context: context,
                barrierDismissible: true,
                builder: (context) => GroupVideoCallPage(
                  targetUserId: _currentCallUserId ?? 0,
                  targetDisplayName: _currentCallDisplayName ?? '',
                  isIncoming: false,
                  groupCallUserIds: _agoraService!.currentGroupCallUserIds,
                  groupCallDisplayNames:
                      _agoraService!.currentGroupCallDisplayNames,
                  currentUserId: _currentUserId,
                  groupId: _agoraService!.minimizedGroupId,
                ),
              ).then((value) {
                setState(() {
                  _isShowingVoiceCallDialog = false;
                });
                if (value is Map && value['callEnded'] == true) {
                  return {
                    'callEnded': true,
                    'callDuration': value['callDuration'],
                  };
                }
                if (value is Map && value['callRejected'] == true) {
                  return {'callRejected': true};
                }
                if (value is Map && value['callCancelled'] == true) {
                  return {'callCancelled': true};
                }
                if (value == null ||
                    (value is Map && value['showFloatingButton'] != true)) {
                  return {'showFloatingButton': true};
                }
                return value;
              });
            } else {
              // 群组语音通话
              logger.debug('📱 打开群组语音通话页面');
              result = await showDialog(
                context: context,
                barrierDismissible: true,
                builder: (context) => VoiceCallPage(
                  targetUserId: _currentCallUserId ?? 0,
                  targetDisplayName: _currentCallDisplayName ?? '',
                  isIncoming: false,
                  callType: CallType.voice,
                  groupCallUserIds: _agoraService!.currentGroupCallUserIds,
                  groupCallDisplayNames:
                      _agoraService!.currentGroupCallDisplayNames,
                  currentUserId: _currentUserId,
                  groupId: _agoraService!.minimizedGroupId,
                ),
              ).then((value) {
                setState(() {
                  _isShowingVoiceCallDialog = false;
                });
                if (value is Map && value['callEnded'] == true) {
                  return {
                    'callEnded': true,
                    'callDuration': value['callDuration'],
                  };
                }
                if (value is Map && value['callRejected'] == true) {
                  return {'callRejected': true};
                }
                if (value is Map && value['callCancelled'] == true) {
                  return {'callCancelled': true};
                }
                if (value == null ||
                    (value is Map && value['showFloatingButton'] != true)) {
                  return {'showFloatingButton': true};
                }
                return value;
              });
            }
          } else {
            // 一对一通话：打开 VoiceCallPage
            logger.debug('📱 恢复一对一通话');
            setState(() {
              _isShowingVoiceCallDialog = true;
            });
            result =
                await showDialog(
                  context: context,
                  barrierDismissible: true, // 允许点击外部区域关闭
                  builder: (context) => VoiceCallPage(
                    targetUserId: _currentCallUserId ?? 0,
                    targetDisplayName: _currentCallDisplayName ?? '',
                    isIncoming: false,
                    callType: _currentCallType ?? CallType.voice,
                    currentUserId: _currentUserId, // 🔴 修复：传递当前用户ID
                  ),
                ).then((value) {
                  // 清除标志：语音通话对话框已关闭
                  setState(() {
                    _isShowingVoiceCallDialog = false;
                  });
                  // 如果通话已结束，不显示悬浮按钮
                  if (value is Map && value['callEnded'] == true) {
                    return {
                      'callEnded': true,
                      'callDuration': value['callDuration'],
                    };
                  }
                  // 如果通话被拒绝，返回拒绝状态
                  if (value is Map && value['callRejected'] == true) {
                    return {'callRejected': true};
                  }
                  // 如果通话被取消，返回取消状态
                  if (value is Map && value['callCancelled'] == true) {
                    return {'callCancelled': true};
                  }
                  // 当对话框被关闭时（无论是通过点击外部区域还是其他方式），
                  // 如果通话还在进行中，返回结果要求显示悬浮按钮
                  if (value == null ||
                      (value is Map && value['showFloatingButton'] != true)) {
                    // 如果 VoiceCallPage 没有返回 showFloatingButton，说明可能是点击外部区域关闭的
                    // 此时应该显示悬浮按钮（最小化）
                    return {'showFloatingButton': true};
                  }
                  return value;
                });
          }

          // 如果返回结果要求显示悬浮按钮
          if (result is Map && result['showFloatingButton'] == true) {
            setState(() {
              _showCallFloatingButton = true;
            });
          } else {
            // 通话正常结束，隐藏悬浮按钮
            setState(() {
              _showCallFloatingButton = false;
            });

            // 🔴 修复：移除重复的消息发送，消息已在 onCallEnded 回调中统一发送
            // 通话结束消息会在 onCallEnded 回调中发送，这里只需处理状态
            // if (result is Map && result['callEnded'] == true) {
            //   final callDuration = result['callDuration'] as int? ?? 0;
            //   await _sendCallEndedMessage(
            //     _currentCallUserId ?? 0,
            //     callDuration,
            //   );
            // }

            // 如果通话被拒绝，发送通话拒绝消息（发起方收到拒绝通知，显示"对方已拒绝"）
            if (result is Map && result['callRejected'] == true) {
              await _sendCallRejectedMessage(
                _currentCallUserId ?? 0,
                isRejecter: false,
              );
            }
            // 如果通话被取消，发送通话取消消息（发起方取消，显示"已取消"）
            else if (result is Map && result['callCancelled'] == true) {
              await _sendCallCancelledMessage(
                _currentCallUserId ?? 0,
                isCaller: true,
              );
            }
          }
        },
        onPanUpdate: (details) {
          // 拖动时更新按钮位置
          setState(() {
            // 从右边和底部计算，所以需要减去拖动的偏移量
            _floatingButtonX -= details.delta.dx;
            _floatingButtonY -= details.delta.dy;

            // 获取屏幕尺寸
            final screenSize = MediaQuery.of(context).size;
            const buttonSize = 60.0;

            // 限制按钮不超出屏幕边界
            // X轴：从右边算起，最小0（贴右边），最大是屏幕宽度减去按钮宽度（贴左边）
            if (_floatingButtonX < 0) _floatingButtonX = 0;
            if (_floatingButtonX > screenSize.width - buttonSize) {
              _floatingButtonX = screenSize.width - buttonSize;
            }

            // Y轴：从下边算起，最小0（贴底边），最大是屏幕高度减去按钮高度（贴顶边）
            if (_floatingButtonY < 0) _floatingButtonY = 0;
            if (_floatingButtonY > screenSize.height - buttonSize) {
              _floatingButtonY = screenSize.height - buttonSize;
            }
          });
        },
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: const Color(0xFF4CAF50),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            _currentCallType == CallType.voice
                ? Icons.phone_in_talk
                : Icons.videocam,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }

  // 左侧导航菜单
  Widget _buildLeftMenu() {
    return Container(
      width: 64,
      color: const Color(0xFF2C2C2C),
      child: Column(
        children: [
          // Logo - 用户头像
          Container(
            height: 64,
            alignment: Alignment.center,
            child: InkWell(
              onTap: () {
                // 显示个人信息菜单（从API获取数据
                if (_token != null && _token!.isNotEmpty) {
                  UserProfileMenuWithAPI.show(
                    context,
                    token: _token!, // 使用内存中的token，避免被其他窗口覆盖
                    offset: const Offset(72, 8),
                    onStatusChanged: (newStatus) {
                      // 状态更新后刷新UI
                      setState(() {
                        _userStatus = newStatus;
                      });
                    },
                    onProfileUpdated: () async {
                      // 个人资料更新后重新加载用户信息
                      await _loadUserInfo();
                      
                      // 如果当前正在查看自己的详情页面，也需要更新 _selectedPerson
                      if (_selectedPerson != null && 
                          _selectedPerson!['id'] == _currentUserId) {
                        // 重新获取用户信息并更新 _selectedPerson
                        final token = _token;
                        if (token != null && token.isNotEmpty) {
                          try {
                            final response = await ApiService.getUserProfile(token: token);
                            if (response['code'] == 0 && response['data'] != null) {
                              final userData = response['data']['user'];
                              final user = UserModel.fromJson(userData);
                              
                              setState(() {
                                // 🔴 修复：优先使用昵称生成头像文字
                                final nameForAvatar = user.fullName ?? user.username;
                                _selectedPerson = {
                                  'id': user.id,
                                  'username': user.username,
                                  'name': user.fullName ?? user.username,
                                  'avatar': nameForAvatar.length >= 2 
                                      ? nameForAvatar.substring(nameForAvatar.length - 2) 
                                      : nameForAvatar,
                                  'avatarUrl': user.avatar,
                                  'status': user.status,
                                  'work_signature': user.workSignature,
                                  'phone': user.phone,
                                  'email': user.email,
                                  'department': user.department,
                                  'position': user.position,
                                };
                              });
                            }
                          } catch (e) {
                            logger.debug('更新个人详情页失败: $e');
                          }
                        }
                      }
                    },
                    onFileAssistantTap: () async {
                      // 确保文件传输助手在最近联系人列表中
                      await _ensureFileAssistantInRecentContacts();
                      
                      // 打开文件传输助手
                      setState(() {
                        _selectedMenuIndex = 0; // 切换到消息页
                        _selectedChatIndex = -1; // 特殊索引表示文件助手
                        _currentChatUserId = 0; // 使用0表示文件助手
                        _isCurrentChatGroup = false;
                        // 清空消息引用
                        _quotedMessage = null;
                      });
                      // 加载文件助手消息
                      _loadFileAssistantMessages();
                    },
                  );
                }
              },
              child: Stack(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A90E2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: _isLoadingUserInfo
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : (_userAvatar != null && _userAvatar!.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    _userAvatar!,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Text(
                                        _userDisplayName.isNotEmpty
                                            ? (_userDisplayName.length >= 2
                                                  ? _userDisplayName.substring(
                                                      _userDisplayName.length -
                                                          2,
                                                    )
                                                  : _userDisplayName)
                                            : '?',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      );
                                    },
                                  ),
                                )
                              : Text(
                                  _userDisplayName.isNotEmpty
                                      ? (_userDisplayName.length >= 2
                                            ? _userDisplayName.substring(
                                                _userDisplayName.length - 2,
                                              )
                                            : _userDisplayName)
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                )),
                  ),
                  // 在线状态指示器
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _getStatusColor(_userStatus),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF2C2C2C),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 菜单
          _buildMenuItem(
            index: 0,
            icon: Icons.message,
            label: AppLocalizations.of(context).translate('chat'),
          ),
          _buildMenuItem(
            index: 1,
            icon: Icons.contacts,
            label: AppLocalizations.of(context).translate('contacts'),
          ),
          _buildMenuItem(
            index: 2,
            icon: Icons.article,
            label: AppLocalizations.of(context).translate('news'),
          ),
          _buildMenuItem(
            index: 3,
            icon: Icons.check_box,
            label: AppLocalizations.of(context).translate('todo'),
          ),
          const Spacer(),
          // 底部用户设置
          _buildMenuItem(
            index: 4,
            icon: Icons.settings,
            label: AppLocalizations.of(context).translate('settings'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildMenuItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _selectedMenuIndex == index;

    // 计算通讯录未处理数量总和（新联系人 + 群通知）
    int pendingCount = 0;
    if (index == 1) {
      // 新联系人未处理数量
      final newContactPendingCount = _contacts.where((c) => c.isPendingForUser(_currentUserId)).length;
      // 群通知未处理数量
      final groupNotificationPendingCount = _pendingGroupMembers.length;
      // 总和
      pendingCount = newContactPendingCount + groupNotificationPendingCount;
    }

    return InkWell(
      onTap: () {
        // 如果点击的是设置按钮（index 4），显示设置对话
        if (index == 4) {
          SettingsDialog.show(
            context,
            onIdleSettingsChanged: () {
              // 当空闲设置变更时，重新初始化自动离线定时
              _initAutoOfflineTimer();
            },
          );
          return;
        }

        // 如果点击的是资讯按钮（index 2），延迟创建 WebView
        if (index == 2 && _tabs.isEmpty) {
          logger.debug('📰 首次打开资讯页面，创建 WebView 标签页');
          _addNewTab('https://mil.ifeng.com/');
        }

        // 如果切换到通讯录（index 1），无条件重新加载联系人和群通知列表（不使用缓存）
        // 注意：这是PC端专用逻辑，APP端使用mobile_home_page.dart
        if (index == 1) {
          logger.debug('🔄 [PC端] 切换到通讯录，无缓存策略 - 重新加载所有数据');
          // 无条件重新加载联系人列表，确保数据最新
          if (!_isLoadingContacts) {
            _loadContacts();
          }
          // 无条件重新加载群通知列表，确保数据最新
          if (!_isLoadingPendingMembers) {
            _loadPendingGroupMembers();
          }
        }

        setState(() {
          _selectedMenuIndex = index;
          // 离开通讯录页面时，清除选中的群组和人员
          if (index != 1) {
            _selectedGroup = null;
            _selectedPerson = null;
          }
        });
      },
      child: Container(
        width: 64,
        height: 64,
        color: isSelected ? const Color(0xFF3C3C3C) : Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 使用 Stack 包裹图标，以便在右上角显示红色气泡
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  color: isSelected
                      ? const Color(0xFF4A90E2)
                      : const Color(0xFF999999),
                  size: 24,
                ),
                // 红色气泡（显示未处理数量总和）
                if (pendingCount > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      height: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4D4F),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        pendingCount > 99 ? '99+' : '$pendingCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFF4A90E2)
                    : const Color(0xFF999999),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 中间会话列表
  Widget _buildConversationList() {
    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E5E5), width: 1)),
      ),
      child: Column(
        children: [
          // 搜索框
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: '搜索联系人、会话',
                        hintStyle: TextStyle(
                          color: Color(0xFFCCCCCC),
                          fontSize: 14,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Color(0xFF999999),
                          size: 20,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add, color: Color(0xFF666666)),
                  offset: const Offset(0, 40),
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
                          Text('添加群组', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
                    // 移动端显示扫一扫选项
                    if (Platform.isAndroid || Platform.isIOS)
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
                      _showAddContactDialog();
                    } else if (value == 'create_group') {
                      _showCreateGroupDialog(autoSelectCurrentChat: false);
                    } else if (value == 'scan_qrcode') {
                      _showQRCodeScanner();
                    }
                  },
                ),
              ],
            ),
          ),
          // 会话列表
          Expanded(
            child: _buildConversationListContent(),
          ),
        ],
      ),
    );
  }

  // 会话列表内容
  Widget _buildConversationListContent() {
    // 如果搜索框不为空，显示搜索结果
    if (_searchText.isNotEmpty) {
      // 正在搜索
      if (_isSearching) {
        return const Center(child: CircularProgressIndicator());
      }

      // 搜索出错
      if (_searchError != null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: Color(0xFFCCCCCC),
              ),
              const SizedBox(height: 16),
              Text(
                _searchError!,
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _searchContacts(_searchText),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90E2),
                  foregroundColor: Colors.white,
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        );
      }

      // 搜索结果为空
      if (_searchResults.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.search_off, size: 48, color: Color(0xFFCCCCCC)),
              const SizedBox(height: 16),
              Text(
                '搜索 "$_searchText"',
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
              const SizedBox(height: 8),
              const Text(
                '暂无搜索结果',
                style: TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
              ),
            ],
          ),
        );
      }

      // 显示搜索结果
      return ListView.builder(
        itemCount: _searchResults.length,
        itemBuilder: (context, index) {
          return _buildRecentContactItem(_searchResults[index], index);
        },
      );
    }

    // 搜索框为空，显示最近联系人列表
    if (_isLoadingRecentContacts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_recentContactsError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 16),
            Text(
              _recentContactsError!,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadRecentContacts,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 首次同步数据时显示加载状态
    if (_isSyncingData) {
      return Center(
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
      );
    }

    if (_recentContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.message_outlined,
              size: 48,
              color: Color(0xFFCCCCCC),
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无最近会话',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 8),
            const Text(
              '开始与好友或群组聊天',
              style: TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
            ),
          ],
        ),
      );
    }

    // 对会话列表按最后消息时间排序（最新的在前面）
    final sortedContacts = List<RecentContactModel>.from(_recentContacts);
    sortedContacts.sort((a, b) {
      final aTime = DateTime.tryParse(a.lastMessageTime ?? '') ?? DateTime(1970);
      final bTime = DateTime.tryParse(b.lastMessageTime ?? '') ?? DateTime(1970);
      return bTime.compareTo(aTime); // 降序：最新的在前
    });

    // 🔍 调试：打印排序后的前5个会话
    logger.debug('📊 [PC端排序] 排序后的会话列表（前${sortedContacts.length > 5 ? 5 : sortedContacts.length}个）:');
    for (int i = 0; i < sortedContacts.length && i < 5; i++) {
      final contact = sortedContacts[i];
      logger.debug('  ${i + 1}. ${contact.isGroup ? "[群组]" : "[私聊]"} ${contact.displayName} - 最后消息时间: ${contact.lastMessageTime}');
    }

    return ListView.builder(
      itemCount: sortedContacts.length,
      itemBuilder: (context, index) {
        return _buildRecentContactItem(sortedContacts[index], index);
      },
    );
  }

  // 最近联系人
  Widget _buildRecentContactItem(RecentContactModel contact, int index) {
    final isGroup = contact.isGroup; // 判断是否为群
    // 生成联系人唯一标识
    final contactKey = Storage.generateContactKey(
      isGroup: contact.isGroup,
      id: contact.isGroup
          ? (contact.groupId ?? contact.userId)
          : contact.userId,
    );
    // 🔧 修复：使用唯一标识判断是否选中，而不是索引
    final isSelected = _selectedChatKey == contactKey;

    return GestureDetector(
      // 右键点击事件
      onSecondaryTapDown: (details) {
        _showContactContextMenu(
          context,
          details.globalPosition,
          contact,
          contactKey,
        );
      },
      child: InkWell(
        onTap: () async {
          // 保存未读消息状态（在清除UI之前）
          final hasUnreadMessages = contact.unreadCount > 0;
          final contactId = _resolveChatId(contact);

          setState(() {
            _selectedChatIndex = index; // 保留用于兼容
            _selectedChatKey = contactKey; // 🔧 修复：使用唯一标识
            _isCurrentChatGroup = contact.isGroup; // 设置当前聊天类型
            _isOtherTyping = false; // 切换聊天对象时清除"对方正在输入"状态

            // 如果联系人有未读消息，立即清除UI上的未读计数（不显示红色气泡）
            if (hasUnreadMessages) {
              // 🔧 修复：在原始列表中查找并更新
              final originalIndex = _recentContacts.indexWhere((c) {
                final cKey = Storage.generateContactKey(
                  isGroup: c.isGroup,
                  id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
                );
                return cKey == contactKey;
              });
              
              if (originalIndex != -1) {
                _recentContacts[originalIndex] = _recentContacts[originalIndex].copyWith(
                  unreadCount: 0,
                  hasMentionedMe: false, // 清除@我的标志
                );
              }

              // 将该联系人添加到已读集合中
              _markedAsReadContacts.add(contactKey);

              logger.debug(
                '📧 点击联系人，已清除UI上的未读计数（原未读数：${contact.unreadCount}条）',
              );
              logger.debug('🔧 修复：已将 $contactKey 添加到已读集合');
            }
          });

          // 🔧 修复：如果有未读消息，立即调用服务器API标记为已读
          if (hasUnreadMessages) {
            logger.debug('📧 点击联系人，立即调用服务器API标记为已读');
            if (contact.isGroup) {
              _markGroupMessagesAsRead(contactId);
            } else {
              _markMessagesAsRead(contactId);
            }
          }

          // 如果是群组聊天，加载群组详细信息（包括群公告）
          final groupId = _resolveGroupId(contact);
          if (groupId != null) {
            await _loadGroupDetail(groupId);
          }

          // 加载该联系人或群组的消息历史
          // 检查是否是文件传输助手
          if (contact.isFileAssistant || contactId == 0) {
            logger.debug('📂 检测到文件传输助手，调用专门的加载方法');
            _loadFileAssistantMessages();
          } else {
            _loadMessageHistory(contactId, isGroup: contact.isGroup);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: isSelected ? const Color(0xFFF5F5F5) : Colors.white,
          child: Row(
            children: [
              // 头像（带未读数量气泡和状态指示器
              Stack(
                children: [
                  // 🔴 文件传输助手：绿色文件夹图标
                  contact.isFileAssistant
                      ? Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFF07C160), // 微信绿色
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(
                            Icons.folder_open,
                            color: Colors.white,
                            size: 24,
                          ),
                        )
                      : Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: (contact.avatar != null && contact.avatar!.isNotEmpty)
                                ? Colors.transparent // 有头像时背景透明
                                : isGroup
                                    ? const Color(0xFF52C41A) // 群组使用绿色
                                    : const Color(0xFF4A90E2), // 个人使用蓝色
                            borderRadius: BorderRadius.circular(4),
                            // 有头像时显示头像图片（群组和个人都支持）
                            image: (contact.avatar != null && contact.avatar!.isNotEmpty)
                                ? DecorationImage(
                                    image: NetworkImage(contact.avatar!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: (contact.avatar != null && contact.avatar!.isNotEmpty)
                              ? null // 有头像时不显示任何子组件
                              : isGroup
                                  ? const Icon(
                                      Icons.people, // 群组默认图标
                                      color: Colors.white,
                                      size: 24,
                                    )
                                  : Text(
                                      contact.avatarText,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                        ),
                  // 状态指示器（右下角 仅对个人对话显示，文件传输助手除外）
                  if (!isGroup && !contact.isFileAssistant)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _getStatusColor(contact.status),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFFF5F5F5)
                                : Colors.white,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  // 未读数量气泡（右上角）
                  if (contact.unreadCount > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: contact.doNotDisturb
                          ? // 消息免打扰（一对一或群组）：显示小红点
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                            )
                          : // 正常情况：显示未读数量气泡
                            Container(
                              constraints: contact.unreadCount < 10
                                  ? null
                                  : const BoxConstraints(minWidth: 16),
                              width: contact.unreadCount < 10 ? 16 : null,
                              height: 16,
                              padding: contact.unreadCount < 10
                                  ? null
                                  : const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                shape: contact.unreadCount < 10
                                    ? BoxShape.circle
                                    : BoxShape.rectangle,
                                borderRadius: contact.unreadCount < 10
                                    ? null
                                    : BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                contact.unreadCount > 99
                                    ? '99+'
                                    : '${contact.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  height: 1.0,
                                ),
                              ),
                            ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              // 消息内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              // 名称
                              Flexible(
                                child: Text(
                                  contact.isFileAssistant 
                                      ? AppLocalizations.of(context).translate('file_transfer_assistant')
                                      : contact.displayName,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF333333),
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
                        Text(
                          _formatMessageTime(contact.lastMessageTime),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 如果是群组消息且有人@我，显示红色的"[有人@我]"前缀
                    contact.isGroup && contact.hasMentionedMe
                        ? RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              children: [
                                const TextSpan(
                                  text: '[有人@我] ',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.red,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                TextSpan(
                                  text: contact.lastMessage,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF999999),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text(
                            contact.lastMessage,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF999999),
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
    );
  }

  // 显示联系人右键菜
  void _showContactContextMenu(
    BuildContext context,
    Offset position,
    RecentContactModel contact,
    String contactKey,
  ) async {
    // 检查是否置顶
    final isPinned = await Storage.isChatPinnedForCurrentUser(contactKey);

    if (!mounted) return;

    // 创建右键菜单
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'pin',
          child: Row(
            children: [
              Icon(
                isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 18,
                color: const Color(0xFF666666),
              ),
              const SizedBox(width: 8),
              Text(isPinned ? '取消置顶' : '置顶'),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Color(0xFFFF4D4F)),
              SizedBox(width: 8),
              Text('删除', style: TextStyle(color: Color(0xFFFF4D4F))),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;

      if (value == 'pin') {
        _togglePinChat(contactKey, isPinned);
      } else if (value == 'delete') {
        _deleteChat(contactKey, contact);
      }
    });
  }

  // 切换置顶状态
  Future<void> _togglePinChat(String contactKey, bool currentlyPinned) async {
    if (currentlyPinned) {
      await Storage.removePinnedChatForCurrentUser(contactKey);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已取消置顶')));
      }
    } else {
      await Storage.addPinnedChatForCurrentUser(contactKey);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已置顶')));
      }
    }

    // 重新加载并排序联系人列表
    await _loadRecentContacts();
  }

  // 删除会话
  Future<void> _deleteChat(
    String contactKey,
    RecentContactModel contact,
  ) async {
    try {
      // 获取当前用户ID
      final currentUserId = _currentUserId;
      if (currentUserId == null) {
        throw Exception('无法获取当前用户ID');
      }

      // 保存当前选中的索引，用于确定删除后选择哪个会话
      final deletedIndex = _selectedChatIndex;
      logger.debug('🗑️ 准备删除会话，当前索引: $deletedIndex');

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
        await localDb.deleteAllGroupMessages(contact.userId, currentUserId);
        logger.debug('已标记群组 ${contact.userId} 的所有消息为已删除');
      }

      // 保存删除状态到本地
      await Storage.addDeletedChatForCurrentUser(contactKey);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除${contact.displayName}会话和历史消息')),
        );
      }

      // 重新加载联系人列表
      await _loadRecentContacts();

      // 删除后自动选择下一个会话
      if (mounted && _recentContacts.isNotEmpty) {
        // 确定要选择的新索引
        // 如果删除的不是最后一个，选择相同索引位置的会话（即原来的下一个）
        // 如果删除的是最后一个，选择新的最后一个会话
        int newIndex;
        if (deletedIndex >= _recentContacts.length) {
          // 删除的是最后一个，选择新的最后一个
          newIndex = _recentContacts.length - 1;
        } else {
          // 删除的不是最后一个，选择相同索引（即原来的下一个）
          newIndex = deletedIndex;
        }

        logger.debug('🔄 删除后自动选择会话，新索引: $newIndex');

        // 获取新选中的联系人
        final newContact = _recentContacts[newIndex];
        final newChatId = _resolveChatId(newContact);
        final newGroupId = _resolveGroupId(newContact);

        setState(() {
          _selectedChatIndex = newIndex;
          _isCurrentChatGroup = newContact.isGroup;
          _currentChatUserId = newChatId;

          // 清除UI上的未读计数
          if (_recentContacts[newIndex].unreadCount > 0) {
            _recentContacts[newIndex] = _recentContacts[newIndex].copyWith(
              unreadCount: 0,
            );
            
            // 添加到已读集合
            final contactKey = newContact.isGroup
                ? 'group_${newContact.groupId}'
                : 'user_${newContact.userId}';
            _markedAsReadContacts.add(contactKey);
          }
        });

        // 如果是群组，先加载群组详细信息
        if (newGroupId != null) {
          await _loadGroupDetail(newGroupId);
        }

        // 加载新会话的消息历史
        await _loadMessageHistory(newChatId, isGroup: newContact.isGroup);

        // 如果有未读消息，标记为已读
        if (newContact.unreadCount > 0) {
          logger.debug('📧 新选中的会话有未读消息，正在标记为已读');
          if (newContact.isGroup) {
            await _markGroupMessagesAsRead(newChatId);
          } else {
            await _markMessagesAsRead(newChatId);
          }
        }

        // 滚动到底部
        _scrollToBottom(animated: false);
        
        logger.debug('✅ 删除后已自动切换到下一个会话并加载消息');
      } else {
        // 没有会话了，清空消息列表
        setState(() {
          _messages = [];
          _currentChatUserId = null;
          _isCurrentChatGroup = false;
          _selectedChatIndex = 0;
        });
        logger.debug('⚠️ 已删除所有会话，清空消息列表');
      }
    } catch (e) {
      logger.error('删除会话失败: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 检查并恢复被删除的会话（当收到新消息时）
  // 返回 true 表示恢复了会话并重新加载了列表，调用者应该直接返回不再继续处理
  Future<bool> _checkAndRestoreDeletedChat({
    required bool isGroup,
    required int id,
  }) async {
    final contactKey = Storage.generateContactKey(isGroup: isGroup, id: id);
    final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);

    if (isDeleted) {
      logger.debug('🔄 收到来自已删除会话的新消息，自动恢复: $contactKey');
      await Storage.removeDeletedChatForCurrentUser(contactKey);
      logger.debug('✅ 已删除会话已恢复: $contactKey，准备重新加载联系人列表');

      // 重新加载联系人列表，确保恢复的会话能够显示
      await _loadRecentContacts();
      return true; // 返回 true 表示已恢复并重新加载列表
    }

    return false; // 返回 false 表示没有恢复会话
  }

  // 应用联系人偏好设置（过滤删除、排序置顶）
  Future<List<RecentContactModel>> _applyContactPreferences(
    List<RecentContactModel> contacts,
  ) async {
    // 1. 获取已删除和置顶的配置（使用当前登录用户）
    final deletedChats = await Storage.getDeletedChatsForCurrentUser();
    final pinnedChats = await Storage.getPinnedChatsForCurrentUser();

    // 2. 过滤掉已删除的会话
    var filteredContacts = contacts.where((contact) {
      final contactKey = Storage.generateContactKey(
        isGroup: contact.isGroup,
        id: contact.isGroup
            ? (contact.groupId ?? contact.userId)
            : contact.userId,
      );
      return !deletedChats.contains(contactKey);
    }).toList();

    // 3. 分离置顶和非置顶的会
    final List<MapEntry<RecentContactModel, int>> pinnedList = [];
    final List<RecentContactModel> unpinnedList = [];

    for (final contact in filteredContacts) {
      final contactKey = Storage.generateContactKey(
        isGroup: contact.isGroup,
        id: contact.isGroup
            ? (contact.groupId ?? contact.userId)
            : contact.userId,
      );

      final pinnedTimestamp = pinnedChats[contactKey];
      if (pinnedTimestamp != null) {
        pinnedList.add(MapEntry(contact, pinnedTimestamp));
      } else {
        unpinnedList.add(contact);
      }
    }

    // 4. 对置顶列表按置顶时间倒序排序（最新置顶的在最前面）
    pinnedList.sort((a, b) => b.value.compareTo(a.value));

    // 5. 对非置顶列表按最后消息时间倒序排序（最新消息在最前面）
    // 包括用户、群组和文件助手，统一按消息时间排序
    unpinnedList.sort((a, b) {
      final aTime = DateTime.tryParse(a.lastMessageTime ?? '') ?? DateTime(1970);
      final bTime = DateTime.tryParse(b.lastMessageTime ?? '') ?? DateTime(1970);
      return bTime.compareTo(aTime); // 降序：最新的在前
    });
    
    // 🔍 调试日志：打印排序后的前5个会话
    if (unpinnedList.isNotEmpty) {
      logger.debug('📊 [PC端排序] 非置顶会话排序结果（前${unpinnedList.length > 5 ? 5 : unpinnedList.length}个）:');
      for (int i = 0; i < unpinnedList.length && i < 5; i++) {
        final contact = unpinnedList[i];
        final displayName = contact.isGroup ? contact.groupName : contact.fullName;
        logger.debug('  [$i] ${contact.type} - $displayName - ${contact.lastMessageTime}');
      }
    }

    // 6. 合并列表：置顶的在前，非置顶的在后
    final result = <RecentContactModel>[];
    result.addAll(pinnedList.map((e) => e.key));
    result.addAll(unpinnedList);

    return result;
  }

  // 启动联系人状态同步定时器
  void _startStatusSyncTimer() {
    // 先取消之前的定时器
    _statusSyncTimer?.cancel();

    logger.debug('⏰ 启动联系人状态同步定时器（每3秒同步一次）');

    // 创建周期性定时器，每3秒执行一次
    _statusSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _syncContactStatuses();
    });
  }

  // 同步联系人状态（定时器调用）
  Future<void> _syncContactStatuses() async {
    try {
      // 如果没有最近联系人，跳过同步
      if (_recentContacts.isEmpty) {
        return;
      }

      // 如果未登录，跳过同步
      if (_token == null || _token!.isEmpty) {
        return;
      }

      // 只查询用户类型的联系人（排除群组和文件助手）
      final userIds = _recentContacts
          .where((contact) => contact.type == 'user')
          .map((contact) => contact.userId)
          .toList();

      if (userIds.isEmpty) {
        return;
      }

      final response = await ApiService.batchGetOnlineStatus(
        token: _token!,
        userIds: userIds,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final statusesData = response['data']['statuses'] as Map<String, dynamic>?;
        if (statusesData != null && statusesData.isNotEmpty) {
          // 更新联系人的在线状态
          int updatedCount = 0;
          int skippedCount = 0;
          bool hasChanges = false;
          final now = DateTime.now();

          for (int i = 0; i < _recentContacts.length; i++) {
            final contact = _recentContacts[i];
            if (contact.type == 'user') {
              // 🔒 检查是否有WebSocket设置的状态，如有则完全使用WebSocket状态
              final websocketStatus = _websocketUserStatus[contact.userId];
              if (websocketStatus != null) {
                // 完全信任WebSocket，忽略API返回值
                if (websocketStatus != contact.status) {
                  _recentContacts[i] = contact.copyWith(status: websocketStatus);
                  updatedCount++;
                  hasChanges = true;
                }
                skippedCount++;
                continue;
              }
              
              // 没有WebSocket记录，使用API状态
              final userIdStr = contact.userId.toString();
              dynamic newStatus = statusesData[userIdStr];
              
              if (newStatus == null) {
                newStatus = statusesData[contact.userId];
              }
              
              if (newStatus != null && newStatus != contact.status) {
                _recentContacts[i] = contact.copyWith(status: newStatus as String);
                updatedCount++;
                hasChanges = true;
              }
            }
          }
          
          // 如果有状态变化，更新UI
          if (hasChanges && mounted) {
            setState(() {
              // 触发UI更新
            });
          }
        }
      }
    } catch (e) {
      // 静默处理错误，避免干扰用户体验
      logger.debug('⚠️ [状态同步] 同步失败: $e');
    }
  }

  // 批量获取联系人的实时在线状态
  Future<void> _fetchOnlineStatuses(List<RecentContactModel> contactsList) async {
    try {
      if (contactsList.isEmpty || _token == null || _token!.isEmpty) {
        logger.debug('📊 跳过在线状态查询 - 列表为空或未登录');
        return;
      }

      // 只查询用户类型的联系人（排除群组和文件助手）
      final userIds = contactsList
          .where((contact) => contact.type == 'user')
          .map((contact) => contact.userId)
          .toList();

      if (userIds.isEmpty) {
        logger.debug('📊 没有需要查询在线状态的用户联系人');
        return;
      }

      final response = await ApiService.batchGetOnlineStatus(
        token: _token!,
        userIds: userIds,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final statusesData = response['data']['statuses'] as Map<String, dynamic>?;
        if (statusesData != null) {
          // 更新联系人的在线状态
          int updatedCount = 0;
          int skippedCount = 0;
          final now = DateTime.now();
          for (int i = 0; i < contactsList.length; i++) {
            final contact = contactsList[i];
            if (contact.type == 'user') {
              // 🔒 检查是否有WebSocket设置的状态，如有则完全使用WebSocket状态
              final websocketStatus = _websocketUserStatus[contact.userId];
              if (websocketStatus != null) {
                // 完全信任WebSocket，忽略API返回值
                if (websocketStatus != contact.status) {
                  contactsList[i] = contact.copyWith(status: websocketStatus);
                  updatedCount++;
                }
                skippedCount++;
                continue;
              }
              
              // 没有WebSocket记录，使用API状态
              final userIdStr = contact.userId.toString();
              dynamic newStatus = statusesData[userIdStr];
              
              if (newStatus == null) {
                newStatus = statusesData[contact.userId];
              }
              
              if (newStatus != null && newStatus != contact.status) {
                contactsList[i] = contact.copyWith(status: newStatus as String);
                updatedCount++;
              }
            }
          }
          
        } else {
          logger.debug('⚠️ 状态数据为空');
        }
      } else {
        logger.debug('⚠️ 查询在线状态失败: ${response['message']}');
      }
    } catch (e, stackTrace) {
      logger.debug('❌ 批量查询在线状态异常: $e');
      logger.debug('❌ 堆栈跟踪: $stackTrace');
    }
  }

  // 右侧聊天窗口
  Widget _buildChatWindow() {
    // 如果没有选中聊天用户，显示空状
    if (_currentChatUserId == null) {
      return Expanded(
        child: Container(
          color: const Color(0xFFF5F5F5),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.message_outlined,
                  size: 64,
                  color: Color(0xFFCCCCCC),
                ),
                SizedBox(height: 16),
                Text(
                  '选择一个会话开始聊天',
                  style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 获取当前聊天的联系人信息（可能来自搜索结果或最近联系人
    RecentContactModel? contact;
    // 🔧 修复：使用唯一标识查找联系人，而不是索引
    if (_selectedChatKey != null) {
      // 先在搜索结果中查找
      if (_searchText.isNotEmpty) {
        contact = _searchResults.firstWhere(
          (c) {
            final key = Storage.generateContactKey(
              isGroup: c.isGroup,
              id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
            );
            return key == _selectedChatKey;
          },
          orElse: () => _recentContacts.firstWhere(
            (c) {
              final key = Storage.generateContactKey(
                isGroup: c.isGroup,
                id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
              );
              return key == _selectedChatKey;
            },
            orElse: () => RecentContactModel.fileAssistant(),
          ),
        );
      } else {
        // 在最近联系人中查找
        contact = _recentContacts.firstWhere(
          (c) {
            final key = Storage.generateContactKey(
              isGroup: c.isGroup,
              id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
            );
            return key == _selectedChatKey;
          },
          orElse: () => RecentContactModel.fileAssistant(),
        );
      }
    }

    // 如果找不到联系人信息，显示空状态
    if (contact == null) {
      return Expanded(
        child: Container(
          color: const Color(0xFFF5F5F5),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.message_outlined,
                  size: 64,
                  color: Color(0xFFCCCCCC),
                ),
                SizedBox(height: 16),
                Text(
                  '选择一个会话开始聊天',
                  style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: Stack(
        children: [
          // 主聊天区域
          Container(
            color: Colors.white,
            child: Column(
              children: [
                // 聊天窗口头部
                _buildChatHeader(contact),
                // 消息列表
                Expanded(child: _buildMessageListArea()),
                // 多选模式下的操作栏
                if (_isMultiSelectMode)
                  _buildMultiSelectActionBar()
                else
                  // 输入区域
                  _buildInputArea(),
              ],
            ),
          ),
          // 半透明遮罩层和右侧筛选面板（覆盖层）
          if (_showFilterPanel) ...[
            // 半透明遮罩层，点击可关闭面
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showFilterPanel = false;
                  });
                },
                child: Container(color: Colors.black.withOpacity(0.3)),
              ),
            ),
            // 筛选面
            Positioned(top: 0, right: 0, bottom: 0, child: _buildFilterPanel()),
          ],
        ],
      ),
    );
  }

  // 消息列表区域
  Widget _buildMessageListArea() {
    // 加载
    if (_isLoadingMessages) {
      return Container(
        color: const Color(0xFFF5F5F5),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // 加载错误
    if (_messagesError != null) {
      return Container(
        color: const Color(0xFFF5F5F5),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: Color(0xFFCCCCCC),
              ),
              const SizedBox(height: 16),
              Text(
                _messagesError!,
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  if (_currentChatUserId != null) {
                    if (_currentChatUserId == 0) {
                      // 文件助手
                      _loadFileAssistantMessages();
                    } else {
                      // 普通对话或群组
                      _loadMessageHistory(
                        _currentChatUserId!,
                        isGroup: _isCurrentChatGroup,
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90E2),
                  foregroundColor: Colors.white,
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 消息列表
    if (_messages.isEmpty) {
      return Container(
        color: const Color(0xFFF5F5F5),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: Color(0xFFCCCCCC),
              ),
              SizedBox(height: 16),
              Text(
                '暂无消息记录',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
              SizedBox(height: 8),
              Text(
                '开始你们的第一条消息吧',
                style: TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
              ),
            ],
          ),
        ),
      );
    }

    return Opacity(
      opacity: _isScrollingToBottom ? 0.0 : 1.0, // 滚动时隐藏，避免显示第一条消息
      child: Container(
        color: const Color(0xFFF5F5F5),
        child: ListView.builder(
          controller: _messageScrollController,
          padding: const EdgeInsets.all(16),
          itemCount: _messages.length + 1, // +1 用于底部透明占位条
          itemBuilder: (context, index) {
            // 如果是最后一个item，显示透明占位条
            if (index == _messages.length) {
              return Container(
                key: _messageListBottomKey, // 设置key用于滚动定位
                height: 1, // 1像素高的透明占位条
                color: Colors.transparent,
              );
            }
            // 否则显示正常的消息item
            return _buildMessageItem(_messages[index]);
          },
        ),
      ),
    );
  }

  // 构建群公告显示区域
  Widget _buildGroupAnnouncement(String announcement) {
    return GestureDetector(
      onTap: () => _showGroupAnnouncementDialog(announcement),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: const BoxDecoration(
          color: Color(0xFFFFFBE6), // 浅黄色背景
          border: Border(
            bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.campaign, size: 16, color: Color(0xFFFF9800)),
            const SizedBox(width: 8),
            const Text(
              '群公告：',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF666666),
                fontWeight: FontWeight.w500,
              ),
            ),
            Expanded(
              child: Text(
                announcement,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.arrow_forward_ios,
              size: 12,
              color: Color(0xFF999999),
            ),
          ],
        ),
      ),
    );
  }

  // 显示群公告详情对话框
  void _showGroupAnnouncementDialog(String announcement) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.campaign, color: Color(0xFFFF9800)),
            SizedBox(width: 8),
            Text('群公告'),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            announcement,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF333333),
              height: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildChatHeader(RecentContactModel contact) {
    // 获取当前群组信息（如果是群组聊天）
    GroupModel? currentGroup;
    if (contact.isGroup && contact.groupId != null) {
      try {
        currentGroup = _groups.firstWhere((g) => g.id == contact.groupId);
      } catch (e) {
        // 群组不存在于列表中
        currentGroup = null;
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 原有的头部行
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              // 如果是多选模式，显示"取消"按钮
              if (_isMultiSelectMode) ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isMultiSelectMode = false;
                      _selectedMessageIds.clear();
                    });
                  },
                  child: const Text(
                    '取消',
                    style: TextStyle(fontSize: 14, color: Color(0xFF4A90E2)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已选择 ${_selectedMessageIds.length} 条',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF666666),
                  ),
                ),
              ] else ...[
                // 如果是文件助手，显示文件图标
                if (contact.isFileAssistant) ...[
                  const Icon(
                    Icons.folder_open,
                    size: 20,
                    color: Color(0xFF07C160),
                  ),
                  const SizedBox(width: 8),
                ]
                // 如果是群组，显示群组图标
                else if (contact.isGroup) ...[
                  const Icon(Icons.people, size: 20, color: Color(0xFF52C41A)),
                  const SizedBox(width: 8),
                ],
                Text(
                  contact.displayName.length > 9
                      ? '${contact.displayName.substring(0, 9)}...'
                      : contact.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF333333),
                  ),
                ),
                // 如果是群组，显示"（群组人数：X人）"标识
                if (contact.isGroup && contact.groupId != null) ...[
                  FutureBuilder<int>(
                    key: ValueKey('group_member_count_${contact.groupId}'),
                    future: _getGroupMemberCount(contact.groupId!),
                    builder: (context, snapshot) {
                      final memberCount = snapshot.data ?? 0;
                      return Text(
                        ' (群组人数：${memberCount}人)',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF999999),
                        ),
                      );
                    },
                  ),
                ],
                // 如果是一对一私聊且对方正在输入，显示"对方正在输入..."
                if (!contact.isGroup &&
                    !contact.isFileAssistant &&
                    _isOtherTyping) ...[
                  const SizedBox(width: 8),
                  const Text(
                    '对方正在输入...',
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF999999),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
              const Spacer(),
              // 工具栏（文件助手不显示通话按钮）
              if (!_isMultiSelectMode && !contact.isFileAssistant) ...[
                // 单人聊天按钮
                if (!contact.isGroup) ...[
                  IconButton(
                    icon: const Icon(Icons.phone, color: Color(0xFF666666)),
                    onPressed: () => _startVoiceCall(contact),
                    tooltip: '语音通话（单人）',
                  ),
                  IconButton(
                    icon: const Icon(Icons.videocam, color: Color(0xFF666666)),
                    onPressed: () => _startVideoCall(contact),
                    tooltip: '视频通话（单人）',
                  ),
                ],
                // 群组聊天按钮
                if (contact.isGroup) ...[
                  IconButton(
                    icon: const Icon(Icons.phone, color: Color(0xFF666666)),
                    onPressed: () => _showGroupCallMemberPicker(contact),
                    tooltip: '语音通话（群组）',
                  ),
                  IconButton(
                    icon: const Icon(Icons.videocam, color: Color(0xFF666666)),
                    onPressed: () => _showGroupVideoCallMemberPicker(contact),
                    tooltip: '视频通话（群组）',
                  ),
                ],
              ],
              // 群组信息按钮（只在查看群组时显示）
              if (!_isMultiSelectMode && _isCurrentChatGroup) ...[
                IconButton(
                  icon: const Icon(Icons.group_add, color: Color(0xFF666666)),
                  onPressed: _showGroupInfoDialog,
                  tooltip: '群组信息',
                ),
              ],
              // 聊天记录按钮（所有类型都显示）
              if (!_isMultiSelectMode) ...[
                IconButton(
                  icon: Icon(
                    _showFilterPanel ? Icons.close : Icons.filter_list,
                    color: const Color(0xFF666666),
                  ),
                  onPressed: () {
                    setState(() {
                      _showFilterPanel = !_showFilterPanel;
                      if (_showFilterPanel) {
                        // 打开面板时，清空搜索框并更新筛选结果
                        _messageSearchController.clear();
                        _messageSearchKeyword = '';
                        _updateFilteredMessages();
                      }
                    });
                  },
                  tooltip: '聊天记录',
                ),
              ],
            ],
          ),
        ),
        // 群公告栏（只在群组聊天且有公告时显示）
        if (contact.isGroup &&
            currentGroup != null &&
            currentGroup.announcement != null &&
            currentGroup.announcement!.isNotEmpty)
          _buildGroupAnnouncement(currentGroup.announcement!),
      ],
    );
  }

  Widget _buildMessageItem(MessageModel message) {
    final isSelf = message.senderId == _currentUserId;

    // 特殊处理：系统消息（system、call_initiated、join_voice_button、join_video_button、call_ended、call_ended_video）居中显示
    if (message.messageType == 'system' ||
        message.messageType == 'call_initiated' ||
        message.messageType == 'join_voice_button' ||
        message.messageType == 'join_video_button' ||
        message.messageType == 'call_ended' ||
        message.messageType == 'call_ended_video') {
      
      // 通话发起消息特殊处理：添加"加入通话"按钮
      if ((message.messageType == 'call_initiated' || 
           message.messageType == 'join_voice_button' || 
           message.messageType == 'join_video_button') && 
          message.channelName != null && 
          message.channelName!.isNotEmpty) {
        
        // 显示通话发起消息（灰色居中文本）
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8E8E8),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              message.content,
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      
      // 普通系统消息
      String systemContent = message.content;
      final isCallEndedMessage = message.messageType == 'call_ended' ||
          message.messageType == 'call_ended_video';

      if (isCallEndedMessage && !systemContent.startsWith('通话时长')) {
        systemContent = '通话时长 ${systemContent}';
      }

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE8E8E8),
            borderRadius: BorderRadius.circular(4),
          ),
          child: isCallEndedMessage
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      message.messageType == 'call_ended_video'
                          ? Icons.videocam
                          : Icons.phone,
                      size: 14,
                      color: const Color(0xFF999999),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      systemContent,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : Text(
                  systemContent,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF999999)),
                  textAlign: TextAlign.center,
                ),
        ),
      );
    }

    // 特殊处理：上传进度消息
    if (message.messageType == 'upload_progress') {
      return Container(
        margin: EdgeInsets.only(
          top: 16,
          bottom: 4,
          left: isSelf ? 80 : 16,
          right: isSelf ? 16 : 80,
        ),
        child: Row(
          mainAxisAlignment: isSelf
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isSelf) ...[
              // 左侧头像
              _buildAvatar(
                avatarText: '加载中',
                avatarUrl: message.senderAvatar,
                isOnline: true,
                size: 36,
              ),
              const SizedBox(width: 8),
            ],
            // 消息内容
            Flexible(
              child: Column(
                crossAxisAlignment: isSelf
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  // 用户名和时间行
                  if (!isSelf)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            message.displaySenderName,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF999999),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            message.formattedTime,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFCCCCCC),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 加载消息内容
                  Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isSelf ? const Color(0xFF95EC69) : Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: _buildUploadProgressContent(message),
                  ),
                ],
              ),
            ),
            if (isSelf) ...[
              const SizedBox(width: 8),
              // 右侧头像
              _buildAvatar(
                avatarText: _getUserAvatarText(),
                avatarUrl: _userAvatar,
                isOnline: true,
                size: 36,
              ),
            ],
          ],
        ),
      );
    }

    // 获取发送者信息
    String displayName = '';
    String username = '';
    String avatarText = '';
    String? senderAvatar; // 动态获取最新头像
    if (isSelf) {
      // 自己发送的消息
      displayName = _userDisplayName.isNotEmpty ? _userDisplayName : '我';
      username = ''; // 自己的消息不显示用户名
      // 🔴 修复：优先使用昵称（_userFullName）生成头像文字，没有昵称才使用用户名
      final userNameForAvatar = (_userFullName != null && _userFullName!.isNotEmpty)
          ? _userFullName!
          : (_username.isNotEmpty ? _username : '我');
      avatarText = userNameForAvatar.length >= 2
          ? userNameForAvatar.substring(userNameForAvatar.length - 2)
          : userNameForAvatar;
      senderAvatar = _userAvatar; // 使用当前用户的头像
    } else {
      // 对方发送的消息
      // 对于群组消息，优先使用群组昵称
      if (_isCurrentChatGroup) {
        displayName = message.displaySenderName;
        // 🔴 修复：优先使用昵称（displaySenderName）生成头像文字，而不是用户名
        final userNameForAvatar = message.displaySenderName;
        avatarText = userNameForAvatar.length >= 2
            ? userNameForAvatar.substring(userNameForAvatar.length - 2)
            : userNameForAvatar;
        // 优先级：头像缓存 > 最近联系人列表 > 消息中的旧头
        if (_avatarCache.containsKey(message.senderId)) {
          senderAvatar = _avatarCache[message.senderId];
        } else {
          // 从最近联系人列表中查找该发送者的最新头
          final sender = _recentContacts.firstWhere(
            (contact) => !contact.isGroup && contact.userId == message.senderId,
            orElse: () => _recentContacts.first,
          );
          if (sender.userId == message.senderId) {
            senderAvatar = sender.avatar;
            // 同时更新缓存
            _avatarCache[message.senderId] = sender.avatar;
          } else {
            senderAvatar = message.senderAvatar; // 找不到就用消息中的旧头像
          }
        }
      } else {
        // 对于私聊消息，从最近联系人或搜索结果中获取用户信息
        // 🔧 修复：使用唯一标识查找联系人
        RecentContactModel? contactInfo;
        if (_selectedChatKey != null) {
          if (_searchText.isNotEmpty) {
            contactInfo = _searchResults.firstWhere(
              (c) {
                final key = Storage.generateContactKey(
                  isGroup: c.isGroup,
                  id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
                );
                return key == _selectedChatKey;
              },
              orElse: () => _recentContacts.firstWhere(
                (c) {
                  final key = Storage.generateContactKey(
                    isGroup: c.isGroup,
                    id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
                  );
                  return key == _selectedChatKey;
                },
                orElse: () => RecentContactModel.fileAssistant(),
              ),
            );
          } else {
            contactInfo = _recentContacts.firstWhere(
              (c) {
                final key = Storage.generateContactKey(
                  isGroup: c.isGroup,
                  id: c.isGroup ? (c.groupId ?? c.userId) : c.userId,
                );
                return key == _selectedChatKey;
              },
              orElse: () => RecentContactModel.fileAssistant(),
            );
          }
        }

        // 获取显示名称优先级：最近联系人昵称 -> 消息中的全名/昵称 -> 消息账号
        final contactDisplayName = contactInfo?.displayName ?? '';
        final messageDisplayName = message.displaySenderName;
        if (contactDisplayName.isNotEmpty) {
          displayName = contactDisplayName;
        } else if (message.senderFullName != null &&
            message.senderFullName!.isNotEmpty) {
          displayName = message.senderFullName!;
        } else if (messageDisplayName.isNotEmpty) {
          displayName = messageDisplayName;
        } else if (message.senderName.isNotEmpty) {
          displayName = message.senderName;
        } else {
          displayName = 'Unknown';
        }
        username = contactInfo?.username ?? message.senderName;

        // 优先级：头像缓存 > 联系人头> 消息中的旧头
        if (_avatarCache.containsKey(message.senderId)) {
          senderAvatar = _avatarCache[message.senderId];
        } else {
          senderAvatar = contactInfo?.avatar ?? message.senderAvatar;
          // 如果从联系人获取到头像，更新缓存
          if (contactInfo?.avatar != null) {
            _avatarCache[message.senderId] = contactInfo!.avatar;
          }
        }

        // 使用username生成头像文字，如果没有username则使用senderName，如果都为空则使用'U'
        final avatarSourceName = displayName.isNotEmpty
            ? displayName
            : (messageDisplayName.isNotEmpty
                  ? messageDisplayName
                  : (username.isNotEmpty ? username : 'Unknown'));
        avatarText = avatarSourceName.length >= 2
            ? avatarSourceName.substring(avatarSourceName.length - 2)
            : avatarSourceName;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 计算消息内容的最大宽度为对话框宽度的60%
        final maxMessageWidth = constraints.maxWidth * 0.6;

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: isSelf
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 多选模式下显示checkbox
              if (_isMultiSelectMode) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Checkbox(
                    value: _selectedMessageIds.contains(message.id),
                    onChanged: (bool? value) {
                      setState(() {
                        if (value == true) {
                          _selectedMessageIds.add(message.id);
                        } else {
                          _selectedMessageIds.remove(message.id);
                        }
                      });
                    },
                    activeColor: const Color(0xFF4A90E2),
                  ),
                ),
              ],
              if (!isSelf) ...[
                // 对方头像（可点击查看用户信息
                GestureDetector(
                  onTap: () {
                    // 点击头像显示对方的用户信
                    _showOtherUserInfo(message.senderId);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A90E2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: senderAvatar != null && senderAvatar.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(
                              senderAvatar,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Text(
                                  avatarText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                );
                              },
                            ),
                          )
                        : Text(
                            avatarText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // 消息内容（最大宽0%
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxMessageWidth),
                child: Column(
                  crossAxisAlignment: isSelf
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 显示时间和发送者信
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            () {
                              if (isSelf) {
                                return message.formattedTime;
                              }
                              final nameToShow = displayName.isNotEmpty
                                  ? displayName
                                  : 'Unknown';
                              return '$nameToShow, ${message.formattedTime}';
                            }(),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF999999),
                            ),
                          ),
                          // 🔴 修复：添加状态图标（仅自己发送的消息显示，根据实际聊天类型判断）
                          if (isSelf) ...[
                            const SizedBox(width: 6),
                            _buildMessageStatusIcon(message, isGroupChat: _isCurrentChatGroup),
                          ],
                        ],
                      ),
                    ),
                    // 添加右键菜单支持
                    GestureDetector(
                      onSecondaryTapDown: (details) {
                        _showMessageContextMenu(
                          context,
                          message,
                          details.globalPosition,
                        );
                      },
                      onLongPressStart: (details) {
                        // 移动端长按显示菜
                        _showMessageContextMenu(
                          context,
                          message,
                          details.globalPosition,
                        );
                      },
                      child: Container(
                        padding: message.messageType == 'image'
                            ? EdgeInsets.zero
                            : const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                        decoration: BoxDecoration(
                          color: _highlightedMessageId == message.id
                              ? const Color(0xFFFFF9E6) // 高亮背景色（淡黄色）
                              : isSelf
                              ? const Color(0xFFD6EBFF)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(4),
                          border: _highlightedMessageId == message.id
                              ? Border.all(
                                  color: const Color(0xFFFFD700),
                                  width: 2,
                                )
                              : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 如果消息被撤回，显示"已被撤销"提示
                            if (message.status == 'recalled')
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.cancel_outlined,
                                    size: 14,
                                    color: Color(0xFF999999),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '此消息已被撤回',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF999999),
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              )
                            // 显示引用消息（messageType == 'quoted' 时显示）
                            else if (message.messageType == 'quoted' &&
                                message.quotedMessageContent != null) ...[
                              // Debug: 确认显示引用消息
                              Builder(
                                builder: (context) {
                                  return const SizedBox.shrink();
                                },
                              ),
                              // 查找被引用的消息以获取发送者信息
                              Builder(
                                builder: (context) {
                                  String? quotedSenderName;
                                  if (message.quotedMessageId != null) {
                                    // 🔴 使用serverId匹配，因为quotedMessageId是服务器ID
                                    final quotedMessage = _messages.firstWhere(
                                      (msg) =>
                                          msg.serverId == message.quotedMessageId || msg.id == message.quotedMessageId,
                                      orElse: () => MessageModel(
                                        id: 0,
                                        senderId: 0,
                                        receiverId: 0,
                                        senderName: '',
                                        receiverName: '',
                                        content: '',
                                        messageType: 'text',
                                        isRead: false,
                                        createdAt: DateTime.now(),
                                      ),
                                    );
                                    if (quotedMessage.id != 0) {
                                      // 判断被引用消息的发送者是否是当前用户
                                      if (quotedMessage.senderId ==
                                          _currentUserId) {
                                        quotedSenderName = '我';
                                      } else {
                                        // 使用 displaySenderName 获取显示名称（优先使用群组昵称）
                                        quotedSenderName =
                                            quotedMessage.displaySenderName;
                                      }
                                    }
                                  }

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      6,
                                      8,
                                      6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelf
                                          ? const Color(0xFFBDD7F3)
                                          : const Color(0xFFF0F0F0),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border(
                                        left: BorderSide(
                                          color: const Color(0xFF4A90E2),
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.reply,
                                              size: 14,
                                              color: Color(0xFF4A90E2),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '引用消息',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF4A90E2),
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                        // 显示引用人的昵称
                                        if (quotedSenderName != null &&
                                            quotedSenderName.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            quotedSenderName,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF4A90E2),
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 4),
                                        Text(
                                          message.quotedMessageContent!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF666666),
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                            // 消息内容（根据类型显示）
                            // 如果消息已撤回，不显示原内容
                            if (message.status != 'recalled')
                              // 语音通话结束
                              message.messageType == 'call_ended'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.phone,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '通话时长',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  // 视频通话结束
                                  : message.messageType == 'call_ended_video'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.videocam,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '通话时长',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  // 语音通话拒绝
                                  : message.messageType == 'call_rejected'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.phone_disabled,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  // 视频通话拒绝
                                  : message.messageType == 'call_rejected_video'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.videocam_off,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  // 语音通话取消
                                  : message.messageType == 'call_cancelled'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.phone_callback,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  // 视频通话取消
                                  : message.messageType ==
                                        'call_cancelled_video'
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.videocam,
                                          size: 16,
                                          color: const Color(0xFF333333),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          message.content,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ],
                                    )
                                  : message.messageType == 'quoted'
                                  ? ExtendedText(
                                      message.content,
                                      specialTextSpanBuilder:
                                          MessageEmojiTextSpanBuilder(),
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFF333333),
                                        height: 1.5,
                                      ),
                                    )
                                  : message.messageType == 'image'
                                  ? GestureDetector(
                                      onTap: () {
                                        // 点击图片打开全屏查看
                                        _showImageViewer(
                                          context,
                                          message.content,
                                        );
                                      },
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 300,
                                            maxHeight: 300,
                                          ),
                                          child: Image.network(
                                            message.content,
                                            fit: BoxFit.contain,
                                            loadingBuilder: (context, child, loadingProgress) {
                                              if (loadingProgress == null) {
                                                return child;
                                              }
                                              return Container(
                                                width: 200,
                                                height: 200,
                                                alignment: Alignment.center,
                                                child: CircularProgressIndicator(
                                                  value:
                                                      loadingProgress
                                                              .expectedTotalBytes !=
                                                          null
                                                      ? loadingProgress
                                                                .cumulativeBytesLoaded /
                                                            loadingProgress
                                                                .expectedTotalBytes!
                                                      : null,
                                                ),
                                              );
                                            },
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                                  return Container(
                                                    width: 200,
                                                    height: 200,
                                                    alignment: Alignment.center,
                                                    child: const Column(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      children: [
                                                        Icon(
                                                          Icons.broken_image,
                                                          size: 48,
                                                          color: Colors.grey,
                                                        ),
                                                        SizedBox(height: 8),
                                                        Text(
                                                          '图片加载失败',
                                                          style: TextStyle(
                                                            color: Colors.grey,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                          ),
                                        ),
                                      ),
                                    )
                                  : message.messageType == 'video'
                                  ? GestureDetector(
                                      onTap: () {
                                        // 点击视频打开预览
                                        _showVideoViewer(
                                          context,
                                          message.content,
                                        );
                                      },
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          constraints: const BoxConstraints(
                                            maxWidth: 300,
                                            maxHeight: 300,
                                          ),
                                          color: Colors.black87,
                                          child: Stack(
                                            children: [
                                              // 视频占位符
                                              Container(
                                                width: double.infinity,
                                                height: 200,
                                                color: Colors.black87,
                                                child: const Center(
                                                  child: Icon(
                                                    Icons.videocam,
                                                    color: Colors.white70,
                                                    size: 48,
                                                  ),
                                                ),
                                              ),
                                              // 播放按钮
                                              const Center(
                                                child: Icon(
                                                  Icons.play_circle_outline,
                                                  color: Colors.white,
                                                  size: 64,
                                                ),
                                              ),
                                              // 视频标识
                                              Positioned(
                                                bottom: 8,
                                                right: 8,
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black54,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons.videocam,
                                                        color: Colors.white,
                                                        size: 14,
                                                      ),
                                                      SizedBox(width: 4),
                                                      Text(
                                                        '视频',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )
                                  : message.messageType == 'voice'
                                  ? _buildVoiceMessageBubble(message, isSelf)
                                  : message.messageType == 'file'
                                  ? Container(
                                      constraints: const BoxConstraints(
                                        minWidth: 200,
                                        maxWidth: 300,
                                      ),
                                      padding: const EdgeInsets.all(12),
                                      child: () {
                                        // 优先使用 fileName 字段，如果没有则URL 提取
                                        String fileName =
                                            message.fileName ?? '未知文件';

                                        if (fileName == '未知文件' &&
                                            message.content.isNotEmpty) {
                                          // 兼容旧数据：尝试content 中解
                                          final parts = message.content.split(
                                            '|',
                                          );
                                          if (parts.length > 1 &&
                                              parts[1].isNotEmpty) {
                                            fileName = parts[1];
                                          } else {
                                            // 从URL提取文件
                                            final url = message.content;
                                            final urlParts = url.split('/');
                                            if (urlParts.isNotEmpty) {
                                              final lastPart = urlParts.last;
                                              // 去掉时间戳前缀（格式：时间戳_文件名）
                                              if (lastPart.contains('_')) {
                                                final nameParts = lastPart
                                                    .split('_');
                                                if (nameParts.length > 1) {
                                                  fileName = nameParts
                                                      .sublist(1)
                                                      .join('_');
                                                } else {
                                                  fileName = lastPart;
                                                }
                                              } else {
                                                fileName = lastPart;
                                              }
                                            }
                                          }
                                        }

                                        logger.debug(
                                          '📨 文件消息 - 文件 $fileName, URL: ${message.content}',
                                        );

                                        return Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _getFileIcon(fileName),
                                              color: const Color(0xFF4A90E2),
                                              size: 40,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    fileName,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  const Text(
                                                    '右键另存',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Color(0xFF999999),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        );
                                      }(),
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 引用消息预览（如果有）
                                        if (message.quotedMessageContent !=
                                                null &&
                                            message
                                                .quotedMessageContent!
                                                .isNotEmpty)
                                          Builder(
                                            builder: (context) {
                                              // 查找被引用消息的发送者信息
                                              String? quotedSenderName;
                                              if (message.quotedMessageId !=
                                                  null) {
                                                final quotedMessage = _messages
                                                    .firstWhere(
                                                      (msg) =>
                                                          msg.id ==
                                                          message
                                                              .quotedMessageId,
                                                      orElse: () =>
                                                          MessageModel(
                                                            id: 0,
                                                            senderId: 0,
                                                            receiverId: 0,
                                                            senderName: '',
                                                            receiverName: '',
                                                            content: '',
                                                            messageType: 'text',
                                                            isRead: false,
                                                            createdAt:
                                                                DateTime.now(),
                                                          ),
                                                    );
                                                if (quotedMessage.id != 0) {
                                                  // 判断被引用消息的发送者是否是当前用户
                                                  if (quotedMessage.senderId ==
                                                      _currentUserId) {
                                                    quotedSenderName = '我';
                                                  } else {
                                                    quotedSenderName =
                                                        quotedMessage
                                                            .displaySenderName;
                                                  }
                                                }
                                              }

                                              return Container(
                                                margin: const EdgeInsets.only(
                                                  bottom: 8,
                                                ),
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                      8,
                                                      6,
                                                      8,
                                                      6,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: isSelf
                                                      ? const Color(0xFFBDD7F3)
                                                      : const Color(0xFFF0F0F0),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  border: Border(
                                                    left: BorderSide(
                                                      color: const Color(
                                                        0xFF4A90E2,
                                                      ),
                                                      width: 3,
                                                    ),
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons.reply,
                                                          size: 14,
                                                          color: Color(
                                                            0xFF4A90E2,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 4,
                                                        ),
                                                        Text(
                                                          '引用消息',
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            color: Color(
                                                              0xFF4A90E2,
                                                            ),
                                                            fontWeight:
                                                                FontWeight.w500,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    // 显示被引用者的名称
                                                    if (quotedSenderName !=
                                                            null &&
                                                        quotedSenderName
                                                            .isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        quotedSenderName,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: Color(
                                                            0xFF4A90E2,
                                                          ),
                                                          fontWeight:
                                                              FontWeight.w400,
                                                        ),
                                                      ),
                                                    ],
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      message
                                                          .quotedMessageContent!,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: Color(
                                                          0xFF666666,
                                                        ),
                                                        fontStyle:
                                                            FontStyle.italic,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        // 消息内容
                                        ExtendedText(
                                          message.content,
                                          specialTextSpanBuilder:
                                              MessageEmojiTextSpanBuilder(),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF333333),
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
                          ],
                        ),
                      ),
                    ), // GestureDetector结束
                  ],
                ),
              ),
              if (isSelf) ...[
                const SizedBox(width: 12),
                // 自己的头像
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: senderAvatar != null && senderAvatar.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            senderAvatar,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Text(
                                avatarText,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              );
                            },
                          ),
                        )
                      : Text(
                          avatarText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // 多选模式下的操作栏
  Widget _buildMultiSelectActionBar() {
    final bool hasSelection = _selectedMessageIds.isNotEmpty;

    return Container(
      height: 60,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E5E5), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 转发按钮
          Expanded(
            child: InkWell(
              onTap: hasSelection ? _showMultiSelectForwardDialog : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.forward,
                    color: hasSelection
                        ? const Color(0xFF4A90E2)
                        : const Color(0xFFCCCCCC),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '转发',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasSelection
                          ? const Color(0xFF333333)
                          : const Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 收藏按钮
          Expanded(
            child: InkWell(
              onTap: hasSelection ? _favoriteSelectedMessages : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.star_border,
                    color: hasSelection
                        ? const Color(0xFF4A90E2)
                        : const Color(0xFFCCCCCC),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '收藏',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasSelection
                          ? const Color(0xFF333333)
                          : const Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 删除按钮
          Expanded(
            child: InkWell(
              onTap: hasSelection ? _deleteSelectedMessages : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.delete_outline,
                    color: hasSelection
                        ? const Color(0xFFE74C3C)
                        : const Color(0xFFCCCCCC),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '删除',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasSelection
                          ? const Color(0xFFE74C3C)
                          : const Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 关闭按钮
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() {
                  _isMultiSelectMode = false;
                  _selectedMessageIds.clear();
                });
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.close, color: Color(0xFF666666)),
                  const SizedBox(height: 4),
                  const Text(
                    '关闭',
                    style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建筛选面
  Widget _buildFilterPanel() {
    return Container(
      width: 330,
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(
          left: BorderSide(color: Color(0xFFE5E5E5), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // 标签栏
          Container(
            height: 50,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
              ),
            ),
            child: Row(
              children: [
                // 全部标签
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedFilterTab = 0;
                        _updateFilteredMessages();
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedFilterTab == 0
                                ? const Color(0xFF4A90E2)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '全部',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: _selectedFilterTab == 0
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _selectedFilterTab == 0
                                ? const Color(0xFF4A90E2)
                                : const Color(0xFF666666),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 文件标签
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedFilterTab = 1;
                        _updateFilteredMessages();
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedFilterTab == 1
                                ? const Color(0xFF4A90E2)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '文件',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: _selectedFilterTab == 1
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _selectedFilterTab == 1
                                ? const Color(0xFF4A90E2)
                                : const Color(0xFF666666),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 搜索
          Container(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _messageSearchController,
              decoration: InputDecoration(
                hintText: '搜索',
                hintStyle: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF999999),
                ),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF999999)),
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _messageSearchKeyword = value.trim();
                });
                _updateFilteredMessages();
              },
            ),
          ),
          // 消息列表
          Expanded(
            child: _filteredMessages.isEmpty
                ? const Center(
                    child: Text(
                      '暂无消息',
                      style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredMessages.length,
                    itemBuilder: (context, index) {
                      return _buildFilterPanelMessageItem(
                        _filteredMessages[index],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // 构建筛选面板中的消息项
  Widget _buildFilterPanelMessageItem(MessageModel message) {
    final isSelf = message.senderId == _currentUserId;
    final displayName = isSelf ? '我' : message.senderName;
    // 限制名字长度，超过9个字符显示省略号
    final truncatedName = displayName.length > 9
        ? '${displayName.substring(0, 9)}...'
        : displayName;

    return InkWell(
      onTap: () {
        // 点击消息项，滚动到对应消
        _scrollToMessage(message.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFF0F0F0), width: 1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 发送者和时间
            Row(
              children: [
                Text(
                  truncatedName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatMessageTimeFromDateTime(message.createdAt),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF999999),
                  ),
                ),
                // 🔴 修复：消息状态图标（仅自己发送的消息显示，根据实际聊天类型判断）
                if (message.senderId == _currentUserId) ...[
                  const SizedBox(width: 4),
                  _buildMessageStatusIcon(message, isGroupChat: _isCurrentChatGroup),
                ],
              ],
            ),
            const SizedBox(height: 6),
            // 消息内容预览
            _buildMessagePreviewContent(message),
          ],
        ),
      ),
    );
  }

  // 构建消息预览内容（根据消息类型显示不同内容）
  Widget _buildMessagePreviewContent(MessageModel message) {
    switch (message.messageType) {
      case 'image':
        // 显示图片缩略图，支持点击预览
        return GestureDetector(
          onTap: () => _showImagePreviewDialog(message.content),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              message.content,
              width: 80,
              height: 80,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 80,
                  height: 80,
                  color: const Color(0xFFF5F5F5),
                  child: const Icon(
                    Icons.image_outlined,
                    color: Color(0xFF999999),
                    size: 40,
                  ),
                );
              },
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  width: 80,
                  height: 80,
                  color: const Color(0xFFF5F5F5),
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
            ),
          ),
        );
      case 'file':
        // 显示文件样式和文件名
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 文件图标
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.insert_drive_file,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 8),
              // 文件
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.fileName ?? '未知文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF333333),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '文件',
                      style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      case 'video':
        // 显示视频标识，支持点击预览
        return GestureDetector(
          onTap: () => _showVideoPreviewDialog(message.content),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_circle_filled, color: Color(0xFF4A90E2), size: 20),
                const SizedBox(width: 6),
                const Text(
                  '[视频] 点击播放',
                  style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
                ),
              ],
            ),
          ),
        );
      default:
        // 显示文本消息
        return Text(
          message.content,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
        );
    }
  }

  // 格式化消息时间（从DateTime对象
  String _formatMessageTimeFromDateTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays == 0) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }

  // 构建消息状态图标（参考APP端实现）
  Widget _buildMessageStatusIcon(MessageModel message, {bool isGroupChat = false}) {
    final isFailed = message.status == 'failed';
    final isForbidden = message.status == 'forbidden'; // 🔴 被拉黑/删除/移除后发送的消息
    
    // 🔴 群聊中：只显示错误图标，其他情况隐藏
    if (isGroupChat) {
      if (isForbidden || isFailed) {
        return const Icon(
          Icons.error,
          size: 14,
          color: Colors.red,
        );
      } else {
        // 其他情况隐藏图标
        return const SizedBox.shrink();
      }
    }
    
    // 🔴 修复：私聊中根据isRead字段显示已读/未读图标
    final isSending = message.status == 'sending';

    if (isForbidden) {
      // 被拉黑/删除/移除状态：显示红色感叹号
      return const Icon(
        Icons.error,
        size: 14,
        color: Colors.red,
      );
    } else if (isFailed) {
      // 失败状态：显示红色感叹号
      return const Icon(
        Icons.error,
        size: 14,
        color: Colors.red,
      );
    } else if (isSending) {
      // 发送中：显示灰色单勾
      return Icon(
        Icons.done,
        size: 14,
        color: Colors.grey[400],
      );
    } else if (message.isRead && message.readAt != null) {
      // 🔴 已读（根据isRead字段判断）：显示蓝色双钩
      return const Icon(
        Icons.done_all,
        size: 14,
        color: Colors.blue,
      );
    } else {
      // 🔴 未读或未确认：显示灰色单勾
      return Icon(
        Icons.done,
        size: 14,
        color: Colors.grey[400],
      );
    }
  }

  // 显示图片预览对话框
  void _showImagePreviewDialog(String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              // 图片内容
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 300,
                        height: 300,
                        color: const Color(0xFF333333),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.broken_image,
                              color: Colors.white54,
                              size: 60,
                            ),
                            SizedBox(height: 12),
                            Text(
                              '图片加载失败',
                              style: TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                          ],
                        ),
                      );
                    },
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        width: 300,
                        height: 300,
                        color: const Color(0xFF333333),
                        child: Center(
                          child: CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                                : null,
                            color: Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // 关闭按钮
              Positioned(
                top: 20,
                right: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 32),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 显示视频预览对话框
  void _showVideoPreviewDialog(String videoUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              // 视频播放提示
              Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.play_circle_filled,
                        color: Color(0xFF4A90E2),
                        size: 80,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '视频预览',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: SelectableText(
                          videoUrl,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () {
                          // 使用系统默认浏览器打开视频URL
                          _launchURL(videoUrl);
                        },
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('在浏览器中打开'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 关闭按钮
              Positioned(
                top: 20,
                right: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 32),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 使用系统默认浏览器打开URL
  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法打开此链接')),
          );
        }
      }
    } catch (e) {
      logger.error('打开URL失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开链接失败: $e')),
        );
      }
    }
  }

  Widget _buildInputArea() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E5E5), width: 1)),
      ),
      child: Column(
        children: [
          // 工具
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Builder(
                  builder: (btnContext) => IconButton(
                    icon: const Icon(
                      Icons.emoji_emotions_outlined,
                      color: Color(0xFF666666),
                    ),
                    onPressed: () => _showEmojiPicker(btnContext),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.image_outlined,
                    color: Color(0xFF666666),
                  ),
                  onPressed: _pickImage,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.videocam_outlined,
                    color: Color(0xFF666666),
                  ),
                  onPressed: _pickVideo,
                  tooltip: '视频',
                ),
                IconButton(
                  icon: const Icon(
                    Icons.upload_file_outlined,
                    color: Color(0xFF666666),
                  ),
                  onPressed: _pickFiles,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.screenshot_outlined,
                    color: Color(0xFF666666),
                  ),
                  onPressed: _captureScreen,
                  tooltip: '截图',
                ),
              ],
            ),
          ),
          // 输入框和发送按钮（按钮在输入框右下角内部）
          Container(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Stack(
              children: [
                // 输入框（撑满整个宽度，根据是否有引用消息/图片/文件动态调整高度）
                Container(
                  height: () {
                    int baseHeight = 126;
                    if (_quotedMessage != null) baseHeight += 70; // 引用消息
                    if (_selectedImageFiles.isNotEmpty) baseHeight += 80;
                    if (_selectedVideoFiles.isNotEmpty) baseHeight += 80;
                    if (_selectedFiles.isNotEmpty) baseHeight += 80;
                    return baseHeight.toDouble();
                  }(),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE5E5E5)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Stack(
                    children: [
                      // 文本输入区域
                      Positioned.fill(
                        child: Focus(
                          onKeyEvent: (FocusNode node, KeyEvent event) {
                            // 监听键盘事件
                            if (event is KeyDownEvent) {
                              // 检查是否按下了Ctrl+V（粘贴）
                              if (event.logicalKey == LogicalKeyboardKey.keyV &&
                                  HardwareKeyboard.instance.isControlPressed) {
                                // Ctrl+V：粘贴剪贴板中的内容（图片或文本
                                _pasteFromClipboard();
                                return KeyEventResult.handled;
                              }
                              // 检查是否按下了Delete或Backspace键
                              if (event.logicalKey ==
                                      LogicalKeyboardKey.delete ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.backspace) {
                                // 检查输入框是否为空或光标在开头
                                final text = _messageInputController.text;
                                final selection =
                                    _messageInputController.selection;
                                final cursorPosition = selection.baseOffset;

                                // 如果输入框为空，或者光标在开头且没有选中文本
                                if (text.isEmpty ||
                                    (cursorPosition == 0 &&
                                        selection.isCollapsed)) {
                                  // 从后往前删除：先删除文件，再删除视频，再删除图片
                                  if (_selectedFiles.isNotEmpty) {
                                    // 删除最后一个文件
                                    setState(() {
                                      _selectedFiles.removeLast();
                                    });
                                    return KeyEventResult.handled;
                                  } else if (_selectedVideoFiles.isNotEmpty) {
                                    // 删除最后一个视频
                                    setState(() {
                                      _selectedVideoFiles.removeLast();
                                    });
                                    return KeyEventResult.handled;
                                  } else if (_selectedImageFiles.isNotEmpty) {
                                    // 删除最后一张图片
                                    setState(() {
                                      _selectedImageFiles.removeLast();
                                    });
                                    return KeyEventResult.handled;
                                  }
                                }
                                // 如果输入框不为空，让系统默认处理Delete键（删除文本）
                                return KeyEventResult.ignored;
                              }
                              // 检查是否按下了回车
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.enter) {
                                // 检查是否同时按下了Shift
                                if (HardwareKeyboard.instance.isShiftPressed) {
                                  // Shift+回车：换行（让ExtendedTextField默认处理
                                  return KeyEventResult.ignored;
                                } else {
                                  // 单独回车：发送消息
                                  _sendMessageWithImage();
                                  return KeyEventResult.handled;
                                }
                              }
                            }
                            return KeyEventResult.ignored;
                          },
                          child: ExtendedTextField(
                            controller: _messageInputController,
                            focusNode: _messageInputFocusNode,
                            specialTextSpanBuilder: EmojiTextSpanBuilder(),
                            maxLines: null,
                            expands: true,
                            scrollPhysics:
                                const AlwaysScrollableScrollPhysics(),
                            onChanged:
                                _handleInputTextChanged, // 监听文本变化，处理表情整体删除
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF333333),
                              height: 1.3,
                            ),
                            decoration: InputDecoration(
                              hintText: AppLocalizations.of(context).translate('message_input_hint_pc'),
                              hintStyle: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFFAAAAAA),
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.fromLTRB(
                                12,
                                () {
                                  int topPadding = 12;
                                  if (_quotedMessage != null) {
                                    topPadding += 70; // 引用消息高度
                                  }
                                  if (_selectedImageFiles.isNotEmpty) {
                                    topPadding += 80;
                                  }
                                  if (_selectedVideoFiles.isNotEmpty) {
                                    topPadding += 80;
                                  }
                                  if (_selectedFiles.isNotEmpty)
                                    topPadding += 80;
                                  return topPadding.toDouble();
                                }(),
                                12,
                                50,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 图片预览（横向滚动列表，浮动在引用消息框下方
                      if (_selectedImageFiles.isNotEmpty)
                        Positioned(
                          left: 8,
                          top: _quotedMessage != null ? 78.0 : 8.0,
                          right: 8,
                          child: SizedBox(
                            height: 70,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _selectedImageFiles.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Stack(
                                    children: [
                                      // 图片缩略
                                      Container(
                                        width: 70,
                                        height: 70,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: const Color(0xFFE5E5E5),
                                            width: 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                          child: Image.file(
                                            _selectedImageFiles[index],
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      ),
                                      // 删除按钮
                                      Positioned(
                                        top: -4,
                                        right: -4,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 1,
                                            ),
                                          ),
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.close,
                                              color: Colors.white,
                                              size: 12,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 20,
                                              minHeight: 20,
                                            ),
                                            onPressed: () =>
                                                _removeImage(index),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      // 视频预览（横向滚动列表，浮动在图片预览下方）
                      if (_selectedVideoFiles.isNotEmpty)
                        Positioned(
                          left: 8,
                          top: () {
                            double topPosition = 8;
                            if (_quotedMessage != null) topPosition += 70;
                            if (_selectedImageFiles.isNotEmpty) {
                              topPosition += 80;
                            }
                            return topPosition;
                          }(),
                          right: 8,
                          child: SizedBox(
                            height: 70,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _selectedVideoFiles.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Stack(
                                    children: [
                                      // 视频缩略图（显示视频第一帧）
                                      Container(
                                        width: 70,
                                        height: 70,
                                        decoration: BoxDecoration(
                                          color: Colors.black,
                                          border: Border.all(
                                            color: const Color(0xFFE5E5E5),
                                            width: 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                          child: _VideoThumbnailWidget(
                                            videoFile:
                                                _selectedVideoFiles[index],
                                          ),
                                        ),
                                      ),
                                      // 删除按钮
                                      Positioned(
                                        top: -4,
                                        right: -4,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 1,
                                            ),
                                          ),
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.close,
                                              color: Colors.white,
                                              size: 12,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 20,
                                              minHeight: 20,
                                            ),
                                            onPressed: () =>
                                                _removeVideo(index),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      // 文件预览（横向滚动列表，浮动在视频预览下方）
                      if (_selectedFiles.isNotEmpty)
                        Positioned(
                          left: 8,
                          top: () {
                            double topPosition = 8;
                            if (_quotedMessage != null) topPosition += 70;
                            if (_selectedImageFiles.isNotEmpty) {
                              topPosition += 80;
                            }
                            if (_selectedVideoFiles.isNotEmpty) {
                              topPosition += 80;
                            }
                            return topPosition;
                          }(),
                          right: 8,
                          child: SizedBox(
                            height: 70,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _selectedFiles.length,
                              itemBuilder: (context, index) {
                                final file = _selectedFiles[index];
                                final fileName = file.path
                                    .split(Platform.pathSeparator)
                                    .last;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Stack(
                                    children: [
                                      // 文件卡片
                                      Container(
                                        width: 150,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[100],
                                          border: Border.all(
                                            color: const Color(0xFFE5E5E5),
                                            width: 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              _getFileIcon(fileName),
                                              color: const Color(0xFF4A90E2),
                                              size: 32,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    fileName,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // 删除按钮
                                      Positioned(
                                        top: -4,
                                        right: -4,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 1,
                                            ),
                                          ),
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.close,
                                              color: Colors.white,
                                              size: 12,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 20,
                                              minHeight: 20,
                                            ),
                                            onPressed: () => _removeFile(index),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      // 引用消息框（显示在最上层，不会被TextField覆盖）
                      if (_quotedMessage != null)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 70,
                            padding: const EdgeInsets.all(12),
                            decoration: const BoxDecoration(
                              color: Color(0xFFF5F5F5),
                              border: Border(
                                bottom: BorderSide(color: Color(0xFFE5E5E5)),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 3,
                                  height: 46,
                                  color: const Color(0xFF4A90E2),
                                  margin: const EdgeInsets.only(right: 12),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _quotedMessage!.senderId ==
                                                _currentUserId
                                            ? '我'
                                            : _quotedMessage!.senderName,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF4A90E2),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _getQuotedMessagePreview(
                                          _quotedMessage!,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    size: 18,
                                    color: Color(0xFF999999),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _quotedMessage = null;
                                    });
                                  },
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 发送按钮（定位在右下角，只占一行高度）
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: ElevatedButton(
                    onPressed:
                        (_isSendingMessage ||
                            _isUploadingImage ||
                            _isUploadingVideo ||
                            _isUploadingFile)
                        ? null
                        : _sendMessageWithImage,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      minimumSize: const Size(60, 32), // 最小尺寸，控制按钮高度约为一
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child:
                        (_isSendingMessage ||
                            _isUploadingImage ||
                            _isUploadingVideo ||
                            _isUploadingFile)
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text('发送', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 通讯录列
  Widget _buildContactList() {
    // 通讯录分组数
    final List<Map<String, dynamic>> contactGroups = [
      {
        'name': '新联系人',
        'icon': Icons.person_add,
        'color': const Color(0xFFFAAD14),
      },
      {
        'name': '群通知',
        'icon': Icons.notifications_active,
        'color': const Color(0xFFFF9800),
      },
      {
        'name': '联系人',
        'icon': Icons.account_tree,
        'color': const Color(0xFF4A90E2),
      },
      {'name': '固定群组', 'icon': Icons.group, 'color': const Color(0xFF4A90E2)},
      {'name': '我的常用', 'icon': Icons.star, 'color': const Color(0xFFFAAD14)},
    ];

    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E5E5), width: 1)),
      ),
      child: Column(
        children: [
          // 搜索
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _contactSearchController,
                      onChanged: (value) {
                        setState(() {
                          _contactSearchKeyword = value.trim();
                        });
                        logger.debug('🔍 [通讯录搜索] 搜索关键词: $_contactSearchKeyword');
                      },
                      decoration: InputDecoration(
                        hintText: '搜索联系人或群组',
                        hintStyle: const TextStyle(
                          color: Color(0xFFCCCCCC),
                          fontSize: 14,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Color(0xFF999999),
                          size: 20,
                        ),
                        suffixIcon: _contactSearchKeyword.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  setState(() {
                                    _contactSearchController.clear();
                                    _contactSearchKeyword = '';
                                  });
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add, color: Color(0xFF666666)),
                  onPressed: () {
                    // 显示添加联系人对话框
                    _showAddContactDialog();
                  },
                ),
              ],
            ),
          ),
          // 通讯录分组列
          Expanded(
            child: ListView.builder(
              itemCount: contactGroups.length,
              itemBuilder: (context, index) {
                return _buildContactGroupItem(contactGroups[index], index);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactGroupItem(Map<String, dynamic> group, int index) {
    final isSelected = _selectedContactIndex == index;

    // 计算未处理数量
    int pendingCount = 0;
    if (index == 0) {
      // 新联系人：统计当前用户需要审核的联系人数量
      pendingCount = _contacts.where((c) => c.isPendingForUser(_currentUserId)).length;
    } else if (index == 1) {
      // 群通知：统计待审核的群成员数量
      pendingCount = _pendingGroupMembers.length;
    }

    return InkWell(
      onTap: () {
        setState(() {
          _selectedContactIndex = index;
          _selectedPerson = null;
          if (index != 3) {
            _selectedGroup = null;
          }
          // 如果切换到"新联系人"、"群通知"、"联系人"或"固定群组"，清空常用分类选择
          if (index == 0 || index == 1 || index == 2 || index == 3) {
            _selectedFavoriteCategory = null;
          }
          // 切换子菜单时清空搜索关键词
          _contactSearchController.clear();
          _contactSearchKeyword = '';
        });

        // [PC端] 通讯录子菜单切换 - 无缓存策略，每次切换都重新加载最新数据
        // 🔴 修复：添加加载状态检查，防止重复加载导致死循环
        if (index == 0) {
          // 新联系人
          if (!_isLoadingContacts) {
            logger.debug('🔄 [PC端] 切换到新联系人，重新加载数据');
            _loadContacts();
          } else {
            logger.debug('⏸️ [PC端] 联系人正在加载中，跳过重复加载');
          }
        } else if (index == 1) {
          // 群通知
          if (!_isLoadingPendingMembers) {
            logger.debug('🔄 [PC端] 切换到群通知，重新加载数据');
            _loadPendingGroupMembers();
          } else {
            logger.debug('⏸️ [PC端] 群通知正在加载中，跳过重复加载');
          }
        } else if (index == 2) {
          // 联系人
          if (!_isLoadingContacts) {
            logger.debug('🔄 [PC端] 切换到联系人，重新加载数据');
            _loadContacts();
          } else {
            logger.debug('⏸️ [PC端] 联系人正在加载中，跳过重复加载');
          }
        } else if (index == 3) {
          // 固定群组
          if (!_isLoadingGroups) {
            logger.debug('🔄 [PC端] 切换到固定群组，重新加载数据');
            _loadGroups();
          } else {
            logger.debug('⏸️ [PC端] 群组正在加载中，跳过重复加载');
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected ? const Color(0xFFF5F5F5) : Colors.white,
        child: Row(
          children: [
            // 图标
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: group['color'],
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Icon(group['icon'], color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            // 分组名称
            Expanded(
              child: Text(
                group['name'],
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
            ),
            // 红色气泡（显示未处理数量）
            if (pendingCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4D4F),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  pendingCount > 99 ? '99+' : '$pendingCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            // 箭头
            const Icon(Icons.chevron_right, color: Color(0xFF999999), size: 20),
          ],
        ),
      ),
    );
  }

  // 通讯录详情区
  Widget _buildContactDetailArea() {
    return Expanded(
      child: Row(
        children: [
          // 中间内容区域
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  right: BorderSide(color: Color(0xFFE5E5E5), width: 1),
                ),
              ),
              child: _selectedContactIndex == -1
                  ? _buildEmptyContactState()
                  : _buildContactContent(),
            ),
          ),
          // 右侧详情区域（人员、群组或常用列表
          SizedBox(
            width: 260,
            child: Container(
              color: Colors.white,
              child: _selectedFavoriteCategory != null
                  ? _buildFavoriteListDetail()
                  : (_selectedGroup != null
                        ? _buildGroupDetail()
                        : (_selectedPerson == null
                              ? _buildEmptyPersonState()
                              : _buildPersonDetail())),
            ),
          ),
        ],
      ),
    );
  }

  // 空状态（未选择联系人）
  Widget _buildEmptyContactState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset('assets/通讯未选择内容.svg', width: 360, height: 208),
          const SizedBox(height: 24),
          const Text(
            '选择一个联系人或群组开始交流',
            style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
        ],
      ),
    );
  }

  // 联系人详情内容（当选择了某个分组时显示
  Widget _buildContactContent() {
    // 根据选中的分组显示不同的内容
    if (_selectedContactIndex == 0) {
      // 新联系人
      return _buildNewContactsContent();
    } else if (_selectedContactIndex == 1) {
      // 群通知
      return _buildGroupNotificationsContent();
    } else if (_selectedContactIndex == 2) {
      // 联系人
      return _buildOrganizationContent();
    } else if (_selectedContactIndex == 3) {
      // 固定群组
      return _buildGroupContent();
    } else if (_selectedContactIndex == 4) {
      // 我的常用
      return _buildFavoriteContent();
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.people, size: 80, color: Color(0xFFCCCCCC)),
          const SizedBox(height: 24),
          const Text(
            '联系人详情页',
            style: TextStyle(fontSize: 16, color: Color(0xFF666666)),
          ),
        ],
      ),
    );
  }

  // 新联系人内容（只显示待审核的联系人）
  Widget _buildNewContactsContent() {
    return Column(
      children: [
        // 头部
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_add, color: Color(0xFFFAAD14), size: 24),
              const SizedBox(width: 8),
              const Text(
                '新联系人',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              // 显示待审核联系人数量
              if (!_isLoadingContacts && _contactsError == null)
                Text(
                  '${_contacts.where((c) => c.isPendingForUser(_currentUserId)).length}人',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF999999),
                  ),
                ),
            ],
          ),
        ),
        // 待审核联系人列表内容
        Expanded(child: _buildNewContactsListContent()),
      ],
    );
  }

  // 联系人内容（只显示已通过审核的联系人）
  Widget _buildOrganizationContent() {
    return Column(
      children: [
        // 头部
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.account_tree,
                color: Color(0xFF4A90E2),
                size: 24,
              ),
              const SizedBox(width: 8),
              const Text(
                '联系人',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              // 显示已通过审核的联系人数量
              if (!_isLoadingContacts && _contactsError == null)
                Text(
                  '${_contacts.where((c) => c.isApproved).length}人',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF999999),
                  ),
                ),
            ],
          ),
        ),
        // 联系人列表内容
        Expanded(child: _buildContactsListContent()),
      ],
    );
  }

  // 新联系人列表内容（只显示待审核的联系人）
  Widget _buildNewContactsListContent() {
    // 加载中
    if (_isLoadingContacts) {
      return const Center(child: CircularProgressIndicator());
    }

    // 加载失败
    if (_contactsError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 16),
            Text(
              _contactsError!,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadContacts,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 过滤出当前用户需要审核的联系人
    var pendingContacts = _contacts.where((c) => c.isPendingForUser(_currentUserId)).toList();

    // 按名称首字母排序
    pendingContacts = SortHelper.sortContactsByName(
      pendingContacts,
      (contact) => contact.displayName,
    );

    // 如果有搜索关键词，进行过滤
    if (_contactSearchKeyword.isNotEmpty) {
      pendingContacts = pendingContacts.where((contact) {
        final keyword = _contactSearchKeyword.toLowerCase();
        return contact.displayName.toLowerCase().contains(keyword) ||
            contact.username.toLowerCase().contains(keyword) ||
            (contact.phone?.toLowerCase().contains(keyword) ?? false);
      }).toList();

      logger.debug('🔍 [新联系人搜索] 搜索"$_contactSearchKeyword"，找到 ${pendingContacts.length} 个结果');
    }

    // 没有待审核的联系人
    if (pendingContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.person_add_outlined,
              size: 48,
              color: Color(0xFFCCCCCC),
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无新的联系人',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
          ],
        ),
      );
    }

    // 显示待审核的联系人列表
    return ListView.builder(
      itemCount: pendingContacts.length,
      itemBuilder: (context, index) {
        final contact = pendingContacts[index];
        return _buildContactMemberItem(contact);
      },
    );
  }

  // 群通知内容（显示待审核的群组成员）
  Widget _buildGroupNotificationsContent() {
    return Column(
      children: [
        // 头部
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.notifications_active,
                color: Color(0xFFFF9800),
                size: 24,
              ),
              const SizedBox(width: 8),
              const Text(
                '群通知',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              // 显示待审核成员数量
              if (!_isLoadingPendingMembers && _pendingMembersError == null)
                Text(
                  '${_pendingGroupMembers.length}人待审核',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF999999),
                  ),
                ),
            ],
          ),
        ),
        // 待审核成员列表内容
        Expanded(child: _buildGroupNotificationsListContent()),
      ],
    );
  }

  // 群通知列表内容
  Widget _buildGroupNotificationsListContent() {
    // 加载中
    if (_isLoadingPendingMembers) {
      return const Center(child: CircularProgressIndicator());
    }

    // 加载失败
    if (_pendingMembersError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 16),
            Text(
              _pendingMembersError!,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadPendingGroupMembers,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 根据搜索关键词过滤待审核成员
    var filteredMembers = _pendingGroupMembers;
    if (_contactSearchKeyword.isNotEmpty) {
      filteredMembers = _pendingGroupMembers.where((member) {
        final keyword = _contactSearchKeyword.toLowerCase();
        final displayName = (member['displayName'] as String? ?? '').toLowerCase();
        final groupName = (member['groupName'] as String? ?? '').toLowerCase();
        return displayName.contains(keyword) || groupName.contains(keyword);
      }).toList();

      logger.debug('🔍 [群通知搜索] 搜索"$_contactSearchKeyword"，找到 ${filteredMembers.length} 个结果');
    }

    // 没有待审核成员
    if (filteredMembers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.notifications_none,
              size: 48,
              color: Color(0xFFCCCCCC),
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无待审核的群组成员',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
          ],
        ),
      );
    }

    // 显示待审核成员列表（过滤后的）
    return ListView.builder(
      itemCount: filteredMembers.length,
      itemBuilder: (context, index) {
        final member = filteredMembers[index];
        return _buildPendingGroupMemberItem(member);
      },
    );
  }

  // 待审核群组成员项
  Widget _buildPendingGroupMemberItem(Map<String, dynamic> member) {
    final groupName = member['groupName'] as String;
    final displayName = member['displayName'] as String;
    final groupId = member['groupId'] as int;
    final userId = member['userId'] as int;
    final avatarText = displayName.isNotEmpty
        ? displayName.substring(0, 1)
        : '?';
    
    // 如果昵称超过9个字符，截断并添加省略号
    final truncatedName = displayName.length > 9 
        ? '${displayName.substring(0, 9)}...' 
        : displayName;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1)),
      ),
      child: Row(
        children: [
          // 头像
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF4A90E2),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Text(
              avatarText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 用户信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  truncatedName,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '申请加入: $groupName',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
            ),
          ),
          // 通过按钮
          TextButton(
            onPressed: () =>
                _approveGroupMember(groupId, userId, displayName, groupName),
            style: TextButton.styleFrom(
              minimumSize: const Size(60, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: const Color(0xFF4CAF50),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('通过', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          // 拒绝按钮
          TextButton(
            onPressed: () =>
                _rejectGroupMember(groupId, userId, displayName, groupName),
            style: TextButton.styleFrom(
              minimumSize: const Size(60, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('拒绝', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // 联系人列表内容（只显示已通过审核的联系人）
  Widget _buildContactsListContent() {
    // 加载中
    if (_isLoadingContacts) {
      return const Center(child: CircularProgressIndicator());
    }

    // 加载失败
    if (_contactsError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 16),
            Text(
              _contactsError!,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadContacts,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 过滤出已通过审核且未删除的联系人
    var approvedContacts = _contacts
        .where((c) => c.isApproved && !c.isDeleted)
        .toList();

    // 按名称首字母排序
    approvedContacts = SortHelper.sortContactsByName(
      approvedContacts,
      (contact) => contact.displayName,
    );

    // 如果有搜索关键词，进行过滤
    if (_contactSearchKeyword.isNotEmpty) {
      approvedContacts = approvedContacts.where((contact) {
        final keyword = _contactSearchKeyword.toLowerCase();
        return contact.displayName.toLowerCase().contains(keyword) ||
            contact.username.toLowerCase().contains(keyword) ||
            (contact.phone?.toLowerCase().contains(keyword) ?? false) ||
            (contact.department?.toLowerCase().contains(keyword) ?? false);
      }).toList();

      logger.debug('🔍 [联系人搜索] 搜索"$_contactSearchKeyword"，找到 ${approvedContacts.length} 个结果');
    }

    // 没有已通过审核的联系人
    if (approvedContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.people_outline,
              size: 48,
              color: Color(0xFFCCCCCC),
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无联系人',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 8),
            const Text(
              '点击右上角"+"添加好友',
              style: TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
            ),
          ],
        ),
      );
    }

    // 显示已通过审核的联系人列表
    return ListView.builder(
      itemCount: approvedContacts.length,
      itemBuilder: (context, index) {
        final contact = approvedContacts[index];
        return _buildContactMemberItem(contact);
      },
    );
  }

  // 联系人成员项（使用ContactModel
  Widget _buildContactMemberItem(ContactModel contact) {
    return InkWell(
      onTap: () {
        // 单击成员，显示详
        setState(() {
          _selectedGroup = null; // 清除选中的群
          _selectedFavoriteCategory = null; // 清除常用分类选择
          _selectedPerson = {
            'id': contact.friendId,
            'username': contact.username,
            'name': contact.displayName,
            'avatar': contact.avatarText,
            'avatarUrl': contact.avatar, // 保存头像URL
            'status': contact.status,
            'work_signature': contact.workSignature,
            'phone': contact.phone,
            'email': contact.email,
            'department': contact.department,
            'position': contact.position,
          };
        });
      },
      onDoubleTap: () {
        // 双击成员，跳转到消息页面并打开聊天
        logger.debug('🖱双击联系 ${contact.displayName}');

        // 检查联系人是否被拉黑
        if (contact.isBlocked || contact.isBlockedByMe) {
          // 如果被拉黑，显示提示消息，不允许打开聊天框
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('该联系人已被拉黑，无法打开聊天'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }

        _openChatFromContacts(contact);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1),
          ),
        ),
        child: Row(
          children: [
            // 头像
            Stack(
              children: [
                _buildAvatar(
                  avatarText: contact.avatarText,
                  avatarUrl: contact.avatar,
                  isOnline: contact.isOnline,
                  size: 40,
                ),
                // 在线状
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _getStatusColor(contact.status),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // 姓名和状
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        contact.displayName.length > 9
                            ? '${contact.displayName.substring(0, 9)}...'
                            : contact.displayName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF333333),
                        ),
                      ),
                      // 显示审核状态标签
                      if (contact.isPendingForUser(_currentUserId)) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3CD),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(0xFFFFE69C),
                              width: 1,
                            ),
                          ),
                          child: const Text(
                            '待审核',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF856404),
                            ),
                          ),
                        ),
                      ] else if (contact.isWaitingForApproval(_currentUserId)) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE3F2FD),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(0xFFBBDEFB),
                              width: 1,
                            ),
                          ),
                          child: const Text(
                            '等待审核',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF1976D2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    contact.workSignature ?? (contact.isOnline ? '在线' : '离线'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // 审核按钮（仅接收方在待审核状态时显示）
            if (contact.isPendingForUser(_currentUserId)) ...[
              const SizedBox(width: 6),
              // 拒绝按钮
              SizedBox(
                height: 28,
                child: TextButton(
                  onPressed: () => _handleContactApproval(contact, 'rejected'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: const Color(0xFFF5F5F5),
                    foregroundColor: const Color(0xFF666666),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('拒绝', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 4),
              // 通过按钮
              SizedBox(
                height: 28,
                child: TextButton(
                  onPressed: () => _handleContactApproval(contact, 'approved'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: const Color(0xFF4A90E2),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('通过', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
            // 拉黑/恢复和删除按钮（仅已通过审核的联系人显示）
            if (contact.isApproved) ...[
              // 拉黑/恢复按钮（只有在对方没有拉黑我的情况下才显示）
              // 判断条件：如果被拉黑且拉黑操作人不是我，则不显示按钮
              if (!contact.isBlocked || 
                  (contact.isBlocked && contact.blockedByUserId == _currentUserId)) ...[
                if (contact.isBlockedByMe) ...[
                  const SizedBox(width: 8),
                  // 恢复按钮（只有拉黑方才能看到）
                  SizedBox(
                    height: 28,
                    child: TextButton(
                      onPressed: () => _handleUnblockContact(contact),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: const Text('恢复', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ] else ...[
                  // 拉黑按钮（正常状态时显示）
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 28,
                    child: TextButton(
                      onPressed: () => _handleBlockContact(contact),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        backgroundColor: const Color(0xFFFF9800),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: const Text('拉黑', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ],
              const SizedBox(width: 8),
              // 删除按钮（始终显示）
              SizedBox(
                height: 28,
                child: TextButton(
                  onPressed: () => _handleDeleteContact(contact),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: const Text('删除', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 固定群组内容
  Widget _buildGroupContent() {
    // 按名称首字母排序
    var filteredGroups = SortHelper.sortGroupsByName(
      _groups,
      (group) => group.name,
    );
    
    // 根据搜索关键词过滤群组
    if (_contactSearchKeyword.isNotEmpty) {
      filteredGroups = filteredGroups.where((group) {
        final keyword = _contactSearchKeyword.toLowerCase();
        return group.name.toLowerCase().contains(keyword) ||
            (group.announcement?.toLowerCase().contains(keyword) ?? false) ||
            (group.remark?.toLowerCase().contains(keyword) ?? false) ||
            (group.nickname?.toLowerCase().contains(keyword) ?? false);
      }).toList();

      logger.debug('🔍 [群组搜索] 搜索"$_contactSearchKeyword"，找到 ${filteredGroups.length} 个结果');
    }

    return Column(
      children: [
        // 头部
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.group, color: Color(0xFF4A90E2), size: 24),
              const SizedBox(width: 8),
              const Text(
                '固定群组',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              // 刷新按钮
              IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFF666666)),
                onPressed: _loadGroups,
                tooltip: '刷新群组列表',
              ),
            ],
          ),
        ),
        // 群组列表（显示过滤后的结果）
        Expanded(
          child: _isLoadingGroups
              ? const Center(child: CircularProgressIndicator())
              : _groupsError != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _groupsError!,
                        style: const TextStyle(color: Color(0xFF999999)),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadGroups,
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                )
              : filteredGroups.isEmpty
              ? Center(
                  child: Text(
                    _contactSearchKeyword.isNotEmpty 
                        ? '没有找到匹配的群组' 
                        : '您还没有加入任何群组',
                    style: const TextStyle(color: Color(0xFF999999)),
                  ),
                )
              : ListView.builder(
                  itemCount: filteredGroups.length,
                  itemBuilder: (context, index) {
                    return _buildGroupItem(filteredGroups[index]);
                  },
                ),
        ),
      ],
    );
  }

  // 群组
  Widget _buildGroupItem(GroupModel group) {
    // 获取群组名称的前2个字符作为头像文
    final avatarText = group.name.length > 2
        ? group.name.substring(0, 2)
        : group.name;

    // 判断当前群组是否被选中
    final isSelected = _selectedGroup?.id == group.id;

    return InkWell(
      onTap: () {
        // 单击群组，显示群组信
        logger.debug('单击群组: ${group.name} (ID: ${group.id})');
        setState(() {
          _selectedGroup = group;
          _selectedPerson = null; // 清除选中的人
          _selectedFavoriteCategory = null; // 清除常用分类选择
        });
      },
      onDoubleTap: () {
        // 双击群组，跳转到消息页面并打开群组聊天
        logger.debug('🖱双击群组: ${group.name}');
        _openChatFromGroup(group);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE8F4FF) : Colors.white,
          border: const Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1),
          ),
        ),
        child: Row(
          children: [
            // 群组头像（绿色默认头像）
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF52C41A), // 绿色背景
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.people, // 人物图标
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            // 群组信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      FutureBuilder<int>(
                        future: _getGroupMemberCount(group.id),
                        builder: (context, snapshot) {
                          final memberCount = snapshot.data ?? 0;
                          return Text(
                            '${memberCount}人',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF999999),
                            ),
                          );
                        },
                      ),
                      if (group.announcement != null &&
                          group.announcement!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            group.announcement!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF999999),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 我的常用内容
  Widget _buildFavoriteContent() {
    // 常用分类数据
    final List<Map<String, dynamic>> favoriteCategories = [
      {'name': '常用群组', 'icon': Icons.people, 'color': const Color(0xFF4A90E2)},
      {'name': '常用联系人', 'icon': Icons.person, 'color': const Color(0xFFFAAD14)},
      {
        'name': '上线提醒',
        'icon': Icons.notifications,
        'color': const Color(0xFF52C41A),
      },
    ];

    return Column(
      children: [
        // 头部
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.star, color: Color(0xFFFAAD14), size: 24),
              const SizedBox(width: 8),
              const Text(
                '我的常用',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
            ],
          ),
        ),
        // 常用分类列表
        Expanded(
          child: ListView.builder(
            itemCount: favoriteCategories.length,
            itemBuilder: (context, index) {
              return _buildFavoriteCategoryItem(favoriteCategories[index]);
            },
          ),
        ),
      ],
    );
  }

  // 常用分类
  Widget _buildFavoriteCategoryItem(Map<String, dynamic> category) {
    final categoryName = category['name'] as String;
    String categoryKey = '';
    if (categoryName == '常用联系人') {
      categoryKey = 'contacts';
    } else if (categoryName == '常用群组') {
      categoryKey = 'groups';
    } else if (categoryName == '上线提醒') {
      categoryKey = 'notifications';
    }

    final isSelected = _selectedFavoriteCategory == categoryKey;

    return InkWell(
      onTap: () {
        // 选择常用分类，在右侧显示列表
        setState(() {
          _selectedFavoriteCategory = categoryKey;
          _selectedPerson = null;
          _selectedGroup = null;
        });
        // 加载对应的数
        _loadFavoriteData(categoryKey);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF5F5F5) : Colors.transparent,
          border: const Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1),
          ),
        ),
        child: Row(
          children: [
            // 展开箭头
            const Icon(Icons.arrow_right, color: Color(0xFF999999), size: 20),
            const SizedBox(width: 12),
            // 图标
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: category['color'],
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Icon(category['icon'], color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            // 分类名称
            Expanded(
              child: Text(
                category['name'],
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 空状态（未选择人员
  Widget _buildEmptyPersonState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset('assets/通讯未选择内容.svg', width: 360, height: 208),
          const SizedBox(height: 24),
          const Text(
            '选择一个联系人查看详情',
            style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
        ],
      ),
    );
  }

  // 群组详情
  Widget _buildGroupDetail() {
    if (_selectedGroup == null) return const SizedBox();

    final group = _selectedGroup!;
    // 获取群组名称的前2个字符作为头像文
    final avatarText = group.name.length > 2
        ? group.name.substring(0, 2)
        : group.name;

    return Column(
      children: [
        // 固定的头部信息区域（不滚动）
        Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像和基本信
              Row(
                children: [
                  // 群组名称和成员数
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                group.name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF333333),
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 2,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.group,
                              color: Color(0xFF4A90E2),
                              size: 18,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        FutureBuilder<int>(
                          future: _getGroupMemberCount(group.id),
                          builder: (context, snapshot) {
                            final memberCount = snapshot.data ?? 0;
                            return Text(
                              '${memberCount}名成员',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF999999),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 群组头像（绿色默认头像）
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: const Color(0xFF52C41A), // 绿色背景
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.people, // 人物图标
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // 打开群组聊天
                    _openChatFromGroup(group);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90E2),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: const Text(
                    '发送消息',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 可滚动的详情和成员列表区
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 详细信息
                  if (group.announcement != null &&
                      group.announcement!.isNotEmpty) ...[
                    const Text(
                      '群公告',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF666666),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        group.announcement!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF333333),
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // 群管理按钮（仅群主可见）
                  if (group.ownerId == _currentUserId) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          logger.debug(
                            '打开群管理对话框，群组ID: ${group.id}, 群主ID: ${group.ownerId}, 当前用户ID: $_currentUserId',
                          );
                          _showGroupManagementDialog(group);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        child: const Text(
                          '群管理',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (group.remark != null && group.remark!.isNotEmpty)
                    _buildCompactInfoItem('备注', group.remark!),
                  if (group.nickname != null && group.nickname!.isNotEmpty)
                    _buildCompactInfoItem('群昵称', group.nickname!),
                  const SizedBox(height: 20),
                  // 群成员列
                  Row(
                    children: [
                      const Text(
                        '群成员',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF666666),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FutureBuilder<int>(
                        future: _getGroupMemberCount(group.id),
                        builder: (context, snapshot) {
                          final memberCount = snapshot.data ?? 0;
                          return Text(
                            '(${memberCount})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF999999),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 成员列表
                  _buildGroupMembersList(group),
                  const SizedBox(height: 20),
                  // 操作按钮
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        flex: 3,
                        child: FutureBuilder<bool>(
                          future: _checkIfFavoriteGroup(group.id),
                          builder: (context, snapshot) {
                            final isFavorite = snapshot.data ?? false;
                            return SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () =>
                                    _toggleFavoriteGroup(group.id, isFavorite),
                                icon: Icon(
                                  isFavorite ? Icons.star : Icons.star_border,
                                  size: 16,
                                  color: isFavorite ? Colors.amber : null,
                                ),
                                label: Text(
                                  isFavorite ? '已添加' : '添加常用群组',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: isFavorite
                                      ? Colors.amber
                                      : const Color(0xFF666666),
                                  side: BorderSide(
                                    color: isFavorite
                                        ? Colors.amber.withOpacity(0.5)
                                        : const Color(0xFFE5E5E5),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  minimumSize: Size.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              // 群组设置 - 显示群组信息弹窗
                              if (_selectedGroup != null) {
                                _showGroupInfoDialogFromGroupId(
                                  _selectedGroup!.id,
                                );
                              }
                            },
                            icon: const Icon(Icons.settings, size: 16),
                            label: const Text(
                              '设置',
                              style: TextStyle(fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF666666),
                              side: const BorderSide(color: Color(0xFFE5E5E5)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              minimumSize: Size.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 紧凑型信息项
  Widget _buildCompactInfoItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 65,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }

  // 群成员列
  Widget _buildGroupMembersList(GroupModel group) {
    if (group.memberIds.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '暂无成员',
            style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E5E5), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: group.memberIds.length,
        itemBuilder: (context, index) {
          final isLastItem = index == group.memberIds.length - 1;
          return _buildGroupMemberItem(
            group.memberIds[index],
            group,
            isLastItem: isLastItem,
          );
        },
      ),
    );
  }

  // 群成员项
  Widget _buildGroupMemberItem(
    int memberId,
    GroupModel group, {
    bool isLastItem = false,
  }) {
    ContactModel? contact;
    try {
      contact = _contacts.firstWhere((c) => c.friendId == memberId);
    } catch (e) {
      // 如果找不到，contact保持为null
    }

    final isCurrentUser = memberId == _currentUserId;
    final displayName = isCurrentUser
        ? _userDisplayName
        : (contact?.displayName ?? '用户$memberId');
    final avatarText = isCurrentUser
        ? (_username.isNotEmpty ? _username.substring(0, 1).toUpperCase() : 'U')
        : (contact?.avatarText ??
              (displayName.isNotEmpty ? displayName.substring(0, 1) : 'U'));
    final status = isCurrentUser ? _userStatus : (contact?.status ?? 'offline');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: isLastItem
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
              ),
      ),
      child: Row(
        children: [
          // 头像
          Stack(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF4A90E2),
                backgroundImage: isCurrentUser
                    ? (_userAvatar != null && _userAvatar!.isNotEmpty
                        ? NetworkImage(_userAvatar!)
                        : null)
                    : (contact?.avatar != null && contact!.avatar.isNotEmpty
                        ? NetworkImage(contact.avatar)
                        : null),
                child: (isCurrentUser && (_userAvatar == null || _userAvatar!.isEmpty)) ||
                        (!isCurrentUser &&
                            (contact == null || contact.avatar.isEmpty))
                    ? Text(
                        avatarText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    : null,
              ),
              // 在线状
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _getStatusColor(status),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          // 姓名
          Expanded(
            child: Text(
              displayName,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 群主标识
          if (memberId == group.ownerId)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: const Color(0xFFFFD666), width: 0.5),
              ),
              child: const Text(
                '群主',
                style: TextStyle(fontSize: 10, color: Color(0xFFD46B08)),
              ),
            ),
        ],
      ),
    );
  }

  // 人员详情
  Widget _buildPersonDetail() {
    if (_selectedPerson == null) return const SizedBox();

    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // 头像和基本信
            Row(
              children: [
                // 姓名和状
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _selectedPerson!['name'].length > 9
                                ? '${_selectedPerson!['name'].substring(0, 9)}...'
                                : _selectedPerson!['name'],
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF333333),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.person,
                            color: Color(0xFF4A90E2),
                            size: 20,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _selectedPerson!['status'] == 'online' ? '在线' : '离线',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ],
                  ),
                ),
                // 头像
                _buildAvatar(
                  avatarText: _selectedPerson!['avatar'],
                  avatarUrl: _selectedPerson!['avatarUrl'],
                  isOnline: _selectedPerson!['status'] == 'online',
                  size: 60,
                ),
              ],
            ),
            const SizedBox(height: 32),
            // 详细信息
            _buildInfoItem('签名', _selectedPerson!['work_signature'] ?? '- 未填-'),
            _buildInfoItem('手机', _selectedPerson!['phone'] ?? '- 未填-'),
            _buildInfoItem('座机', '- 未填-'),
            _buildInfoItem('短号', '- 未填-'),
            _buildInfoItem('邮箱', _selectedPerson!['email'] ?? '- 未填-'),
            _buildInfoItem('部门', _selectedPerson!['department'] ?? '- 未填-'),
            _buildInfoItem('职位', _selectedPerson!['position'] ?? '- 未填-'),
            const SizedBox(height: 32),
            // 操作按钮（仅在"联系人"分类下显示）
            if (_selectedContactIndex == 2) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 3,
                    child: FutureBuilder<bool>(
                      future: _checkIfFavoriteContact(_selectedPerson!['id']),
                      builder: (context, snapshot) {
                        final isFavorite = snapshot.data ?? false;
                        return SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _toggleFavoriteContact(
                              _selectedPerson!['id'],
                              _selectedPerson!['name'],
                              isFavorite,
                            ),
                            icon: Icon(
                              isFavorite ? Icons.star : Icons.star_border,
                              size: 16,
                              color: isFavorite ? Colors.amber : null,
                            ),
                            label: Text(
                              isFavorite ? '已添加' : '添加常用联系人',
                              style: const TextStyle(fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isFavorite
                                  ? Colors.amber
                                  : const Color(0xFF666666),
                              side: BorderSide(
                                color: isFavorite
                                    ? Colors.amber.withOpacity(0.5)
                                    : const Color(0xFFE5E5E5),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              minimumSize: Size.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FutureBuilder<bool>(
                      future: _checkIfOnlineNotificationEnabled(_selectedPerson!['id']),
                      builder: (context, snapshot) {
                        final isEnabled = snapshot.data ?? false;
                        return SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _toggleOnlineNotification(
                              _selectedPerson!['id'],
                              _selectedPerson!['name'],
                              isEnabled,
                            ),
                            icon: Icon(
                              isEnabled ? Icons.notifications_active : Icons.notifications_none,
                              size: 16,
                              color: isEnabled ? const Color(0xFF52C41A) : null,
                            ),
                            label: Text(
                              isEnabled ? '已开启' : '上线提醒',
                              style: const TextStyle(fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isEnabled
                                  ? const Color(0xFF52C41A)
                                  : const Color(0xFF666666),
                              side: BorderSide(
                                color: isEnabled
                                    ? const Color(0xFF52C41A).withOpacity(0.5)
                                    : const Color(0xFFE5E5E5),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              minimumSize: Size.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
            ],
          ),
        ),
      ),
    );
  }

  // 信息
  Widget _buildInfoItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
          ),
        ],
      ),
    );
  }

  // ============ 常用联系人和常用群组相关方法 ============

  /// 加载常用数据
  Future<void> _loadFavoriteData(String category) async {
    if (category.isEmpty) return;

    setState(() {
      _isLoadingFavorites = true;
    });

    try {
      final token = _token;
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      if (category == 'contacts') {
        // 加载常用联系
        final response = await ApiService.getFavoriteContacts(token: token);
        if (response['code'] == 0) {
          final List<dynamic> data = response['data'] ?? [];
          setState(() {
            _favoriteContacts = data;
          });
          
          // 🔄 加载完成后，查询这些联系人的在线状态
          if (data.isNotEmpty) {
            _updateFavoriteContactsStatus();
          }
        }
      } else if (category == 'groups') {
        // 加载常用群组
        final response = await ApiService.getFavoriteGroups(token: token);
        if (response['code'] == 0) {
          final List<dynamic> groupIds = response['data'] ?? [];
          
          // 将群组ID转换为完整的群组对象
          final List<Map<String, dynamic>> favoriteGroupsList = [];
          for (var groupId in groupIds) {
            if (groupId is int) {
              // 从现有群组列表中查找
              try {
                final group = _groups.firstWhere((g) => g.id == groupId);
                favoriteGroupsList.add({
                  'group_id': group.id,
                  'name': group.name,
                  'avatar': group.avatar,
                  'member_count': group.memberIds.length,
                });
              } catch (e) {
                logger.debug('⚠️ 常用群组ID $groupId 在当前群组列表中未找到');
              }
            }
          }
          
          setState(() {
            _favoriteGroups = favoriteGroupsList;
          });
        }
      } else if (category == 'notifications') {
        // 加载上线提醒
        final allNotifications = await Storage.getOnlineNotifications();
        
        // 过滤出已开启上线提醒的用户
        final currentUserId = _currentUserId;
        if (currentUserId != null) {
          final prefs = await SharedPreferences.getInstance();
          final filteredNotifications = allNotifications.where((notification) {
            final key = 'online_notification_${currentUserId}_${notification.userId}';
            return prefs.getBool(key) ?? false;
          }).toList();
          
          // 根据用户ID去重，保留每个用户最新的一条通知
          final Map<int, OnlineNotificationModel> uniqueNotifications = {};
          for (var notification in filteredNotifications) {
            final existingNotification = uniqueNotifications[notification.userId];
            // 如果不存在或者当前通知时间更新，则更新
            if (existingNotification == null || 
                notification.onlineTime.isAfter(existingNotification.onlineTime)) {
              uniqueNotifications[notification.userId] = notification;
            }
          }
          
          // 转换为列表并按时间倒序排列
          final deduplicatedNotifications = uniqueNotifications.values.toList()
            ..sort((a, b) => b.onlineTime.compareTo(a.onlineTime));
          
          setState(() {
            _onlineNotifications = deduplicatedNotifications;
          });
          
          logger.debug('📋 上线提醒去重：原始${filteredNotifications.length}条 → 去重后${deduplicatedNotifications.length}条');
        } else {
          setState(() {
            _onlineNotifications = [];
          });
        }
      }
    } catch (e) {
      logger.debug('加载常用数据失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingFavorites = false;
        });
      }
    }
  }

  /// 更新常用联系人的在线状态
  Future<void> _updateFavoriteContactsStatus() async {
    try {
      // 提取所有用户ID
      final userIds = _favoriteContacts
          .where((contact) => contact is Map<String, dynamic>)
          .map((contact) => (contact as Map<String, dynamic>)['user_id'] as int?)
          .where((id) => id != null)
          .cast<int>()
          .toList();

      if (userIds.isEmpty) return;

      logger.debug('🔄 [常用联系人] 查询 ${userIds.length} 个用户的在线状态');

      // 批量查询在线状态
      final token = await Storage.getToken();
      if (token == null) return;

      final response = await ApiService.batchGetOnlineStatus(
        token: token,
        userIds: userIds,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final statusesData = response['data']['statuses'] as Map<String, dynamic>?;
        if (statusesData != null && statusesData.isNotEmpty) {
          // 更新状态
          bool hasChanges = false;
          for (int i = 0; i < _favoriteContacts.length; i++) {
            final contact = _favoriteContacts[i];
            if (contact is Map<String, dynamic>) {
              final userId = contact['user_id'] as int?;
              if (userId == null) continue;

              // 🔒 优先使用WebSocket状态
              final websocketStatus = _websocketUserStatus[userId];
              String? newStatus;
              
              if (websocketStatus != null) {
                newStatus = websocketStatus;
                logger.debug('🔒 [常用联系人] 用户 $userId 使用WebSocket状态: $websocketStatus');
              } else {
                // 尝试从API获取状态
                final userIdStr = userId.toString();
                newStatus = statusesData[userIdStr] as String?;
                if (newStatus == null) {
                  newStatus = statusesData[userId] as String?;
                }
                if (newStatus != null) {
                  logger.debug('📡 [常用联系人] 用户 $userId 使用API状态: $newStatus');
                }
              }

              if (newStatus != null && newStatus != contact['status']) {
                contact['status'] = newStatus;
                hasChanges = true;
              }
            }
          }

          if (hasChanges && mounted) {
            setState(() {
              // 触发UI更新
            });
            logger.debug('✅ [常用联系人] 状态更新完成');
          }
        }
      }
    } catch (e) {
      logger.debug('❌ [常用联系人] 更新状态失败: $e');
    }
  }

  /// 构建常用列表详情（在右侧第三列显示）
  Widget _buildFavoriteListDetail() {
    if (_isLoadingFavorites) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_selectedFavoriteCategory == 'contacts') {
      return _buildFavoriteContactsList();
    } else if (_selectedFavoriteCategory == 'groups') {
      return _buildFavoriteGroupsList();
    } else if (_selectedFavoriteCategory == 'notifications') {
      return _buildOnlineNotificationsList();
    }

    return const Center(
      child: Text('请选择一个分类', style: TextStyle(color: Colors.grey)),
    );
  }

  /// 构建常用联系人列
  Widget _buildFavoriteContactsList() {
    if (_favoriteContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_outline, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              '暂无常用联系人',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              '在联系人详情中点击\n"常用联系按钮添加',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 标题
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.person, color: Color(0xFFFAAD14), size: 20),
              const SizedBox(width: 8),
              const Text(
                '常用联系人',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              Text(
                '${_favoriteContacts.length}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
        // 列表
        Expanded(
          child: ListView.builder(
            itemCount: _favoriteContacts.length,
            itemBuilder: (context, index) {
              final contact = _favoriteContacts[index];
              return _buildFavoriteContactItem(contact);
            },
          ),
        ),
      ],
    );
  }

  /// 构建常用联系人项
  Widget _buildFavoriteContactItem(Map<String, dynamic> contact) {
    final displayName = contact['full_name'] ?? contact['username'] ?? '';
    final avatar = contact['avatar'] ?? '';
    final status = contact['status'] ?? 'offline';
    final isOnline = status == 'online';

    return InkWell(
      onTap: () {
        // 可以添加跳转到聊天或详情的逻辑
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1),
          ),
        ),
        child: Row(
          children: [
            // 头像
            Stack(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFF4A90E2).withOpacity(0.1),
                  backgroundImage: avatar.isNotEmpty
                      ? NetworkImage(avatar)
                      : null,
                  child: avatar.isEmpty
                      ? Text(
                          displayName.length >= 2
                              ? displayName.substring(displayName.length - 2)
                              : displayName,
                          style: const TextStyle(
                            color: Color(0xFF4A90E2),
                            fontSize: 14,
                          ),
                        )
                      : null,
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (contact['work_signature'] != null)
                    Text(
                      contact['work_signature'],
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            // 移除按钮
            IconButton(
              icon: const Icon(Icons.star, color: Colors.amber, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _removeFavoriteContactFromList(contact),
              tooltip: '移除',
            ),
          ],
        ),
      ),
    );
  }

  /// 构建常用群组列表
  Widget _buildFavoriteGroupsList() {
    if (_favoriteGroups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.group_outlined, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              '暂无常用群组',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              '在群组详情中点击\n"常用"按钮添加',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 标题
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.people, color: Color(0xFF4A90E2), size: 20),
              const SizedBox(width: 8),
              const Text(
                '常用群组',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              Text(
                '${_favoriteGroups.length}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
        // 列表
        Expanded(
          child: ListView.builder(
            itemCount: _favoriteGroups.length,
            itemBuilder: (context, index) {
              final group = _favoriteGroups[index];
              return _buildFavoriteGroupItem(group);
            },
          ),
        ),
      ],
    );
  }

  /// 构建常用群组
  Widget _buildFavoriteGroupItem(Map<String, dynamic> group) {
    final name = group['name'] ?? '';
    final avatar = group['avatar'];
    final groupId = group['id'] as int?;

    return InkWell(
      onTap: () {
        // 可以添加跳转到群聊或详情的逻辑
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1),
          ),
        ),
        child: Row(
          children: [
            // 头像
            CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF4A90E2).withOpacity(0.1),
              backgroundImage: avatar != null && avatar.isNotEmpty
                  ? NetworkImage(avatar)
                  : null,
              child: avatar == null || avatar.isEmpty
                  ? Text(
                      name.length >= 2 ? name.substring(name.length - 2) : name,
                      style: const TextStyle(
                        color: Color(0xFF4A90E2),
                        fontSize: 14,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (groupId != null)
                    FutureBuilder<int>(
                      future: _getGroupMemberCount(groupId),
                      builder: (context, snapshot) {
                        final memberCount = snapshot.data ?? 0;
                        return Text(
                          '$memberCount 人',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            // 移除按钮
            IconButton(
              icon: const Icon(Icons.star, color: Colors.amber, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _removeFavoriteGroupFromList(group),
              tooltip: '移除',
            ),
          ],
        ),
      ),
    );
  }

  /// 构建上线提醒列表
  Widget _buildOnlineNotificationsList() {
    if (_onlineNotifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.notifications_outlined,
              size: 60,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无上线提醒',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              '当您的联系人上线时\n会在这里显示',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 标题
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.notifications,
                color: Color(0xFF52C41A),
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text(
                '上线提醒',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              Text(
                '${_onlineNotifications.length}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
        // 列表
        Expanded(
          child: ListView.builder(
            itemCount: _onlineNotifications.length,
            itemBuilder: (context, index) {
              final notification = _onlineNotifications[index];
              return _buildOnlineNotificationItem(notification);
            },
          ),
        ),
      ],
    );
  }

  /// 构建上线提醒
  Widget _buildOnlineNotificationItem(OnlineNotificationModel notification) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF5F5F5), width: 1)),
      ),
      child: Row(
        children: [
          // 头像
          Stack(
            children: [
              // 显示头像或默认头
              notification.avatar != null && notification.avatar!.isNotEmpty
                  ? CircleAvatar(
                      radius: 20,
                      backgroundImage: NetworkImage(notification.avatar!),
                      backgroundColor: const Color(0xFF4A90E2),
                      onBackgroundImageError: (_, __) {
                        // 图片加载失败时显示文字头像
                      },
                      child: notification.avatar!.isEmpty
                          ? Text(
                              notification.avatarText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            )
                          : null,
                    )
                  : CircleAvatar(
                      radius: 20,
                      backgroundColor: const Color(0xFF4A90E2),
                      child: Text(
                        notification.avatarText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
              // 在线状态指示器
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // 用户信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 显示用户名（优先full_name
                Text(
                  notification.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF333333),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // 显示上线时间
                Text(
                  notification.formattedTime,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
            ),
          ),
          // 可以添加点击查看按钮
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, size: 20),
            color: const Color(0xFF999999),
            onPressed: () {
              // 点击后打开与该用户的聊天窗
              _openChatWithUser(notification.userId);
            },
            tooltip: '发送消息',
          ),
        ],
      ),
    );
  }

  // 打开与指定用户的聊天窗口
  void _openChatWithUser(int userId) {
    logger.debug('📱 从上线提醒打开聊天: 用户ID=$userId');

    // 切换到消息页
    setState(() {
      _selectedMenuIndex = 0;
    });

    // 在最近联系人列表中查找该用户
    final contactIndex = _recentContacts.indexWhere((c) => c.userId == userId);

    if (contactIndex != -1) {
      // 如果在最近联系人中找到了，直接选中
      setState(() {
        _selectedChatIndex = contactIndex;
        _currentChatUserId = userId;
        _isCurrentChatGroup = false;
      });
      _loadMessageHistory(userId, isGroup: false);
    } else {
      // 如果不在最近联系人中，从联系人列表查找
      final contactInfo = _contacts.firstWhere(
        (c) => c.friendId == userId,
        orElse: () {
          logger.debug('⚠️ 在联系人列表中未找到用户ID: $userId');
          return ContactModel(
            relationId: 0,
            userId: 0,
            friendId: userId,
            username: '未知用户',
            fullName: null,
            avatar: '',
            workSignature: null,
            status: 'offline',
            phone: null,
            email: null,
            department: null,
            position: null,
            createdAt: DateTime.now(),
          );
        },
      );

      // 创建RecentContactModel并添加到最近联系人列表
      final recentContact = RecentContactModel(
        type: 'user', // 明确指定为用户类型
        userId: contactInfo.friendId,
        username: contactInfo.username,
        fullName: contactInfo.fullName ?? '',
        lastMessageTime: DateTime.now().toIso8601String(), // 使用当前时间而不是空字符串
        lastMessage: '暂无消息', // 使用默认消息而不是空字符串
        status: contactInfo.status,
      );

      setState(() {
        _recentContacts.insert(0, recentContact);
        _selectedChatIndex = 0;
        _currentChatUserId = userId;
        _isCurrentChatGroup = false;
      });
      _loadMessageHistory(userId, isGroup: false);
    }
  }

  /// 从列表中移除常用联系
  Future<void> _removeFavoriteContactFromList(
    Map<String, dynamic> contact,
  ) async {
    final contactId = contact['contact_id'] as int;
    final displayName = contact['full_name'] ?? contact['username'] ?? '';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认移除'),
        content: Text('确定要将 $displayName 从常用联系人中移除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final token = _token;
      if (token == null) return;

      final response = await ApiService.removeFavoriteContact(
        token: token,
        contactId: contactId,
      );

      if (response['code'] == 0) {
        setState(() {
          _favoriteContacts.removeWhere((c) => c['contact_id'] == contactId);
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('移除成功')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除失败: $e')));
      }
    }
  }

  /// 从列表中移除常用群组
  Future<void> _removeFavoriteGroupFromList(Map<String, dynamic> group) async {
    final groupId = group['group_id'] as int;
    final name = group['name'] ?? '';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认移除'),
        content: Text('确定要将 $name 从常用群组中移除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final token = _token;
      if (token == null) return;

      final response = await ApiService.removeFavoriteGroup(
        token: token,
        groupId: groupId,
      );

      if (response['code'] == 0) {
        setState(() {
          _favoriteGroups.removeWhere((g) => g['group_id'] == groupId);
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('移除成功')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除失败: $e')));
      }
    }
  }

  /// 检查是否为常用联系
  Future<bool> _checkIfFavoriteContact(int contactId) async {
    try {
      final token = _token;
      if (token == null) return false;

      final response = await ApiService.checkFavoriteContact(
        token: token,
        contactId: contactId,
      );

      if (response['code'] == 0) {
        return response['data']['is_favorite'] as bool;
      }
      return false;
    } catch (e) {
      logger.debug('检查常用联系人失败: $e');
      return false;
    }
  }

  /// 切换常用联系人状
  Future<void> _toggleFavoriteContact(
    int contactId,
    String name,
    bool isFavorite,
  ) async {
    try {
      final token = _token;
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      if (isFavorite) {
        // 移除常用联系
        final response = await ApiService.removeFavoriteContact(
          token: token,
          contactId: contactId,
        );

        if (response['code'] == 0) {
          if (mounted) {
            setState(() {
              // 刷新UI
            });
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已将 $name 从常用联系人中移除')));
          }
        } else {
          throw Exception(response['message'] ?? '移除失败');
        }
      } else {
        // 添加常用联系
        final response = await ApiService.addFavoriteContact(
          token: token,
          contactId: contactId,
        );

        if (response['code'] == 0) {
          if (mounted) {
            setState(() {
              // 刷新UI
            });
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已将 $name 添加到常用联系人')));
          }
        } else {
          throw Exception(response['message'] ?? '添加失败');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败: $e')));
      }
    }
  }

  /// 检查是否已开启上线提醒
  Future<bool> _checkIfOnlineNotificationEnabled(int userId) async {
    try {
      final currentUserId = _currentUserId;
      if (currentUserId == null) return false;

      // 从本地存储获取上线提醒配置
      final prefs = await SharedPreferences.getInstance();
      final key = 'online_notification_${currentUserId}_$userId';
      return prefs.getBool(key) ?? false;
    } catch (e) {
      logger.debug('检查上线提醒失败: $e');
      return false;
    }
  }

  /// 切换上线提醒状态
  Future<void> _toggleOnlineNotification(
    int userId,
    String userName,
    bool isEnabled,
  ) async {
    try {
      final currentUserId = _currentUserId;
      if (currentUserId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先登录')),
          );
        }
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final key = 'online_notification_${currentUserId}_$userId';

      if (isEnabled) {
        // 关闭上线提醒
        await prefs.remove(key);
        
        // 从Storage中删除该用户的上线通知记录
        await Storage.removeOnlineNotification(userId);
        
        if (mounted) {
          setState(() {
            // 从上线提醒列表中移除
            _onlineNotifications.removeWhere((n) => n.userId == userId);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已关闭 $userName 的上线提醒')),
          );
        }
      } else {
        // 开启上线提醒
        await prefs.setBool(key, true);
        
        // 从联系人列表或选中的人员中获取用户信息
        String? userStatus;
        String? username;
        String? avatarUrl;
        
        // 优先从选中的人员获取
        if (_selectedPerson != null && _selectedPerson!['id'] == userId) {
          userStatus = _selectedPerson!['status'];
          username = _selectedPerson!['username'];
          avatarUrl = _selectedPerson!['avatarUrl'];
        } else {
          // 从联系人列表查找
          final contact = _contacts.firstWhere(
            (c) => c.friendId == userId,
            orElse: () => ContactModel(
              relationId: 0,
              userId: 0,
              friendId: userId,
              username: userName,
              fullName: userName,
              avatar: '',
              status: 'offline',
              createdAt: DateTime.now(),
            ),
          );
          userStatus = contact.status;
          username = contact.username;
          avatarUrl = contact.avatar;
        }
        
        // 如果用户当前在线，立即添加到上线提醒列表
        if (userStatus == 'online') {
          final notification = OnlineNotificationModel(
            userId: userId,
            username: username ?? userName,
            fullName: userName,
            avatar: avatarUrl ?? '',
            onlineTime: DateTime.now(),
          );
          
          await Storage.addOnlineNotification(notification);
          
          if (mounted) {
            setState(() {
              // 刷新上线提醒列表
              _onlineNotifications.insert(0, notification);
            });
          }
        }
        
        if (mounted) {
          setState(() {
            // 刷新UI
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已开启 $userName 的上线提醒')),
          );
        }
      }
      
      // 如果当前正在查看上线提醒列表，刷新数据
      if (_selectedFavoriteCategory == 'notifications') {
        _loadFavoriteData('notifications');
      }
    } catch (e) {
      logger.debug('切换上线提醒失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  /// 检查是否为常用群组
  Future<bool> _checkIfFavoriteGroup(int groupId) async {
    try {
      final token = _token;
      if (token == null) return false;

      final response = await ApiService.checkFavoriteGroup(
        token: token,
        groupId: groupId,
      );

      if (response['code'] == 0) {
        return response['data']['is_favorite'] as bool;
      }
      return false;
    } catch (e) {
      logger.debug('检查常用群组失 $e');
      return false;
    }
  }

  /// 切换常用群组状
  Future<void> _toggleFavoriteGroup(int groupId, bool isFavorite) async {
    try {
      final token = _token;
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      if (isFavorite) {
        // 移除常用群组
        final response = await ApiService.removeFavoriteGroup(
          token: token,
          groupId: groupId,
        );

        if (response['code'] == 0) {
          if (mounted) {
            setState(() {
              // 刷新UI
            });
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已从常用群组中移除')));
          }
        } else {
          throw Exception(response['message'] ?? '移除失败');
        }
      } else {
        // 添加常用群组
        final response = await ApiService.addFavoriteGroup(
          token: token,
          groupId: groupId,
        );

        if (response['code'] == 0) {
          if (mounted) {
            setState(() {
              // 刷新UI
            });
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已添加到常用群组')));
          }
        } else {
          throw Exception(response['message'] ?? '添加失败');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败: $e')));
      }
    }
  }

  // ============ 多选模式相关方============

  // 显示多选转发对话框
  void _showMultiSelectForwardDialog() {
    if (_selectedMessageIds.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => _ForwardDialog(
        currentUserId: _currentChatUserId,
        recentContacts: _recentContacts,
        onConfirm: (selectedContacts) {
          _forwardMessages(selectedContacts);
        },
      ),
    );
  }

  // 转发消息
  Future<void> _forwardMessages(List<int> targetUserIds) async {
    if (_selectedMessageIds.isEmpty || targetUserIds.isEmpty) return;

    try {
      // 获取要转发的消息列表
      final messagesToForward = _messages
          .where((msg) => _selectedMessageIds.contains(msg.id))
          .toList();

      // 按时间顺序排
      messagesToForward.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      int successCount = 0;
      int totalCount = targetUserIds.length * messagesToForward.length;

      // 逐个联系人转
      for (final targetUserId in targetUserIds) {
        // 逐条消息转发
        for (final message in messagesToForward) {
          // 使用 WebSocket 发送消
          final success = await _wsService.sendMessage(
            receiverId: targetUserId,
            content: message.content,
            messageType: message.messageType,
            fileName: message.fileName,
          );

          if (success) {
            successCount++;
          }

          // 添加小延迟，避免发送过
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      if (successCount == totalCount) {
        _showSnackBar('转发成功（已转发 $totalCount 条消息）');
      } else {
        _showSnackBar('部分转发成功 $successCount/$totalCount');
      }

      // 退出多选模
      setState(() {
        _isMultiSelectMode = false;
        _selectedMessageIds.clear();
      });
    } catch (e) {
      logger.debug('转发消息失败: $e');
      _showSnackBar('转发失败e');
    }
  }

  // 收藏选中的消息（合并为一条收藏）
  Future<void> _favoriteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    try {
      final token = _token;
      if (token == null) {
        _showSnackBar('未登录，请先登录');
        return;
      }

      // 从消息列表中提取选中消息的完整信息
      final selectedMessages = _messages
          .where((msg) => _selectedMessageIds.contains(msg.id))
          .map(
            (msg) => {
              'message_id': msg.id,
              'content': msg.content,
              'message_type': msg.messageType,
              'file_name': msg.fileName,
              'sender_id': msg.senderId,
              'sender_name': msg.senderName,
            },
          )
          .toList();

      // 调用批量收藏API
      final response = await ApiService.createBatchFavorite(
        token: token,
        messages: selectedMessages,
      );

      if (response['code'] == 0) {
        _showSnackBar(response['message'] ?? '已保存到收藏');
      } else {
        _showSnackBar(response['message'] ?? '收藏失败');
      }

      // 退出多选模
      setState(() {
        _isMultiSelectMode = false;
        _selectedMessageIds.clear();
      });
    } catch (e) {
      logger.debug('收藏消息失败: $e');
      _showSnackBar('收藏失败e');
    }
  }

  // 删除选中的消
  Future<void> _deleteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    // 显示确认对话
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中${_selectedMessageIds.length} 条消息吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE74C3C),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final token = _token;
      if (token == null) {
        _showSnackBar('未登录，请先登录');
        return;
      }

      // 批量删除
      final response = await ApiService.batchDeleteMessages(
        token: token,
        messageIds: _selectedMessageIds.toList(),
      );

      // 获取删除结果
      final data = response['data'] ?? {};
      final successCount = data['success_count'] ?? 0;
      final failedCount = data['failed_count'] ?? 0;

      if (successCount > 0) {
        _showSnackBar(
          '已删$successCount 条消息${failedCount > 0 ? '$failedCount 条删除失败' : '全部删除成功'}',
        );

        // 从本地列表中移除已删除的消息
        setState(() {
          _messages.removeWhere((msg) => _selectedMessageIds.contains(msg.id));
          _isMultiSelectMode = false;
          _selectedMessageIds.clear();
        });

        // 刷新最近联系人列表，以更新最新消息显示
        _loadRecentContacts();
      } else {
        _showSnackBar('删除失败');
      }
    } catch (e) {
      logger.debug('删除消息失败: $e');
      _showSnackBar('删除失败e');
    }
  }

  // 显示提示信息
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // 构建资讯页面
  Widget _buildNewsPage() {
    return Expanded(
      child: Column(
        children: [
          // 导航栏
          _buildNavigationBar(),
          // 加载进度条
          if (_currentTab?.isLoading ?? false)
            const LinearProgressIndicator(minHeight: 3),
          // WebView 内容展示区域
          Expanded(child: _buildWebView()),
        ],
      ),
    );
  }

  // 构建标签栏
  Widget _buildTabBar() {
    return Container(
      height: 40,
      color: Colors.grey.shade200,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) {
                final tab = _tabs[index];
                final isActive = index == _currentTabIndex;
                return _buildTab(tab, index, isActive);
              },
            ),
          ),
          // 新建标签页按钮
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _addNewTab('https://www.baidu.com'),
              child: Container(
                width: 40,
                alignment: Alignment.center,
                child: const Icon(Icons.add, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(_BrowserTab tab, int index, bool isActive) {
    return GestureDetector(
      onTap: () => _switchTab(index),
      child: Container(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.grey.shade300,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            if (tab.isLoading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.public, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tab.title,
                style: TextStyle(
                  fontSize: 12,
                  color: isActive ? Colors.black : Colors.grey.shade700,
                  fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            // 关闭按钮
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _closeTab(index),
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  // 构建导航栏
  Widget _buildNavigationBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            spreadRadius: 0,
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 22),
            onPressed: _canGoBack ? _goBack : null,
            tooltip: '后退',
            padding: const EdgeInsets.all(8),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward, size: 22),
            onPressed: _canGoForward ? _goForward : null,
            tooltip: '前进',
            padding: const EdgeInsets.all(8),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _reload,
            tooltip: '刷新',
            padding: const EdgeInsets.all(8),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    if (_currentTab == null) {
      return const Center(child: Text('没有打开的标签页'));
    }

    if (_isWindows) {
      if (_currentTab!.windowsController == null) {
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在初始化WebView...'),
              SizedBox(height: 8),
              Text(
                '提示：Windows 需要安装WebView2 运行时',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        );
      }
      return win_webview.Webview(_currentTab!.windowsController!);
    } else {
      if (_currentTab!.mobileController == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return WebViewWidget(controller: _currentTab!.mobileController!);
    }
  }

  // 显示图片查看器（全屏查看，支持缩放和平移）
  void _showImageViewer(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (BuildContext dialogContext) {
        return _ImageViewerDialog(imageUrl: imageUrl);
      },
    );
  }

  // 显示视频查看器（全屏播放）
  void _showVideoViewer(BuildContext context, String videoUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (BuildContext dialogContext) {
        return _VideoViewerDialog(videoUrl: videoUrl);
      },
    );
  }

  // 🔴 已删除：处理群组语音通话邀请成员的通知方法
  // 不再需要此功能，邀请消息由服务器API直接推送
}

// ============ 图片查看器对话框 ============
class _ImageViewerDialog extends StatefulWidget {
  final String imageUrl;

  const _ImageViewerDialog({required this.imageUrl});

  @override
  State<_ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<_ImageViewerDialog> {
  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  // 处理双击缩放
  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _handleDoubleTap() {
    if (_doubleTapDetails == null) return;

    final Matrix4 currentMatrix = _transformationController.value;
    final double currentScale = currentMatrix.getMaxScaleOnAxis();

    Matrix4 newMatrix;
    if (currentScale > 1.0) {
      // 如果已经放大，则重置为原始大小
      newMatrix = Matrix4.identity();
    } else {
      // 放大到2倍，并以双击位置为中心
      final position = _doubleTapDetails!.localPosition;
      newMatrix = Matrix4.identity()
        ..translate(-position.dx, -position.dy)
        ..scale(2.0)
        ..translate(position.dx, position.dy);
    }

    _transformationController.value = newMatrix;
  }

  // 放大
  void _zoomIn() {
    final Matrix4 currentMatrix = _transformationController.value;
    final double currentScale = currentMatrix.getMaxScaleOnAxis();

    if (currentScale >= 4.0) return; // 已达到最大缩放

    final double newScale = (currentScale * 1.5).clamp(0.5, 4.0);
    final double scaleFactor = newScale / currentScale;

    // 以屏幕中心为缩放中心
    final Size screenSize = MediaQuery.of(context).size;
    final Offset center = Offset(screenSize.width / 2, screenSize.height / 2);

    // 获取当前的平移量
    final double translationX = currentMatrix.storage[12];
    final double translationY = currentMatrix.storage[13];

    // 计算以屏幕中心为缩放中心的新平移量
    // 公式：newTranslation = center + scaleFactor * (oldTranslation - center)
    // 这样可以让屏幕中心点对应的图片位置保持不变
    final double newTranslationX =
        center.dx + scaleFactor * (translationX - center.dx);
    final double newTranslationY =
        center.dy + scaleFactor * (translationY - center.dy);

    // 创建新的变换矩阵：先缩放，再平移
    // InteractiveViewer 的变换顺序是：先 scale，再 translate
    final Matrix4 newMatrix = Matrix4.identity()
      ..scale(newScale)
      ..translate(newTranslationX / newScale, newTranslationY / newScale);

    _transformationController.value = newMatrix;
  }

  // 缩小
  void _zoomOut() {
    final Matrix4 currentMatrix = _transformationController.value;
    final double currentScale = currentMatrix.getMaxScaleOnAxis();

    if (currentScale <= 0.5) return; // 已达到最小缩放

    final double newScale = (currentScale / 1.5).clamp(0.5, 4.0);
    final double scaleFactor = newScale / currentScale;

    // 以屏幕中心为缩放中心
    final Size screenSize = MediaQuery.of(context).size;
    final Offset center = Offset(screenSize.width / 2, screenSize.height / 2);

    // 获取当前的平移量
    final double translationX = currentMatrix.storage[12];
    final double translationY = currentMatrix.storage[13];

    // 计算以屏幕中心为缩放中心的新平移量
    // 公式：newTranslation = center + scaleFactor * (oldTranslation - center)
    // 这样可以让屏幕中心点对应的图片位置保持不变
    final double newTranslationX =
        center.dx + scaleFactor * (translationX - center.dx);
    final double newTranslationY =
        center.dy + scaleFactor * (translationY - center.dy);

    // 创建新的变换矩阵：先缩放，再平移
    // InteractiveViewer 的变换顺序是：先 scale，再 translate
    final Matrix4 newMatrix = Matrix4.identity()
      ..scale(newScale)
      ..translate(newTranslationX / newScale, newTranslationY / newScale);

    _transformationController.value = newMatrix;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 图片查看器主体
          Center(
            child: GestureDetector(
              onDoubleTapDown: _handleDoubleTapDown,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _transformationController,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.network(
                  widget.imageUrl,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) {
                      return child;
                    }
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                : null,
                            color: Colors.white,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            loadingProgress.expectedTotalBytes != null
                                ? '${(loadingProgress.cumulativeBytesLoaded / 1024 / 1024).toStringAsFixed(1)} MB / ${(loadingProgress.expectedTotalBytes! / 1024 / 1024).toStringAsFixed(1)} MB'
                                : '加载中...',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.broken_image,
                            size: 80,
                            color: Colors.white54,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '图片加载失败',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          // 关闭按钮
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              onPressed: () {
                Navigator.of(context).pop();
              },
              tooltip: '关闭',
            ),
          ),
          // 放大/缩小按钮
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 放大按钮
                    IconButton(
                      icon: const Icon(
                        Icons.zoom_in,
                        color: Colors.white70,
                        size: 24,
                      ),
                      onPressed: _zoomIn,
                      tooltip: '放大',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                    // 缩小按钮
                    IconButton(
                      icon: const Icon(
                        Icons.zoom_out,
                        color: Colors.white70,
                        size: 24,
                      ),
                      onPressed: _zoomOut,
                      tooltip: '缩小',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============ 视频缩略图组件 ============
class _VideoThumbnailWidget extends StatefulWidget {
  final File videoFile;

  const _VideoThumbnailWidget({required this.videoFile});

  @override
  State<_VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<_VideoThumbnailWidget> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      _controller = VideoPlayerController.file(widget.videoFile);
      await _controller!.initialize();
      // 暂停在第一帧，不播放
      await _controller!.pause();
      await _controller!.seekTo(Duration.zero);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Colors.black87,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        ),
      );
    }

    if (_hasError || _controller == null || !_controller!.value.isInitialized) {
      return Stack(
        children: [
          Container(
            color: Colors.black87,
            child: const Center(
              child: Icon(Icons.videocam, color: Colors.white70, size: 24),
            ),
          ),
          const Center(
            child: Icon(
              Icons.play_circle_outline,
              color: Colors.white,
              size: 32,
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        // 视频第一帧
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          ),
        ),
        // 播放图标覆盖层
        Container(
          color: Colors.black.withOpacity(0.3),
          child: const Center(
            child: Icon(
              Icons.play_circle_outline,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
      ],
    );
  }
}

// ============ 视频查看器对话框 ============
class _VideoViewerDialog extends StatefulWidget {
  final String videoUrl;

  const _VideoViewerDialog({required this.videoUrl});

  @override
  State<_VideoViewerDialog> createState() => _VideoViewerDialogState();
}

class _VideoViewerDialogState extends State<_VideoViewerDialog> {
  // 参考 example 实现：移动端使用 video_player + chewie
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;

  // Windows 使用 WebView（参考 example 实现）
  win_webview.WebviewController? _windowsWebViewController;

  bool _isInitialized = false;
  String? _errorMessage;
  bool _isWindows = !kIsWeb && Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      if (_isWindows) {
        // Windows 平台使用 WebView
        await _initializeWindowsWebView();
      } else {
        // 移动端使用 video_player + chewie
        await _initializeMobileVideoPlayer();
      }

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _initializeMobileVideoPlayer() async {
    // 创建VideoPlayerController（参考 example 实现）
    _videoPlayerController = VideoPlayerController.networkUrl(
      Uri.parse(widget.videoUrl),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );

    // 初始化视频播放器
    await _videoPlayerController!.initialize();

    // 创建ChewieController（参考 example 实现）
    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController!,
      autoPlay: true, // 自动播放
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      allowPlaybackSpeedChanging: true,
      showControls: true,
      aspectRatio: _videoPlayerController!.value.aspectRatio,
      errorBuilder: (context, errorMessage) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 48),
              const SizedBox(height: 16),
              Text(
                '视频加载失败: $errorMessage',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );

    // 确保视频自动播放（显式调用播放方法）
    if (mounted && _videoPlayerController != null) {
      await _videoPlayerController!.play();
    }
  }

  // 创建播放视频的 HTML 内容（参考 example 实现）
  String _createVideoHtml(String videoUrl) {
    // 对视频URL进行HTML属性值转义，只转义引号，保持URL中的特殊字符（如&、?、=等）不变
    final escapedUrl = videoUrl.replaceAll('"', '&quot;');

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      margin: 0;
      padding: 0;
      background: black;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
    }
    video {
      max-width: 100%;
      max-height: 100%;
      width: auto;
      height: auto;
    }
  </style>
</head>
<body>
  <video controls autoplay preload="auto" playsinline muted>
    <source src="$escapedUrl" type="video/mp4">
    <source src="$escapedUrl" type="video/webm">
    <source src="$escapedUrl" type="video/ogg">
    您的浏览器不支持视频播放。
  </video>
  <script>
    const video = document.querySelector('video');
    // 确保视频自动播放
    video.addEventListener('loadeddata', function() {
      video.play().catch(function(error) {
        console.log('自动播放失败，可能需要用户交互:', error);
      });
    });
    video.addEventListener('error', function(e) {
      console.error('视频加载错误:', e);
    });
    video.addEventListener('loadstart', function() {
      console.log('开始加载视频');
    });
    video.addEventListener('canplay', function() {
      console.log('视频可以播放');
      // 再次尝试播放，确保自动播放
      video.play().catch(function(error) {
        console.log('自动播放失败:', error);
      });
    });
  </script>
</body>
</html>
''';
  }

  Future<void> _initializeWindowsWebView() async {
    if (Platform.isWindows) {
      // Windows 平台使用 WebView（参考 example 实现）
      try {
        _windowsWebViewController = win_webview.WebviewController();
        await _windowsWebViewController!.initialize();

        // 创建 HTML 页面，使用 video 标签播放视频（参考 example 实现）
        final htmlContent = _createVideoHtml(widget.videoUrl);

        // 使用 data URI 加载 HTML 内容（参考 example 实现）
        final dataUri =
            'data:text/html;charset=utf-8,${Uri.encodeComponent(htmlContent)}';
        await _windowsWebViewController!.loadUrl(dataUri);
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'WebView 初始化失败: $e';
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // 参考 example 实现：确保所有资源都被正确释放
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    _windowsWebViewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 视频查看器主体
          Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 800),
              child: _buildVideoContent(),
            ),
          ),
          // 关闭按钮
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              onPressed: () {
                Navigator.of(context).pop();
              },
              tooltip: '关闭',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoContent() {
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            const Text(
              '视频加载失败',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (!_isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _isWindows
            ? _buildWindowsVideoPlayer()
            : _buildMobileVideoPlayer(),
      ),
    );
  }

  Widget _buildWindowsVideoPlayer() {
    if (_windowsWebViewController == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return win_webview.Webview(_windowsWebViewController!);
  }

  Widget _buildMobileVideoPlayer() {
    // 参考 example 实现：移动端优先使用 Chewie 播放器
    if (_chewieController != null) {
      return Chewie(controller: _chewieController!);
    } else {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
  }
}

// ============ 标签页数据类 ============
class _BrowserTab {
  final String id;
  String url;
  String title;
  WebViewController? mobileController;
  win_webview.WebviewController? windowsController;
  bool isLoading = false;

  _BrowserTab({required this.id, required this.url, this.title = '新标签页'});
}

// ============ 转发对话============
class _ForwardDialog extends StatefulWidget {
  final int? currentUserId;
  final List<RecentContactModel> recentContacts;
  final Function(List<int>) onConfirm;

  const _ForwardDialog({
    required this.currentUserId,
    required this.recentContacts,
    required this.onConfirm,
  });

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  final Set<int> _selectedUserIds = {};

  @override
  Widget build(BuildContext context) {
    // 按类型分组：联系人和群组
    final userContacts = widget.recentContacts
        .where((contact) => !contact.isGroup)
        // 仅对用户类型过滤当前聊天对象
        .where((contact) => contact.userId != widget.currentUserId)
        .toList();

    final groupContacts = widget.recentContacts
        .where((contact) => contact.isGroup)
        .toList();

    return AlertDialog(
      title: const Text('选择转发对象'),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      content: SizedBox(
        width: 400,
        height: 500,
        child: (userContacts.isEmpty && groupContacts.isEmpty)
            ? const Center(
                child: Text(
                  '暂无可转发的联系人或群组',
                  style: TextStyle(color: Color(0xFF999999)),
                ),
              )
            : ListView(
                children: [
                  if (userContacts.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        '联系人',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    ...userContacts.map(_buildContactTile),
                  ],

                  if (groupContacts.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        '群组',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    ...groupContacts.map(_buildContactTile),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _selectedUserIds.isEmpty
              ? null
              : () {
                  widget.onConfirm(_selectedUserIds.toList());
                  Navigator.pop(context);
                },
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF4A90E2)),
          child: Text(
            '确认${_selectedUserIds.isNotEmpty ? '(${_selectedUserIds.length})' : ''}',
          ),
        ),
      ],
    );
  }

  Widget _buildContactTile(RecentContactModel contact) {
    final isSelected = _selectedUserIds.contains(contact.userId);

    return CheckboxListTile(
      value: isSelected,
      onChanged: (value) {
        setState(() {
          if (value == true) {
            _selectedUserIds.add(contact.userId);
          } else {
            _selectedUserIds.remove(contact.userId);
          }
        });
      },
      title: Text(contact.displayName),
      subtitle: !contact.isGroup && contact.username.isNotEmpty
          ? Text('@${contact.username}')
          : null,
      secondary: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF4A90E2),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          contact.displayName.length >= 2
              ? contact.displayName.substring(contact.displayName.length - 2)
              : contact.displayName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      activeColor: const Color(0xFF4A90E2),
    );
  }
}
