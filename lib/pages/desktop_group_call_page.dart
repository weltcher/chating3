// Windows/macOS/Linux 桌面端群组通话页面
// 支持显示"正在呼叫"状态，等有人接听后开始计时
// 每个成员显示独立的连接状态
// 支持最小化到悬浮窗口
//
// 流程：
// 1. 发起者首先看到"正在呼叫"弹窗（紧凑UI）
// 2. 等有人接听后，切换到通话页面（全屏UI）并开始计时
// 3. 被邀请的人根据连接状态展示不同
// 4. 点击返回按钮最小化到悬浮窗口，点击悬浮窗口恢复

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/trtc_desktop_service.dart';
import '../utils/logger.dart';

/// 群组通话成员状态
enum MemberCallStatus {
  waiting,    // 等待接听
  connected,  // 已连接
  rejected,   // 已拒绝
  timeout,    // 超时未接
  left,       // 已离开
}

/// 桌面端群组通话成员信息
class DesktopGroupCallMember {
  final int userId;
  final String displayName;
  final String? avatar;
  MemberCallStatus status;

  DesktopGroupCallMember({
    required this.userId,
    required this.displayName,
    this.avatar,
    this.status = MemberCallStatus.waiting,
  });
}

/// 群组通话最小化悬浮窗口管理器
class GroupCallFloatingManager {
  static final GroupCallFloatingManager _instance = GroupCallFloatingManager._internal();
  factory GroupCallFloatingManager() => _instance;
  GroupCallFloatingManager._internal();

  OverlayEntry? _overlayEntry;
  Timer? _durationTimer;
  
  // 通话状态（用于恢复）
  int _callDuration = 0;
  int _connectedCount = 0;
  int _totalCount = 0;
  bool _isVideoCall = false;
  bool _hasAnyoneConnected = false;
  
  // 恢复通话所需的参数
  List<int>? _userIds;
  List<String>? _displayNames;
  List<String?>? _avatarUrls;
  int? _groupId;
  int? _currentUserId;
  String? _currentUserName;
  String? _currentUserAvatar;
  List<DesktopGroupCallMember>? _members;
  
  // 恢复回调
  Function(BuildContext context)? _onRestore;
  
  bool get isMinimized => _overlayEntry != null;
  int get callDuration => _callDuration;
  bool get hasAnyoneConnected => _hasAnyoneConnected;
  List<DesktopGroupCallMember>? get members => _members;

  void show(
    BuildContext context, {
    required Function(BuildContext context) onRestore,
    required int callDuration,
    required int connectedCount,
    required int totalCount,
    required bool isVideoCall,
    required bool hasAnyoneConnected,
    required List<int> userIds,
    required List<String> displayNames,
    List<String?>? avatarUrls,
    int? groupId,
    required int currentUserId,
    required String currentUserName,
    String? currentUserAvatar,
    required List<DesktopGroupCallMember> members,
  }) {
    _onRestore = onRestore;
    _callDuration = callDuration;
    _connectedCount = connectedCount;
    _totalCount = totalCount;
    _isVideoCall = isVideoCall;
    _hasAnyoneConnected = hasAnyoneConnected;
    _userIds = userIds;
    _displayNames = displayNames;
    _avatarUrls = avatarUrls;
    _groupId = groupId;
    _currentUserId = currentUserId;
    _currentUserName = currentUserName;
    _currentUserAvatar = currentUserAvatar;
    _members = members;
    
    // 启动计时器更新通话时长
    _startDurationTimer();
    
    if (_overlayEntry != null) {
      _overlayEntry!.markNeedsBuild();
      return;
    }

    _overlayEntry = OverlayEntry(
      builder: (context) => _GroupCallFloatingWidget(
        manager: this,
        onTap: () {
          final restoreCallback = _onRestore;
          hide();
          restoreCallback?.call(context);
        },
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    logger.debug('📞 [GroupCallFloating] 显示最小化悬浮窗');
  }
  
  void _startDurationTimer() {
    _durationTimer?.cancel();
    if (_hasAnyoneConnected) {
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _callDuration++;
        _overlayEntry?.markNeedsBuild();
      });
    }
  }

  void update({
    required int callDuration,
    required int connectedCount,
    required int totalCount,
    List<DesktopGroupCallMember>? members,
  }) {
    _callDuration = callDuration;
    _connectedCount = connectedCount;
    _totalCount = totalCount;
    if (members != null) {
      _members = members;
    }
    _overlayEntry?.markNeedsBuild();
  }

