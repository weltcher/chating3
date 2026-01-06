/// TUICallKit 通话页面
/// 使用腾讯云 TUICallKit 实现音视频通话
/// 
/// 此文件替代原有的 voice_call_page.dart 和 group_video_call_page.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:tencent_calls_uikit/tencent_calls_uikit.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/tuicallkit_service.dart' as tui;
import '../services/agora_service.dart' show CallType, CallState;
import '../services/api_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import '../utils/responsive_helper.dart';
import 'desktop_call_page.dart';

/// 判断是否为桌面平台
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// 通话页面 - 支持单人和群组通话
class CallPage extends StatefulWidget {
  final int targetUserId;
  final String targetDisplayName;
  final bool isIncoming;
  final CallType callType;
  final String? targetAvatar;
  // 群组通话相关参数
  final List<int>? groupCallUserIds;
  final List<String>? groupCallDisplayNames;
  final List<String?>? groupCallAvatarUrls;
  final int? currentUserId;
  final int? groupId;
  final bool isJoiningExistingCall;
  final String? memberRole;

  const CallPage({
    super.key,
    required this.targetUserId,
    required this.targetDisplayName,
    this.isIncoming = false,
    this.callType = CallType.voice,
    this.targetAvatar,
    this.groupCallUserIds,
    this.groupCallDisplayNames,
    this.groupCallAvatarUrls,
    this.currentUserId,
    this.groupId,
    this.isJoiningExistingCall = false,
    this.memberRole,
  });

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final tui.TUICallKitService _callService = tui.TUICallKitService();
  AudioPlayer? _waitingPlayer;

  CallState _callState = CallState.idle;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isCameraOn = true;
  int _callDuration = 0;
  bool _isClosing = false;
  bool _disposed = false;
  
  Timer? _durationTimer;
  String _statusText = '正在连接...';

  // 群组通话成员
  List<int> _currentGroupCallUserIds = [];
  List<String> _currentGroupCallDisplayNames = [];
  List<String?> _currentGroupCallAvatarUrls = [];
  final Set<int> _connectedMemberIds = {};

  // 当前用户头像
  String? _currentUserAvatarUrl;
  String? _targetAvatarUrl;

  // 是否是群组通话
  bool get _isGroupCall => 
      widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    logger.debug('🔴🔴🔴 ═══════════════════════════════════════════════════════════');
    logger.debug('🔴🔴🔴 [CallPage/VoiceCallPage] initState 被调用！');
    logger.debug('🔴🔴🔴 ═══════════════════════════════════════════════════════════');
    logger.debug('📞 CallPage initState');
    logger.debug('  - targetUserId: ${widget.targetUserId}');
    logger.debug('  - targetDisplayName: ${widget.targetDisplayName}');
    logger.debug('  - isIncoming: ${widget.isIncoming}');
    logger.debug('  - callType: ${widget.callType}');
    logger.debug('  - isGroupCall: $_isGroupCall');
    logger.debug('  - groupId: ${widget.groupId}');
    logger.debug('  - isDesktopPlatform: $_isDesktopPlatform');
    logger.debug('  - isJoiningExistingCall: ${widget.isJoiningExistingCall}');
    // 打印调用堆栈，帮助定位是从哪里打开的
    logger.debug('🔴🔴🔴 调用堆栈:');
    try {
      throw Exception('Stack trace for debugging');
    } catch (e, stackTrace) {
      final lines = stackTrace.toString().split('\n').take(15).join('\n');
      logger.debug(lines);
    }
    logger.debug('🔴🔴🔴 ═══════════════════════════════════════════════════════════');

