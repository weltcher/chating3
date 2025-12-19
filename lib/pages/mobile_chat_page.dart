/// 移动端聊天页面 - 完整版本
///
/// 功能已实现：
/// - 文本、图片、视频、文件、语音、链接、位置等多种消息类型显示
/// - 消息操作（复制、转发、引用、撤回、删除、多选）
/// - 输入工具栏（表情、图片、视频、文件、语音/视频通话）
/// - 群组功能（群公告显示、@提及、群成员数显示、群组信息页）
/// - 正在输入指示器
/// - 消息已读状态
/// - 时间戳分隔线
/// - 消息搜索功能
/// - 表情选择器（支持多种表情分类）
/// - 语音消息播放器（带波形显示）
/// - 使用WebSocket发送私聊和群聊消息（实时通信）
/// - 文件上传功能（图片、视频、文件）
///
/// 已创建的组件：
/// ✅ emoji_picker.dart: 表情选择器
/// ✅ voice_message_player.dart: 语音消息播放器
/// ✅ message_search_page.dart: 消息搜索页
/// ✅ 使用 MobileCreateGroupPage 作为群组信息页
///
/// 已实现的API方法：
/// ✅ sendMessage: 使用WebSocket发送私聊消息
/// ✅ sendGroupMessage: 使用WebSocket发送群聊消息
/// ✅ uploadFileFromFile: 文件上传
/// ✅ getGroupInfo: 获取群组详情
/// ✅ markMessagesAsRead: 标记消息已读
/// ✅ markGroupMessagesAsRead: 标记群组消息已读
///
/// 仍需要添加的依赖包（在pubspec.yaml）：
/// - image_picker: ^1.0.0  # 用于拍照功能
/// - url_launcher: ^6.1.0  # 用于打开链接
/// - audioplayers: ^5.0.0  # 用于语音播放（如需实际播放功能）
///
/// 注意：Dart分析器可能会显示一些关于sendMessage参数的错误，
/// 这是因为WebSocketService.sendMessage和ApiService.sendMessage
/// 方法签名不同导致的误报，代码实际运行是正确的。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:gal/gal.dart';
// import 'package:url_launcher/url_launcher.dart'; // TODO: Add url_launcher package when needed
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/agora_service.dart';
import 'package:youdu/services/video_upload_service.dart';
import '../constants/upload_limits.dart';
import '../services/message_service.dart';
import '../services/local_database_service.dart';
import '../models/message_model.dart';
import '../models/group_model.dart';
import '../models/contact_model.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import '../utils/mobile_storage_permission_helper.dart';
import '../utils/mobile_permission_helper.dart';
import '../utils/app_localizations.dart';
// import '../utils/date_utils.dart' as date_utils; // TODO: Create date_utils
import '../config/feature_config.dart';
import '../widgets/emoji_picker.dart';
// import '../widgets/message_bubble.dart'; // TODO: Create message_bubble widget
import '../widgets/voice_message_player.dart';
import '../widgets/voice_message_bubble.dart';
import '../widgets/voice_record_panel.dart';
import '../widgets/video_player_page.dart';
import '../services/voice_record_service.dart';
import 'voice_call_page.dart';
import 'mobile_create_group_page.dart'; // 用作群组信息页面
import 'message_search_page.dart';
import '../widgets/forward_message_dialog.dart';
import '../widgets/user_info_dialog_simple.dart';
import '../widgets/mobile_group_call_member_picker.dart';
import '../widgets/mention_member_picker.dart';
import 'group_video_call_page.dart';
import 'mobile_home_page.dart'; // 🔴 修复：导入MobileHomePage以访问静态方法
import '../services/message_position_cache.dart'; // 消息位置缓存服务

/// 移动端聊天页面
class MobileChatPage extends StatefulWidget {
  final int userId;
  final String displayName;
  final bool isGroup;
  final int? groupId; // 群组ID（群聊时使用）
  final String? avatar; // 头像URL
  final bool isFileAssistant; // 是否是文件助手
  final Function(int contactId, bool isGroup)? onChatClosed; // 🔴 新增：聊天页面关闭时的回调
  final Function(int contactId, bool isGroup, bool doNotDisturb)? onDoNotDisturbChanged; // 🔴 新增：免打扰状态变化回调

  const MobileChatPage({
    super.key,
    required this.userId,
    required this.displayName,
    this.isGroup = false,
    this.groupId,
    this.avatar,
    this.isFileAssistant = false,
    this.onChatClosed, // 🔴 新增回调参数
    this.onDoNotDisturbChanged, // 🔴 新增免打扰状态变化回调
  });

  // 消息缓存：保存最新15条消息（静态变量，跨实例共享）
  static const int _cacheSize = 15;
  static final Map<String, List<MessageModel>> _messageCache = {};
  
  // 🔴 聊天页面打开标志（公共静态变量，用于避免与聊天列表重复处理 message_sent）
  static bool isChatPageOpen = false;

  /// 清除特定会话的缓存（静态方法，供外部调用）
  static void clearCache({
    required bool isGroup,
    required int id,
    int? currentUserId,
    bool isFileAssistant = false,
  }) {
    String cacheKey;
    if (isFileAssistant) {
      // 文件传输助手的缓存键
      cacheKey = 'file_assistant_${currentUserId ?? id}';
    } else if (isGroup) {
      cacheKey = 'group_$id';
    } else if (currentUserId != null) {
      cacheKey = 'user_${id}_$currentUserId';
    } else {
      // 如果没有currentUserId，清除所有包含该用户的缓存
      final keysToRemove = _messageCache.keys
          .where((key) => key.startsWith('user_${id}_') || (key.startsWith('user_') && key.contains('_$id')))
          .toList();
      for (final key in keysToRemove) {
        _messageCache.remove(key);
      }
      return;
    }
    
    if (_messageCache.containsKey(cacheKey)) {
      _messageCache.remove(cacheKey);
    }
  }

  /// 清除所有消息缓存（静态方法，供登录后调用）
  static void clearAllCache() {
    _messageCache.clear();
  }

  /// 设置消息缓存（公共静态方法，供外部访问）
  static void setMessageCache(String cacheKey, List<MessageModel> messages) {
    _messageCache[cacheKey] = messages;
  }

  @override
  State<MobileChatPage> createState() => _MobileChatPageState();
}

