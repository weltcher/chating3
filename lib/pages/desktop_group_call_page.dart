// Windows/macOS/Linux 桌面端群组通话页面
// 支持显示"正在呼叫"状态，等有人接听后开始计时
// 每个成员显示独立的连接状态
//
// 流程：
// 1. 发起者首先看到"正在呼叫"弹窗（紧凑UI）
// 2. 等有人接听后，切换到通话页面（全屏UI）并开始计时
// 3. 被邀请的人根据连接状态展示不同

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
  });

  @override
  State<DesktopGroupCallPage> createState() => _DesktopGroupCallPageState();
}

class _DesktopGroupCallPageState extends State<DesktopGroupCallPage> {
  final TRTCDesktopService _callService = TRTCDesktopService();
  
  // 音效播放器
  AudioPlayer? _waitingPlayer;
  
  // 成员列表
  List<DesktopGroupCallMember> _members = [];
  
  // UI 状态
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isClosing = false;
  bool _hasAnyoneConnected = false;  // 是否有人已接听
  
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
    
    _initMembers();
    _setupCallbacks();
    _startCall();
  }

  @override
  void dispose() {
    _stopSound();
    _durationTimer?.cancel();
    _callTimeoutTimer?.cancel();
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
            // 状态变为 accept 时，检查是否需要开始计时和停止音效
            if (!_hasAnyoneConnected) {
              _hasAnyoneConnected = true;
              _startDurationTimer();
              _stopSound();  // 🔴 停止呼叫音效
              _stopCallTimeoutTimer();  // 🔴 停止超时计时器
            }
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
        _stopSound();  // 在 setState 外部调用异步方法
        _stopCallTimeoutTimer();  // 停止超时计时器
      }
      
      setState(() {
        // 更新成员状态
        for (var member in _members) {
          if (member.userId == odUserIdInt) {
            member.status = MemberCallStatus.connected;
            break;
          }
        }
        
        // 第一个人接听时开始计时
        if (isFirstConnection) {
          _hasAnyoneConnected = true;
          _startDurationTimer();
        }
        
        _updateStatusText();
      });
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
    try {
      await _waitingPlayer?.stop();
      await _waitingPlayer?.dispose();
      _waitingPlayer = null;
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
    _stopSound();
    await _callService.hangup();
  }

  void _endCallAndClose() {
    if (_isClosing) return;
    _isClosing = true;
    
    _stopSound();
    _durationTimer?.cancel();
    _callTimeoutTimer?.cancel();
    
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
          // 返回按钮
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _endCall,
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