    // 桌面平台跳转到 DesktopCallPage
    if (_isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          logger.debug('📞 [CallPage] 桌面平台，跳转到 DesktopCallPage');
          // 使用 push 而不是 pushReplacement，以便正确传递返回值
          final result = await Navigator.of(context).push<Map<String, dynamic>>(
            MaterialPageRoute(
              builder: (context) => DesktopCallPage(
                targetUserId: widget.targetUserId,
                targetDisplayName: widget.targetDisplayName,
                targetAvatar: widget.targetAvatar,
                isIncoming: widget.isIncoming,
                isVideoCall: widget.callType == CallType.video,
              ),
            ),
          );
          logger.debug('📞 [CallPage] DesktopCallPage 返回结果: $result');
          // 将 DesktopCallPage 的返回值传递回调用者
          if (mounted) {
            logger.debug('📞 [CallPage] 将结果传递回调用者');
            Navigator.of(context).pop(result);
          }
        }
      });
      return;
    }

    _targetAvatarUrl = widget.targetAvatar;
    
    // 初始化群组成员列表
    if (widget.groupCallUserIds != null) {
      _currentGroupCallUserIds = List<int>.from(widget.groupCallUserIds!);
      if (widget.groupCallDisplayNames != null) {
        _currentGroupCallDisplayNames = List<String>.from(widget.groupCallDisplayNames!);
      }
      if (widget.groupCallAvatarUrls != null) {
        _currentGroupCallAvatarUrls = List<String?>.from(widget.groupCallAvatarUrls!);
      }
    }

    _loadCurrentUserAvatar();
    _setupCallbacks();
    
    // 延迟启动通话
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) {
        _startCall();
      }
    });
  }

  Future<void> _loadCurrentUserAvatar() async {
    try {
      final avatar = await Storage.getAvatar();
      if (mounted) {
        setState(() {
          _currentUserAvatarUrl = avatar;
        });
      }
    } catch (e) {
      logger.debug('⚠️ 加载当前用户头像失败: $e');
    }
  }

  void _setupCallbacks() {
    _callService.onCallStateChanged = (state) {
      if (_disposed || !mounted || _isClosing) return;
      
      logger.debug('📞 通话状态变化: $state');
      
      CallState newState;
      switch (state) {
        case tui.CallState.idle:
          newState = CallState.idle;
          break;
        case tui.CallState.calling:
          newState = CallState.calling;
          // 只有在非 connected 状态时才播放等待音
          if (_callState != CallState.connected) {
            _playWaitingSound();
          }
          break;
        case tui.CallState.ringing:
          newState = CallState.ringing;
          // 只有在非 connected 状态时才播放等待音
          if (_callState != CallState.connected) {
            _playWaitingSound();
          }
          break;
        case tui.CallState.connected:
          newState = CallState.connected;
          _stopSound();
          // 只有在尚未开始计时时才启动计时器
          if (_durationTimer == null) {
            _startDurationTimer();
          }
          break;
        case tui.CallState.ended:
          newState = CallState.ended;
          _stopSound();
          _handleCallEnded();
          return;
      }
      
      setState(() {
        _callState = newState;
        _updateStatusText();
      });
    };

    // 🔴 监听远程用户加入 - 这是通话接通的另一个信号
    _callService.onRemoteUserJoined = (uid) {
      if (_disposed || !mounted) return;
      logger.debug('📞 远程用户加入: $uid');
      
      setState(() {
        _connectedMemberIds.add(uid);
      });
      
      // 远程用户加入意味着通话已接通
      if (_callState != CallState.connected) {
        logger.debug('📞 远程用户加入，切换到通话状态');
        _stopSound();
        setState(() {
          _callState = CallState.connected;
          _updateStatusText();
        });
        if (_durationTimer == null) {
          _startDurationTimer();
        }
      }
    };

    _callService.onRemoteUserLeft = (uid) {
      if (_disposed || !mounted) return;
      logger.debug('📞 远程用户离开: $uid');
      
      setState(() {
        _connectedMemberIds.remove(uid);
      });
    };

    _callService.onError = (error) {
      if (_disposed || !mounted) return;
      logger.debug('📞 通话错误: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    };

    _callService.onCallEnded = (duration) {
      logger.debug('📞 通话结束回调，时长: $duration');
      _callDuration = duration;
      // 🔴 修复：当收到 onCallEnded 回调时，也需要关闭页面
      // 这对于使用 TRTC SDK 直接进入房间的场景（如加入已存在的群组通话）很重要
      // 因为这种情况下 onCallStateChanged 可能不会触发 ended 状态
      if (!_isClosing && mounted) {
        logger.debug('📞 onCallEnded 触发页面关闭');
        _handleCallEnded();
      }
    };
  }


  void _updateStatusText() {
    switch (_callState) {
      case CallState.idle:
        _statusText = '准备中...';
        break;
      case CallState.calling:
        if (widget.isJoiningExistingCall) {
          _statusText = '正在加入通话...';
        } else {
          _statusText = widget.isIncoming ? '来电中...' : '正在呼叫...';
        }
        break;
      case CallState.ringing:
        _statusText = '对方响铃中...';
        break;
      case CallState.connected:
        _statusText = '通话中';
        break;
      case CallState.ended:
        _statusText = '通话结束';
        break;
    }
  }

  /// 将 TUICallKit 状态映射到本地 CallState
  CallState _mapTuiCallState(tui.CallState state) {
    switch (state) {
      case tui.CallState.idle:
        return CallState.idle;
      case tui.CallState.calling:
        return CallState.calling;
      case tui.CallState.ringing:
        return CallState.ringing;
      case tui.CallState.connected:
        return CallState.connected;
      case tui.CallState.ended:
        return CallState.ended;
    }
  }

  Future<void> _startCall() async {
    logger.debug('📞 开始通话流程');
    logger.debug('📞 isIncoming: ${widget.isIncoming}');
    logger.debug('📞 isJoiningExistingCall: ${widget.isJoiningExistingCall}');
    logger.debug('📞 当前 TUICallKit 状态: ${_callService.callState}');
    
    // 🔴 加入已存在的通话 - 直接进入房间，不发起新通话
    if (widget.isJoiningExistingCall && _isGroupCall) {
      logger.debug('📞 加入已存在的群组通话，直接进入房间');
      setState(() {
        _callState = CallState.calling;
        _statusText = '正在加入通话...';
      });
      
      try {
        // 使用 TUICallKitService 的 joinGroupCall 方法加入通话
        await _callService.joinGroupCall(
          widget.groupCallUserIds ?? [],
          widget.groupCallDisplayNames ?? [],
          widget.callType,
          groupId: widget.groupId,
        );
        logger.debug('📞 已调用 joinGroupCall');
      } catch (e) {
        logger.debug('📞 加入群组通话失败: $e');
        _showError('加入通话失败: $e');
      }
      return;
    }
    
    if (widget.isIncoming) {
      // 来电 - 检查通话是否已经被接听（从来电对话框接听后打开此页面）
      final currentState = _callService.callState;
      logger.debug('📞 来电处理 - TUICallKit 当前状态: $currentState');
      
      if (currentState == tui.CallState.connected) {
        // 通话已经接听，直接进入通话状态
        logger.debug('📞 通话已接听，直接进入通话状态');
        setState(() {
          _callState = CallState.connected;
          _updateStatusText();
        });
        _startDurationTimer();
      } else if (currentState == tui.CallState.ringing || currentState == tui.CallState.idle) {
        // 通话还在响铃中，显示来电界面
        logger.debug('📞 通话响铃中，显示来电界面');
        setState(() {
          _callState = CallState.ringing;
          _updateStatusText();
        });
        _playWaitingSound();
      } else {
        // 其他状态，按照 TUICallKit 状态处理
        logger.debug('📞 其他状态: $currentState');
        setState(() {
          _callState = _mapTuiCallState(currentState);
          _updateStatusText();
        });
      }
    } else {
      // 去电 - 检查通话是否已经由 TUICallKitService 发起
      final currentState = _callService.callState;
      logger.debug('📞 去电处理 - TUICallKit 当前状态: $currentState');
      
      if (currentState == tui.CallState.connected) {
        // 通话已经接通，直接进入通话状态
        logger.debug('📞 通话已接通，直接进入通话状态');
        setState(() {
          _callState = CallState.connected;
          _updateStatusText();
        });
        _stopSound();
        _startDurationTimer();
        return;
      }
      
      if (currentState == tui.CallState.calling || currentState == tui.CallState.ringing) {
        // 通话已经发起，只更新UI状态，不再重复调用 API
        logger.debug('📞 通话已发起，只更新UI状态');
        setState(() {
          _callState = _mapTuiCallState(currentState);
          _updateStatusText();
        });
        _playWaitingSound();
        return;
      }
      
      // 通话尚未发起，需要发起通话（这种情况通常不会发生，因为 TUICallKitService 已经发起了）
      logger.debug('📞 通话尚未发起，开始发起通话');
      setState(() {
        _callState = CallState.calling;
        _updateStatusText();
      });
      
      try {
        final mediaType = widget.callType == CallType.video 
            ? TUICallMediaType.video 
            : TUICallMediaType.audio;

        if (_isGroupCall) {
          // 群组通话 - 使用 TUICallEngine 避免内置 UI
          final userIdStrList = widget.groupCallUserIds!
              .map((id) => id.toString())
              .toList();
          
          final params = TUICallParams();
          if (widget.groupId != null) {
            params.chatGroupId = widget.groupId.toString();
          }
          
          final result = await TUICallEngine.instance.groupCall(
            widget.groupId?.toString() ?? '',
            userIdStrList,
            mediaType,
            params,
          );
          
          if (result.code.isNotEmpty) {
            logger.debug('📞 发起群组通话失败: ${result.message}');
            _showError('发起通话失败: ${result.message}');
          }
        } else {
          // 单人通话 - 使用 TUICallEngine 避免内置 UI
          final params = TUICallParams();
          final result = await TUICallEngine.instance.call(
            widget.targetUserId.toString(),
            mediaType,
            params,
          );
          
          if (result.code.isNotEmpty) {
            logger.debug('📞 发起通话失败: ${result.message}');
            _showError('发起通话失败: ${result.message}');
          }
        }
        
        _playWaitingSound();
      } catch (e) {
        logger.debug('📞 发起通话异常: $e');
        _showError('发起通话失败: $e');
      }
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  void _handleCallEnded() {
    if (_isClosing) return;
    _isClosing = true;
    
    _stopDurationTimer();
    _stopSound();
    
    // 🔴 检查是否是最后一个成员（通过 remoteUids 判断）
    final isLastMember = _callService.remoteUids.isEmpty;
    
    if (mounted) {
      Navigator.of(context).pop({
        'callEnded': true,
        'callDuration': _callDuration,
        'isLocalHangup': _callService.isLocalHangup,
        'isCallEnded': isLastMember,  // 🔴 是否是最后一个成员离开（通话完全结束）
        'isGroupCall': _isGroupCall,   // 🔴 是否是群组通话
      });
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && !_disposed) {
        setState(() {
          _callDuration++;
        });
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  Future<void> _playWaitingSound() async {
    if (_disposed || !mounted) return;
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
    try {
      await _waitingPlayer?.stop();
      await _waitingPlayer?.dispose();
      _waitingPlayer = null;
      logger.debug('🔊 等待音效已停止');
    } catch (e) {
      logger.debug('⚠️ 停止音效失败: $e');
    }
  }

  Future<void> _acceptCall() async {
    logger.debug('📞 接听来电');
    await _callService.acceptCall();
  }

  Future<void> _rejectCall() async {
    logger.debug('📞 拒绝来电');
    await _callService.rejectCall();
  }

  Future<void> _endCall() async {
    logger.debug('📞 挂断通话, 当前状态: $_callState');
    
    // 如果是来电且还在响铃状态，应该调用 rejectCall 而不是 endCall
    if (_callState == CallState.ringing && widget.isIncoming) {
      logger.debug('📞 来电响铃中，调用 rejectCall');
      await _callService.rejectCall();
    } else {
      logger.debug('📞 调用 endCall');
      await _callService.endCall(isLocalHangup: true);
    }
  }

  Future<void> _toggleMute() async {
    setState(() {
      _isMuted = !_isMuted;
    });
    await _callService.toggleMicrophone(!_isMuted);
  }

  Future<void> _toggleSpeaker() async {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    await _callService.toggleSpeaker(_isSpeakerOn);
  }

  Future<void> _toggleCamera() async {
    if (widget.callType != CallType.video) return;
    setState(() {
      _isCameraOn = !_isCameraOn;
    });
    await _callService.toggleCamera(_isCameraOn);
  }

  Future<void> _switchCamera() async {
    if (widget.callType != CallType.video) return;
    await _callService.switchCamera();
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _disposed = true;
    _stopDurationTimer();
    _stopSound();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final isVideoCall = widget.callType == CallType.video;
    
    return Scaffold(
      backgroundColor: isVideoCall ? Colors.black : const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Stack(
          children: [
            // 视频通话背景
            if (isVideoCall && _callState == CallState.connected)
              _buildVideoView(),
            
            // 主要内容
            _buildMainContent(isMobile, isVideoCall),
            
            // 控制按钮
            Positioned(
              left: 0,
              right: 0,
              bottom: isMobile ? 50 : 40,
              child: _buildControlButtons(isMobile, isVideoCall),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoView() {
    // TUICallKit 会自动管理视频视图
    // 这里返回一个占位容器，实际视频由 TUICallKit 内置 UI 显示
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videocam,
              size: 80,
              color: Colors.white.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '视频通话中',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent(bool isMobile, bool isVideoCall) {
    if (_isGroupCall) {
      return _buildGroupCallContent(isMobile, isVideoCall);
    } else {
      return _buildSingleCallContent(isMobile, isVideoCall);
    }
  }

  Widget _buildSingleCallContent(bool isMobile, bool isVideoCall) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 头像
          _buildAvatar(
            _targetAvatarUrl,
            widget.targetDisplayName,
            isMobile ? 120 : 100,
          ),
          const SizedBox(height: 24),
          
          // 名称
          Text(
            widget.targetDisplayName,
            style: TextStyle(
              fontSize: isMobile ? 28 : 24,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          
          // 状态/时长
          Text(
            _callState == CallState.connected
                ? _formatDuration(_callDuration)
                : _statusText,
            style: TextStyle(
              fontSize: isMobile ? 18 : 16,
              color: Colors.white.withOpacity(0.7),
            ),
          ),
          
          // 通话类型标识
          if (isVideoCall) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.videocam,
                  color: Colors.white.withOpacity(0.5),
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  '视频通话',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGroupCallContent(bool isMobile, bool isVideoCall) {
    return Column(
      children: [
        const SizedBox(height: 60),
        
        // 群组通话标题
        Text(
          '群组${isVideoCall ? '视频' : '语音'}通话',
          style: TextStyle(
            fontSize: isMobile ? 24 : 20,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        
        // 状态/时长
        Text(
          _callState == CallState.connected
              ? _formatDuration(_callDuration)
              : _statusText,
          style: TextStyle(
            fontSize: isMobile ? 18 : 16,
            color: Colors.white.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 24),
        
        // 成员列表
        Expanded(
          child: _buildMembersList(isMobile),
        ),
      ],
    );
  }

  Widget _buildMembersList(bool isMobile) {
    final members = _currentGroupCallUserIds;
    final names = _currentGroupCallDisplayNames;
    final avatars = _currentGroupCallAvatarUrls;
    
    return GridView.builder(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 20 : 40),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isMobile ? 3 : 4,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.8,
      ),
      itemCount: members.length,
      itemBuilder: (context, index) {
        final userId = members[index];
        final name = index < names.length ? names[index] : '用户$userId';
        final avatar = index < avatars.length ? avatars[index] : null;
        final isConnected = _connectedMemberIds.contains(userId);
        final isMe = userId == widget.currentUserId;
        
        return _buildMemberItem(
          userId: userId,
          name: name,
          avatar: avatar,
          isConnected: isConnected || isMe,
          isMe: isMe,
          isMobile: isMobile,
        );
      },
    );
  }

  Widget _buildMemberItem({
    required int userId,
    required String name,
    String? avatar,
    required bool isConnected,
    required bool isMe,
    required bool isMobile,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            _buildAvatar(
              isMe ? _currentUserAvatarUrl : avatar,
              name,
              isMobile ? 60 : 50,
            ),
            // 连接状态指示器
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: isConnected ? Colors.green : Colors.orange,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          isMe ? '我' : name,
          style: TextStyle(
            color: Colors.white,
            fontSize: isMobile ? 14 : 12,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          isConnected ? '已连接' : '等待中...',
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: isMobile ? 12 : 10,
          ),
        ),
      ],
    );
  }

  Widget _buildAvatar(String? avatarUrl, String name, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.grey[700],
        image: avatarUrl != null && avatarUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(avatarUrl),
                fit: BoxFit.cover,
                onError: (_, __) {},
              )
            : null,
      ),
      child: avatarUrl == null || avatarUrl.isEmpty
          ? Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
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


  Widget _buildControlButtons(bool isMobile, bool isVideoCall) {
    if (_callState == CallState.ringing && widget.isIncoming) {
      // 来电状态 - 显示接听和拒绝按钮
      return _buildIncomingCallButtons(isMobile);
    } else {
      // 通话中或呼叫中 - 显示控制按钮
      return _buildCallControlButtons(isMobile, isVideoCall);
    }
  }

  Widget _buildIncomingCallButtons(bool isMobile) {
    final buttonSize = isMobile ? 70.0 : 60.0;
    final iconSize = isMobile ? 32.0 : 28.0;
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 拒绝按钮
        _buildCircleButton(
          onTap: _rejectCall,
          color: Colors.red,
          icon: Icons.call_end,
          label: '拒绝',
          size: buttonSize,
          iconSize: iconSize,
        ),
        // 接听按钮
        _buildCircleButton(
          onTap: _acceptCall,
          color: Colors.green,
          icon: Icons.call,
          label: '接听',
          size: buttonSize,
          iconSize: iconSize,
        ),
      ],
    );
  }

  Widget _buildCallControlButtons(bool isMobile, bool isVideoCall) {
    final buttonSize = isMobile ? 56.0 : 48.0;
    final iconSize = isMobile ? 26.0 : 22.0;
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 静音按钮
        _buildCircleButton(
          onTap: _toggleMute,
          color: _isMuted ? Colors.red : Colors.white.withOpacity(0.2),
          icon: _isMuted ? Icons.mic_off : Icons.mic,
          label: _isMuted ? '取消静音' : '静音',
          size: buttonSize,
          iconSize: iconSize,
        ),
        
        // 扬声器按钮
        _buildCircleButton(
          onTap: _toggleSpeaker,
          color: _isSpeakerOn ? Colors.blue : Colors.white.withOpacity(0.2),
          icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
          label: _isSpeakerOn ? '扬声器' : '听筒',
          size: buttonSize,
          iconSize: iconSize,
        ),
        
        // 视频通话时显示摄像头按钮
        if (isVideoCall) ...[
          _buildCircleButton(
            onTap: _toggleCamera,
            color: _isCameraOn ? Colors.blue : Colors.white.withOpacity(0.2),
            icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
            label: _isCameraOn ? '关闭摄像头' : '开启摄像头',
            size: buttonSize,
            iconSize: iconSize,
          ),
          _buildCircleButton(
            onTap: _switchCamera,
            color: Colors.white.withOpacity(0.2),
            icon: Icons.cameraswitch,
            label: '切换摄像头',
            size: buttonSize,
            iconSize: iconSize,
          ),
        ],
        
        // 挂断按钮
        _buildCircleButton(
          onTap: _endCall,
          color: Colors.red,
          icon: Icons.call_end,
          label: '挂断',
          size: buttonSize + 8,
          iconSize: iconSize + 4,
        ),
      ],
    );
  }

  Widget _buildCircleButton({
    required VoidCallback onTap,
    required Color color,
    required IconData icon,
    required String label,
    required double size,
    required double iconSize,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: iconSize,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// 兼容旧代码的别名
typedef VoiceCallPage = CallPage;
typedef GroupVideoCallPage = CallPage;

/// 根据平台返回正确的通话页面 Widget
/// 桌面平台返回 DesktopCallPage，移动平台返回 CallPage
Widget buildCallPage({
  required int targetUserId,
  required String targetDisplayName,
  bool isIncoming = false,
  CallType callType = CallType.voice,
  String? targetAvatar,
  List<int>? groupCallUserIds,
  List<String>? groupCallDisplayNames,
  List<String?>? groupCallAvatarUrls,
  int? currentUserId,
  int? groupId,
  bool isJoiningExistingCall = false,
  String? memberRole,
}) {
  if (_isDesktopPlatform) {
    return DesktopCallPage(
      targetUserId: targetUserId,
      targetDisplayName: targetDisplayName,
      targetAvatar: targetAvatar,
      isIncoming: isIncoming,
      isVideoCall: callType == CallType.video,
    );
  } else {
    return CallPage(
      targetUserId: targetUserId,
      targetDisplayName: targetDisplayName,
      isIncoming: isIncoming,
      callType: callType,
      targetAvatar: targetAvatar,
      groupCallUserIds: groupCallUserIds,
      groupCallDisplayNames: groupCallDisplayNames,
      groupCallAvatarUrls: groupCallAvatarUrls,
      currentUserId: currentUserId,
      groupId: groupId,
      isJoiningExistingCall: isJoiningExistingCall,
      memberRole: memberRole,
    );
  }
}

/// 显示通话页面的便捷方法
/// 自动根据平台选择正确的通话页面
Future<Map<String, dynamic>?> showCallPage(
  BuildContext context, {
  required int targetUserId,
  required String targetDisplayName,
  bool isIncoming = false,
  CallType callType = CallType.voice,
  String? targetAvatar,
  List<int>? groupCallUserIds,
  List<String>? groupCallDisplayNames,
  List<String?>? groupCallAvatarUrls,
  int? currentUserId,
  int? groupId,
  bool isJoiningExistingCall = false,
  String? memberRole,
  bool useDialog = false,
}) async {
  final page = buildCallPage(
    targetUserId: targetUserId,
    targetDisplayName: targetDisplayName,
    isIncoming: isIncoming,
    callType: callType,
    targetAvatar: targetAvatar,
    groupCallUserIds: groupCallUserIds,
    groupCallDisplayNames: groupCallDisplayNames,
    groupCallAvatarUrls: groupCallAvatarUrls,
    currentUserId: currentUserId,
    groupId: groupId,
    isJoiningExistingCall: isJoiningExistingCall,
    memberRole: memberRole,
  );

  if (useDialog) {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => page,
    );
  } else {
    return await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (context) => page),
    );
  }
}