  void hide() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _onRestore = null;
    _members = null;
    logger.debug('📞 [GroupCallFloating] 隐藏最小化悬浮窗');
  }
}

/// 群组通话最小化悬浮窗口组件
class _GroupCallFloatingWidget extends StatefulWidget {
  final GroupCallFloatingManager manager;
  final VoidCallback onTap;

  const _GroupCallFloatingWidget({
    required this.manager,
    required this.onTap,
  });

  @override
  State<_GroupCallFloatingWidget> createState() => _GroupCallFloatingWidgetState();
}

class _GroupCallFloatingWidgetState extends State<_GroupCallFloatingWidget> {
  // 悬浮窗位置
  double _left = 20;
  double _top = 100;

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _left,
      top: _top,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: (details) {
          setState(() {
            _left += details.delta.dx;
            _top += details.delta.dy;
            // 限制在屏幕范围内
            final size = MediaQuery.of(context).size;
            _left = _left.clamp(0, size.width - 180);
            _top = _top.clamp(0, size.height - 60);
          });
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(30),
          color: const Color(0xFF1A1A2E),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.green, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 通话图标（带动画）
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.manager._isVideoCall ? Icons.videocam : Icons.call,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                // 通话信息
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatDuration(widget.manager._callDuration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${widget.manager._connectedCount}/${widget.manager._totalCount} 人',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                // 展开图标
                Icon(
                  Icons.open_in_full,
                  color: Colors.white.withValues(alpha: 0.7),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面端群组通话页面
class DesktopGroupCallPage extends StatefulWidget {
  final List<int> userIds;
  final List<String> displayNames;
  final List<String?>? avatarUrls;
  final int? groupId;
  final bool isVideoCall;
  final int currentUserId;
  final String currentUserName;
  final String? currentUserAvatar;
  
  // 从最小化恢复时的状态
  final bool isRestoring;
  final int? restoredCallDuration;
  final bool? restoredHasAnyoneConnected;
  final List<DesktopGroupCallMember>? restoredMembers;

  const DesktopGroupCallPage({
    super.key,
    required this.userIds,
    required this.displayNames,
    this.avatarUrls,
    this.groupId,
    this.isVideoCall = false,
    required this.currentUserId,
    required this.currentUserName,
    this.currentUserAvatar,
    this.isRestoring = false,
    this.restoredCallDuration,
    this.restoredHasAnyoneConnected,
    this.restoredMembers,
  });

  @override
  State<DesktopGroupCallPage> createState() => _DesktopGroupCallPageState();
}

class _DesktopGroupCallPageState extends State<DesktopGroupCallPage> {
  final TRTCDesktopService _callService = TRTCDesktopService();
  final GroupCallFloatingManager _floatingManager = GroupCallFloatingManager();
  
  // 音效播放器
  AudioPlayer? _waitingPlayer;
  
  // 成员列表
  List<DesktopGroupCallMember> _members = [];
  
  // UI 状态
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isClosing = false;
  bool _hasAnyoneConnected = false;  // 是否有人已接听
  bool _isMinimized = false;  // 是否最小化
  
  // 通话时长
  int _callDuration = 0;
  Timer? _durationTimer;
  
  // 呼叫超时计时器
  Timer? _callTimeoutTimer;
  static const int _callTimeoutSeconds = 60;  // 60秒超时
  int _remainingTimeoutSeconds = _callTimeoutSeconds;
  
  // 状态文本
  String _statusText = '正在呼叫...';

  @override
  void initState() {
    super.initState();
    logger.debug('📞 DesktopGroupCallPage initState');
    logger.debug('  - userIds: ${widget.userIds}');
    logger.debug('  - displayNames: ${widget.displayNames}');
    logger.debug('  - groupId: ${widget.groupId}');
    logger.debug('  - isVideoCall: ${widget.isVideoCall}');
    logger.debug('  - isRestoring: ${widget.isRestoring}');
    
    if (widget.isRestoring) {
      // 从最小化恢复
      _restoreFromMinimized();
    } else {
      // 正常发起通话
      _initMembers();
      _setupCallbacks();
      _startCall();
    }
  }
  
  /// 从最小化状态恢复
  void _restoreFromMinimized() {
    logger.debug('📞 [Desktop Group UI] 从最小化状态恢复');
    
    // 恢复成员列表
    if (widget.restoredMembers != null) {
      _members = widget.restoredMembers!;
    } else {
      _initMembers();
    }
    
    // 恢复通话时长
    if (widget.restoredCallDuration != null) {
      _callDuration = widget.restoredCallDuration!;
    }
    
    // 恢复连接状态
    if (widget.restoredHasAnyoneConnected != null) {
      _hasAnyoneConnected = widget.restoredHasAnyoneConnected!;
    }
    
    // 设置回调
    _setupCallbacks();
    
    // 如果已有人接听，启动计时器
    if (_hasAnyoneConnected) {
      _startDurationTimer();
    }
    
    _updateStatusText();
  }

  @override
  void dispose() {
    // 🔴 先标记为正在关闭，避免回调中的操作
    _isClosing = true;
    
    // 🔴 取消定时器
    _durationTimer?.cancel();
    _callTimeoutTimer?.cancel();
    
    // 🔴 只有在非最小化状态下才隐藏悬浮窗口
    // 最小化时悬浮窗需要保留
    if (!_isMinimized) {
      _floatingManager.hide();
    }
    
    // 🔴 同步停止音效（dispose 时必须同步清理）
    final player = _waitingPlayer;
    _waitingPlayer = null;
    if (player != null) {
      try {
        player.stop();
        player.dispose();
      } catch (e) {
        logger.debug('⚠️ dispose 时停止音效失败: $e');
      }
    }
    
    super.dispose();
  }

  void _initMembers() {
    _members = [];
    for (int i = 0; i < widget.userIds.length; i++) {
      final userId = widget.userIds[i];
      final displayName = i < widget.displayNames.length 
          ? widget.displayNames[i] 
          : '用户$userId';
      final avatar = widget.avatarUrls != null && i < widget.avatarUrls!.length 
          ? widget.avatarUrls![i] 
          : null;
      
      _members.add(DesktopGroupCallMember(
        userId: userId,
        displayName: displayName,
        avatar: avatar,
        status: MemberCallStatus.waiting,
      ));
    }
    logger.debug('📞 初始化成员列表: ${_members.length} 人');
  }

  void _setupCallbacks() {
    _callService.onCallStateChanged = (state) {
      if (!mounted || _isClosing) return;
      logger.debug('📞 [Desktop Group UI] 通话状态变化: $state');
      
      // 🔴 在 setState 外部处理异步操作
      if (state == DesktopCallState.accept && !_hasAnyoneConnected) {
        _hasAnyoneConnected = true;
        _startDurationTimer();
        _stopCallTimeoutTimer();
        // 🔴 延迟停止音效，避免线程冲突
        Future.microtask(() => _stopSound());
      }
      
      if (!mounted) return;
      setState(() {
        switch (state) {
          case DesktopCallState.idle:
            _statusText = '通话结束';
            _endCallAndClose();
            break;
          case DesktopCallState.waiting:
            _statusText = '正在呼叫...';
            break;
          case DesktopCallState.accept:
            _updateStatusText();
            break;
        }
      });
    };

    _callService.onRemoteUserJoined = (odUserId, odUserIdInt) {
      logger.debug('📞 [Desktop Group UI] 远端用户加入: $odUserId ($odUserIdInt)');
      if (!mounted) return;
      
      // 第一个人接听时停止呼叫音效
      final isFirstConnection = !_hasAnyoneConnected;
      if (isFirstConnection) {
        _hasAnyoneConnected = true;
        _startDurationTimer();
        _stopCallTimeoutTimer();
        // 🔴 延迟停止音效，避免线程冲突
        Future.microtask(() => _stopSound());
      }
      
      if (!mounted) return;
      setState(() {
        // 更新成员状态
        for (var member in _members) {
          if (member.userId == odUserIdInt) {
            member.status = MemberCallStatus.connected;
            break;
          }
        }
        
        _updateStatusText();
      });
      
      // 更新悬浮窗口
      _updateFloatingWindow();
    };

    _callService.onRemoteUserLeft = (odUserId, odUserIdInt) {
      logger.debug('📞 [Desktop Group UI] 远端用户离开: $odUserId ($odUserIdInt)');
      if (!mounted) return;
      
      setState(() {
        // 更新成员状态为已离开
        for (var member in _members) {
          if (member.userId == odUserIdInt) {
            member.status = MemberCallStatus.left;
            break;
          }
        }
        _updateStatusText();
      });
      
      // 更新悬浮窗口
      _updateFloatingWindow();
      
      // 检查是否所有人都离开了
      final connectedCount = _members.where((m) => m.status == MemberCallStatus.connected).length;
      if (connectedCount == 0 && _hasAnyoneConnected) {
        logger.debug('📞 所有成员已离开，结束通话');
        _endCallAndClose();
      }
    };

    _callService.onCallTimeUpdate = (timeCount) {
      if (!mounted) return;
      setState(() {
        _callDuration = timeCount;
      });
    };

    _callService.onError = (error) {
      logger.debug('📞 [Desktop Group UI] 通话错误: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
    };

    _callService.onCallEnded = (duration) {
      logger.debug('📞 [Desktop Group UI] 通话结束，时长: $duration 秒');
      _callDuration = duration;
      _endCallAndClose();
    };

    // 🔴 新增：群组通话成员状态同步回调
    _callService.onGroupCallMembersSync = (connectedMembers, totalInvited, callStartTime) {
      logger.debug('📞 [Desktop Group UI] 收到成员状态同步:');
      logger.debug('📞 [Desktop Group UI]   - 已连接成员数: ${connectedMembers.length}');
      logger.debug('📞 [Desktop Group UI]   - 总邀请人数: $totalInvited');
      logger.debug('📞 [Desktop Group UI]   - 通话开始时间: $callStartTime');
      
      if (!mounted || _isClosing) return;
      
      setState(() {
        // 更新成员状态
        for (final memberData in connectedMembers) {
          final memberId = memberData['user_id'] as int? ?? 0;
          if (memberId > 0 && memberId != widget.currentUserId) {
            for (var member in _members) {
              if (member.userId == memberId) {
                member.status = MemberCallStatus.connected;
                logger.debug('📞 [Desktop Group UI] 更新成员 $memberId 状态为已连接');
                break;
              }
            }
          }
        }
        
        // 如果有已连接的成员，更新状态
        final connectedCount = _members.where((m) => m.status == MemberCallStatus.connected).length;
        if (connectedCount > 0 && !_hasAnyoneConnected) {
          _hasAnyoneConnected = true;
          _startDurationTimer();
          _stopCallTimeoutTimer();
          Future.microtask(() => _stopSound());
        }
        
        _updateStatusText();
      });
      
      // 更新悬浮窗口
      _updateFloatingWindow();
    };
  }

  void _updateStatusText() {
    final connectedCount = _members.where((m) => m.status == MemberCallStatus.connected).length;
    final totalCount = _members.length;
    final waitingCount = _members.where((m) => m.status == MemberCallStatus.waiting).length;
    
    if (_hasAnyoneConnected) {
      if (connectedCount > 0) {
        _statusText = '通话中 ($connectedCount/$totalCount 人已连接)';
      } else {
        _statusText = '等待其他成员...';
      }
    } else {
      _statusText = '正在呼叫 $waitingCount 人...';
    }
  }

  /// 开始呼叫超时计时器
  void _startCallTimeoutTimer() {
    _remainingTimeoutSeconds = _callTimeoutSeconds;
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      setState(() {
        _remainingTimeoutSeconds--;
      });
      
      if (_remainingTimeoutSeconds <= 0) {
        timer.cancel();
        // 超时，将所有等待中的成员标记为超时
        logger.debug('📞 [Desktop Group UI] 呼叫超时');
        setState(() {
          for (var member in _members) {
            if (member.status == MemberCallStatus.waiting) {
              member.status = MemberCallStatus.timeout;
            }
          }
        });
        
        // 如果没有人接听，结束通话
        if (!_hasAnyoneConnected) {
          _endCallAndClose();
        }
      }
    });
  }

  /// 停止呼叫超时计时器
  void _stopCallTimeoutTimer() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
  }

  Future<void> _startCall() async {
    logger.debug('📞 [Desktop Group UI] 开始发起群组通话');
    
    setState(() {
      _statusText = '正在呼叫 ${_members.length} 人...';
    });
    
    _playWaitingSound();
    _startCallTimeoutTimer();  // 开始超时计时
    
    // 调用 TRTCDesktopService 发起群组通话
    final callType = widget.isVideoCall ? DesktopCallType.video : DesktopCallType.audio;
    final success = await _callService.startGroupCall(
      widget.userIds,
      widget.displayNames,
      callType,
      groupId: widget.groupId,
    );
    
    if (!success) {
      logger.debug('📞 [Desktop Group UI] 发起群组通话失败');
      _stopCallTimeoutTimer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发起群组通话失败'), backgroundColor: Colors.red),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration++;
        });
        // 更新悬浮窗口
        _updateFloatingWindow();
      }
    });
  }

  Future<void> _playWaitingSound() async {
    if (!mounted) return;
    try {
      _waitingPlayer = AudioPlayer();
      await _waitingPlayer!.setReleaseMode(ReleaseMode.loop);
      await _waitingPlayer!.play(AssetSource('mp3/wait.mp3'));
      logger.debug('🔊 等待音效播放中');
    } catch (e) {
      logger.debug('⚠️ 播放等待音效失败: $e');
    }
  }

  Future<void> _stopSound() async {
    // 🔴 使用局部变量保存引用，避免并发问题
    final player = _waitingPlayer;
    _waitingPlayer = null;
    
    if (player == null) {
      logger.debug('🔊 音效播放器已为空，跳过停止');
      return;
    }
    
    try {
      // 🔴 在主线程中执行停止操作，避免线程安全问题
      await Future.delayed(const Duration(milliseconds: 50));
      await player.stop();
      await player.dispose();
      logger.debug('🔊 等待音效已停止');
    } catch (e) {
      logger.debug('⚠️ 停止音效失败: $e');
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Future<void> _endCall() async {
    logger.debug('📞 [Desktop Group UI] 挂断通话');
    // 🔴 异步停止音效，避免阻塞
    Future.microtask(() => _stopSound());
    await _callService.hangup();
  }

  void _endCallAndClose() {
    if (_isClosing) return;
    _isClosing = true;
    
    // 🔴 先取消定时器
    _durationTimer?.cancel();
    _callTimeoutTimer?.cancel();
    
    // 🔴 隐藏悬浮窗口
    _floatingManager.hide();
    
    // 🔴 异步停止音效，避免阻塞
    Future.microtask(() => _stopSound());
    
    if (mounted) {
      Navigator.of(context).pop({
        'callEnded': true,
        'callDuration': _callDuration,
        'isLocalHangup': _callService.isLocalHangup,
      });
    }
  }

  Future<void> _toggleMute() async {
    final newMuted = !_isMuted;
    await _callService.toggleMicrophone(!newMuted);
    setState(() {
      _isMuted = newMuted;
    });
  }

  Future<void> _toggleSpeaker() async {
    final newSpeakerOn = !_isSpeakerOn;
    await _callService.toggleSpeaker(newSpeakerOn);
    setState(() {
      _isSpeakerOn = newSpeakerOn;
    });
  }

  /// 最小化通话窗口
  void _minimizeCall() {
    if (_isMinimized) return;
    
    logger.debug('📞 [Desktop Group UI] 最小化通话窗口');
    
    final connectedCount = _members.where((m) => m.status == MemberCallStatus.connected).length;
    
    // 停止本地计时器（悬浮窗会自己计时）
    _durationTimer?.cancel();
    
    // 标记为最小化
    _isMinimized = true;
    
    // 显示悬浮窗并保存状态
    _floatingManager.show(
      context,
      onRestore: _restoreCallFromFloating,
      callDuration: _callDuration,
      connectedCount: connectedCount,
      totalCount: _members.length,
      isVideoCall: widget.isVideoCall,
      hasAnyoneConnected: _hasAnyoneConnected,
      userIds: widget.userIds,
      displayNames: widget.displayNames,
      avatarUrls: widget.avatarUrls,
      groupId: widget.groupId,
      currentUserId: widget.currentUserId,
      currentUserName: widget.currentUserName,
      currentUserAvatar: widget.currentUserAvatar,
      members: List.from(_members),  // 复制成员列表
    );
    
    // Pop 当前页面，返回主页面
    Navigator.of(context).pop({'minimized': true});
  }
  
  /// 从悬浮窗恢复通话（静态方法，用于在其他页面调用）
  static void _restoreCallFromFloating(BuildContext context) {
    final manager = GroupCallFloatingManager();
    
    if (manager._userIds == null || manager._currentUserId == null) {
      logger.debug('📞 [Desktop Group UI] 恢复失败：缺少必要参数');
      return;
    }
    
    logger.debug('📞 [Desktop Group UI] 从悬浮窗恢复通话');
    
    // 打开新的通话页面，传入恢复状态
    Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => DesktopGroupCallPage(
          userIds: manager._userIds!,
          displayNames: manager._displayNames!,
          avatarUrls: manager._avatarUrls,
          groupId: manager._groupId,
          isVideoCall: manager._isVideoCall,
          currentUserId: manager._currentUserId!,
          currentUserName: manager._currentUserName!,
          currentUserAvatar: manager._currentUserAvatar,
          isRestoring: true,
          restoredCallDuration: manager._callDuration,
          restoredHasAnyoneConnected: manager._hasAnyoneConnected,
          restoredMembers: manager._members,
        ),
      ),
    );
  }

  /// 更新悬浮窗口信息
  void _updateFloatingWindow() {
    if (_floatingManager.isMinimized) {
      final connectedCount = _members.where((m) => m.status == MemberCallStatus.connected).length;
      _floatingManager.update(
        callDuration: _callDuration,
        connectedCount: connectedCount,
        totalCount: _members.length,
        members: List.from(_members),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 根据是否有人接听，显示不同的UI
    if (_hasAnyoneConnected) {
      // 通话中 - 显示全屏通话页面
      return _buildInCallPage();
    } else {
      // 正在呼叫 - 显示呼叫弹窗
      return _buildCallingDialog();
    }
  }

  /// 构建"正在呼叫"弹窗UI
  Widget _buildCallingDialog() {
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题
              Row(
                children: [
                  Icon(
                    widget.isVideoCall ? Icons.videocam : Icons.call,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.isVideoCall ? '群组视频通话' : '群组语音通话',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              
              // 呼叫状态
              Text(
                _statusText,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              
              // 超时倒计时
              Text(
                '${_remainingTimeoutSeconds}秒后自动取消',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              
              // 成员头像列表（横向滚动）
              SizedBox(
                height: 100,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _members.length,
                  itemBuilder: (context, index) {
                    final member = _members[index];
                    return _buildCallingMemberItem(member);
                  },
                ),
              ),
              const SizedBox(height: 24),
              
              // 取消按钮
              ElevatedButton.icon(
                onPressed: _endCall,
                icon: const Icon(Icons.call_end, color: Colors.white),
                label: const Text('取消呼叫', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建呼叫中的成员项
  Widget _buildCallingMemberItem(DesktopGroupCallMember member) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头像带状态指示
          Stack(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey[700],
                  image: member.avatar != null && member.avatar!.isNotEmpty
                      ? DecorationImage(
                          image: NetworkImage(member.avatar!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: member.avatar == null || member.avatar!.isEmpty
                    ? Center(
                        child: Text(
                          member.displayName.isNotEmpty 
                              ? member.displayName[0].toUpperCase() 
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
              ),
              // 状态指示器
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: _getStatusColor(member.status, false),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF1A1A2E), width: 2),
                  ),
                  child: member.status == MemberCallStatus.waiting
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Icon(
                          _getStatusIcon(member.status, false),
                          color: Colors.white,
                          size: 10,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 名称
          SizedBox(
            width: 60,
            child: Text(
              member.displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          // 状态文本
          Text(
            _getShortStatusText(member.status),
            style: TextStyle(
              color: _getStatusColor(member.status, false).withValues(alpha: 0.8),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  /// 获取简短的状态文本
  String _getShortStatusText(MemberCallStatus status) {
    switch (status) {
      case MemberCallStatus.waiting:
        return '呼叫中';
      case MemberCallStatus.connected:
        return '已接听';
      case MemberCallStatus.rejected:
        return '已拒绝';
      case MemberCallStatus.timeout:
        return '未接听';
      case MemberCallStatus.left:
        return '已离开';
    }
  }

  /// 构建通话中的全屏页面
  Widget _buildInCallPage() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          children: [
            // 顶部信息栏
            _buildTopBar(),
            
            // 成员列表
            Expanded(
              child: _buildMembersList(),
            ),
            
            // 底部控制栏
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // 最小化按钮（返回按钮改为最小化）
          IconButton(
            icon: const Icon(Icons.remove, color: Colors.white),
            tooltip: '最小化',
            onPressed: _minimizeCall,
          ),
          const Spacer(),
          // 通话状态/时长
          Column(
            children: [
              Text(
                _hasAnyoneConnected ? _formatDuration(_callDuration) : _statusText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (_hasAnyoneConnected)
                Text(
                  _statusText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const Spacer(),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildMembersList() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          const SizedBox(height: 20),
          // 标题
          Text(
            widget.isVideoCall ? '群组视频通话' : '群组语音通话',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 30),
          // 成员网格
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 20,
                mainAxisSpacing: 20,
                childAspectRatio: 0.85,
              ),
              itemCount: _members.length + 1,  // +1 是自己
              itemBuilder: (context, index) {
                if (index == 0) {
                  // 第一个是自己
                  return _buildMemberItem(
                    userId: widget.currentUserId,
                    displayName: widget.currentUserName,
                    avatar: widget.currentUserAvatar,
                    status: MemberCallStatus.connected,
                    isMe: true,
                  );
                } else {
                  final member = _members[index - 1];
                  return _buildMemberItem(
                    userId: member.userId,
                    displayName: member.displayName,
                    avatar: member.avatar,
                    status: member.status,
                    isMe: false,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberItem({
    required int userId,
    required String displayName,
    String? avatar,
    required MemberCallStatus status,
    required bool isMe,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头像
        Stack(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey[700],
                image: avatar != null && avatar.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(avatar),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: avatar == null || avatar.isEmpty
                  ? Center(
                      child: Text(
                        displayName.isNotEmpty 
                            ? displayName[0].toUpperCase() 
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : null,
            ),
            // 状态指示器
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: _getStatusColor(status, isMe),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1A1A2E), width: 2),
                ),
                child: Icon(
                  _getStatusIcon(status, isMe),
                  color: Colors.white,
                  size: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 名称
        Text(
          isMe ? '我' : displayName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        // 状态文本
        Text(
          _getStatusText(status, isMe),
          style: TextStyle(
            color: _getStatusColor(status, isMe).withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Color _getStatusColor(MemberCallStatus status, bool isMe) {
    if (isMe) return Colors.green;
    switch (status) {
      case MemberCallStatus.waiting:
        return Colors.orange;
      case MemberCallStatus.connected:
        return Colors.green;
      case MemberCallStatus.rejected:
        return Colors.red;
      case MemberCallStatus.timeout:
        return Colors.grey;
      case MemberCallStatus.left:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(MemberCallStatus status, bool isMe) {
    if (isMe) return Icons.check;
    switch (status) {
      case MemberCallStatus.waiting:
        return Icons.hourglass_empty;
      case MemberCallStatus.connected:
        return Icons.check;
      case MemberCallStatus.rejected:
        return Icons.close;
      case MemberCallStatus.timeout:
        return Icons.access_time;
      case MemberCallStatus.left:
        return Icons.exit_to_app;
    }
  }

  String _getStatusText(MemberCallStatus status, bool isMe) {
    if (isMe) return '已连接';
    switch (status) {
      case MemberCallStatus.waiting:
        return '等待接听...';
      case MemberCallStatus.connected:
        return '已连接';
      case MemberCallStatus.rejected:
        return '已拒绝';
      case MemberCallStatus.timeout:
        return '未接听';
      case MemberCallStatus.left:
        return '已离开';
    }
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 静音
          _buildControlButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            label: _isMuted ? '取消静音' : '静音',
            color: _isMuted ? Colors.red : Colors.white.withValues(alpha: 0.3),
            onPressed: _toggleMute,
          ),
          
          // 扬声器
          _buildControlButton(
            icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
            label: _isSpeakerOn ? '关闭扬声器' : '开启扬声器',
            color: _isSpeakerOn ? Colors.white.withValues(alpha: 0.3) : Colors.red,
            onPressed: _toggleSpeaker,
          ),
          
          // 挂断
          _buildControlButton(
            icon: Icons.call_end,
            label: _hasAnyoneConnected ? '挂断' : '取消',
            color: Colors.red,
            onPressed: _endCall,
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Container(
              width: 60,
              height: 60,
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// 显示桌面端群组通话页面
Future<Map<String, dynamic>?> showDesktopGroupCallPage(
  BuildContext context, {
  required List<int> userIds,
  required List<String> displayNames,
  List<String?>? avatarUrls,
  int? groupId,
  bool isVideoCall = false,
  required int currentUserId,
  required String currentUserName,
  String? currentUserAvatar,
}) async {
  return await Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (context) => DesktopGroupCallPage(
        userIds: userIds,
        displayNames: displayNames,
        avatarUrls: avatarUrls,
        groupId: groupId,
        isVideoCall: isVideoCall,
        currentUserId: currentUserId,
        currentUserName: currentUserName,
        currentUserAvatar: currentUserAvatar,
      ),
    ),
  );
}