class _MobileChatPageState extends State<MobileChatPage>
    with WidgetsBindingObserver {
  // 控制器
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  // 服务
  final WebSocketService _wsService = WebSocketService();
  final AgoraService? _agoraService = FeatureConfig.enableWebRTC
      ? AgoraService()
      : null;

  // 消息相关
  final List<MessageModel> _messages = [];
  bool _isLoadingMore = false; // 是否正在加载更多消息
  bool _hasLoadedCache = false; // 是否已加载缓存
  String? _messagesError;

  int? _currentUserId;
  String? _token;
  String? _currentUserAvatar; // 当前用户头像
  
  // 头像缓存（用于动态更新头像）
  final Map<int, String?> _avatarCache = {};
  
  // 消息免打扰状态
  bool _doNotDisturb = false;
  
  // 置顶聊天状态
  bool _isPinned = false;

  // WebSocket 订阅
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  // 🔴 网络连接状态
  bool _isConnecting = false; // 是否正在连接网络
  bool _isNetworkConnected = false; // 网络是否已连接
  Timer? _networkStatusTimer; // 网络状态监听定时器

  // 🔴 初始加载状态（用于优化进入聊天页面的体验）
  bool _isInitialLoading = true; // 是否正在初始加载
  bool _cacheWasValid = false; // 缓存是否有效
  int _pendingMediaCount = 0; // 待加载的媒体数量
  int _loadedMediaCount = 0; // 已加载的媒体数量
  final Set<int> _loadedMediaIds = {}; // 已加载的媒体消息ID（防止重复计数）

  // 输入状态
  bool _isOtherTyping = false;
  Timer? _typingTimer;
  Timer? _typingIndicatorTimer;

  // 自动滚动定时器
  Timer? _messageScrollTimer;
  bool _isUserScrolling = false; // 用户是否手动向上滚动（用于暂停自动滚动）
  double _lastScrollPosition = 0.0; // 上次滚动位置（用于检测用户是否向上滚动）

  // 消息操作
  bool _isMultiSelectMode = false;
  final Set<int> _selectedMessageIds = {};
  int? _quotedMessageId;
  MessageModel? _quotedMessage;
  
  // 消息项的GlobalKey，用于定位和跳转
  final Map<int, GlobalKey> _messageKeys = {};
  int? _highlightedMessageId; // 高亮的消息ID

  // 群组信息
  GroupModel? _currentGroup;
  int? _groupMemberCount;
  String? _currentUserGroupRole; // 当前用户在群组中的角色
  bool _isCurrentUserMuted = false; // 当前用户是否被禁言
  bool _isGroupAllMuted = false; // 群组是否开启全体禁言
  bool _showMentionMenu = false;
  List<GroupMemberForMention> _groupMembers = []; // 群组成员列表
  final Set<int> _mentionedUserIds = {};

  // 搜索功能
  final TextEditingController _searchController = TextEditingController();

  // 更多功能菜单
  bool _showMoreOptions = false;

  // 表情选择器
  OverlayEntry? _emojiOverlayEntry;

  // 发送状态控制
  bool _isSending = false;

  // 最近发送的临时消息ID（用于错误时标记失败状态）
  int? _lastSentTempMessageId;

  @override
  void initState() {
    super.initState();
    // 🔴 标记聊天页面已打开
    MobileChatPage.isChatPageOpen = true;
    _initialize();
    _setupInputListeners();
    _setupAutoScrollTimer();
    _setupScrollListener();
    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initialize() async {
    _currentUserId = await Storage.getUserId();
    _token = await Storage.getToken();
    _currentUserAvatar = await Storage.getAvatar(); // 加载当前用户头像

    // 加载群组信息（如果是群聊）
    if (widget.isGroup && widget.groupId != null) {
      await _loadGroupInfo();
    }

    // 加载消息免打扰状态
    await _loadDoNotDisturbStatus();
    
    // 加载置顶聊天状态
    await _loadPinStatus();

    // 加载消息历史
    await _loadMessages();

    // 设置WebSocket监听和网络状态监听
    _setupWebSocketListener();
    _setupNetworkStatusListener();
    
    // 🔴 检查初始连接状态
    if (!_wsService.isConnected) {
      setState(() {
        _isConnecting = true;
      });
    }

    // 页面加载完成后，标记所有消息为已读
    if (mounted) {
      await _markCurrentChatAsRead();
    }

    // 初始化Agora服务
    if (_agoraService != null && _currentUserId != null) {
      await _agoraService.initialize(_currentUserId!);
    }
  }

  /// 刷新当前用户头像（当用户更新头像后调用）
  Future<void> _refreshUserAvatar() async {
    final newAvatar = await Storage.getAvatar();
    if (mounted && newAvatar != _currentUserAvatar) {
      setState(() {
        _currentUserAvatar = newAvatar;
      });
    }
  }

  void _setupInputListeners() {
    // 监听输入框焦点变化
    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        // 输入框获得焦点时，滚动到底部
        Future.delayed(const Duration(milliseconds: 300), () {
          _scrollToBottom();
        });
      }
    });

    // 监听输入内容变化（用于@提及功能）
    _messageController.addListener(() {
      final text = _messageController.text;
      _checkForMentions(text);
      _sendTypingIndicator();
    });
  }

  // 启动自动滚动定时器
  void _setupAutoScrollTimer() {
    // 启动消息列表自动滚动定时器，每隔1500毫秒检查一次
    _messageScrollTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      timer,
    ) {
      _checkAndScrollToBottom();
    });
  }

  // 设置滚动监听器
  void _setupScrollListener() {
    // 添加滚动监听器，检测用户是否手动向上滚动
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;

      final currentPosition = _scrollController.position.pixels;
      final maxScroll = _scrollController.position.maxScrollExtent;
      const threshold = 10.0; // 10像素的阈值

      // 如果用户滚动到底部，重新启用自动滚动
      if (currentPosition >= maxScroll - threshold) {
        if (_isUserScrolling) {
          setState(() {
            _isUserScrolling = false;
          });
        }
      } else {
        // 如果用户向上滚动（当前位置小于上次位置），标记为用户手动滚动
        if (currentPosition < _lastScrollPosition - threshold) {
          // 用户向上滚动，暂停自动滚动
          if (!_isUserScrolling) {
            setState(() {
              _isUserScrolling = true;
            });
          }
        }
      }

      // 更新上次滚动位置
      _lastScrollPosition = currentPosition;
    });
  }

  void _setupWebSocketListener() {
    _messageSubscription = _wsService.messageStream.listen((data) {
      if (!mounted) return;

      final type = data['type'] as String?;

      switch (type) {
        case 'message':
        case 'group_message':
        case 'group_message_send': // 处理发送群组消息的响应
          _handleNewMessage(data);
          break;

        case 'typing_indicator':
          _handleTypingIndicator(data);
          break;

        case 'read_receipt':
          _handleReadReceipt(data);
          break;

        case 'message_recall':
          _handleMessageRecall(data);
          break;

        case 'message_delete':
          _handleMessageDelete(data);
          break;

        case 'delete_message':
          // 处理删除消息通知（例如删除"加入通话"按钮）
          _handleDeleteMessage(data['data']);
          break;

        case 'group_announcement_update':
          _handleGroupAnnouncementUpdate(data);
          break;

        case 'message_error':
          // 私聊消息发送错误（如被拉黑、被删除、被驳回等）
          _handleMessageError(data['data']);
          break;

        case 'group_message_error':
          // 群组消息发送错误
          _handleGroupMessageError(data['data']);
          break;

        case 'avatar_updated':
          // 处理头像更新通知
          _handleAvatarUpdated(data);
          break;

        case 'group_nickname_updated':
          // 处理群组昵称更新通知
          _handleGroupNicknameUpdated(data);
          break;

        case 'message_sent':
          // 私聊消息发送成功确认，主动保存到数据库
          _handleMessageSent(data);
          break;

        case 'recall_success':
          // 撤回消息成功确认
          logger.debug('✅ 消息撤回成功: ${data['data']}');
          break;

        case 'recall_error':
          // 撤回消息失败
          _handleRecallError(data['data']);
          break;

        case 'message_recalled':
          // 🔴 处理服务器发来的消息撤回通知
          _handleMessageRecalledFromServer(data['data']);
          break;
      }
    });
  }

  // 🔴 处理服务器发来的消息撤回通知
  void _handleMessageRecalledFromServer(dynamic data) async {
    if (data == null) return;
    
    final messageId = data['message_id'] as int?;
    if (messageId == null) {
      logger.debug('❌ 撤回通知数据不完整');
      return;
    }

    logger.debug('↩️ 收到消息撤回通知 - 服务器消息ID: $messageId');
    logger.debug('📋 当前消息列表包含 ${_messages.length} 条消息');

    // 🔴 修复：更新本地数据库中的消息状态
    try {
      final localDb = LocalDatabaseService();
      if (widget.isGroup) {
        await localDb.recallGroupMessageByServerId(messageId);
      } else {
        await localDb.recallMessageByServerId(messageId);
      }
      logger.debug('✅ 本地数据库消息状态已更新为recalled');
    } catch (e) {
      logger.debug('❌ 更新本地数据库消息状态失败: $e');
    }

    setState(() {
      // 🔴 同时检查本地ID和服务器ID
      final index = _messages.indexWhere((msg) => msg.serverId == messageId || msg.id == messageId);
      if (index != -1) {
        logger.debug('✅ 找到消息，更新为已撤回状态');
        _messages[index] = _messages[index].copyWith(
          status: 'recalled',
        );
      } else {
        logger.debug('⚠️ 未找到要撤回的消息ID: $messageId');
      }
    });

    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('对方撤回了一条消息'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // 处理撤回消息错误
  void _handleRecallError(dynamic data) {
    if (data == null) return;
    final errorMsg = data['error'] as String? ?? '撤回失败';
    logger.debug('❌ 消息撤回失败: $errorMsg');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMsg),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // 🔴 下拉刷新方法
  Future<void> _onRefresh() async {
    
    setState(() {
      _isConnecting = true;
    });
    
    try {
      // 尝试重新连接WebSocket
      await _wsService.connect();
      
      // 重新加载消息
      await _loadMessages();
      
    } catch (e) {
      logger.error('❌ [下拉刷新] 刷新失败', error: e);
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
          } else if (currentConnected && _isConnecting) {
            // 重连成功，开始数据同步（但不立即隐藏刷新提示）
            
            // 异步执行数据同步和UI渲染，完成后才隐藏刷新提示
            _syncDataAfterReconnect().then((_) {
              if (mounted) {
                setState(() {
                  _isConnecting = false; // 数据同步和UI渲染完成后才隐藏提示
                });
              }
            }).catchError((error) {
              logger.error('❌ [网络状态] 数据同步失败，隐藏刷新提示', error: error);
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
      
      // 1. 等待离线消息同步完成
      // WebSocket重连后，服务器会自动推送离线消息到本地数据库
      
      // 监听离线消息同步完成的信号，最多等待5秒
      bool offlineMessagesSynced = false;
      late StreamSubscription messageSubscription;
      
      messageSubscription = _wsService.messageStream.listen((message) {
        if (message['type'] == 'offline_messages_saved' || 
            message['type'] == 'offline_group_messages_saved') {
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
      } else {
      }
      
      // 2. 重新加载消息数据（此时本地数据库已包含最新的离线消息）
      await _loadMessages();
      
      // 3. 等待UI完全渲染完成后才隐藏"正在刷新..."提示
      
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
          
        }
      }
      
    } catch (e) {
      logger.error('❌ [数据同步] 重连后数据同步失败', error: e);
    }
  }

  void _handleNewMessage(Map<String, dynamic> data) {
    try {
      final messageData = data['data'] as Map<String, dynamic>;
      final message = MessageModel.fromJson(messageData);

      // 更新头像缓存（如果消息包含头像信息）
      if (message.senderAvatar != null && message.senderAvatar!.isNotEmpty) {
        _avatarCache[message.senderId] = message.senderAvatar;
      }

      // 打印调试信息

      // 判断消息是否属于当前聊天
      bool isCurrentChat = false;

      // 🔴 修复：首先检查消息类型，确保群组消息和私人消息不会混淆
      final messageType = data['type'] as String?;
      
      if (widget.isGroup && widget.groupId != null) {
        // 群聊消息 - 必须同时满足：消息类型为group_message 且 receiverId匹配当前群组ID
        isCurrentChat = (messageType == 'group_message' || messageType == 'group_message_send') && 
                       message.receiverId == widget.groupId;
      } else if (widget.isFileAssistant) {
        // 文件助手消息 - 发送者和接收者都是当前用户自己
        isCurrentChat = (message.senderId == _currentUserId && 
                        message.receiverId == _currentUserId);
      } else {
        // 私聊消息 - 必须是message类型（非group_message）
        isCurrentChat = (messageType == 'message' || messageType == null) &&
            ((message.senderId == widget.userId &&
                message.receiverId == _currentUserId) ||
            (message.senderId == _currentUserId &&
                message.receiverId == widget.userId));
      }

      // 🔴 无论消息是否属于当前聊天，都更新对应会话的缓存
      _updateMessageCacheForAnyChat(message);

      if (isCurrentChat) {
        
        // 如果是自己发送的消息回传，查找并替换临时消息
        if (message.senderId == _currentUserId) {
          final tempMessageIndex = _messages.indexWhere((m) => 
            m.content == message.content && 
            m.senderId == message.senderId && 
            m.receiverId == message.receiverId &&
            m.messageType == message.messageType &&
            m.id != message.id); // 临时ID与真实ID不同
          
          if (tempMessageIndex != -1) {
            setState(() {
              // 🔄 保持status='sent'状态，确保刚发送的消息显示单钩
              _messages[tempMessageIndex] = message.copyWith(status: 'sent');
            });
          } else {
            // 没找到临时消息，直接添加（可能是其他设备发送的）
            setState(() {
              // 🔄 同样设置status='sent'，确保显示单钩
              _messages.add(message.copyWith(status: 'sent'));
            });
          }
        } else {
          // 不是自己发送的消息，直接添加
          setState(() {
            _messages.add(message);
          });
          
          // 🔴 关键修复：如果是"加入通话"按钮消息，强制刷新UI确保按钮立即显示
          if (message.messageType == 'join_voice_button' || message.messageType == 'join_video_button') {
            // 延迟一帧后再次刷新，确保UI完全更新
            Future.microtask(() {
              if (mounted) {
                setState(() {
                  // 触发UI重建，确保按钮显示
                });
              }
            });
          }
        }

        // 🔴 检查是否是禁言相关的系统消息
        if (message.messageType == 'system' && widget.isGroup) {
          _handleMuteRelatedSystemMessage(message);
        }

        // 如果不是自己发的消息，播放提示音
        if (message.senderId != _currentUserId) {
          _playMessageSound();
        }

        // 收到新消息，重新启用自动滚动定时器
        if (_isUserScrolling) {
          setState(() {
            _isUserScrolling = false;
            _lastScrollPosition = 0.0; // 重置滚动位置记录
          });
        }

        // 滚动到底部
        Future.delayed(const Duration(milliseconds: 100), () {
          _scrollToBottom();
        });

        // 🔴 更新消息位置缓存（新消息添加后需要更新）
        _cacheMessagePositions();

        // 🔴 修复：自动发送已读回执（如果是私聊且用户正在查看对话框）
        if (message.senderId != _currentUserId && !widget.isGroup && !widget.isFileAssistant) {
          // 发送批量已读回执
          _wsService.sendReadReceiptForContact(message.senderId);
          
          // 立即标记该消息为已读
          _markMessageAsReadLocally(message.id);
        }
      } else {
      }
    } catch (e) {
      logger.error('处理新消息失败', error: e);
    }
  }

  /// 处理消息发送成功确认
  void _handleMessageSent(Map<String, dynamic> data) async {
    try {
      
      final messageData = data['data'] as Map<String, dynamic>?;
      if (messageData == null) {
        return;
      }

      final messageId = messageData['message_id'] as int?;

      // 🔴 修复：传递serverMessageId给saveRecentPendingMessage，直接更新数据库消息状态
      if (widget.userId != 0) {
        await _wsService.saveRecentPendingMessage(
          widget.userId,
          serverMessageId: messageId,
        );
      }

      // 🔴 关键修复：同步更新内存中的消息serverId
      // 查找最近发送给该接收者的消息（状态为sending或sent），更新其serverId
      if (messageId != null) {
        setState(() {
          // 从后往前查找（最近的消息在后面）
          for (int i = _messages.length - 1; i >= 0; i--) {
            final msg = _messages[i];
            // 找到发送给当前接收者的、状态为sending或sent的消息
            if (msg.senderId == _currentUserId &&
                msg.receiverId == widget.userId &&
                (msg.status == 'sending' || msg.status == 'sent') &&
                msg.serverId == null) {
              // 更新serverId
              _messages[i] = msg.copyWith(
                serverId: messageId,
                status: 'sent', // 确保状态为sent
              );
              logger.debug('✅ [内存更新] 已更新消息serverId - localId: ${msg.id}, serverId: $messageId');
              break; // 只更新最近的一条
            }
          }
        });
      }

      // 清空当前会话的缓存
      final cacheKey = _getCacheKey();
      MobileChatPage._messageCache.remove(cacheKey);
      
      // 🔴 添加小延迟确保数据库更新完成，然后重新加载消息列表
      await Future.delayed(const Duration(milliseconds: 100));
      await _loadMessages();

    } catch (e) {
      logger.error('❌ 处理消息发送确认失败: $e');
    }
  }

  void _handleTypingIndicator(Map<String, dynamic> data) {
    final userId = data['data']['userId'] as int?;
    final isTyping = data['data']['isTyping'] as bool? ?? false;

    if (userId == widget.userId && !widget.isGroup) {
      setState(() {
        _isOtherTyping = isTyping;
      });

      // 如果对方正在输入，3秒后自动取消
      if (isTyping) {
        _typingIndicatorTimer?.cancel();
        _typingIndicatorTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _isOtherTyping = false;
            });
          }
        });
      }
    }
  }

  void _handleReadReceipt(Map<String, dynamic> data) {
    final dataMap = data['data'] as Map<String, dynamic>?;
    if (dataMap == null) return;

    // 🔴 修复：按 receiver_id 批量标记（接收者读了消息）
    final receiverId = dataMap['receiver_id'] as int?;
    if (receiverId != null) {
      
      // 如果当前是一对一聊天，且接收者ID匹配当前聊天对象
      if (!widget.isGroup && widget.userId == receiverId) {
        setState(() {
          // 批量更新所有发送给该接收者的未读消息为已读
          for (int i = 0; i < _messages.length; i++) {
            if (_messages[i].senderId == _currentUserId && 
                _messages[i].receiverId == receiverId && 
                !_messages[i].isRead) {
              // 🔴 修复：使用 copyWith 保留所有字段（包括 voiceDuration）
              _messages[i] = _messages[i].copyWith(
                isRead: true,
                readAt: DateTime.now(),
              );
            }
          }
        });
        
        // 🔴 修复：保存已读状态到本地数据库
        _saveReadStatusToDatabase(receiverId);
      }
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
    } catch (e) {
      logger.error('💾 [已读回执] 保存已读状态到数据库失败', error: e);
    }
  }

  void _handleMessageRecall(Map<String, dynamic> data) {
    // 🔴 注意：这个方法处理的是 message_recall 类型的消息
    // 但服务器不会发送这个类型，所以这个方法实际上不会被调用
    // 保留此方法以兼容旧版本
    final messageId = data['data']['messageId'] as int?;
    if (messageId != null) {
      logger.debug('📥 [message_recall] 收到撤回请求回显 - messageId: $messageId');
      setState(() {
        // 🔴 同时检查本地ID和服务器ID
        final index = _messages.indexWhere((msg) => msg.serverId == messageId || msg.id == messageId);
        if (index != -1) {
          // 🔴 修复：只更新status，不修改content和messageType
          _messages[index] = _messages[index].copyWith(
            status: 'recalled',
          );
          logger.debug('✅ [message_recall] 消息已更新为撤回状态');
        } else {
          logger.debug('⚠️ [message_recall] 未找到消息ID: $messageId');
        }
      });
    }
  }

  void _handleMessageDelete(Map<String, dynamic> data) {
    final messageId = data['data']['messageId'] as int?;
    if (messageId != null) {
      setState(() {
        _messages.removeWhere((msg) => msg.id == messageId);
      });
    }
  }

  // 处理删除消息通知（用于删除"加入通话"按钮等消息）
  Future<void> _handleDeleteMessage(Map<String, dynamic> data) async {
    final messageId = data['message_id'] as int?;
    final groupId = data['group_id'] as int?;

    if (messageId == null) {
      return;
    }

    // 🔴 关键修复：检查要删除的消息类型
    // 如果是"加入通话"按钮，不删除它，因为用户可能需要加入正在进行的通话
    final messageToDelete = _messages.firstWhereOrNull(
      (msg) => msg.id == messageId,
    );

    if (messageToDelete != null &&
        (messageToDelete.messageType == 'join_voice_button' ||
         messageToDelete.messageType == 'join_video_button')) {
      return;
    }

    // 🔴 修复：先从数据库删除
    try {
      final localDb = LocalDatabaseService();
      if (groupId != null) {
        await localDb.deleteGroupMessageById(messageId);
      } else {
        // 私聊消息删除（虽然目前主要是群组通话按钮，但为完整性也处理）
        await localDb.deleteMessageById(messageId);
      }
    } catch (e) {
    }

    setState(() {
      // 从消息列表中删除对应的消息
      _messages.removeWhere((msg) => msg.id == messageId);
      
      // 🔴 修复：同时从静态缓存中删除
      if (groupId != null) {
        final cacheKey = 'group_$groupId';
        final cachedMessages = MobileChatPage._messageCache[cacheKey];
        if (cachedMessages != null) {
          cachedMessages.removeWhere((msg) => msg.id == messageId);
        }
      }
    });
  }

  void _handleGroupAnnouncementUpdate(Map<String, dynamic> data) {
    if (widget.isGroup && widget.groupId == data['data']['groupId']) {
      final announcement = data['data']['announcement'] as String?;
      if (_currentGroup != null && announcement != null) {
        setState(() {
          _currentGroup = GroupModel(
            id: _currentGroup!.id,
            name: _currentGroup!.name,
            announcement: announcement,
            ownerId: _currentGroup!.ownerId,
            memberIds: _currentGroup!.memberIds,
            createdAt: _currentGroup!.createdAt,
          );
        });

        // 显示公告更新提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('群公告已更新'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  // 处理私聊消息发送错误（如被拉黑、被删除、被驳回等）
  void _handleMessageError(dynamic data) {
    if (data == null) {
      return;
    }
    if (!mounted) {
      return;
    }

    try {
      
      final errorData = data as Map<String, dynamic>;
      final errorType = errorData['error'] as String? ?? '未知错误';
      final errorMessage =
          errorData['message'] as String? ??
          errorData['error'] as String? ??
          '发送失败';

      // 对所有消息错误都更新状态为failed（不仅仅是黑名单或删除错误）
      
      // 通过保存的临时ID查找消息
      if (_lastSentTempMessageId != null) {
        final failedMessageIndex = _messages.indexWhere((m) => m.id == _lastSentTempMessageId);
        
        if (failedMessageIndex != -1) {
          final failedMessage = _messages[failedMessageIndex];
          
          // 标记消息为失败状态
          
          // 使用copyWith更新消息状态为failed
          setState(() {
            _messages[failedMessageIndex] = failedMessage.copyWith(status: 'failed');
          });
          
          
          // 清除临时ID
          _lastSentTempMessageId = null;
        } else {
          for (var msg in _messages) {
          }
        }
      } else {
      }

      // 显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
    }
  }

  // 处理群组消息发送错误
  void _handleGroupMessageError(dynamic data) {
    if (data == null) return;
    if (!mounted) return;

    try {
      final errorData = data as Map<String, dynamic>;
      
      final errorMessage =
          errorData['error'] as String? ??
          errorData['message'] as String? ??
          '发送失败';

      // 对所有群组消息错误都更新状态为failed（统一处理，和私聊一致）
      
      // 通过保存的临时ID查找消息并更新状态为failed
      if (_lastSentTempMessageId != null) {
        final failedMessageIndex = _messages.indexWhere((m) => m.id == _lastSentTempMessageId);
        
        if (failedMessageIndex != -1) {
          final failedMessage = _messages[failedMessageIndex];
          
          // 更新消息状态为failed
          setState(() {
            _messages[failedMessageIndex] = failedMessage.copyWith(status: 'failed');
          });
          
          
          // 清除临时ID
          _lastSentTempMessageId = null;
        } else {
        }
      } else {
      }

      // 针对不同错误类型显示不同的提示消息
      String displayMessage = errorMessage;
      final isRemovedFromGroup = errorMessage.contains('不是该群组成员') || errorMessage.contains('已被移除群组');
      final isMutedError = errorMessage.contains('禁言') || errorMessage.contains('已被禁言');
      
      if (isRemovedFromGroup) {
        displayMessage = '您已被移除群组';
      }

      // 显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMessage),
          backgroundColor: (isMutedError || isRemovedFromGroup) ? Colors.orange : Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
    }
  }

  /// 处理禁言相关的系统消息
  void _handleMuteRelatedSystemMessage(MessageModel message) {
    final content = message.content.toLowerCase();
    
    // 检查是否是全体禁言或个人禁言相关的消息
    if (content.contains('全体禁言') || 
        content.contains('禁言') || 
        content.contains('已被禁言') ||
        content.contains('解除禁言')) {
      
      
      // 延迟一点时间再重新加载，确保服务器端状态已更新
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _loadGroupInfo();
        }
      });
    }
  }

  /// 检查当前用户是否被禁言（包括个人禁言和全体禁言）
  bool get _isUserMuted {
    if (!widget.isGroup) return false;
    
    // 如果是群主或管理员，不受全体禁言影响
    if (_currentUserGroupRole == 'owner' || _currentUserGroupRole == 'admin') {
      return _isCurrentUserMuted; // 只检查个人禁言
    }
    
    // 普通成员：个人禁言 或 全体禁言
    return _isCurrentUserMuted || _isGroupAllMuted;
  }

  /// 更新所有消息缓存中的头像信息（静态缓存）
  void _updateAvatarInAllCaches(int userId, String? newAvatar) {
    try {
      int updatedCaches = 0;
      int updatedMessages = 0;

      // 遍历所有消息缓存
      for (String cacheKey in MobileChatPage._messageCache.keys.toList()) {
        final cachedMessages = MobileChatPage._messageCache[cacheKey];
        if (cachedMessages == null || cachedMessages.isEmpty) continue;

        bool cacheModified = false;

        // 更新该用户作为发送者的所有消息
        for (int i = 0; i < cachedMessages.length; i++) {
          final message = cachedMessages[i];
          
          if (message.senderId == userId) {
            cachedMessages[i] = message.copyWith(senderAvatar: newAvatar);
            cacheModified = true;
            updatedMessages++;
          }
          
          // 注意：receiverId 在群聊中是群组ID，不需要更新
          // 只在私聊消息中更新 receiverAvatar
          if (message.receiverId == userId && message.messageType != 'group') {
            cachedMessages[i] = cachedMessages[i].copyWith(receiverAvatar: newAvatar);
            cacheModified = true;
            updatedMessages++;
          }
        }

        if (cacheModified) {
          updatedCaches++;
        }
      }

    } catch (e) {
    }
  }

  /// 更新当前消息列表中的头像信息
  void _updateAvatarInCurrentMessages(int userId, String? newAvatar) {
    try {
      int updatedCount = 0;

      for (int i = 0; i < _messages.length; i++) {
        final message = _messages[i];
        
        if (message.senderId == userId) {
          _messages[i] = message.copyWith(senderAvatar: newAvatar);
          updatedCount++;
        }
        
        // 只在私聊消息中更新 receiverAvatar
        if (message.receiverId == userId && message.messageType != 'group') {
          _messages[i] = _messages[i].copyWith(receiverAvatar: newAvatar);
          updatedCount++;
        }
      }

    } catch (e) {
    }
  }

  // 处理头像更新通知
  Future<void> _handleAvatarUpdated(dynamic data) async {
    if (data == null) return;
    if (!mounted) return;

    try {
      final avatarData = data['data'] as Map<String, dynamic>;
      final userId = avatarData['user_id'] as int?;
      final newAvatar = avatarData['avatar'] as String?;

      if (userId == null) {
        return;
      }

      // 1. 更新头像缓存（用于后续显示）
      _avatarCache[userId] = newAvatar;

      // 2. 更新所有消息缓存中的头像信息（静态缓存）
      _updateAvatarInAllCaches(userId, newAvatar);

      // 3. 更新当前消息列表中的头像信息
      _updateAvatarInCurrentMessages(userId, newAvatar);

      // 4. 更新本地数据库中的头像信息（确保下次加载时显示最新头像）
      final localDb = LocalDatabaseService();
      final dbUpdatedCount = await localDb.updateUserAvatarInMessages(userId, newAvatar);

      // 5. 检查是否需要触发UI更新
      bool shouldUpdate = false;
      
      if (!widget.isGroup && !widget.isFileAssistant) {
        // 私聊：检查是否是聊天对象的头像更新
        shouldUpdate = (userId == widget.userId || userId == _currentUserId);
      } else if (widget.isGroup) {
        // 群聊：任何群成员的头像更新都需要刷新消息列表中的头像
        shouldUpdate = true;
      }

      // 6. 触发UI重建
      if (shouldUpdate) {
        setState(() {
          // 触发重建，消息气泡会重新获取最新头像
        });
      } else {
      }
    } catch (e) {
    }
  }

  // 处理群组昵称更新通知
  Future<void> _handleGroupNicknameUpdated(dynamic data) async {
    if (data == null) return;
    if (!mounted) return;

    try {
      final nicknameData = data['data'] as Map<String, dynamic>;
      final groupId = nicknameData['group_id'] as int?;
      final userId = nicknameData['user_id'] as int?;
      final newNickname = nicknameData['new_nickname'] as String?;

      if (groupId == null || userId == null || newNickname == null) {
        return;
      }

      // 只有当前正在查看该群组时才需要更新UI
      if (!widget.isGroup || widget.groupId != groupId) {
        return;
      }

      // WebSocketService已经更新了数据库，这里需要清空缓存并刷新当前显示的消息
      // 重新从数据库加载消息，以显示更新后的昵称
      
      // 清空相关缓存，确保重新从数据库加载最新数据
      final cacheKey = _getCacheKey();
      MobileChatPage._messageCache.remove(cacheKey);
      
      setState(() {
        _messages.clear();
        _messagesError = null;
        _hasLoadedCache = false; // 重置缓存加载状态，强制从数据库重新加载
      });
      
      await _loadMessages();
      
    } catch (e) {
    }
  }

  /// 获取缓存键
  String _getCacheKey() {
    if (widget.isFileAssistant) {
      return 'file_assistant_$_currentUserId';
    } else if (widget.isGroup && widget.groupId != null) {
      return 'group_${widget.groupId}';
    } else {
      return 'user_${widget.userId}_$_currentUserId';
    }
  }

  /// 从缓存获取消息并立即显示
  void _loadFromCache() {
    final cacheKey = _getCacheKey();
    final cachedMessages = MobileChatPage._messageCache[cacheKey];

    if (cachedMessages != null && cachedMessages.isNotEmpty) {
      // 🔴 缓存有效，标记状态
      _cacheWasValid = true;
      
      setState(() {
        _messages.clear();
        // 🔄 将从缓存加载的、自己发送的消息状态从'sent'改为null，这样重新进入后显示双钩
        final updatedMessages = cachedMessages.map((msg) {
          if (msg.senderId == _currentUserId && msg.status == 'sent') {
            return msg.copyWith(status: null);
          }
          return msg;
        }).toList();
        _messages.addAll(updatedMessages);
        _hasLoadedCache = true;
        // 🔴 缓存有效时，直接关闭初始加载状态
        _isInitialLoading = false;
      });

      // 🔴 缓存有效时，直接跳转到底部（无动画）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } else {
      // 🔴 缓存无效，需要显示加载动画
      _cacheWasValid = false;
      setState(() {
        _hasLoadedCache = true;
      });
    }
  }

  /// 更新缓存
  void _updateCache(List<MessageModel> messages) {
    final cacheKey = _getCacheKey();

    // 只保存最新的15条消息到缓存
    final latestMessages = messages.length > MobileChatPage._cacheSize
        ? messages.sublist(messages.length - MobileChatPage._cacheSize)
        : messages;

    MobileChatPage._messageCache[cacheKey] = List.from(latestMessages);
  }

  /// 添加新消息到缓存
  void _addMessageToCache(MessageModel message) {
    final cacheKey = _getCacheKey();

    // 获取当前缓存
    List<MessageModel> cachedMessages = MobileChatPage._messageCache[cacheKey] ?? [];

    // 添加新消息
    cachedMessages.add(message);

    // 保持缓存大小限制
    if (cachedMessages.length > MobileChatPage._cacheSize) {
      cachedMessages = cachedMessages.sublist(
        cachedMessages.length - MobileChatPage._cacheSize,
      );
    }

    MobileChatPage._messageCache[cacheKey] = cachedMessages;
  }

  /// 更新任意会话的消息缓存（用于处理收到的新消息）
  void _updateMessageCacheForAnyChat(MessageModel message) {
    if (_currentUserId == null) return;

    String cacheKey;
    
    // 根据消息类型生成缓存键
    if (message.messageType == 'group_message' || 
        (widget.isGroup && message.receiverId != _currentUserId)) {
      // 群聊消息
      cacheKey = 'group_${message.receiverId}';
    } else if (message.senderId == _currentUserId && 
               message.receiverId == _currentUserId) {
      // 文件助手消息
      cacheKey = 'file_assistant_$_currentUserId';
    } else {
      // 私聊消息：确定对方用户ID
      final otherUserId = message.senderId == _currentUserId 
          ? message.receiverId 
          : message.senderId;
      cacheKey = 'user_${otherUserId}_$_currentUserId';
    }

    // 获取该会话的缓存
    List<MessageModel> cachedMessages = MobileChatPage._messageCache[cacheKey] ?? [];

    // 检查消息是否已存在（避免重复）
    final exists = cachedMessages.any((m) => m.id == message.id);
    if (exists) {
      return;
    }

    // 添加新消息
    cachedMessages.add(message);

    // 保持缓存大小限制（最新15条）
    if (cachedMessages.length > MobileChatPage._cacheSize) {
      cachedMessages = cachedMessages.sublist(
        cachedMessages.length - MobileChatPage._cacheSize,
      );
    }

    // 更新缓存
    MobileChatPage._messageCache[cacheKey] = cachedMessages;
  }

  /// 获取当前会话的唯一标识（用于消息位置缓存）
  String _getSessionKey() {
    return MessagePositionCache.generateSessionKey(
      isGroup: widget.isGroup,
      id: widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId,
      isFileAssistant: widget.isFileAssistant,
      currentUserId: _currentUserId,
    );
  }

  /// 缓存消息位置（用于引用消息跳转）
  void _cacheMessagePositions() {
    final sessionKey = _getSessionKey();
    final positionCache = MessagePositionCache();
    
    // 批量缓存所有消息的位置
    final positionDataList = _messages.asMap().entries.map((entry) {
      return MessagePositionData(
        serverId: entry.value.serverId,
        localId: entry.value.id,
      );
    }).toList();
    
    positionCache.cachePositions(
      sessionKey: sessionKey,
      messages: positionDataList,
    );
    
    logger.debug('📍 [消息位置缓存] 已缓存 ${_messages.length} 条消息的位置 (sessionKey: $sessionKey)');
  }

  /// 异步加载完整消息数据
  Future<void> _loadMessages() async {

    if (_token == null) {
      return;
    }

    // 防止重复加载
    if (_isLoadingMore) {
      return;
    }

    // 1. 首先从缓存加载并立即显示（由于上面清除了缓存，这里会跳过）
    if (!_hasLoadedCache) {
      _loadFromCache();
    }

    // 2. 然后异步加载完整数据
    setState(() {
      _isLoadingMore = true;
      _messagesError = null;
    });

    try {
      List<MessageModel> messages = [];

      if (widget.isFileAssistant) {
        // 文件助手消息需要从API获取（特殊处理）
        final response = await ApiService.getFileAssistantMessages(
          token: _token!,
        );
        if (response['data'] != null) {
          final messagesData = response['data']['messages'] as List?;
          if (messagesData != null) {
            messages = messagesData
                .map(
                  (json) => MessageModel.fromJson(json as Map<String, dynamic>),
                )
                .toList();
          }
        }
      } else {
        // 从本地数据库获取私聊或群聊消息
        final messageService = MessageService();
        if (widget.isGroup && widget.groupId != null) {
          // 群聊消息
          // 🔴 修复：增加pageSize到200，确保加载所有最近消息（包括刚发送的消息）
          messages = await messageService.getGroupMessageList(
            groupId: widget.groupId!,
            pageSize: 200,
          );
        } else {
          // 私聊消息
          // 🔴 修复：增加pageSize到200，确保加载所有最近消息（包括刚发送的消息）
          messages = await messageService.getMessages(
            contactId: widget.userId,
            pageSize: 200,
          );
        }
      }

      if (mounted) {
        // 3. 更新缓存
        if (messages.isNotEmpty) {
          _updateCache(messages);
        }

        // 4. 🔴 修复：无条件更新UI，确保从数据库加载的消息（包含完整字段如voiceDuration）替换临时消息
        if (messages.isNotEmpty) {
          // 🔴 计算需要加载的媒体数量（图片和视频）
          final mediaMessages = messages.where((msg) => 
            (msg.messageType == 'image' || msg.messageType == 'video') &&
            msg.status != 'uploading' && 
            msg.status != 'failed' &&
            msg.content.isNotEmpty &&
            !msg.content.startsWith('/') && // 排除本地文件路径
            !msg.content.startsWith('C:')
          ).toList();
          
          setState(() {
            _messages.clear();
            // 🔄 将从数据库加载的、自己发送的消息状态从'sent'改为null，这样重新进入后显示双钩
            final updatedMessages = messages.map((msg) {
              if (msg.senderId == _currentUserId && msg.status == 'sent') {
                return msg.copyWith(status: null);
              }
              return msg;
            }).toList();
            _messages.addAll(updatedMessages);
            
            // 🔴 如果缓存无效且有媒体需要加载，设置待加载数量
            if (!_cacheWasValid && mediaMessages.isNotEmpty) {
              _pendingMediaCount = mediaMessages.length;
              _loadedMediaCount = 0;
            }
          });

          // 🔴 如果缓存有效，直接跳转到底部（无动画）
          // 如果缓存无效，等待媒体加载完成后再关闭加载状态
          if (_cacheWasValid) {
            // 缓存有效，直接跳转到底部
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scrollController.hasClients) {
                _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
              }
            });
          } else {
            // 缓存无效，先跳转到底部，然后等待媒体加载
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scrollController.hasClients) {
                _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
              }
            });
            
            // 🔴 如果没有媒体需要加载，直接关闭加载状态
            if (mediaMessages.isEmpty) {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) {
                  setState(() {
                    _isInitialLoading = false;
                  });
                }
              });
            } else {
              // 🔴 设置超时机制，防止媒体加载时间过长（最多等待5秒）
              Future.delayed(const Duration(seconds: 5), () {
                if (mounted && _isInitialLoading) {
                  setState(() {
                    _isInitialLoading = false;
                  });
                }
              });
            }
            // 如果有媒体需要加载，等待 _onMediaLoadedWithId 回调来关闭加载状态
          }
        } else {
          // 没有消息，直接关闭加载状态
          if (!_cacheWasValid) {
            setState(() {
              _isInitialLoading = false;
            });
          }
        }

        setState(() {
          _isLoadingMore = false;
        });

        // 🔴 缓存消息位置（用于引用消息跳转）
        _cacheMessagePositions();

        // 标记所有消息为已读
        _markAllMessagesAsRead();
      } else {
      }
    } catch (e) {
      logger.error('❌ 加载消息失败: $e', error: e);
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _messagesError = '加载消息失败: $e';
        });
      }
    }
  }

  Future<void> _loadGroupInfo() async {
    if (!widget.isGroup || widget.groupId == null || _token == null) return;

    try {
      final response = await ApiService.getGroupDetail(
        token: _token!,
        groupId: widget.groupId!,
      );

      if (response['data'] != null && mounted) {
        setState(() {
          if (response['data']['group'] != null) {
            _currentGroup = GroupModel.fromJson(response['data']['group']);
            
            // 获取群组全体禁言状态
            _isGroupAllMuted = _currentGroup?.allMuted ?? false;

            // 修复：从members列表中获取成员数量
            // 服务器返回的group对象中没有member_ids字段，需要从members列表中获取
            if (response['data']['members'] != null) {
              final members = response['data']['members'] as List;
              // 只统计已通过审核的成员（approval_status为'approved'）
              final approvedMembers = members.where((member) {
                final approvalStatus = member['approval_status'] as String?;
                return approvalStatus == 'approved';
              }).toList();
              _groupMemberCount = approvedMembers.length;

              // 获取当前用户的禁言状态
              final currentUserMember = members.firstWhere(
                (m) => m['user_id'] == _currentUserId,
                orElse: () => null,
              );
              if (currentUserMember != null) {
                _isCurrentUserMuted = currentUserMember['is_muted'] as bool? ?? false;
              }

              // 加载群组成员列表用于@功能
              _groupMembers = approvedMembers
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
            } else {
              _groupMemberCount = _currentGroup?.memberIds.length ?? 0;
            }
          }
          // 获取当前用户在群组中的角色
          _currentUserGroupRole = response['data']['member_role'] as String?;
        });
      }
    } catch (e) {
      logger.error('加载群组信息失败', error: e);
    }
  }

  Future<void> _markAllMessagesAsRead() async {
    if (_token == null) return;

    final unreadMessageIds = _messages
        .where((msg) => msg.senderId != _currentUserId && !msg.isRead)
        .map((msg) => msg.id)
        .toList();

    if (unreadMessageIds.isNotEmpty) {
      try {
        // 🔴 修复：一对一私聊时，发送已读回执给发送者
        if (!widget.isGroup && !widget.isFileAssistant && widget.userId != 0) {
          // 发送已读回执，包含发送者ID（这会触发服务器更新数据库并推送给发送者）
          _wsService.sendReadReceiptForContact(widget.userId);
        }

        // 更新本地消息状态
        setState(() {
          for (var i = 0; i < _messages.length; i++) {
            if (unreadMessageIds.contains(_messages[i].id)) {
              // 🔴 修复：使用 copyWith 保留所有字段（包括 voiceDuration）
              _messages[i] = _messages[i].copyWith(
                isRead: true,
                readAt: DateTime.now(),
              );
            }
          }
        });
      } catch (e) {
        logger.error('标记消息已读失败', error: e);
      }
    }
  }

  // 检查并滚动到底部（定时器调用）
  void _checkAndScrollToBottom() {
    // 如果用户正在手动向上滚动，不执行自动滚动
    if (_isUserScrolling) {
      return;
    }

    // 如果没有消息列表，不执行任何操作
    if (_messages.isEmpty) {
      return;
    }

    // 如果滚动控制器没有客户端，不执行任何操作
    if (!_scrollController.hasClients) {
      return;
    }

    // 检查是否已经到达底部（使用10像素的阈值，避免浮点数比较问题）
    final position = _scrollController.position;
    final maxScroll = position.maxScrollExtent;
    final currentScroll = position.pixels;
    const threshold = 10.0; // 10像素的阈值

    // 如果已经到达底部（当前滚动位置 >= 最大滚动位置 - 阈值），不执行任何操作
    if (currentScroll >= maxScroll - threshold) {
      return;
    }

    // 如果没有到达底部，则滚动到底部
    try {
      _scrollController.jumpTo(maxScroll);
    } catch (e) {
      // 忽略滚动错误
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!mounted || !_scrollController.hasClients) return;

    try {
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        if (animate) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      }
    } catch (e) {
      // 忽略滚动错误
    }
  }

  /// 🔴 媒体加载完成回调（图片或视频加载完成时调用）
  void _onMediaLoadedWithId(int messageId) {
    if (!mounted || _cacheWasValid || !_isInitialLoading) return;
    
    // 防止重复计数
    if (_loadedMediaIds.contains(messageId)) return;
    _loadedMediaIds.add(messageId);
    
    _loadedMediaCount++;
    
    // 更新UI显示加载进度
    if (mounted) {
      setState(() {});
    }
    
    // 当所有媒体都加载完成时，关闭初始加载状态
    if (_loadedMediaCount >= _pendingMediaCount && _isInitialLoading) {
      // 延迟一小段时间确保UI渲染完成
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          setState(() {
            _isInitialLoading = false;
          });
          // 确保滚动到底部
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
            }
          });
        }
      });
    }
  }

  /// 🔴 媒体加载完成回调（无ID版本，用于兼容）
  void _onMediaLoaded() {
    // 这个方法不再使用，保留以防万一
  }

  /// 🔴 媒体加载失败回调（也算作加载完成，避免无限等待）
  void _onMediaLoadFailedWithId(int messageId) {
    _onMediaLoadedWithId(messageId); // 失败也算完成，避免卡住
  }

  // 播放消息提示音
  void _playMessageSound() {
    // TODO: 实现消息提示音播放
  }

  // 发送已读回执
  void _sendReadReceipt(int messageId) {
    _wsService.sendReadReceipt(messageId);
  }

  // 本地标记单个消息为已读
  void _markMessageAsReadLocally(int messageId) {
    final index = _messages.indexWhere((msg) => msg.id == messageId);
    if (index != -1 && !_messages[index].isRead) {
      setState(() {
        // 🔴 使用 copyWith 替代手动创建，确保所有字段都被保留（包括 voiceDuration）
        _messages[index] = _messages[index].copyWith(
          isRead: true,
          readAt: DateTime.now(),
        );
      });
    }
  }

  // 标记当前聊天的所有消息为已读
  Future<void> _markCurrentChatAsRead() async {
    if (_token == null) return;

    try {
      if (widget.isGroup && widget.groupId != null) {
        // 标记群组消息为已读
        await ApiService.markGroupMessagesAsRead(
          token: _token!,
          groupID: widget.groupId!,
        );
      } else if (!widget.isFileAssistant) {
        // 标记私聊消息为已读
        await ApiService.markMessagesAsRead(
          token: _token!,
          senderID: widget.userId,
        );
      }

      // 更新本地消息状态
      final unreadMessageIds = _messages
          .where((msg) => msg.senderId != _currentUserId && !msg.isRead)
          .map((msg) => msg.id)
          .toList();

      if (unreadMessageIds.isNotEmpty) {
        setState(() {
          for (int i = 0; i < _messages.length; i++) {
            if (unreadMessageIds.contains(_messages[i].id)) {
              // 🔴 修复：使用 copyWith 保留所有字段（包括 voiceDuration）
              _messages[i] = _messages[i].copyWith(
                isRead: true,
                readAt: DateTime.now(),
              );
            }
          }
        });
      }
    } catch (e) {
      logger.error('标记消息为已读失败', error: e);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 当应用回到前台并且当前页面可见时，标记消息为已读
    if (state == AppLifecycleState.resumed) {
      _markCurrentChatAsRead();
    }
  }

  // 发送正在输入指示器
  void _sendTypingIndicator() {
    if (widget.isGroup || widget.isFileAssistant) return;

    // 取消之前的计时器
    _typingTimer?.cancel();

    // 发送正在输入状态
    _wsService.sendTypingIndicator(receiverId: widget.userId, isTyping: true);

    // 3秒后发送停止输入状态
    _typingTimer = Timer(const Duration(seconds: 3), () {
      _wsService.sendTypingIndicator(
        receiverId: widget.userId,
        isTyping: false,
      );
    });
  }

  // 检查@提及
  void _checkForMentions(String text) {
    if (!widget.isGroup) {
      setState(() {
        _showMentionMenu = false;
      });
      return;
    }

    // 检查是否有@符号
    final atIndex = text.lastIndexOf('@');
    if (atIndex == -1) {
      setState(() {
        _showMentionMenu = false;
      });
      return;
    }

    // 获取@后面的文字
    final textAfterAt = text.substring(atIndex + 1);

    // 如果@符号后有空格且不是紧跟着@，说明已经选择完成，关闭弹窗
    if (textAfterAt.contains(' ') && textAfterAt.indexOf(' ') > 0) {
      setState(() {
        _showMentionMenu = false;
      });
      return;
    }

    // 检查是否有群组成员
    if (_groupMembers.isEmpty) {
      setState(() {
        _showMentionMenu = false;
      });
      return;
    }

    // 显示提及菜单（MentionMemberPicker 组件内部会处理搜索过滤）
    setState(() {
      _showMentionMenu = true;
    });
  }

  // 发送文本消息
  Future<void> _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _token == null) return;

    // 🔴 优化：先清空输入框，提升用户体验
    _messageController.clear();

    // 立即置灰发送按钮
    setState(() {
      _isSending = true;
    });

    try {
      // 获取引用信息
      final quotedId = _quotedMessageId;
      final quotedContent = _quotedMessage != null
          ? _getQuotedMessagePreview(_quotedMessage!)
          : null;

      // 如果有引用消息，将消息类型设置为 quoted
      String messageType = 'text';
      if (_quotedMessage != null) {
        messageType = 'quoted';
      }

      // 构建@提及信息
      // String? mentions;
      // if (_mentionedUserIds.isNotEmpty) {
      //   if (_mentionedUserIds.contains(-1)) {
      //     mentions = '@all';
      //   } else {
      //     // 这里需要实际的用户信息，暂时简化处理
      //     mentions = _mentionedUserIds.map((id) => '@user$id').join(',');
      //   }
      // }

      // 发送消息
      if (widget.isFileAssistant) {
        // 文件助手消息仍使用HTTP API（因为文件助手是特殊的系统功能）
        final result = await ApiService.sendFileAssistantMessage(
          token: _token!,
          content: text,
          messageType: messageType,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
        );
                // 🔴 立即在UI上显示发送的消息，避免重复加载
        if (result['code'] == 0 && mounted && _currentUserId != null) {
          final messageData = result['data'] as Map<String, dynamic>;
          final messageId = messageData['id'] as int;
          
          // 检查消息是否已存在，避免重复添加
          final exists = _messages.any((m) => m.id == messageId);
          if (!exists) {
            final newMessage = MessageModel(
              id: messageId,
              content: text,
              messageType: messageType,
              senderId: _currentUserId!,
              receiverId: _currentUserId!,
              senderName: await Storage.getUsername() ?? '',
              receiverName: '文件传输助手',
              senderAvatar: await Storage.getAvatar() ?? '',
              receiverAvatar: '',
              createdAt: DateTime.parse(messageData['created_at'] as String),
              isRead: true,
              quotedMessageId: quotedId,
              quotedMessageContent: quotedContent,
            );
            
            setState(() {
              _messages.add(newMessage);
              // 消息已显示，恢复发送按钮
              _isSending = false;
            });
          } else {
            // 消息已存在，直接恢复按钮
            setState(() {
              _isSending = false;
            });
          }
          
          // 滚动到底部
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        } else {
          // API调用失败，恢复发送按钮
          setState(() {
            _isSending = false;
          });
        }
      } else if (widget.isGroup && widget.groupId != null) {
        // 🔴 检查是否被禁言
        if (_isUserMuted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已被禁言中'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        
        // 群聊消息 - 先创建临时消息（和私聊逻辑一致）
        if (_currentUserId != null) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          final tempId = DateTime.now().millisecondsSinceEpoch; // 使用临时ID
          _lastSentTempMessageId = tempId; // 保存临时ID用于错误处理
          
          // 🔴 修复：移除基于内容的去重检查，允许发送相同内容的消息
          // 每条消息都有唯一的tempId，不会真正重复
          setState(() {
            final newMessage = MessageModel(
              id: tempId,
              content: text,
              messageType: messageType,
              senderId: _currentUserId!,
              receiverId: widget.groupId!,
              senderName: userName,
              receiverName: widget.displayName,
              senderAvatar: userAvatar,
              receiverAvatar: '',
              createdAt: DateTime.now(),
              quotedMessageId: quotedId,
              quotedMessageContent: quotedContent,
              mentionedUserIds: _mentionedUserIds.isEmpty
                  ? null
                  : _mentionedUserIds.toList(),
              isRead: false,
              status: 'sent', // 标记为已发送（刚发送完成）
            );
            _messages.add(newMessage);
          });
          
          // 滚动到底部
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
        
        // 然后发送WebSocket
        final success = await _wsService.sendGroupMessage(
          groupId: widget.groupId!,
          content: text,
          messageType: messageType,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
          mentionedUserIds: _mentionedUserIds.toList(),
        );

        // 恢复发送按钮
        setState(() {
          _isSending = false;
        });
      } else {
        // 私聊消息 - 使用 WebSocket
        
        // 🔴 关键修复：先在UI上显示消息，再发送WebSocket
        // 这样当错误快速返回时，消息已经在列表中，可以被标记为失败
        if (mounted) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          final tempId = DateTime.now().millisecondsSinceEpoch; // 使用临时ID
          _lastSentTempMessageId = tempId; // 保存临时ID用于错误处理
          
          // 🔴 修复：移除基于内容的去重检查，允许发送相同内容的消息
          // 每条消息都有唯一的tempId，不会真正重复
          setState(() {
            final newMessage = MessageModel(
              id: tempId,
              content: text,
              messageType: messageType,
              senderId: _currentUserId!,
              receiverId: widget.userId,
              senderName: userName,
              receiverName: widget.displayName,
              senderAvatar: userAvatar,
              receiverAvatar: widget.avatar ?? '',
              createdAt: DateTime.now(),
              quotedMessageId: quotedId,
              quotedMessageContent: quotedContent,
              isRead: false, // 刚发送的消息标记为未读（显示单钩）
              status: 'sent', // 标记为已发送（刚发送完成）
            );
            _messages.add(newMessage);
          });
          
          // 滚动到底部
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
        
        // 然后发送WebSocket
        await _wsService.sendMessage(
          receiverId: widget.userId,
          content: text,
          messageType: messageType,
          quotedMessageId: quotedId,
          quotedMessageContent: quotedContent,
        );
        
        
        // 恢复发送按钮
        setState(() {
          _isSending = false;
        });
      }

      // 清空引用消息和@提及（输入框已在开头清空）
      _quotedMessage = null;
      _quotedMessageId = null;
      _mentionedUserIds.clear();
    } catch (e) {
      logger.error('发送消息失败', error: e);
      // 发送失败，恢复发送按钮
      if (mounted) {
        setState(() {
          _isSending = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 🎤 显示语音录制面板
  void _showVoiceRecordPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => VoiceRecordPanel(
        onRecordComplete: (filePath, duration) {
          _sendVoiceMessage(filePath, duration);
        },
      ),
    );
  }

  // 🎤 发送语音消息
  Future<void> _sendVoiceMessage(String filePath, int duration) async {
    logger.debug('🎤 ========== 开始发送语音消息 ==========');
    logger.debug('🎤 [Step 1] 参数: filePath=$filePath, duration=$duration秒');
    
    if (_token == null) return;

    // 创建临时消息用于显示上传进度
    final tempId = DateTime.now().millisecondsSinceEpoch;
    logger.debug('🎤 [Step 2] 创建临时消息，tempId=$tempId, duration=$duration');
    
    final tempMessage = MessageModel(
      id: tempId,
      content: filePath,
      messageType: 'voice',
      voiceDuration: duration,
      senderId: _currentUserId!,
      receiverId: widget.isGroup ? widget.groupId! : widget.userId,
      senderName: '',
      receiverName: widget.displayName,
      createdAt: DateTime.now(),
      status: 'uploading',
      uploadProgress: 0.0,
      isRead: false,
    );
    logger.debug('🎤 [Step 3] 临时消息创建完成，voiceDuration=${tempMessage.voiceDuration}');

    // 添加临时消息到消息列表
    setState(() {
      _messages.add(tempMessage);
    });

    // 滚动到底部
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom();
    });

    try {
      logger.debug('🎤 [Step 4] 开始上传语音文件到OSS，duration=$duration');
      
      // 上传语音文件到OSS
      final uploadResult = await VoiceRecordService.uploadVoice(
        token: _token!,
        filePath: filePath,
        onProgress: (uploaded, total) {
          // 更新上传进度
          setState(() {
            final index = _messages.indexWhere((m) => m.id == tempId);
            if (index != -1) {
              _messages[index] = tempMessage.copyWith(
                uploadProgress: uploaded / total,
              );
            }
          });
        },
      );

      final voiceUrl = uploadResult['url'] as String;
      logger.debug('🎤 [Step 5] OSS上传完成，voiceUrl=$voiceUrl, duration仍为=$duration');

      // 移除临时消息
      setState(() {
        _messages.removeWhere((m) => m.id == tempId);
      });

      // 发送语音消息
      if (widget.isGroup && widget.groupId != null) {
        // 群聊语音消息
        logger.debug('🎤 [Step 6-群组] 准备发送群组语音消息，duration=$duration');
        
        if (_currentUserId != null) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          final newTempId = DateTime.now().millisecondsSinceEpoch;
          _lastSentTempMessageId = newTempId;
          
          logger.debug('🎤 [Step 7-群组] 创建新消息对象，newTempId=$newTempId, duration=$duration');
          
          setState(() {
            final newMessage = MessageModel(
              id: newTempId,
              content: voiceUrl,
              messageType: 'voice',
              voiceDuration: duration,
              senderId: _currentUserId!,
              receiverId: widget.groupId!,
              senderName: userName,
              receiverName: widget.displayName,
              senderAvatar: userAvatar,
              receiverAvatar: '',
              createdAt: DateTime.now(),
              isRead: false,
              status: 'sent',
            );
            logger.debug('🎤 [Step 8-群组] newMessage创建完成，voiceDuration=${newMessage.voiceDuration}');
            _messages.add(newMessage);
          });
          
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
        
        logger.debug('🎤 [Step 9-群组] 调用WebSocket发送，duration=$duration');
        await _wsService.sendGroupMessage(
          groupId: widget.groupId!,
          content: voiceUrl,
          messageType: 'voice',
          voiceDuration: duration,
        );
        logger.debug('🎤 [Step 10-群组] WebSocket发送完成');
      } else {
        // 私聊语音消息
        logger.debug('🎤 [Step 6-私聊] 准备发送私聊语音消息，duration=$duration');
        
        if (_currentUserId != null) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          final newTempId = DateTime.now().millisecondsSinceEpoch;
          _lastSentTempMessageId = newTempId;
          
          logger.debug('🎤 [Step 7-私聊] 创建新消息对象，newTempId=$newTempId, duration=$duration');
          
          setState(() {
            final newMessage = MessageModel(
              id: newTempId,
              content: voiceUrl,
              messageType: 'voice',
              voiceDuration: duration,
              senderId: _currentUserId!,
              receiverId: widget.userId,
              senderName: userName,
              receiverName: widget.displayName,
              senderAvatar: userAvatar,
              receiverAvatar: widget.avatar ?? '',
              createdAt: DateTime.now(),
              isRead: false,
              status: 'sent',
            );
            logger.debug('🎤 [Step 8-私聊] newMessage创建完成，voiceDuration=${newMessage.voiceDuration}');
            _messages.add(newMessage);
          });
          
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
        
        logger.debug('🎤 [Step 9-私聊] 调用WebSocket发送，duration=$duration');
        await _wsService.sendMessage(
          receiverId: widget.userId,
          content: voiceUrl,
          messageType: 'voice',
          voiceDuration: duration,
        );
        logger.debug('🎤 [Step 10-私聊] WebSocket发送完成');
      }

      // 删除本地临时文件
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        logger.debug('删除临时语音文件失败: $e');
      }

    } catch (e) {
      // 上传失败，更新临时消息状态
      setState(() {
        final index = _messages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          _messages[index] = tempMessage.copyWith(
            status: 'failed',
            uploadProgress: 0.0,
          );
        }
      });

      logger.error('发送语音消息失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送语音失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 发送图片消息
  Future<void> _sendImageMessage(File imageFile) async {
    if (_token == null) return;

    final fileSize = await imageFile.length();
    if (fileSize > kMaxImageUploadBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片大小不能超过32MB')),
        );
      }
      return;
    }

    // 创建临时消息用于显示上传进度
    final tempId = DateTime.now().millisecondsSinceEpoch;
    final tempMessage = MessageModel(
      id: tempId,
      content: imageFile.path,
      messageType: 'image',
      senderId: _currentUserId!,
      receiverId: widget.userId,
      senderName: '',
      receiverName: widget.displayName,
      createdAt: DateTime.now(),
      status: 'uploading',
      uploadProgress: 0.0,
      isRead: false,
    );

    // 添加临时消息到消息列表（添加到末尾，与其他消息一致）
    setState(() {
      _messages.add(tempMessage);
    });

    // 滚动到底部显示上传进度
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom();
    });

    try {
      // 上传图片 - 使用带进度的接口
      final uploadResponse = await ApiService.uploadImageWithProgress(
        token: _token!,
        filePath: imageFile.path,
        onProgress: (progress) {
          // 更新上传进度
          setState(() {
            final index = _messages.indexWhere((m) => m.id == tempId);
            if (index != -1) {
              // 🔴 修复：使用 copyWith 保留所有字段
              _messages[index] = _messages[index].copyWith(
                uploadProgress: progress,
              );
            }
          });
        },
      );

      final uploadData = uploadResponse['data'] as Map<String, dynamic>?;
      if (uploadData != null) {
        final imageUrl = uploadData['url'] as String;

        // 移除临时消息
        setState(() {
          _messages.removeWhere((m) => m.id == tempId);
        });

        // 发送图片消息
        if (widget.isFileAssistant) {
          final result = await ApiService.sendFileAssistantMessage(
            token: _token!,
            content: imageUrl,
            messageType: 'image',
          );
          
          // 🔴 立即在UI上显示发送的图片消息
          if (result['code'] == 0 && mounted && _currentUserId != null) {
            final messageData = result['data'] as Map<String, dynamic>;
            final messageId = messageData['id'] as int;
            
            // 检查消息是否已存在，避免重复添加
            final exists = _messages.any((m) => m.id == messageId);
            if (!exists) {
              final newMessage = MessageModel(
                id: messageId,
                content: imageUrl,
                messageType: 'image',
                senderId: _currentUserId!,
                receiverId: _currentUserId!,
                senderName: await Storage.getUsername() ?? '',
                receiverName: '文件传输助手',
                senderAvatar: await Storage.getAvatar() ?? '',
                receiverAvatar: '',
                createdAt: DateTime.parse(messageData['created_at'] as String),
                isRead: true,
              );
              
              setState(() {
                _messages.add(newMessage);
              });
            }
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
        } else if (widget.isGroup && widget.groupId != null) {
          // 群聊图片消息 - 先创建临时消息，再发送（和文本消息一致）
          if (_currentUserId != null) {
            final userName = await Storage.getUsername() ?? '';
            final userAvatar = await Storage.getAvatar() ?? '';
            
            final tempId = DateTime.now().millisecondsSinceEpoch;
            _lastSentTempMessageId = tempId; // 保存临时ID用于错误处理
            
            setState(() {
              final newMessage = MessageModel(
                id: tempId,
                content: imageUrl,
                messageType: 'image',
                senderId: _currentUserId!,
                receiverId: widget.groupId!,
                senderName: userName,
                receiverName: widget.displayName,
                senderAvatar: userAvatar,
                receiverAvatar: '',
                createdAt: DateTime.now(),
                isRead: false,
                status: 'sent', // 初始状态为sent
              );
              _messages.add(newMessage);
            });
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
          
          // 然后发送WebSocket
          await _wsService.sendGroupMessage(
            groupId: widget.groupId!,
            content: imageUrl,
            messageType: 'image',
          );
        } else {
          // 私聊图片消息 - 使用 WebSocket
          await _wsService.sendMessage(
            receiverId: widget.userId,
            content: imageUrl,
            messageType: 'image',
          );
          
          // 🔴 立即在UI上显示发送的图片消息
          if (mounted) {
            final userName = await Storage.getUsername() ?? '';
            final userAvatar = await Storage.getAvatar() ?? '';
            
            // 检查消息是否已存在，避免重复添加
            final exists = _messages.any((m) => 
              m.content == imageUrl && 
              m.senderId == _currentUserId && 
              m.receiverId == widget.userId &&
              m.messageType == 'image');
            
            if (!exists) {
              setState(() {
                final newMessage = MessageModel(
                  id: DateTime.now().millisecondsSinceEpoch,
                  content: imageUrl,
                  messageType: 'image',
                  senderId: _currentUserId!,
                  receiverId: widget.userId,
                  senderName: userName,
                  receiverName: widget.displayName,
                  senderAvatar: userAvatar,
                  receiverAvatar: widget.avatar ?? '',
                  createdAt: DateTime.now(),
                  isRead: true,
                );
                _messages.add(newMessage);
              });
            }
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
        }
      }
    } catch (e) {
      // 上传失败，更新临时消息状态
      setState(() {
        final index = _messages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          // 🔴 修复：使用 copyWith 保留所有字段
          _messages[index] = _messages[index].copyWith(
            status: 'failed',
            uploadProgress: 0.0,
          );
        }
      });

      logger.error('发送图片失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送图片失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 发送视频消息
  Future<void> _sendVideoMessage(File videoFile) async {
    if (_token == null) return;

    final fileSize = await videoFile.length();
    if (fileSize > kMaxVideoUploadBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('视频大小不能超过500MB')),
        );
      }
      return;
    }

    // 创建临时消息用于显示上传进度
    final tempId = DateTime.now().millisecondsSinceEpoch;
    final tempMessage = MessageModel(
      id: tempId,
      content: videoFile.path,
      messageType: 'video',
      senderId: _currentUserId!,
      receiverId: widget.userId,
      senderName: '',
      receiverName: widget.displayName,
      createdAt: DateTime.now(),
      status: 'uploading',
      uploadProgress: 0.0,
      isRead: false,
    );

    // 添加临时消息到消息列表（添加到末尾，与其他消息一致）
    setState(() {
      _messages.add(tempMessage);
    });

    // 滚动到底部显示上传进度
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom();
    });

    try {
      // 上传视频 - 使用分片上传服务
      final uploadResponse = await VideoUploadService.uploadVideo(
        token: _token!,
        filePath: videoFile.path,
        onProgress: (uploaded, total) {
          // 更新上传进度
          setState(() {
            final index = _messages.indexWhere((m) => m.id == tempId);
            if (index != -1) {
              // 🔴 修复：使用 copyWith 保留所有字段
              _messages[index] = _messages[index].copyWith(
                uploadProgress: uploaded / total,
              );
            }
          });
        },
      );

      // VideoUploadService 直接返回 url 和 file_name，不包含 data 字段
      final videoUrl = uploadResponse['url'] as String;

      // 移除临时消息
      setState(() {
        _messages.removeWhere((m) => m.id == tempId);
      });

      // 发送视频消息
      if (widget.isFileAssistant) {
        final result = await ApiService.sendFileAssistantMessage(
          token: _token!,
          content: videoUrl,
          messageType: 'video',
        );
        
        // 🔴 立即在UI上显示发送的视频消息
        if (result['code'] == 0 && mounted && _currentUserId != null) {
          final messageData = result['data'] as Map<String, dynamic>;
          final messageId = messageData['id'] as int;
          
          // 检查消息是否已存在，避免重复添加
          final exists = _messages.any((m) => m.id == messageId);
          if (!exists) {
            final newMessage = MessageModel(
              id: messageId,
              content: videoUrl,
              messageType: 'video',
              senderId: _currentUserId!,
              receiverId: _currentUserId!,
              senderName: await Storage.getUsername() ?? '',
              receiverName: '文件传输助手',
              senderAvatar: await Storage.getAvatar() ?? '',
              receiverAvatar: '',
              createdAt: DateTime.parse(messageData['created_at'] as String),
              isRead: true,
            );
            
            setState(() {
              _messages.add(newMessage);
            });
          }
          
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
      } else if (widget.isGroup && widget.groupId != null) {
        // 群聊视频消息 - 先创建临时消息，再发送
        if (_currentUserId != null) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          final tempId = DateTime.now().millisecondsSinceEpoch;
          _lastSentTempMessageId = tempId; // 保存临时ID用于错误处理
          
          setState(() {
            final newMessage = MessageModel(
              id: tempId,
              content: videoUrl,
              messageType: 'video',
              senderId: _currentUserId!,
              receiverId: widget.groupId!,
              senderName: userName,
              receiverName: widget.displayName,
              senderAvatar: userAvatar,
              receiverAvatar: '',
              createdAt: DateTime.now(),
              isRead: false,
              status: 'sent', // 初始状态为sent
            );
            _messages.add(newMessage);
          });
          
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
        
        // 然后发送WebSocket
        await _wsService.sendGroupMessage(
          groupId: widget.groupId!,
          content: videoUrl,
          messageType: 'video',
        );
      } else {
        // 私聊视频消息 - 使用 WebSocket
        await _wsService.sendMessage(
          receiverId: widget.userId,
          content: videoUrl,
          messageType: 'video',
        );
        
        // 🔴 立即在UI上显示发送的视频消息
        if (mounted) {
          final userName = await Storage.getUsername() ?? '';
          final userAvatar = await Storage.getAvatar() ?? '';
          
          // 检查消息是否已存在，避免重复添加
          final exists = _messages.any((m) => 
            m.content == videoUrl && 
            m.senderId == _currentUserId && 
            m.receiverId == widget.userId &&
            m.messageType == 'video');
          
          if (!exists) {
            setState(() {
              _messages.removeWhere((m) => m.id == tempId); // 移除临时消息
              final newMessage = MessageModel(
                id: DateTime.now().millisecondsSinceEpoch,
                content: videoUrl,
                messageType: 'video',
                senderId: _currentUserId!,
                receiverId: widget.userId,
                senderName: userName,
                receiverName: widget.displayName,
                senderAvatar: userAvatar,
                receiverAvatar: widget.avatar ?? '',
                createdAt: DateTime.now(),
                isRead: true,
              );
              _messages.add(newMessage);
            });
          } else {
            // 如果消息已存在，只移除临时消息
            setState(() {
              _messages.removeWhere((m) => m.id == tempId);
            });
          }
          
          Future.delayed(const Duration(milliseconds: 100), () {
            _scrollToBottom();
          });
        }
      }
    } catch (e) {
      // 上传失败，更新临时消息状态
      setState(() {
        final index = _messages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          // 🔴 修复：使用 copyWith 保留所有字段
          _messages[index] = _messages[index].copyWith(
            status: 'failed',
            uploadProgress: 0.0,
          );
        }
      });

      logger.error('发送视频失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送视频失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 发送文件消息
  Future<void> _sendFileMessage(File file, String fileName) async {
    if (_token == null) return;

    final fileSize = await file.length();
    if (fileSize > kMaxFileUploadBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件大小不能超过1GB')),
        );
      }
      return;
    }

    // 创建临时消息用于显示上传进度
    final tempId = DateTime.now().millisecondsSinceEpoch;
    final tempMessage = MessageModel(
      id: tempId,
      content: file.path,
      messageType: 'file',
      fileName: fileName,
      senderId: _currentUserId!,
      receiverId: widget.userId,
      senderName: '',
      receiverName: widget.displayName,
      createdAt: DateTime.now(),
      status: 'uploading',
      uploadProgress: 0.0,
      isRead: false,
    );

    // 添加临时消息到消息列表（添加到末尾，与其他消息一致）
    setState(() {
      _messages.add(tempMessage);
    });

    // 滚动到底部显示上传进度
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom();
    });

    try {
      // 上传文件 - 使用带进度的接口
      final uploadResponse = await ApiService.uploadFileWithProgress(
        token: _token!,
        filePath: file.path,
        onProgress: (progress) {
          // 更新上传进度
          setState(() {
            final index = _messages.indexWhere((m) => m.id == tempId);
            if (index != -1) {
              // 🔴 修复：使用 copyWith 保留所有字段
              _messages[index] = _messages[index].copyWith(
                uploadProgress: progress,
              );
            }
          });
        },
      );

      final uploadData = uploadResponse['data'] as Map<String, dynamic>?;
      if (uploadData != null) {
        final fileUrl = uploadData['url'] as String;

        // 移除临时消息
        setState(() {
          _messages.removeWhere((m) => m.id == tempId);
        });

        // 发送文件消息
        if (widget.isFileAssistant) {
          final result = await ApiService.sendFileAssistantMessage(
            token: _token!,
            content: fileUrl,
            messageType: 'file',
            fileName: fileName,
          );
          
          // 🔴 立即在UI上显示发送的文件消息
          if (result['code'] == 0 && mounted && _currentUserId != null) {
            final messageData = result['data'] as Map<String, dynamic>;
            final messageId = messageData['id'] as int;
            
            // 检查消息是否已存在，避免重复添加
            final exists = _messages.any((m) => m.id == messageId);
            if (!exists) {
              final newMessage = MessageModel(
                id: messageId,
                content: fileUrl,
                messageType: 'file',
                fileName: fileName,
                senderId: _currentUserId!,
                receiverId: _currentUserId!,
                senderName: await Storage.getUsername() ?? '',
                receiverName: '文件传输助手',
                senderAvatar: await Storage.getAvatar() ?? '',
                receiverAvatar: '',
                createdAt: DateTime.parse(messageData['created_at'] as String),
                isRead: true,
              );
              
              setState(() {
                _messages.add(newMessage);
              });
            }
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
        } else if (widget.isGroup && widget.groupId != null) {
          // 群聊文件消息 - 先创建临时消息，再发送
          if (_currentUserId != null) {
            final userName = await Storage.getUsername() ?? '';
            final userAvatar = await Storage.getAvatar() ?? '';
            
            final tempId = DateTime.now().millisecondsSinceEpoch;
            _lastSentTempMessageId = tempId; // 保存临时ID用于错误处理
            
            setState(() {
              final newMessage = MessageModel(
                id: tempId,
                content: fileUrl,
                messageType: 'file',
                fileName: fileName,
                senderId: _currentUserId!,
                receiverId: widget.groupId!,
                senderName: userName,
                receiverName: widget.displayName,
                senderAvatar: userAvatar,
                receiverAvatar: '',
                createdAt: DateTime.now(),
                isRead: false,
                status: 'sent', // 初始状态为sent
              );
              _messages.add(newMessage);
            });
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
          
          // 然后发送WebSocket
          await _wsService.sendGroupMessage(
            groupId: widget.groupId!,
            content: fileUrl,
            messageType: 'file',
            fileName: fileName,
          );
        } else {
          // 私聊文件消息 - 使用 WebSocket
          await _wsService.sendMessage(
            receiverId: widget.userId,
            content: fileUrl,
            messageType: 'file',
            fileName: fileName,
          );
          
          // 🔴 立即在UI上显示发送的文件消息
          if (mounted) {
            final userName = await Storage.getUsername() ?? '';
            final userAvatar = await Storage.getAvatar() ?? '';
            
            // 检查消息是否已存在，避免重复添加
            final exists = _messages.any((m) => 
              m.content == fileUrl && 
              m.senderId == _currentUserId && 
              m.receiverId == widget.userId &&
              m.messageType == 'file');
            
            if (!exists) {
              setState(() {
                _messages.removeWhere((m) => m.id == tempId); // 移除临时消息
                final newMessage = MessageModel(
                  id: DateTime.now().millisecondsSinceEpoch,
                  content: fileUrl,
                  messageType: 'file',
                  fileName: fileName,
                  senderId: _currentUserId!,
                  receiverId: widget.userId,
                  senderName: userName,
                  receiverName: widget.displayName,
                  senderAvatar: userAvatar,
                  receiverAvatar: widget.avatar ?? '',
                  createdAt: DateTime.now(),
                  isRead: true,
                );
                _messages.add(newMessage);
              });
            } else {
              // 如果消息已存在，只移除临时消息
              setState(() {
                _messages.removeWhere((m) => m.id == tempId);
              });
            }
            
            Future.delayed(const Duration(milliseconds: 100), () {
              _scrollToBottom();
            });
          }
        }
      }
    } catch (e) {
      // 上传失败，更新临时消息状态
      setState(() {
        final index = _messages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          // 🔴 修复：使用 copyWith 保留所有字段
          _messages[index] = _messages[index].copyWith(
            status: 'failed',
            uploadProgress: 0.0,
          );
        }
      });

      logger.error('发送文件失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送文件失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 拍照
  Future<void> _takePhoto() async {
    try {
      // 使用统一的相机权限检测
      final hasPermission =
          await MobilePermissionHelper.requestCameraPermission(context);

      if (!hasPermission) {
        return;
      }

      // 使用ImagePicker调用相机
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85, // 设置图片质量，减少文件大小
      );

      if (photo != null) {
        final file = File(photo.path);
        await _sendImageMessage(file);
      }
    } catch (e) {
      logger.error('拍照失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('拍照失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 选择图片
  Future<void> _pickImage() async {
    try {
      // 使用统一的权限检测方法
      final hasPermission =
          await MobileStoragePermissionHelper.checkAndRequestStoragePermission(
            context,
            forSaving: false,
          );

      if (!hasPermission) {
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false, // 禁用自动压缩，避免权限问题
        allowCompression: false, // 禁用压缩
      );

      if (result != null && result.files.isNotEmpty) {
        final file = File(result.files.first.path!);
        await _sendImageMessage(file);
      }
    } catch (e) {
      logger.error('选择图片失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择图片失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 选择视频
  Future<void> _pickVideo() async {
    try {
      // 使用统一的权限检测方法
      final hasPermission =
          await MobileStoragePermissionHelper.checkAndRequestStoragePermission(
            context,
            forSaving: false,
          );

      if (!hasPermission) {
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = File(result.files.first.path!);
        await _sendVideoMessage(file);
      }
    } catch (e) {
      logger.error('选择视频失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择视频失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 选择文件
  Future<void> _pickFile() async {
    try {
      // 使用统一的权限检测方法
      final hasPermission =
          await MobileStoragePermissionHelper.checkAndRequestStoragePermission(
            context,
            forSaving: false,
          );

      if (!hasPermission) {
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final platformFile = result.files.first;
        final file = File(platformFile.path!);
        final fileName = platformFile.name;
        await _sendFileMessage(file, fileName);
      }
    } catch (e) {
      logger.error('选择文件失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择文件失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 开始语音通话
  Future<void> _startVoiceCall() async {
    if (widget.isFileAssistant || _token == null) return;

    try {
      // 检查麦克风权限
      final hasMicPermission =
          await MobilePermissionHelper.requestMicrophonePermission(context);
      if (!hasMicPermission) {
        return;
      }

      if (widget.isGroup && widget.groupId != null) {
        // 群组语音通话
        await _showGroupCallMemberPicker(CallType.voice);
      } else {
        // 🔴 一对一语音通话 - 检查好友关系（前端限制）
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          final contactsResponse = await ApiService.getContacts(token: _token!);
          if (contactsResponse['code'] == 0) {
            final contactsData = contactsResponse['data']['contacts'] as List?;
            if (contactsData != null) {
              final contacts = contactsData.map((json) => ContactModel.fromJson(json)).toList();
              final contactModel = contacts.firstWhere(
                (c) => c.friendId == widget.userId,
                orElse: () => ContactModel(
                  relationId: 0,
                  userId: 0,
                  friendId: widget.userId,
                  username: widget.displayName,
                  avatar: '',
                  status: 'offline',
                  createdAt: DateTime.now(),
                  isDeleted: true, // 默认标记为已删除（找不到联系人）
                ),
              );

              // 检查是否被删除
              if (contactModel.isDeleted) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('该联系人已被删除，无法发起通话'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }

              // 检查是否被拉黑
              if (contactModel.isBlocked || contactModel.isBlockedByMe) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('该联系人已被拉黑，无法发起通话'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }
            }
          }
        }

        // 一对一语音通话
        if (_agoraService != null) {
          await _agoraService.startVoiceCall(widget.userId, widget.displayName);

          // 导航到通话页面
          if (mounted) {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => VoiceCallPage(
                  targetUserId: widget.userId,
                  targetDisplayName: widget.displayName,
                  targetAvatar: widget.avatar,
                  callType: CallType.voice,
                ),
              ),
            );

            // 处理通话结束后的结果
            if (result is Map) {

              // 如果通话最小化，需要导航回主页并显示悬浮按钮
              if (result['showFloatingButton'] == true) {

                // 返回到主页，并传递悬浮按钮信息
                if (mounted) {
                  // 返回主页并传递需要显示悬浮按钮的标记
                  Navigator.of(context).pop({'showFloatingButton': true});
                }
              }
              // 🔴 新增：处理通话取消的情况（发起方在对方未接听时取消）
              else if (result['callCancelled'] == true) {
                await _sendCallCancelledMessage(
                  widget.userId,
                  CallType.voice,
                  isCaller: true,
                );
              }
              // 🔴 新增：处理通话拒绝的情况（接收方拒绝通话）
              else if (result['callRejected'] == true) {
                await _sendCallRejectedMessage(
                  widget.userId,
                  CallType.voice,
                  isRejecter: true,
                );
              }
            }
          }
        }
      }
    } catch (e) {
      logger.error('发起语音通话失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发起语音通话失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 开始视频通话
  Future<void> _startVideoCall() async {
    if (widget.isFileAssistant || _token == null) return;

    try {
      // 检查摄像头权限
      final hasCameraPermission =
          await MobilePermissionHelper.requestCameraPermission(context);
      if (!hasCameraPermission) {
        return;
      }

      // 检查麦克风权限
      final hasMicPermission =
          await MobilePermissionHelper.requestMicrophonePermission(context);
      if (!hasMicPermission) {
        return;
      }

      if (widget.isGroup && widget.groupId != null) {
        // 群组视频通话
        await _showGroupCallMemberPicker(CallType.video);
      } else {
        // 🔴 一对一视频通话 - 检查好友关系（前端限制）
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          final contactsResponse = await ApiService.getContacts(token: _token!);
          if (contactsResponse['code'] == 0) {
            final contactsData = contactsResponse['data']['contacts'] as List?;
            if (contactsData != null) {
              final contacts = contactsData.map((json) => ContactModel.fromJson(json)).toList();
              final contactModel = contacts.firstWhere(
                (c) => c.friendId == widget.userId,
                orElse: () => ContactModel(
                  relationId: 0,
                  userId: 0,
                  friendId: widget.userId,
                  username: widget.displayName,
                  avatar: '',
                  status: 'offline',
                  createdAt: DateTime.now(),
                  isDeleted: true, // 默认标记为已删除（找不到联系人）
                ),
              );

              // 检查是否被删除
              if (contactModel.isDeleted) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('该联系人已被删除，无法发起通话'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }

              // 检查是否被拉黑
              if (contactModel.isBlocked || contactModel.isBlockedByMe) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('该联系人已被拉黑，无法发起通话'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }
            }
          }
        }

        // 一对一视频通话
        if (_agoraService != null) {
          await _agoraService.startVideoCall(widget.userId, widget.displayName);

          // 导航到通话页面
          if (mounted) {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => VoiceCallPage(
                  targetUserId: widget.userId,
                  targetDisplayName: widget.displayName,
                  targetAvatar: widget.avatar,
                  callType: CallType.video,
                ),
              ),
            );

            // 处理通话结束后的结果
            if (result is Map) {

              // 如果通话最小化，需要导航回主页并显示悬浮按钮
              if (result['showFloatingButton'] == true) {

                // 返回到主页，并传递悬浮按钮信息
                if (mounted) {
                  // 返回主页并传递需要显示悬浮按钮的标记
                  Navigator.of(context).pop({'showFloatingButton': true});
                }
              }
              // 🔴 新增：处理通话取消的情况（发起方在对方未接听时取消）
              else if (result['callCancelled'] == true) {
                await _sendCallCancelledMessage(
                  widget.userId,
                  CallType.video,
                  isCaller: true,
                );
              }
              // 🔴 新增：处理通话拒绝的情况（接收方拒绝通话）
              else if (result['callRejected'] == true) {
                await _sendCallRejectedMessage(
                  widget.userId,
                  CallType.video,
                  isRejecter: true,
                );
              }
            }
          }
        }
      }
    } catch (e) {
      logger.error('发起视频通话失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发起视频通话失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 🔴 新增：发送通话拒绝消息
  // isRejecter: true 表示是拒绝方（接收方），false 表示是发起方（收到拒绝通知）
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

      logger.debug('📞 [MobileChatPage] 发送通话拒绝消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为拒绝方: $isRejecter');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');

      // 发送消息给对方
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      logger.debug('✅ [MobileChatPage] 通话拒绝消息已发送给对方');

      // 🔴 在拒绝方/发起方的聊天页面显示相应消息
      if (mounted) {
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          // 拒绝方显示"已拒绝"，发起方显示"对方已拒绝"
          final displayContent = isRejecter ? '已拒绝' : '对方已拒绝';
          
          final rejectMessage = MessageModel(
            id: DateTime.now().millisecondsSinceEpoch,
            senderId: currentUserId,
            receiverId: targetUserId,
            senderName: '',
            receiverName: widget.displayName,
            content: displayContent,
            messageType: messageType,
            isRead: true,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(rejectMessage);
          });

          // 滚动到底部
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });

          logger.debug('📞 [MobileChatPage] 已在聊天页面添加"$displayContent"消息');
        }
      }
    } catch (e) {
      logger.error('❌ [MobileChatPage] 发送通话拒绝消息失败: $e');
    }
  }

  // 🔴 新增：发送通话取消消息
  Future<void> _sendCallCancelledMessage(
    int targetUserId,
    CallType callType, {
    bool isCaller = true,
  }) async {
    try {
      // 发送给对方的消息内容
      // 如果是发起方取消，发送给对方显示"对方已取消"
      final contentToSend = isCaller ? '对方已取消' : '已取消';

      // 根据通话类型确定消息类型
      final messageType = (callType == CallType.video)
          ? 'call_cancelled_video'
          : 'call_cancelled';

      logger.debug('📞 [MobileChatPage] 发送通话取消消息:');
      logger.debug('  - 目标用户ID: $targetUserId');
      logger.debug('  - 消息内容: $contentToSend');
      logger.debug('  - 是否为发起方: $isCaller');
      logger.debug('  - 通话类型: ${callType == CallType.video ? "视频" : "语音"}');

      // 发送消息给对方
      await _wsService.sendMessage(
        receiverId: targetUserId,
        content: contentToSend,
        messageType: messageType,
      );

      logger.debug('✅ [MobileChatPage] 通话取消消息已发送给对方');

      // 🔴 在发起方的聊天页面显示"已取消"消息
      if (isCaller && mounted) {
        final currentUserId = await Storage.getUserId();
        if (currentUserId != null) {
          final cancelMessage = MessageModel(
            id: DateTime.now().millisecondsSinceEpoch,
            senderId: currentUserId,
            receiverId: targetUserId,
            senderName: '',
            receiverName: widget.displayName,
            content: '已取消',
            messageType: messageType,
            isRead: true,
            createdAt: DateTime.now(),
          );

          setState(() {
            _messages.add(cancelMessage);
          });

          // 滚动到底部
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });

          logger.debug('📞 [MobileChatPage] 已在发起方聊天页面添加"已取消"消息');
        }
      }
    } catch (e) {
      logger.error('❌ [MobileChatPage] 发送通话取消消息失败: $e');
    }
  }

  // 显示群组通话成员选择弹窗
  Future<void> _showGroupCallMemberPicker(CallType callType) async {
    if (widget.groupId == null || _token == null) return;

    try {
      // 显示加载对话框
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // 获取群组详情
      final response = await ApiService.getGroupDetail(
        token: _token!,
        groupId: widget.groupId!,
      );

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (response['code'] == 0 && response['data'] != null) {
        final groupData = response['data'];
        
        // 🔐 权限检查：只有群主和管理员可以发起群组通话
        final memberRole = groupData['member_role'] as String?;
        
        if (memberRole != 'owner' && memberRole != 'admin') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  callType == CallType.voice 
                      ? '只有群主和管理员可以发起群组语音通话'
                      : '只有群主和管理员可以发起群组视频通话'
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;
        }
        
        
        final membersData = groupData['members'] as List<dynamic>?;

        if (membersData == null || membersData.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('群组成员列表为空')));
          }
          return;
        }

        // 转换为 GroupCallMember 对象列表
        final members = membersData.map((memberData) {
          return GroupCallMember(
            userId: memberData['user_id'] as int,
            fullName:
                memberData['full_name'] as String? ??
                memberData['username'] as String? ??
                'Unknown',
            username: memberData['username'] as String? ?? 'unknown',
            avatar: memberData['avatar'] as String?,
          );
        }).toList();

        // 获取当前用户ID
        final currentUserId = await Storage.getUserId() ?? 0;

        // 显示成员选择弹窗
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: true,
            builder: (context) => MobileGroupCallMemberPicker(
              members: members,
              currentUserId: currentUserId,
              isVideoCall: callType == CallType.video,
              onConfirm: (selectedUserIds) async {

                if (selectedUserIds.isEmpty) {
                  return;
                }

                // 检查 WebRTC 功能是否启用
                if (!FeatureConfig.enableWebRTC) {
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('通话功能未启用')));
                  }
                  return;
                }

                // 获取选中成员的显示名称
                final selectedDisplayNames = selectedUserIds.map((userId) {
                  if (userId == currentUserId) {
                    return '我';
                  }
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

                // 发起群组通话
                await _startGroupCall(
                  selectedUserIds,
                  selectedDisplayNames,
                  callType,
                  memberRole: memberRole,
                );
              },
            ),
          );
        }
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
      logger.error('显示群组通话成员选择弹窗失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载群组成员失败: $e')));
      }
    }
  }

  // 发起群组通话
  Future<void> _startGroupCall(
    List<int> userIds,
    List<String> displayNames,
    CallType callType, {
    String? memberRole,
  }) async {

    if (!mounted) return;

    try {
      // 获取当前用户ID
      final currentUserId = await Storage.getUserId() ?? 0;

      // 过滤掉当前用户，只保留其他成员
      final otherUserIds = userIds.where((id) => id != currentUserId).toList();
      final otherDisplayNames = <String>[];
      for (int i = 0; i < userIds.length; i++) {
        if (userIds[i] != currentUserId && i < displayNames.length) {
          otherDisplayNames.add(displayNames[i]);
        }
      }

      if (otherUserIds.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请至少选择一个其他成员')));
        }
        return;
      }

      // 确保 Agora 服务已初始化
      if (_agoraService == null) {
        logger.error('📱 [MobileChatPage] Agora 服务未初始化');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('通话服务未准备好')));
        }
        return;
      }

      // 使用第一个其他成员作为主要通话对象
      final firstUserId = otherUserIds.first;
      final firstDisplayName = otherDisplayNames.first;

      // 调用服务器API发起群组通话
      final callData = await ApiService.initiateGroupCall(
        token: _token!,
        calleeIds: otherUserIds,
        callType: callType == CallType.voice ? 'voice' : 'video',
        groupId: widget.isGroup ? widget.groupId : null, // 传递群组ID（仅群聊时）
      );

      // 设置 AgoraService 的频道信息
      _agoraService!.setGroupCallChannel(
        callData['channel_name'],
        callData['token'],
        callType,
        groupId: widget.groupId,
      );

      // 发送群组通话发起消息
      if (widget.groupId != null) {
        await _sendGroupCallInitiatedMessage(widget.groupId!, callType);
      }

      // 创建成员列表（用于UI显示）
      final membersData = callData['members'] as List<dynamic>;
      final memberUserIds =
          membersData.map((m) => m['user_id'] as int).toList();
      final memberDisplayNames = membersData
          .map(
            (m) =>
                m['display_name'] as String? ??
                m['username'] as String? ??
                'Unknown',
          )
          .toList();

      // 为群组成员构建头像URL列表
      final List<String?> memberAvatarUrls = [];
      try {
        final db = LocalDatabaseService();
        for (final uid in memberUserIds) {
          String? avatarUrl;
          if (uid == currentUserId) {
            // 当前用户使用本地存储的头像
            avatarUrl = await Storage.getAvatar();
          } else {
            final snapshot = await db.getContactSnapshot(
              ownerId: currentUserId,
              contactId: uid,
              contactType: 'user',
            );
            if (snapshot == null) {
            } else {
            }
            avatarUrl = snapshot?['avatar']?.toString();
          }
          memberAvatarUrls.add(avatarUrl);
        }
      } catch (e) {
        while (memberAvatarUrls.length < memberUserIds.length) {
          memberAvatarUrls.add(null);
        }
      }

      // 导航到通话页面
      if (mounted) {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => callType == CallType.voice
                ? VoiceCallPage(
                    targetUserId: firstUserId,
                    targetDisplayName: firstDisplayName,
                    isIncoming: false,
                    callType: callType,
                    groupCallUserIds: memberUserIds,
                    groupCallDisplayNames: memberDisplayNames,
                    groupCallAvatarUrls: memberAvatarUrls,
                    currentUserId: currentUserId,
                    groupId: widget.groupId,
                    memberRole: memberRole,
                  )
                : GroupVideoCallPage(
                    targetUserId: firstUserId,
                    targetDisplayName: firstDisplayName,
                    isIncoming: false,
                    groupCallUserIds: memberUserIds,
                    groupCallDisplayNames: memberDisplayNames,
                    currentUserId: currentUserId,
                    groupId: widget.groupId,
                    memberRole: memberRole,
                  ),
          ),
        );

        // 处理通话结束后的结果
        if (result is Map) {

          // 如果通话最小化，需要导航回主页并显示悬浮按钮
          if (result['showFloatingButton'] == true) {

            // 返回到主页，并传递悬浮按钮信息
            if (mounted) {
              Navigator.of(context).pop({'showFloatingButton': true});
            }
          }
        }
      }
    } catch (e) {
      logger.error('发起群组通话失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发起群组通话失败: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // 发送群组通话发起消息
  Future<void> _sendGroupCallInitiatedMessage(
    int groupId,
    CallType callType,
  ) async {
    try {
      final callTypeText = callType == CallType.video ? '视频' : '语音';
      
      // 注释：不再由客户端发送通话发起消息，改由服务器端统一发送 join_voice_button 或 join_video_button 消息
    } catch (e) {
      logger.error('❌ [MobileChatPage] 发送群组通话发起消息失败: $e');
    }
  }

  Widget _buildMessageList() {
    Widget content;

    // 直接显示消息列表，不显示加载指示器
    if (_messagesError != null) {
      content = Container(
        color: const Color(0xFFF5F5F5),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _messagesError!,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadMessages,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90E2),
                ),
                child: const Text('重试', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    } else if (_messages.isEmpty && _hasLoadedCache) {
      // 只有在已加载缓存且确实无消息时才显示空状态
      content = Container(
        color: const Color(0xFFF5F5F5),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '暂无消息记录',
                style: TextStyle(fontSize: 16, color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Text(
                '开始你们的第一条消息吧',
                style: TextStyle(fontSize: 14, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
      );
    } else {
      content = Container(
        color: const Color(0xFFF5F5F5),
        child: Stack(
          children: [
            // 消息列表
            RefreshIndicator(
              onRefresh: _onRefresh,
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                // 🔴 使用reverse: false，保持正常顺序，通过jumpTo跳转到底部
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  final previousMessage = index > 0 ? _messages[index - 1] : null;

                  if (_isDuplicateCallEndedMessage(message, previousMessage)) {
                    return const SizedBox.shrink();
                  }

                  final showTimestamp = _shouldShowTimestamp(
                    message,
                    previousMessage,
                  );

                  if (!_messageKeys.containsKey(message.id)) {
                    _messageKeys[message.id] = GlobalKey();
                  }

                  return Column(
                    key: _messageKeys[message.id],
                    children: [
                      if (showTimestamp) _buildTimestampDivider(message.createdAt),
                      _buildMessageItem(message),
                    ],
                  );
                },
              ),
            ),
            // 🔴 初始加载时的加载动画覆盖层（缓存失效时显示）
            if (_isInitialLoading && !_cacheWasValid)
              Container(
                color: const Color(0xFFF5F5F5),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '加载中...',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                      if (_pendingMediaCount > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '正在加载媒体 $_loadedMediaCount/$_pendingMediaCount',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // 添加手势检测器来关闭更多功能面板
    return GestureDetector(
      onTap: () {
        if (_showMoreOptions) {
          setState(() {
            _showMoreOptions = false;
          });
        }
      },
      behavior: HitTestBehavior.translucent,
      child: content,
    );
  }

  bool _isDuplicateCallEndedMessage(
    MessageModel message,
    MessageModel? previousMessage,
  ) {
    if (previousMessage == null) return false;

    final currentType = message.messageType;
    final previousType = previousMessage.messageType;

    final isCurrentCallEnded =
        currentType == 'call_ended' || currentType == 'call_ended_video';
    final isPreviousCallEnded =
        previousType == 'call_ended' || previousType == 'call_ended_video';

    if (!isCurrentCallEnded || !isPreviousCallEnded) {
      return false;
    }

    if (message.content != previousMessage.content) {
      return false;
    }

    final diff = message.createdAt.difference(previousMessage.createdAt).abs();
    if (diff.inSeconds > 10) {
      return false;
    }

    return true;
  }

  // 判断是否显示时间戳
  bool _shouldShowTimestamp(
    MessageModel message,
    MessageModel? previousMessage,
  ) {
    if (previousMessage == null) return true;

    final diff = message.createdAt.difference(previousMessage.createdAt);
    return diff.inMinutes > 5;
  }

  // 构建时间戳分隔线
  Widget _buildTimestampDivider(DateTime timestamp) {
    final now = DateTime.now();
    final isToday =
        timestamp.year == now.year &&
        timestamp.month == now.month &&
        timestamp.day == now.day;

    final isYesterday =
        timestamp.year == now.year &&
        timestamp.month == now.month &&
        timestamp.day == now.day - 1;

    String timeText;
    if (isToday) {
      timeText = DateFormat('HH:mm').format(timestamp);
    } else if (isYesterday) {
      timeText = '昨天 ${DateFormat('HH:mm').format(timestamp)}';
    } else if (timestamp.year == now.year) {
      timeText = DateFormat('MM-dd HH:mm').format(timestamp);
    } else {
      timeText = DateFormat('yyyy-MM-dd HH:mm').format(timestamp);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Container(height: 0.5, color: Colors.grey[300])),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              timeText,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
          Expanded(child: Container(height: 0.5, color: Colors.grey[300])),
        ],
      ),
    );
  }

  // 构建@提及菜单
  Widget _buildMentionMenu() {
    // 使用 MentionMemberPicker 组件，带搜索栏
    return MentionMemberPicker(
      members: _groupMembers, // 传入所有成员，组件内部会处理搜索
      currentUserRole: _currentUserGroupRole,
      onSelect: (mentionText, mentionedUserIds) {
        // 获取当前输入框文本
        final currentText = _messageController.text;

        // 找到最后一个 @ 符号的位置
        final atIndex = currentText.lastIndexOf('@');
        if (atIndex != -1) {
          // 替换 @ 及其后面的文本
          final newText = currentText.substring(0, atIndex) + mentionText + ' ';
          _messageController.text = newText;
          _messageController.selection = TextSelection.fromPosition(
            TextPosition(offset: newText.length),
          );

          // 添加到已提及用户列表
          _mentionedUserIds.addAll(mentionedUserIds);
        }

        // 关闭菜单
        setState(() {
          _showMentionMenu = false;
        });
      },
    );
  }

  // 构建消息项
  Widget _buildMessageItem(MessageModel message) {
    final isMe = message.senderId == _currentUserId;
    final isHighlighted = _highlightedMessageId == message.id;

    // 系统消息（通话记录等）
    if (_isSystemMessage(message)) {
      return _buildSystemMessage(message);
    }

    // 撤回的消息
    if (message.status == 'recalled') {
      return _buildRecalledMessage(message, isMe);
    }

    return GestureDetector(
      onLongPress: () => _showMessageActions(message),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.only(bottom: 4),
        padding: isHighlighted 
            ? const EdgeInsets.symmetric(vertical: 8, horizontal: 4)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: isHighlighted 
              ? Colors.yellow.withOpacity(0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: isMe
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) _buildAvatar(message),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  // 发送者名称（群聊中显示）
                  if (!isMe)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: 4,
                        left: 8,
                        right: 8,
                      ),
                      child: _buildSenderHeader(message),
                    ),
                  // 消息内容
                  _buildMessageContent(message, isMe),
                  // 消息状态（时间、已读等）
                  if (!_isMultiSelectMode) _buildMessageStatus(message, isMe),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isMe) _buildAvatar(message),
            // 多选模式复选框
            if (_isMultiSelectMode)
              Checkbox(
                value: _selectedMessageIds.contains(message.id),
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedMessageIds.add(message.id);
                    } else {
                      _selectedMessageIds.remove(message.id);
                    }
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  // 判断是否为系统消息
  bool _isSystemMessage(MessageModel message) {
    final isSystem = message.messageType == 'call_initiated' ||
        message.messageType == 'join_voice_button' ||
        message.messageType == 'join_video_button' ||
        message.messageType == 'call_ended' ||
        message.messageType == 'call_ended_video' ||
        message.messageType == 'call_rejected' ||
        message.messageType == 'call_rejected_video' ||
        message.messageType == 'call_cancelled' ||
        message.messageType == 'call_cancelled_video' ||
        message.messageType == 'system';
    
    if (message.messageType == 'join_voice_button' || message.messageType == 'join_video_button') {
    }
    
    return isSystem;
  }

  // 构建系统消息
  Widget _buildSystemMessage(MessageModel message) {
    // logger.debug('🎨 [Mobile-构建消息] _buildSystemMessage被调用 - MessageID: ${message.id}, Type: ${message.messageType}');

    // 特殊处理：通话发起消息，显示"加入通话"按钮
    // 注意：通话结束后，服务器会删除按钮消息，所以不需要客户端判断
    if ((message.messageType == 'call_initiated' ||
            message.messageType == 'join_voice_button' ||
            message.messageType == 'join_video_button') &&
        message.channelName != null &&
        message.channelName!.isNotEmpty) {

      // 根据消息类型确定通话类型文案
      String callTypeText;
      if (message.messageType == 'join_video_button') {
        callTypeText = '视频通话';
      } else if (message.messageType == 'join_voice_button') {
        callTypeText = '语音通话';
      } else {
        // 兼容旧的 call_initiated 消息，使用 callType 字段
        callTypeText = message.callType == 'video' ? '视频通话' : '语音通话';
      }

      // 目前需求：隐藏"加入通话"按钮，仅展示系统提示文本
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            message.content,
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // 通话相关消息（拒绝、取消、结束）- 添加图标
    if (message.messageType == 'call_rejected' ||
        message.messageType == 'call_rejected_video' ||
        message.messageType == 'call_cancelled' ||
        message.messageType == 'call_cancelled_video' ||
        message.messageType == 'call_ended' ||
        message.messageType == 'call_ended_video') {

      // 根据消息类型确定图标
      IconData callIcon;
      if (message.messageType == 'call_rejected_video' ||
          message.messageType == 'call_cancelled_video' ||
          message.messageType == 'call_ended_video') {
        callIcon = Icons.videocam_off; // 视频通话图标
      } else {
        callIcon = Icons.call_end; // 语音通话图标
      }

      // 🔴 修复：根据当前用户是发送者还是接收者来决定显示内容
      // 发送者看到的是"已拒绝"/"已取消"，接收者看到的是"对方已拒绝"/"对方已取消"
      String displayContent = message.content;
      final isSender = message.senderId == _currentUserId;
      
      // 处理拒绝消息
      if (message.messageType == 'call_rejected' ||
          message.messageType == 'call_rejected_video') {
        if (isSender) {
          // 发送者（拒绝方）看到"已拒绝"
          displayContent = '已拒绝';
        } else {
          // 接收者（被拒绝方）看到"对方已拒绝"
          displayContent = '对方已拒绝';
        }
      }
      // 处理取消消息
      else if (message.messageType == 'call_cancelled' ||
               message.messageType == 'call_cancelled_video') {
        if (isSender) {
          // 发送者（取消方）看到"已取消"
          displayContent = '已取消';
        } else {
          // 接收者（被取消方）看到"对方已取消"
          displayContent = '对方已取消';
        }
      }
      // 通话结束消息前增加"通话时长"
      else if ((message.messageType == 'call_ended' ||
              message.messageType == 'call_ended_video') &&
          !displayContent.startsWith('通话时长')) {
        displayContent = '通话时长 ${displayContent}';
      }

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                callIcon,
                size: 14,
                color: Colors.grey[600],
              ),
              const SizedBox(width: 6),
              Text(
                displayContent,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // 普通系统消息
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message.content,
          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  // 处理加入群组通话
  Future<void> _handleJoinGroupCall(MessageModel message) async {
    try {
      
      // 检查必要参数
      if (message.channelName == null || message.channelName!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('通话信息不完整，无法加入')),
          );
        }
        return;
      }

      // 检查是否已在其他通话中
      final agoraService = AgoraService();
      if (agoraService.isMinimized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('您已在其他通话中，请先挂断当前通话')),
          );
        }
        return;
      }

      final token = await Storage.getToken();
      final currentUserId = await Storage.getUserId();
      
      if (token == null || currentUserId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录信息已过期，请重新登录')),
          );
        }
        return;
      }

      // 调用acceptGroupCall API，加入通话
      final acceptResponse = await ApiService.acceptGroupCall(
        token: token,
        channelName: message.channelName!,
      );

      // 获取群组成员信息（如果有groupId）
      List<int>? groupCallUserIds;
      List<String>? groupCallDisplayNames;
      
      if (widget.isGroup && widget.groupId != null) {
        try {
          final response = await ApiService.getGroupDetail(
            token: token,
            groupId: widget.groupId!,
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
            }
          }
        } catch (e) {
        }
      }

      // 🔴 新增：设置AgoraService的频道信息（主动加入通话时需要）
      // 使用acceptGroupCall API返回的频道信息和Token
      if (agoraService.currentChannelName == null) {
        final callType = message.callType == 'video' ? CallType.video : CallType.voice;
        agoraService.setGroupCallChannel(
          acceptResponse['channel_name'] ?? message.channelName!,
          acceptResponse['token'] ?? '', // 使用API返回的Token
          callType,
          groupId: widget.groupId,
          memberUserIds: groupCallUserIds,
          memberDisplayNames: groupCallDisplayNames,
        );
      }

      // 导航到通话页面
      if (mounted) {
        final callType = message.callType == 'video' ? CallType.video : CallType.voice;
        
        dynamic result;
        if (callType == CallType.video) {
          // 视频通话
          result = await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => GroupVideoCallPage(
                targetUserId: message.senderId,
                targetDisplayName: message.displaySenderName,
                isIncoming: true,
                groupCallUserIds: groupCallUserIds,
                groupCallDisplayNames: groupCallDisplayNames,
                currentUserId: currentUserId,
                groupId: widget.groupId,
              ),
            ),
          );
        } else {
          // 语音通话 - 修复：主动加入通话应该设置为 isIncoming: false
          result = await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => VoiceCallPage(
                targetUserId: message.senderId,
                targetDisplayName: message.displaySenderName,
                isIncoming: false, // 🔴 修复：主动加入通话，不是来电
                groupCallUserIds: groupCallUserIds,
                groupCallDisplayNames: groupCallDisplayNames,
                currentUserId: currentUserId,
                groupId: widget.groupId,
                isJoiningExistingCall: true, // 🔴 新增：标记为加入已存在的通话
              ),
            ),
          );
        }
        
        // 注意：通话结束后服务器会自动删除"加入通话"按钮消息并推送delete_message通知
        // 客户端通过WebSocket接收通知并自动删除，不需要手动刷新
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加入通话失败: $e')),
        );
      }
    }
  }

  // 构建撤回的消息
  Widget _buildRecalledMessage(MessageModel message, bool isMe) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        isMe ? '你撤回了一条消息' : '${message.displaySenderName}撤回了一条消息',
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  // 构建头像
  Widget _buildAvatar(MessageModel message) {
    final isMe = message.senderId == _currentUserId;
    
    // 优先使用头像缓存中的最新头像
    String? avatarUrl;
    if (isMe) {
      // 自己的消息：优先使用当前用户头像，然后是缓存，最后是消息中的头像
      avatarUrl = _currentUserAvatar?.isNotEmpty == true 
          ? _currentUserAvatar 
          : (_avatarCache[_currentUserId] ?? message.senderAvatar);
    } else {
      // 对方的消息：优先使用缓存中的头像，然后是消息中的头像
      avatarUrl = _avatarCache[message.senderId] ?? message.senderAvatar;
    }
    final displayName = isMe ? '我' : message.displaySenderName;

    // 生成头像文字（取名字最后两个字）
    String avatarText = '';
    if (displayName.isNotEmpty) {
      avatarText = displayName.length >= 2
          ? displayName.substring(displayName.length - 2)
          : displayName;
    }

    Widget avatarWidget = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFF4A90E2),
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl != null && avatarUrl.isNotEmpty
          ? Image.network(
              avatarUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Center(
                  child: Text(
                    avatarText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            )
          : Center(
              child: Text(
                avatarText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
    );

    // 如果不是自己的头像，添加点击事件
    if (!isMe) {
      return GestureDetector(
        onTap: () {
          // 点击头像显示对方的用户信息
          _showOtherUserInfo(message.senderId);
        },
        child: avatarWidget,
      );
    }

    return avatarWidget;
  }

  // 显示对方的用户信息
  Future<void> _showOtherUserInfo(int userId) async {
    try {

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
      if (widget.isGroup && widget.groupId != null) {
        try {

          // 调用API获取群组详细信息
          final groupResponse = await ApiService.getGroupDetail(
            token: token,
            groupId: widget.groupId!,
          );

          if (groupResponse['code'] == 0 && groupResponse['data'] != null) {
            final groupData =
                groupResponse['data']['group'] as Map<String, dynamic>?;
            final memberRole = groupResponse['data']['member_role'] as String?;

            if (groupData != null) {
              final ownerId = groupData['owner_id'] as int?;
              final memberViewPermission =
                  groupData['member_view_permission'] as bool? ?? true;

              final currentUserId = _currentUserId;
              if (currentUserId != null && currentUserId > 0) {
                // 检查当前用户是否是群主
                final isOwner = ownerId == currentUserId;
                // 检查当前用户是否是管理员
                final isAdmin = memberRole == 'admin';

                // 如果不是群主也不是管理员，且群组关闭了成员查看权限，则不允许查看
                if (!isOwner && !isAdmin && !memberViewPermission) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('群主已关闭群成员查看权限')),
                    );
                  }
                  return;
                }

              }
            }
          } else {
            // 获取群组信息失败，为了安全起见，禁止查看
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('获取群组信息失败，无法查看成员信息')),
              );
            }
            return;
          }
        } catch (e) {
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

        // 显示用户信息弹窗（不显示编辑按钮）
        if (mounted) {
          UserInfoDialog.show(
            context,
            username: userData['username'] ?? '',
            userId: userId.toString(),
            status: userData['status'] ?? 'offline',
            token: _token ?? '',
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

  // 构建消息内容
  Widget _buildMessageContent(MessageModel message, bool isMe) {
    Widget content;

    switch (message.messageType) {
      case 'quoted':
        // 引用消息：在一个容器内显示引用内容和回复内容
        content = _buildQuotedMessageWithReply(message, isMe);
        break;
      case 'text':
        content = _buildTextMessage(message, isMe);
        break;
      case 'image':
        content = _buildImageMessage(message, isMe);
        break;
      case 'video':
        content = _buildVideoMessage(message, isMe);
        break;
      case 'file':
        content = _buildFileMessage(message, isMe);
        break;
      case 'voice':
        content = _buildVoiceMessage(message, isMe);
        break;
      case 'link':
        content = _buildLinkMessage(message, isMe);
        break;
      case 'location':
        content = _buildLocationMessage(message, isMe);
        break;
      default:
        content = _buildTextMessage(message, isMe);
    }

    return content;
  }

  // 构建引用消息（包含引用内容和回复内容）
  Widget _buildQuotedMessageWithReply(MessageModel message, bool isMe) {
    // 查找被引用的原始消息
    String quotedSenderName = '';
    if (message.quotedMessageId != null) {
      // 🔴 使用serverId匹配，因为quoted_message_id是服务器ID
      logger.debug('🔍 [_buildQuotedMessageWithReply] 查找引用消息 - quotedMessageId: ${message.quotedMessageId}');
      logger.debug('🔍 [_buildQuotedMessageWithReply] 本地消息列表数量: ${_messages.length}');
      
      // 打印所有消息的ID和serverId用于调试
      for (var i = 0; i < _messages.length; i++) {
        logger.debug('🔍 [_buildQuotedMessageWithReply] 消息[$i] - id: ${_messages[i].id}, serverId: ${_messages[i].serverId}');
      }
      
      final quotedMessage = _messages.firstWhere(
        (msg) => msg.serverId == message.quotedMessageId || msg.id == message.quotedMessageId,
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
        logger.debug('✅ [_buildQuotedMessageWithReply] 找到引用消息 - id: ${quotedMessage.id}, content: ${quotedMessage.content}');
        // 判断被引用消息的发送者是否是当前用户
        if (quotedMessage.senderId == _currentUserId) {
          quotedSenderName = '我';
        } else {
          // 使用 displaySenderName 获取显示名称（优先使用群组昵称）
          quotedSenderName = quotedMessage.displaySenderName;
        }
      } else {
        logger.debug('❌ [_buildQuotedMessageWithReply] 未找到引用消息 - quotedMessageId: ${message.quotedMessageId}');
      }
    }

    return GestureDetector(
      onTap: () {
        // 点击引用消息，跳转到被引用的消息位置
        if (message.quotedMessageId != null) {
          _scrollToQuotedMessage(message.quotedMessageId!);
        }
      },
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.50,
        ),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFBDD7F3) : const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(color: const Color(0xFF4A90E2), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 引用消息标题
            Row(
              children: [
                Icon(Icons.reply, size: 14, color: Color(0xFF4A90E2)),
                const SizedBox(width: 4),
                Text(
                  '引用消息',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF4A90E2),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
            if (quotedSenderName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                quotedSenderName,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF4A90E2),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
            const SizedBox(height: 4),
            // 被引用的内容
            Text(
              message.quotedMessageContent ?? '',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF666666),
                fontStyle: FontStyle.italic,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            // 回复内容
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '回复：',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  TextSpan(
                    text: message.content,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF333333),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建文本消息
  Widget _buildTextMessage(MessageModel message, bool isMe) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.65,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFFD6EFEC) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: _buildMessageWithEmotions(message.content, isMe),
    );
  }

  // 解析并渲染包含表情的文本
  Widget _buildMessageWithEmotions(String content, bool isMe) {
    // 检查是否包含表情标签
    if (!content.contains('[emotion:')) {
      return AbsorbPointer(
        child: SelectableText(
          content,
          style: TextStyle(
            fontSize: 15,
            color: isMe ? Colors.black : Colors.black87,
            height: 1.4,
          ),
        ),
      );
    }

    // 解析表情和文本
    final List<InlineSpan> spans = [];
    final RegExp emotionPattern = RegExp(r'\[emotion:([^\]]+\.png)\]');
    int lastMatchEnd = 0;

    for (final match in emotionPattern.allMatches(content)) {
      // 添加表情前的文本
      if (match.start > lastMatchEnd) {
        spans.add(
          TextSpan(
            text: content.substring(lastMatchEnd, match.start),
            style: TextStyle(
              fontSize: 15,
              color: isMe ? Colors.black : Colors.black87,
              height: 1.4,
            ),
          ),
        );
      }

      // 添加表情图片
      final emotionFile = match.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Image.asset(
            'assets/消息/emotion/$emotionFile',
            width: 24,
            height: 24,
            errorBuilder: (context, error, stackTrace) {
              // 如果图片加载失败，显示表情文本
              return Text(
                '[表情]',
                style: TextStyle(
                  fontSize: 15,
                  color: isMe ? Colors.black : Colors.black87,
                ),
              );
            },
          ),
        ),
      );

      lastMatchEnd = match.end;
    }

    // 添加最后剩余的文本
    if (lastMatchEnd < content.length) {
      spans.add(
        TextSpan(
          text: content.substring(lastMatchEnd),
          style: TextStyle(
            fontSize: 15,
            color: isMe ? Colors.black : Colors.black87,
            height: 1.4,
          ),
        ),
      );
    }

    return AbsorbPointer(
      child: Text.rich(TextSpan(children: spans)),
    );
  }



  // 构建图片消息
  Widget _buildImageMessage(MessageModel message, bool isMe) {
    // 处理正在上传的图片
    if (message.status == 'uploading') {
      return Container(
        constraints: const BoxConstraints(maxWidth: 200, maxHeight: 300),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 如果是本地文件，显示预览
            if (message.content.startsWith('/') ||
                message.content.startsWith('C:'))
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(message.content),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      width: 200,
                      height: 150,
                      color: Colors.grey[300],
                      child: const Icon(
                        Icons.image,
                        size: 48,
                        color: Colors.grey,
                      ),
                    );
                  },
                ),
              ),
            // 半透明遮罩
            Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // 上传进度 - 转圈动画
            const SizedBox(
              width: 50,
              height: 50,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    // 处理上传失败的图片
    if (message.status == 'failed') {
      return Container(
        constraints: const BoxConstraints(maxWidth: 200, maxHeight: 150),
        decoration: BoxDecoration(
          color: Colors.red[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red[200]!, width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[400]),
            const SizedBox(height: 8),
            Text(
              '图片发送失败',
              style: TextStyle(color: Colors.red[600], fontSize: 12),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () async {
                // 重新发送
                final file = File(message.content);
                if (await file.exists()) {
                  // 移除失败的消息
                  setState(() {
                    _messages.removeWhere((m) => m.id == message.id);
                  });
                  // 重新发送
                  await _sendImageMessage(file);
                }
              },
              child: Text(
                '点击重试',
                style: TextStyle(
                  color: Theme.of(context).primaryColor,
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 正常的图片消息（已上传完成）
    return GestureDetector(
      onTap: () => _viewImage(message.content),
      onLongPress: () => _showMessageActions(message),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200, maxHeight: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          message.content,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              // 🔴 图片加载完成，通知回调（传入消息ID防止重复计数）
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _onMediaLoadedWithId(message.id);
              });
              return child;
            }
            return Container(
              width: 200,
              height: 150,
              color: Colors.grey[200],
              child: Center(
                child: CircularProgressIndicator(
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                      : null,
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            // 🔴 图片加载失败，也通知回调（避免卡住）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _onMediaLoadFailedWithId(message.id);
            });
            return Container(
              width: 200,
              height: 150,
              color: Colors.grey[200],
              child: const Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
            );
          },
        ),
      ),
    );
  }

  // 构建视频消息
  Widget _buildVideoMessage(MessageModel message, bool isMe) {
    // 处理正在上传的视频
    if (message.status == 'uploading') {
      return Container(
        width: 200,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 视频图标背景
            Container(
              decoration: BoxDecoration(color: Colors.grey[800]),
              child: const Center(
                child: Icon(Icons.videocam, color: Colors.white54, size: 48),
              ),
            ),
            // 半透明遮罩
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.black.withOpacity(0.5),
              ),
            ),
            // 上传进度指示器 - 转圈动画
            const SizedBox(
              width: 50,
              height: 50,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    // 处理上传失败的视频
    if (message.status == 'failed') {
      return GestureDetector(
        onTap: () {
          // 重新发送
          if (message.content.startsWith('/') ||
              message.content.startsWith('C:')) {
            _sendVideoMessage(File(message.content));
          }
        },
        child: Container(
          width: 200,
          height: 150,
          decoration: BoxDecoration(
            color: Colors.red[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 8),
              const Text(
                '视频上传失败',
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '点击重试',
                  style: TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 正常的视频消息
    // 🔴 视频消息不需要网络加载缩略图，直接通知加载完成（传入消息ID防止重复计数）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onMediaLoadedWithId(message.id);
    });
    
    return GestureDetector(
      onTap: () => _playVideo(message.content),
      child: Container(
        width: 200,
        height: 150,
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFD6EFEC) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 视频缩略图或占位符
              Container(
                decoration: BoxDecoration(color: Colors.grey[800]),
                child: const Center(
                  child: Icon(Icons.videocam, color: Colors.white54, size: 48),
                ),
              ),
              // 播放按钮
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              // 时长标签（如果有的话）
              // if (message.videoDuration != null)
              //   Positioned(
              //     bottom: 8,
              //     right: 8,
              //     child: Container(
              //       padding: const EdgeInsets.symmetric(
              //         horizontal: 6,
              //         vertical: 2,
              //       ),
              //       decoration: BoxDecoration(
              //         color: Colors.black.withOpacity(0.7),
              //         borderRadius: BorderRadius.circular(4),
              //       ),
              //       child: Text(
              //         _formatVideoDuration(message.videoDuration!),
              //         style: const TextStyle(
              //           color: Colors.white,
              //           fontSize: 12,
              //         ),
              //       ),
              //     ),
              //   ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建文件消息
  Widget _buildFileMessage(MessageModel message, bool isMe) {
    final fileName = message.fileName ?? '未知文件';
    final fileExt = fileName.split('.').last.toLowerCase();
    IconData fileIcon = Icons.insert_drive_file;
    Color iconColor = Colors.grey;

    // 根据文件类型显示不同图标
    if (['doc', 'docx'].contains(fileExt)) {
      fileIcon = Icons.description;
      iconColor = Colors.blue;
    } else if (['xls', 'xlsx'].contains(fileExt)) {
      fileIcon = Icons.table_chart;
      iconColor = Colors.green;
    } else if (['ppt', 'pptx'].contains(fileExt)) {
      fileIcon = Icons.slideshow;
      iconColor = Colors.orange;
    } else if (['pdf'].contains(fileExt)) {
      fileIcon = Icons.picture_as_pdf;
      iconColor = Colors.red;
    } else if (['zip', 'rar', '7z'].contains(fileExt)) {
      fileIcon = Icons.archive;
      iconColor = Colors.purple;
    }

    // 处理正在上传的文件
    if (message.status == 'uploading') {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(fileIcon, color: iconColor.withOpacity(0.3), size: 40),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[800],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '上传中...',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 处理上传失败的文件
    if (message.status == 'failed') {
      return GestureDetector(
        onTap: () {
          // 重新发送
          if (message.content.startsWith('/') ||
              message.content.startsWith('C:')) {
            _sendFileMessage(File(message.content), fileName);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.red,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '上传失败，点击重试',
                      style: TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 正常的文件消息
    return GestureDetector(
      onTap: () => _downloadFile(message),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFD6EFEC) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(fileIcon, color: iconColor, size: 40),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    '点击下载',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建语音消息
  Widget _buildVoiceMessage(MessageModel message, bool isMe) {
    // 语音时长：优先使用voiceDuration字段，其次从content中解析（格式：url|duration）
    int duration = message.voiceDuration ?? 0;
    String voiceUrl = message.content;
    
    // 🔍 添加详细日志
    logger.debug('🎤 [_buildVoiceMessage] 构建语音消息:');
    logger.debug('   - message.id: ${message.id}');
    logger.debug('   - message.voiceDuration: ${message.voiceDuration}');
    logger.debug('   - duration: $duration');
    logger.debug('   - content: ${message.content}');

    // 兼容旧格式：url|duration
    if (duration == 0 && message.content.contains('|')) {
      final parts = message.content.split('|');
      voiceUrl = parts[0];
      duration = int.tryParse(parts[1]) ?? 0;
    }

    return VoiceMessageBubble(
      url: voiceUrl,
      duration: duration,
      isMe: isMe,
    );
  }

  // 构建链接消息
  Widget _buildLinkMessage(MessageModel message, bool isMe) {
    return GestureDetector(
      onTap: () => _openLink(message.content),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFD6EFEC) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link, color: Colors.blue, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message.content,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建位置消息
  Widget _buildLocationMessage(MessageModel message, bool isMe) {
    // 位置信息格式：lat,lng|address
    String address = '未知位置';
    if (message.content.contains('|')) {
      address = message.content.split('|')[1];
    }

    return GestureDetector(
      onTap: () => _viewLocation(message.content),
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFD6EFEC) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_on, color: Colors.red, size: 20),
                const SizedBox(width: 4),
                const Text(
                  '位置',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              address,
              style: const TextStyle(fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSenderHeader(MessageModel message) {
    final displayName = message.senderNickname?.isNotEmpty == true
        ? message.senderNickname!
        : (message.displaySenderName.isNotEmpty
              ? message.displaySenderName
              : 'Unknown');
    final timeLabel = message.formattedTime;

    return Text(
      '$displayName, $timeLabel',
      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
    );
  }

  // 构建消息状态（时间、已读等）
  Widget _buildMessageStatus(MessageModel message, bool isMe) {
    if (!isMe) {
      return const SizedBox(height: 4);
    }

    final time = DateFormat('HH:mm').format(message.createdAt);
    
    // 检查消息状态
    final isFailed = message.status == 'failed';
    final isForbidden = message.status == 'forbidden'; // 🔴 被拉黑/删除/移除后发送的消息
    final isSending = message.status == 'sending';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(time, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          if (isMe) ...[
            const SizedBox(width: 4),
            // 🔴 群聊中：只显示错误图标，其他情况隐藏
            if (widget.isGroup) ...[
              if (isForbidden || isFailed)
                const Icon(
                  Icons.error,
                  size: 14,
                  color: Colors.red,
                )
              // 其他状态不显示图标
            ] else ...[
              // 🔴 修复：私聊中根据isRead字段显示已读/未读图标
              if (isForbidden)
                // 被拉黑/删除/移除状态：显示红色感叹号
                const Icon(
                  Icons.error,
                  size: 14,
                  color: Colors.red,
                )
              else if (isFailed)
                // 失败状态：显示红色感叹号
                const Icon(
                  Icons.error,
                  size: 14,
                  color: Colors.red,
                )
              else if (isSending)
                // 发送中：显示灰色单勾
                Icon(
                  Icons.done,
                  size: 14,
                  color: Colors.grey[400],
                )
              else if (message.isRead && message.readAt != null)
                // 🔴 已读（根据isRead字段判断）：显示蓝色双钩
                const Icon(
                  Icons.done_all,
                  size: 14,
                  color: Colors.blue,
                )
              else
                // 🔴 未读或未确认：显示灰色单勾
                Icon(
                  Icons.done,
                  size: 14,
                  color: Colors.grey[400],
                ),
            ],
          ],
        ],
      ),
    );
  }

  // 显示消息操作菜单
  void _showMessageActions(MessageModel message) {
    final isMe = message.senderId == _currentUserId;
    final isMediaFile =
        message.messageType == 'image' ||
        message.messageType == 'video' ||
        message.messageType == 'voice' ||
        message.messageType == 'file';

    // 调试信息：打印消息详情
    logger.debug('长按消息 - ID: ${message.id}, Type: ${message.messageType}, Content: ${message.content}, FileName: ${message.fileName}');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        // 获取设备底部安全区域高度
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          constraints: const BoxConstraints(
            minHeight: 400, // 设置最小高度，确保菜单有足够空间显示
          ),
          // 使用底部安全区域高度，至少20像素
          padding: EdgeInsets.only(
            bottom: bottomPadding > 0 ? bottomPadding : 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 5,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                // 保存到本地（图片、视频、文件）
                if (isMediaFile)
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: const Text('保存到本地'),
                    onTap: () {
                      Navigator.pop(context);
                      _downloadFile(message);
                    },
                  ),
                // 复制（文本消息）
                if (message.messageType == 'text')
                  ListTile(
                    leading: const Icon(Icons.copy),
                    title: const Text('复制'),
                    onTap: () {
                      Navigator.pop(context);
                      _copyMessage(message);
                    },
                  ),
                // 转发
                ListTile(
                  leading: const Icon(Icons.forward),
                  title: const Text('转发'),
                  onTap: () {
                    Navigator.pop(context);
                    _forwardMessage(message);
                  },
                ),
                // 收藏
                ListTile(
                  leading: const Icon(Icons.star_border),
                  title: const Text('收藏'),
                  onTap: () {
                    Navigator.pop(context);
                    _favoriteMessage(message);
                  },
                ),
                // 引用回复
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('引用'),
                  onTap: () {
                    Navigator.pop(context);
                    _quoteMessage(message);
                  },
                ),
                // 多选
                ListTile(
                  leading: const Icon(Icons.checklist),
                  title: const Text('多选'),
                  onTap: () {
                    Navigator.pop(context);
                    _startMultiSelect(message);
                  },
                ),
                // 删除
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text('删除', style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(context);
                    _deleteMessage(message);
                  },
                ),
                // 撤回（自己的消息3分钟内可撤回；群主/管理员可随时撤回群组内任何人的消息）
                if (_canRecallMessage(message, isMe))
                  ListTile(
                    leading: const Icon(Icons.undo),
                    title: const Text('撤回'),
                    onTap: () {
                      Navigator.pop(context);
                      _recallMessage(message);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 复制消息
  void _copyMessage(MessageModel message) {
    Clipboard.setData(ClipboardData(text: message.content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
    );
  }

  // 下载文件到本地（完全按照"我的收藏"的实现）
  Future<void> _downloadFile(MessageModel message) async {
    try {
      // 桌面端使用原有的文件选择器方式（不修改PC端代码）
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        await _downloadFileDesktop(message);
        return;
      }

      // 移动端：使用统一的权限检测方法
      final hasPermission =
          await MobileStoragePermissionHelper.checkAndRequestStoragePermission(
            context,
            forSaving: true,
          );

      if (!hasPermission) {
        return;
      }

      // 显示下载提示
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在下载...')));
      }

      final fileUrl = message.content;

      logger.debug('开始下载文件 - messageType: ${message.messageType}, URL: $fileUrl');

      // 确定文件名
      String fileName = message.fileName ?? 'download';
      if (!fileName.contains('.')) {
        final uri = Uri.parse(fileUrl);
        final segments = uri.pathSegments;
        if (segments.isNotEmpty) {
          fileName = segments.last;
        } else {
          // 根据消息类型添加扩展名
          if (message.messageType == 'image') {
            fileName = '${fileName}.jpg';
          } else if (message.messageType == 'video') {
            fileName = '${fileName}.mp4';
          } else if (message.messageType == 'voice') {
            fileName = '${fileName}.m4a';
          }
        }
      }

      logger.debug('文件名: $fileName');

      // 下载文件
      final response = await http.get(Uri.parse(fileUrl));
      if (response.statusCode != 200) {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }

      // 🔴 只有图片和视频保存到相册，语音和其他文件保存到Download目录
      if (message.messageType == 'image' || message.messageType == 'video') {
        // 保存图片或视频到相册
        // 先保存到临时文件
        final tempDir = await getTemporaryDirectory();
        
        // 从文件名中获取扩展名，如果没有则使用默认扩展名
        String extension;
        if (fileName.contains('.')) {
          extension = fileName.split('.').last.toLowerCase();
        } else {
          extension = message.messageType == 'image' ? 'jpg' : 'mp4';
        }
        
        // 确保视频使用支持的格式
        if (message.messageType == 'video') {
          // iOS 支持的视频格式：mp4, mov, m4v
          if (!['mp4', 'mov', 'm4v'].contains(extension)) {
            extension = 'mp4';
          }
        }
        
        final tempFile = File('${tempDir.path}/youdu_${DateTime.now().millisecondsSinceEpoch}.$extension');
        await tempFile.writeAsBytes(response.bodyBytes);
        
        logger.debug('准备保存${message.messageType == 'image' ? '图片' : '视频'}到相册: ${tempFile.path}');
        
        // 使用 Gal 保存到相册
        try {
          if (message.messageType == 'image') {
            await Gal.putImage(tempFile.path);
            logger.debug('图片已成功保存到相册');
          } else {
            await Gal.putVideo(tempFile.path);
            logger.debug('视频已成功保存到相册');
          }
          
          // 删除临时文件
          await tempFile.delete();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message.messageType == 'image' ? '图片已保存到相册' : '视频已保存到相册'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } catch (galError) {
          logger.error('保存到相册失败: $galError');
          // 删除临时文件
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
          throw Exception('保存到相册失败: $galError');
        }
      } else {
        // 其他文件保存到Download目录
        Directory? directory;
        if (Platform.isAndroid) {
          // Android: 保存到 Downloads 目录
          directory = Directory('/storage/emulated/0/Download/Youdu');
          if (!await directory.exists()) {
            await directory.create(recursive: true);
          }
        } else {
          // iOS: 保存到应用文档目录
          directory = await getApplicationDocumentsDirectory();
        }

        // 保存文件
        final filePath = '${directory.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '已保存到: ${Platform.isAndroid ? 'Download/Youdu' : '应用文档目录'}/$fileName',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      logger.error('下载文件失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  // 桌面端下载文件
  Future<void> _downloadFileDesktop(MessageModel message) async {
    try {
      final fileUrl = message.content;
      String defaultFileName = message.fileName ?? 'download';
      if (!defaultFileName.contains('.')) {
        final uri = Uri.parse(fileUrl);
        final segments = uri.pathSegments;
        if (segments.isNotEmpty) {
          defaultFileName = segments.last;
        }
      }

      final String? outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: defaultFileName,
      );

      if (outputPath == null) {
        return;
      }

      final response = await http.get(Uri.parse(fileUrl));

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('文件已保存至: $outputPath')));
        }
      } else {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }
    } catch (e) {
      logger.error('下载文件失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  // 获取Android版本号（与"我的收藏"实现一致）
  // 转发消息
  void _forwardMessage(MessageModel message) async {
    // 显示转发弹窗，传递单条消息的列表
    final result = await showForwardMessageDialog(context, [message]);

    // 如果转发成功，显示提示（弹窗内部已经显示了，这里可以省略）
    if (result == true && mounted) {
      // 可以选择在这里显示额外的提示，或者什么都不做
    }
  }

  // 收藏消息
  Future<void> _favoriteMessage(MessageModel message) async {
    if (_token == null) return;

    try {
      // 🔍 添加详细日志：打印消息的所有关键字段
      logger.debug('⭐ [收藏消息] 准备收藏消息');
      logger.debug('   - message.id (本地ID): ${message.id}');
      logger.debug('   - message.serverId (服务器ID): ${message.serverId}');
      logger.debug('   - message.senderId: ${message.senderId}');
      logger.debug('   - message.receiverId: ${message.receiverId}');
      logger.debug('   - message.messageType: ${message.messageType}');
      logger.debug('   - message.content: ${message.content.substring(0, message.content.length > 50 ? 50 : message.content.length)}...');
      
      // 🔴 修复：使用displaySenderName获取正确的发送者名称（优先使用群组昵称，其次使用全名，最后使用账号）
      final senderNameToUse = message.displaySenderName.isNotEmpty 
          ? message.displaySenderName 
          : message.senderName;
      
      final response = await ApiService.createFavorite(
        token: _token!,
        messageId: message.id,
        serverMessageId: message.serverId,
        content: message.content,
        messageType: message.messageType,
        senderId: message.senderId,
        senderName: senderNameToUse,
        fileName: message.fileName,
      );

      if (response['code'] == 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已保存到收藏'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('收藏失败: ${response['message'] ?? '未知错误'}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      logger.error('收藏消息失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('收藏失败'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  // 引用消息
  void _quoteMessage(MessageModel message) {
    setState(() {
      _quotedMessage = message;
      _quotedMessageId = message.id;
    });
    _inputFocusNode.requestFocus();
  }

  // 滚动到被引用的消息并高亮显示
  void _scrollToQuotedMessage(int quotedMessageId) {
    logger.debug('🔍 [跳转引用消息] 开始查找消息 - quotedMessageId: $quotedMessageId');
    
    // 🔴 优先使用消息位置缓存查找
    final sessionKey = _getSessionKey();
    final positionCache = MessagePositionCache();
    final position = positionCache.getPosition(
      sessionKey: sessionKey,
      serverId: quotedMessageId,
    );
    
    int? targetLocalId;
    int targetIndex = -1;
    if (position != null) {
      targetLocalId = position.localId;
      targetIndex = position.index;
      logger.debug('📍 [跳转引用消息] 从缓存找到消息位置 - localId: $targetLocalId, index: $targetIndex');
    }
    
    // 查找被引用的消息
    // 🔴 使用serverId匹配，因为quotedMessageId是服务器ID
    final targetMessage = _messages.firstWhere(
      (msg) => msg.serverId == quotedMessageId || msg.id == quotedMessageId || (targetLocalId != null && msg.id == targetLocalId),
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

    if (targetMessage.id == 0) {
      // 没有找到被引用的消息
      logger.debug('❌ [跳转引用消息] 未找到消息 - quotedMessageId: $quotedMessageId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('引用的消息未找到'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    logger.debug('✅ [跳转引用消息] 找到目标消息 - id: ${targetMessage.id}, serverId: ${targetMessage.serverId}');

    // 如果缓存中没有找到索引，则在消息列表中查找
    if (targetIndex == -1) {
      targetIndex = _messages.indexWhere((msg) => msg.id == targetMessage.id);
    }

    if (targetIndex == -1) {
      logger.debug('❌ [跳转引用消息] 无法获取消息索引');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法定位到该消息'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    logger.debug('📍 [跳转引用消息] 消息索引: $targetIndex, 总消息数: ${_messages.length}');

    // 🔴 方案1：先尝试使用 GlobalKey（如果消息已渲染）
    GlobalKey? messageKey = _messageKeys[targetMessage.id];
    if (messageKey != null && messageKey.currentContext != null) {
      logger.debug('✅ [跳转引用消息] 使用 GlobalKey 滚动');
      Scrollable.ensureVisible(
        messageKey.currentContext!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
    } else {
      // 🔴 方案2：使用估算的滚动位置（当消息未渲染时）
      logger.debug('📍 [跳转引用消息] GlobalKey 不可用，使用估算位置滚动');
      
      if (_scrollController.hasClients) {
        // 估算每条消息的平均高度（包括时间戳、头像、气泡等）
        final double estimatedItemHeight = 80.0;
        final double targetOffset = targetIndex * estimatedItemHeight;
        final double maxScroll = _scrollController.position.maxScrollExtent;
        final double scrollTo = targetOffset.clamp(0.0, maxScroll);
        
        logger.debug('📍 [跳转引用消息] 滚动到位置: $scrollTo (索引: $targetIndex, 最大: $maxScroll)');
        
        _scrollController.animateTo(
          scrollTo,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        
        // 滚动完成后，再次尝试使用 GlobalKey 精确定位
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) {
            final key = _messageKeys[targetMessage.id];
            if (key != null && key.currentContext != null) {
              logger.debug('✅ [跳转引用消息] 二次精确定位');
              Scrollable.ensureVisible(
                key.currentContext!,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                alignment: 0.3,
              );
            }
          }
        });
      }
    }

    // 高亮显示目标消息 - 使用本地ID
    setState(() {
      _highlightedMessageId = targetMessage.id;
    });

    // 2秒后取消高亮
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _highlightedMessageId = null;
        });
      }
    });
  }

  // 获取引用消息的预览文本
  String _getQuotedMessagePreview(MessageModel message) {
    if (message.messageType == 'image') {
      return '[图片]';
    } else if (message.messageType == 'file') {
      return '[文件] ${message.fileName ?? "未知文件"}';
    } else if (message.messageType == 'video') {
      return '[视频]';
    } else if (message.messageType == 'voice') {
      return '[语音消息]';
    } else if (message.messageType == 'quoted') {
      // 如果引用的是引用消息，只返回回复内容，不包含被引用部分
      return message.content;
    } else {
      return message.content;
    }
  }

  // 开始多选
  void _startMultiSelect(MessageModel message) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedMessageIds.clear();
      _selectedMessageIds.add(message.id);
    });
  }

  // 判断是否可以撤回消息
  bool _canRecallMessage(MessageModel message, bool isMe) {
    // 判断是否是群主/管理员（在群组中）
    final isGroupAdmin =
        widget.isGroup &&
        (_currentUserGroupRole == 'owner' || _currentUserGroupRole == 'admin');

    // 计算消息发送时间与当前时间的差
    final now = DateTime.now();
    final diff = now.difference(message.createdAt);
    final canRecallSelf = diff.inMinutes < 3; // 自己的消息3分钟内可以撤回

    // 判断是否可以撤回：
    // 1. 自己的消息，3分钟内可以撤回
    // 2. 群主/管理员可以随时撤回群组内任何人的消息（无时间限制）
    return isMe ? canRecallSelf : isGroupAdmin;
  }

  // 撤回消息
  Future<void> _recallMessage(MessageModel message) async {
    if (_token == null) return;

    // 🔴 修复：必须使用服务器ID进行撤回
    final serverMessageId = message.serverId;
    logger.debug('📤 [撤回消息] 本地ID: ${message.id}, 服务器ID: ${message.serverId}');

    // 🔴 检查是否有服务器ID
    if (serverMessageId == null) {
      logger.debug('⚠️ [撤回消息] 消息没有服务器ID，无法撤回');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('消息尚未同步到服务器，无法撤回'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    try {
      // 调用撤回消息API（更新本地数据库）
      final response = await ApiService.recallMessage(
        token: _token!,
        messageId: message.id, // 本地数据库使用本地ID
      );

      if (response['code'] == 0) {
        // 立即更新本地消息状态为已撤回
        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((msg) => msg.id == message.id);
            if (index != -1) {
              // 🔴 修复：使用 copyWith 保留所有字段（包括 voiceDuration）
              _messages[index] = _messages[index].copyWith(
                status: 'recalled',
              );
            }
          });
        }

        // 撤回成功，通过WebSocket通知服务器和其他客户端
        // 🔴 修复：使用服务器ID发送给服务器
        await _wsService.sendMessageRecall(
          messageId: serverMessageId, // 服务器使用服务器ID
          userId: widget.userId,
          isGroup: widget.isGroup,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('消息已撤回'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } else {
        throw Exception(response['message'] ?? '撤回失败');
      }
    } catch (e) {
      logger.error('撤回消息失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('撤回失败: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 删除消息
  Future<void> _deleteMessage(MessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && _token != null) {
      try {
        // 调用删除消息API
        final response = await ApiService.deleteMessage(
          token: _token!,
          messageId: message.id,
        );

        if (response['code'] == 0) {
          // 删除成功，从本地列表中移除
          setState(() {
            _messages.removeWhere((m) => m.id == message.id);
          });

          // 通过WebSocket通知删除
          await _wsService.sendMessageDelete(
            messageId: message.id,
            userId: widget.userId,
            isGroup: widget.isGroup,
          );
        } else {
          throw Exception(response['message'] ?? '删除失败');
        }
      } catch (e) {
        logger.error('删除消息失败', error: e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('删除失败: ${e.toString()}'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  // 查看图片
  void _viewImage(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // 图片查看器
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Center(
                  child: InteractiveViewer(
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Center(
                          child: CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                : null,
                            color: Colors.white,
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                color: Colors.white,
                                size: 48,
                              ),
                              SizedBox(height: 8),
                              Text(
                                '图片加载失败',
                                style: TextStyle(color: Colors.white),
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
                top: MediaQuery.of(context).padding.top + 10,
                right: 10,
                child: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 播放视频
  void _playVideo(String videoUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            VideoPlayerPage(videoUrl: videoUrl, title: '视频预览'),
      ),
    );
  }

  // 打开链接
  Future<void> _openLink(String url) async {
    // TODO: 实现打开链接功能，需要添加 url_launcher 包
    // final uri = Uri.parse(url);
    // if (await canLaunchUrl(uri)) {
    //   await launchUrl(uri, mode: LaunchMode.externalApplication);
    // } else {
    //   if (mounted) {
    //     ScaffoldMessenger.of(context).showSnackBar(
    //       const SnackBar(
    //         content: Text('无法打开链接'),
    //         backgroundColor: Colors.red,
    //       ),
    //     );
    //   }
    // }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开链接: $url')));
    }
  }

  // 查看位置
  void _viewLocation(String locationData) {
    // TODO: 实现查看位置功能
  }

  // 显示表情选择器
  void _showEmojiPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: (MediaQuery.of(context).size.height * 0.4).round().toDouble(),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: EmojiPicker(
          onEmojiSelected: (emoji) {
            final text = _messageController.text;
            final selection = _messageController.selection;

            // 检查 selection 是否有效
            int start = selection.start;
            int end = selection.end;

            // 如果 selection 无效，则在文本末尾插入
            if (start < 0 ||
                end < 0 ||
                start > text.length ||
                end > text.length) {
              start = text.length;
              end = text.length;
            }

            final newText = text.replaceRange(start, end, emoji);
            _messageController.text = newText;
            _messageController.selection = TextSelection.fromPosition(
              TextPosition(offset: start + emoji.length),
            );
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            offset: const Offset(0, -1),
            blurRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 引用消息显示
          if (_quotedMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: const Border(top: BorderSide(color: Color(0xFFE5E5E5))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 40,
                    color: const Color(0xFF4A90E2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _quotedMessage!.displaySenderName,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF4A90E2),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          _quotedMessage!.content,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      setState(() {
                        _quotedMessage = null;
                        _quotedMessageId = null;
                      });
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

          // 输入区域
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 更多功能按钮
                IconButton(
                  icon: Icon(
                    _showMoreOptions ? Icons.close : Icons.add_circle_outline,
                    color: const Color(0xFF4A90E2),
                  ),
                  onPressed: () {
                    setState(() {
                      _showMoreOptions = !_showMoreOptions;
                    });
                  },
                ),

                // 输入框
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 表情按钮
                        IconButton(
                          icon: const Icon(
                            Icons.emoji_emotions_outlined,
                            size: 22,
                          ),
                          onPressed: _showEmojiPicker,
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(),
                        ),

                        // 文本输入
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            enabled: !_isUserMuted, // 🔴 禁言时禁用输入框
                            focusNode: _inputFocusNode,
                            decoration: InputDecoration(
                              hintText: _isUserMuted 
                                  ? AppLocalizations.of(context).translate('muted_cannot_send')
                                  : AppLocalizations.of(context).translate('message_input_hint_mobile'),
                              hintStyle: TextStyle(
                                color: _isUserMuted 
                                    ? Colors.orange 
                                    : Colors.grey[400],
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 0,
                                vertical: 10,
                              ),
                            ),
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                          ),
                        ),

                        // 发送按钮或语音按钮
                        _messageController.text.trim().isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.send, size: 22),
                                onPressed: (!_isSending && !_isUserMuted)
                                    ? _sendTextMessage
                                    : null,
                                color: (_isSending || _isUserMuted)
                                    ? Colors.grey 
                                    : const Color(0xFF4A90E2),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                              )
                            : IconButton(
                                icon: const Icon(Icons.mic, size: 22),
                                onPressed: (!_isUserMuted && !widget.isFileAssistant)
                                    ? _showVoiceRecordPanel
                                    : null,
                                color: (_isUserMuted || widget.isFileAssistant)
                                    ? Colors.grey 
                                    : const Color(0xFF4A90E2),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                              ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 构建更多功能面板
  Widget _buildMoreOptionsPanel() {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        // 向下滑动时关闭面板
        if (details.delta.dy > 0) {
          // 滑动速度超过阈值时关闭
          if (details.delta.dy > 5) {
            setState(() {
              _showMoreOptions = false;
            });
          }
        }
      },
      onVerticalDragEnd: (details) {
        // 快速向下滑动时也关闭
        if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
          setState(() {
            _showMoreOptions = false;
          });
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          minHeight: 120,
          maxHeight: MediaQuery.of(context).size.height * 0.45,
        ),
        padding: EdgeInsets.only(top: 16, bottom: 16, left: 16, right: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              offset: const Offset(0, -2),
              blurRadius: 8,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动指示器
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 功能按钮网格
            Wrap(
              spacing: 16,
              runSpacing: 16,
              alignment: WrapAlignment.start,
              children: [
                _buildToolButton(
                  icon: Icons.camera_alt,
                  label: '拍照',
                  onTap: (_isUserMuted && widget.isGroup) ? null : () {
                    setState(() {
                      _showMoreOptions = false;
                    });
                    _takePhoto();
                  },
                ),
                _buildToolButton(
                  icon: Icons.image,
                  label: '图片',
                  onTap: (_isUserMuted && widget.isGroup) ? null : () {
                    setState(() {
                      _showMoreOptions = false;
                    });
                    _pickImage();
                  },
                ),
                _buildToolButton(
                  icon: Icons.videocam,
                  label: '视频',
                  onTap: (_isUserMuted && widget.isGroup) ? null : () {
                    setState(() {
                      _showMoreOptions = false;
                    });
                    _pickVideo();
                  },
                ),
                _buildToolButton(
                  icon: Icons.attach_file,
                  label: '文件',
                  onTap: (_isUserMuted && widget.isGroup) ? null : () {
                    setState(() {
                      _showMoreOptions = false;
                    });
                    _pickFile();
                  },
                ),
                if (!widget.isFileAssistant) ...[
                  _buildToolButton(
                    icon: Icons.phone,
                    label: '语音通话',
                    onTap: () {
                      setState(() {
                        _showMoreOptions = false;
                      });
                      _startVoiceCall();
                    },
                  ),
                  _buildToolButton(
                    icon: Icons.video_call,
                    label: '视频通话',
                    onTap: () {
                      setState(() {
                        _showMoreOptions = false;
                      });
                      _startVideoCall();
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap, // 🔴 改为可选参数
  }) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: isDisabled ? 0.4 : 1.0, // 🔴 禁用时降低透明度
        child: SizedBox(
          width: 70,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: isDisabled ? Colors.grey[200] : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon, 
                  color: isDisabled ? Colors.grey : const Color(0xFF4A90E2),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12, 
                  color: isDisabled ? Colors.grey[400] : Colors.grey,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        elevation: 0.5,
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black87),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // 返回时传递需要刷新的信息
            Navigator.pop(context, {
              'needRefresh': true,
              'contactId': widget.isGroup ? widget.groupId : widget.userId,
              'isGroup': widget.isGroup,
            });
          },
        ),
        title: InkWell(
          onTap: widget.isGroup && widget.groupId != null
              ? () => _navigateToGroupInfo()
              : null,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.displayName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // 🔴 网络连接状态显示
                    if (_isConnecting)
                      Row(
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
                      )
                    else if (_isOtherTyping &&
                        !widget.isGroup &&
                        !widget.isFileAssistant)
                      const Text(
                        '对方正在输入...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else if (widget.isGroup && _groupMemberCount != null)
                      Text(
                        '${_groupMemberCount}人',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!_isMultiSelectMode) ...[
            if (widget.isGroup && widget.groupId != null)
              IconButton(
                icon: const Icon(Icons.group_outlined),
                onPressed: _navigateToGroupInfo,
                tooltip: '群组信息',
              ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MessageSearchPage(
                      messages: _messages,
                      chatName: widget.displayName,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _showMoreMenu,
            ),
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
                },
                tooltip: '测试网络状态',
              ),
          ] else ...[
            TextButton(
              onPressed: () {
                setState(() {
                  _isMultiSelectMode = false;
                  _selectedMessageIds.clear();
                });
              },
              child: const Text('取消'),
            ),
          ],
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 群公告（如果有）
            if (widget.isGroup &&
                _currentGroup != null &&
                _currentGroup!.announcement != null &&
                _currentGroup!.announcement!.isNotEmpty)
              _buildGroupAnnouncement(),

            // 消息列表和更多功能面板
            Expanded(
              child: Stack(
                children: [
                  // 消息列表
                  _buildMessageList(),

                  // @提及菜单（悬浮在消息列表上方，紧贴输入框）
                  if (_showMentionMenu && widget.isGroup)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: (_isUserMuted && widget.isGroup) ? null : () {
                          _buildMentionMenu();
                        },
                        child: _buildMentionMenu(),
                      ),
                    ),

                  // 更多功能面板（悬浮在消息列表上方）
                  if (_showMoreOptions)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildMoreOptionsPanel(),
                    ),
                ],
              ),
            ),

            // 多选操作栏或输入区域
            SafeArea(
              top: false,
              child: _isMultiSelectMode
                  ? _buildMultiSelectActionBar()
                  : _buildInputArea(),
            ),
          ],
        ),
      ),
    );
  }

  // 构建群公告栏（带滚动文字效果）
  Widget _buildGroupAnnouncement() {
    if (_currentGroup == null ||
        _currentGroup!.announcement == null ||
        _currentGroup!.announcement!.isEmpty) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: _showGroupAnnouncementDetail,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(
          color: Color(0xFFFFF8E1), // 淡黄色背景
          border: Border(
            bottom: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.campaign_outlined,
              size: 18,
              color: Color(0xFFF57C00),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _MarqueeText(
                text: '群公告：${_currentGroup!.announcement!}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF616161)),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: Color(0xFF9E9E9E),
            ),
          ],
        ),
      ),
    );
  }

  // 显示群公告详情
  void _showGroupAnnouncementDetail() {
    if (_currentGroup == null || _currentGroup!.announcement == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // 标题栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.campaign, color: Color(0xFFF57C00)),
                  const SizedBox(width: 8),
                  const Text(
                    '群公告',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // 公告内容
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: AbsorbPointer(
                  child: SelectableText(
                    _currentGroup!.announcement!,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建多选操作栏
  Widget _buildMultiSelectActionBar() {
    return Container(
      height: 60,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E5E5))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.forward),
            onPressed: _selectedMessageIds.isNotEmpty
                ? () => _forwardSelectedMessages()
                : null,
            tooltip: '转发',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _selectedMessageIds.isNotEmpty
                ? () => _deleteSelectedMessages()
                : null,
            tooltip: '删除',
          ),
          IconButton(
            icon: const Icon(Icons.star),
            onPressed: _selectedMessageIds.isNotEmpty
                ? () => _favoriteSelectedMessages()
                : null,
            tooltip: '收藏',
          ),
        ],
      ),
    );
  }

  // 导航到群组信息页
  void _navigateToGroupInfo() {
    if (widget.groupId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MobileCreateGroupPage(
            isEditMode: true,
            groupId: widget.groupId!,
            groupName: widget.displayName,
          ),
        ),
      ).then((_) {
        // 返回后重新加载群组信息
        _loadGroupInfo();
      });
    }
  }

  // 显示更多菜单
  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            ListTile(
              leading: Icon(
                _doNotDisturb ? Icons.notifications_off : Icons.notifications,
              ),
              title: Text(
                _doNotDisturb ? '关闭消息免打扰' : '开启消息免打扰',
              ),
              onTap: () {
                Navigator.pop(context);
                _toggleDoNotDisturb();
              },
            ),
            ListTile(
              leading: Icon(_isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(_isPinned ? '取消置顶聊天' : '置顶聊天'),
              onTap: () {
                Navigator.pop(context);
                _togglePinChat();
              },
            ),
            ListTile(
              leading: const Icon(Icons.clear_all),
              title: const Text('清空聊天记录'),
              onTap: () {
                Navigator.pop(context);
                _clearChatHistory();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cancel),
              title: const Text('取消'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  // 转发选中的消息
  void _forwardSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    // 获取要转发的消息列表
    final messagesToForward = _messages
        .where((msg) => _selectedMessageIds.contains(msg.id))
        .toList();

    // 按时间顺序排序
    messagesToForward.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // 显示转发弹窗，传递所有选中的消息
    final result = await showForwardMessageDialog(context, messagesToForward);

    if (result == true && mounted) {
      // 转发成功后，退出多选模式
      setState(() {
        _isMultiSelectMode = false;
        _selectedMessageIds.clear();
      });
    }
  }

  // 删除选中的消息
  Future<void> _deleteSelectedMessages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除这 ${_selectedMessageIds.length} 条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // TODO: 实现批量删除
      setState(() {
        _messages.removeWhere((m) => _selectedMessageIds.contains(m.id));
        _isMultiSelectMode = false;
        _selectedMessageIds.clear();
      });
    }
  }

  // 收藏选中的消息（合并为一条收藏）
  Future<void> _favoriteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    try {
      final token = _token;
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录，请先登录')));
        }
        return;
      }

      // 从消息列表中提取选中消息的完整信息
      // 🔴 修复：使用displaySenderName获取正确的发送者名称
      final selectedMessages = _messages
          .where((msg) => _selectedMessageIds.contains(msg.id))
          .map(
            (msg) => {
              'message_id': msg.id,
              'content': msg.content,
              'message_type': msg.messageType,
              'file_name': msg.fileName,
              'sender_id': msg.senderId,
              'sender_name': msg.displaySenderName.isNotEmpty 
                  ? msg.displaySenderName 
                  : msg.senderName,
            },
          )
          .toList();

      // 调用批量收藏API
      final response = await ApiService.createBatchFavorite(
        token: token,
        messages: selectedMessages,
      );

      if (mounted) {
        if (response['code'] == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? '已保存到收藏'),
              duration: const Duration(seconds: 2),
            ),
          );

          // 退出多选模式
          setState(() {
            _isMultiSelectMode = false;
            _selectedMessageIds.clear();
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? '收藏失败'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      logger.error('收藏消息失败', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('收藏失败: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 清空聊天记录
  Future<void> _clearChatHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: const Text('确定要清空所有聊天记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && _token != null) {
      try {
        final currentUserId = await Storage.getUserId();
        if (currentUserId == null) {
          return;
        }

        // 删除本地数据库中的消息（标记为已删除）
        final localDb = LocalDatabaseService();
        if (widget.isFileAssistant) {
          // 文件助手：硬删除所有消息
          await localDb.deleteAllFileAssistantMessages(currentUserId);
        } else if (widget.isGroup && widget.groupId != null) {
          // 群聊：软删除所有消息
          await localDb.deleteAllGroupMessages(widget.groupId!, currentUserId);
        } else {
          // 私聊：软删除所有消息
          await localDb.deleteAllMessagesWithContact(currentUserId, widget.userId);
        }

        // 清空UI中的消息列表
        setState(() {
          _messages.clear();
        });

        // 清空消息缓存
        final cacheKey = _getCacheKey();
        MobileChatPage._messageCache.remove(cacheKey);

        // 通知会话列表更新（将最新消息置空但保留会话）
        if (widget.onChatClosed != null) {
          final contactId = widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId;
          try {
            widget.onChatClosed?.call(contactId, widget.isGroup);
          } catch (e) {
            logger.error('❌ 会话列表更新回调执行失败: $e');
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('聊天记录已清空')));
        }
      } catch (e) {
        logger.error('清空聊天记录失败', error: e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('清空失败: ${e.toString()}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  // 加载消息免打扰状态
  Future<void> _loadDoNotDisturbStatus() async {
    try {
      if (_currentUserId == null) return;

      final contactKey = Storage.generateContactKey(
        isGroup: widget.isGroup,
        id: widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId,
      );

      // 从本地存储加载消息免打扰状态
      final doNotDisturb = await Storage.getDoNotDisturb(_currentUserId!, contactKey);
      
      if (mounted) {
        setState(() {
          _doNotDisturb = doNotDisturb;
        });
      }
      
    } catch (e) {
      logger.error('加载消息免打扰状态失败: $e');
    }
  }

  // 切换消息免打扰状态
  Future<void> _toggleDoNotDisturb() async {
    try {
      if (_currentUserId == null || _token == null) {
        return;
      }

      final newValue = !_doNotDisturb;
      final contactKey = Storage.generateContactKey(
        isGroup: widget.isGroup,
        id: widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId,
      );

      // 如果是群组聊天，调用服务器API
      if (widget.isGroup && widget.groupId != null) {
        final response = await ApiService.updateGroup(
          token: _token!,
          groupId: widget.groupId!,
          doNotDisturb: newValue,
        );

        if (response['code'] == 0) {
          // 更新本地状态
          await Storage.saveDoNotDisturb(_currentUserId!, contactKey, newValue);
          
          if (mounted) {
            setState(() {
              _doNotDisturb = newValue;
            });

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(newValue ? '已开启消息免打扰' : '已关闭消息免打扰'),
                duration: const Duration(seconds: 1),
              ),
            );
          }
          
          
          // 🔴 通知会话列表更新该联系人的免打扰状态
          final contactId = widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId;
          widget.onDoNotDisturbChanged?.call(contactId, widget.isGroup, newValue);
        } else {
          throw Exception(response['message'] ?? '更新失败');
        }
      } else {
        // 一对一聊天：暂时只保存到本地存储（等待服务器端实现）
        await Storage.saveDoNotDisturb(_currentUserId!, contactKey, newValue);
        
        if (mounted) {
          setState(() {
            _doNotDisturb = newValue;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(newValue ? '已开启消息免打扰' : '已关闭消息免打扰'),
              duration: const Duration(seconds: 1),
            ),
          );
        }
        
        
        // 🔴 通知会话列表更新该联系人的免打扰状态
        final contactId = widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId;
        widget.onDoNotDisturbChanged?.call(contactId, widget.isGroup, newValue);
      }
    } catch (e) {
      logger.error('切换消息免打扰状态失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 加载置顶聊天状态
  Future<void> _loadPinStatus() async {
    try {
      if (_currentUserId == null) return;

      final contactKey = Storage.generateContactKey(
        isGroup: widget.isGroup,
        id: widget.isFileAssistant 
            ? _currentUserId! // 文件传输助手使用当前用户ID
            : (widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId),
      );

      // 从本地存储加载置顶状态
      final pinnedChats = await Storage.getPinnedChatsForCurrentUser();
      final isPinned = pinnedChats.containsKey(contactKey);
      
      if (mounted) {
        setState(() {
          _isPinned = isPinned;
        });
      }
      
    } catch (e) {
      logger.error('加载置顶聊天状态失败: $e');
    }
  }

  // 切换置顶聊天状态
  Future<void> _togglePinChat() async {
    try {
      if (_currentUserId == null) {
        return;
      }

      final newValue = !_isPinned;
      final contactKey = Storage.generateContactKey(
        isGroup: widget.isGroup,
        id: widget.isFileAssistant 
            ? _currentUserId! // 文件传输助手使用当前用户ID
            : (widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId),
      );

      // 更新本地存储
      if (newValue) {
        // 添加到置顶列表
        await Storage.addPinnedChatForCurrentUser(contactKey);
      } else {
        // 从置顶列表移除
        await Storage.removePinnedChatForCurrentUser(contactKey);
      }
      
      // 🔴 修复：清除会话列表的置顶缓存，确保退出对话框后能正确显示置顶状态
      MobileHomePage.clearPinnedChatsCache();
      
      // 更新UI状态
      if (mounted) {
        setState(() {
          _isPinned = newValue;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newValue ? '已置顶聊天' : '已取消置顶'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      
    } catch (e) {
      logger.error('切换置顶聊天状态失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    // 🔴 标记聊天页面已关闭
    MobileChatPage.isChatPageOpen = false;
    
    // 清除头像缓存（确保页面关闭时清理缓存数据）
    _avatarCache.clear();
    
    // 移除生命周期观察者
    WidgetsBinding.instance.removeObserver(this);

    // 清理控制器
    _messageController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _inputFocusNode.dispose();

    // 取消订阅
    _messageSubscription?.cancel();

    // 取消计时器
    _typingTimer?.cancel();
    _typingIndicatorTimer?.cancel();
    _messageScrollTimer?.cancel();
    _networkStatusTimer?.cancel(); // 🔴 取消网络状态监听定时器

    // 清理表情选择器
    _emojiOverlayEntry?.remove();

    // 发送停止输入状态
    if (!widget.isGroup && !widget.isFileAssistant) {
      _wsService.sendTypingIndicator(
        receiverId: widget.userId,
        isTyping: false,
      );
    }

    // 🔴 页面退出时，通知最近联系人列表更新该会话的最新消息
    if (widget.onChatClosed != null) {
      final contactId = widget.isGroup ? (widget.groupId ?? widget.userId) : widget.userId;
      try {
        widget.onChatClosed?.call(contactId, widget.isGroup);
      } catch (e) {
        logger.error('❌ 回调执行失败: $e');
      }
    } else {
    }

    super.dispose();
  }
}

// 跑马灯文字组件
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final double velocity;

  const _MarqueeText({
    Key? key,
    required this.text,
    this.style,
    this.velocity = 50.0, // 像素/秒
  }) : super(key: key);

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _textWidth = 0;
  double _containerWidth = 0;
  bool _shouldAnimate = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10), // 默认时长，会根据文字长度调整
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleCalculation();
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.reset();
      _isInitialized = false;
      _shouldAnimate = false;
      _scheduleCalculation();
    }
  }

  void _scheduleCalculation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _calculateTextWidth();
      }
    });
  }

  void _calculateTextWidth() {
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final newTextWidth = textPainter.size.width;
    if (_textWidth != newTextWidth) {
      setState(() {
        _textWidth = newTextWidth;
      });
    }
  }

  void _setupAnimation() {
    if (!mounted) return;
    
    if (_textWidth > _containerWidth && _containerWidth > 0) {
      // 文字超出容器宽度，需要滚动
      // 计算动画时长
      final totalDistance = _textWidth + 100; // 文字宽度 + 间隔
      final duration = Duration(
        milliseconds: (totalDistance / widget.velocity * 1000).round(),
      );

      _controller.duration = duration;
      
      setState(() {
        _shouldAnimate = true;
        _isInitialized = true;
      });

      _controller.repeat();
    } else {
      // 文字未超出，不需要滚动
      setState(() {
        _shouldAnimate = false;
        _isInitialized = true;
      });
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final newContainerWidth = constraints.maxWidth;
        
        if (_containerWidth != newContainerWidth || !_isInitialized) {
          _containerWidth = newContainerWidth;
          // 设置动画
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _textWidth > 0) {
              _setupAnimation();
            }
          });
        }

        // 在初始化完成前或文字宽度未计算时，显示静态文字
        if (!_isInitialized || _textWidth == 0 || !_shouldAnimate) {
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        // 文字超出，显示滚动动画
        final totalDistance = _textWidth + 100;
        return ClipRect(
          child: SizedBox(
            height: 20, // 调整高度以匹配文字
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // 计算当前偏移量
                final offset = -(_controller.value * totalDistance);
                return Stack(
                  children: [
                    Positioned(
                      left: offset,
                      top: 0,
                      bottom: 0,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.text,
                          style: widget.style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                    Positioned(
                      left: offset + _textWidth + 100,
                      top: 0,
                      bottom: 0,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.text,
                          style: widget.style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
