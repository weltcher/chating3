// Windows/macOS/Linux 桌面端通话页面
// 参考 TUICallKit 的 UI 逻辑实现
// 使用 TRTC SDK 实现音视频通话

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';
import '../services/trtc_desktop_service.dart';
import '../utils/logger.dart';

/// 桌面端通话页面
class DesktopCallPage extends StatefulWidget {
  final int targetUserId;
  final String targetDisplayName;
  final String? targetAvatar;
  final bool isIncoming;
  final bool isVideoCall;

  const DesktopCallPage({
    super.key,
    required this.targetUserId,
    required this.targetDisplayName,
    this.targetAvatar,
    this.isIncoming = false,
    this.isVideoCall = false,
  });

  @override
  State<DesktopCallPage> createState() => _DesktopCallPageState();
}

class _DesktopCallPageState extends State<DesktopCallPage> {
  final TRTCDesktopService _callService = TRTCDesktopService();
  
  // 音效播放器
  AudioPlayer? _waitingPlayer;
  
  // UI 状态
  bool _isMuted = false;
  bool _isCameraOn = false;
  bool _isSpeakerOn = true;
  bool _hasRemoteVideo = false;
  bool _isClosing = false;
  
  // 通话时长
  int _callDuration = 0;
  
  // 状态文本
  String _statusText = '正在连接...';

  @override
  void initState() {
    super.initState();
    logger.debug('📞 DesktopCallPage initState');
    logger.debug('  - targetUserId: ${widget.targetUserId}');
    logger.debug('  - isIncoming: ${widget.isIncoming}');
    logger.debug('  - isVideoCall: ${widget.isVideoCall}');
    
    _setupCallbacks();
    _initCall();
  }

  @override
  void dispose() {
    _stopSound();
    super.dispose();
  }

  void _setupCallbacks() {
    _callService.onCallStateChanged = (state) {
      if (!mounted || _isClosing) return;
      logger.debug('📞 [Desktop UI] 通话状态变化: $state');
      
      setState(() {
        switch (state) {
          case DesktopCallState.idle:
            _statusText = '通话结束';
            _endCallAndClose();
            break;
          case DesktopCallState.waiting:
            if (_callService.callRole == DesktopCallRole.caller) {
              _statusText = '正在呼叫...';
            } else {
              _statusText = '来电中...';
            }
            break;
          case DesktopCallState.accept:
            _statusText = '通话中';
            _stopSound();
            break;
        }
      });
    };

    _callService.onRemoteUserJoined = (odUserId, odUserIdInt) {
      logger.debug('📞 [Desktop UI] 远端用户加入: $odUserId');
      if (!mounted) return;
      setState(() {
        _statusText = '通话中';
      });
      _stopSound();
    };

    _callService.onRemoteUserLeft = (odUserId, odUserIdInt) {
      logger.debug('📞 [Desktop UI] 远端用户离开: $odUserId');
      if (!mounted) return;
      // 通话服务会自动处理结束逻辑
    };

    _callService.onRemoteVideoAvailable = (odUserId, available) {
      logger.debug('📞 [Desktop UI] 远端视频可用: $odUserId, $available');
      if (!mounted) return;
      setState(() {
        _hasRemoteVideo = available;
      });
    };

    _callService.onCallTimeUpdate = (timeCount) {
      if (!mounted) return;
      setState(() {
        _callDuration = timeCount;
      });
    };

    _callService.onError = (error) {
      logger.debug('📞 [Desktop UI] 通话错误: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
    };

    _callService.onCallEnded = (duration) {
      logger.debug('📞 [Desktop UI] 通话结束，时长: $duration 秒');
      _callDuration = duration;
      _endCallAndClose();
    };
  }

  Future<void> _initCall() async {
    // 🔴 检查通话是否已经在进行中（来电已在 home_page 中接听）
    if (_callService.callState == DesktopCallState.accept) {
      logger.debug('📞 [Desktop UI] 通话已在进行中，直接显示通话界面');
      setState(() {
        _statusText = '通话中';
        _isCameraOn = widget.isVideoCall;
      });
      return;
    }
    
    // 🔴 检查是否为被叫方且正在等待中（来电已接听但还未完全连接）
    if (_callService.callState == DesktopCallState.waiting && 
        _callService.callRole == DesktopCallRole.called) {
      logger.debug('📞 [Desktop UI] 来电已接听，等待连接中');
      setState(() {
        _statusText = '正在连接...';
        _isCameraOn = widget.isVideoCall;
      });
      // 不需要再次调用 accept，因为 home_page 已经调用过了
      return;
    }
    
    if (widget.isIncoming) {
      // 来电 - 等待用户操作
      setState(() {
        _statusText = '来电中...';
      });
      _playWaitingSound();
    } else {
      // 去电 - 发起呼叫
      setState(() {
        _statusText = '正在呼叫...';
        _isCameraOn = widget.isVideoCall;
      });
      
      _playWaitingSound();
      
      if (widget.isVideoCall) {
        await _callService.startVideoCall(widget.targetUserId, widget.targetDisplayName);
      } else {
        await _callService.startVoiceCall(widget.targetUserId, widget.targetDisplayName);
      }
    }
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

  Future<void> _acceptCall() async {
    logger.debug('📞 [Desktop UI] 接听来电');
    _stopSound();
    await _callService.accept();
    setState(() {
      _isCameraOn = widget.isVideoCall;
    });
  }

  Future<void> _rejectCall() async {
    logger.debug('📞 [Desktop UI] 拒绝来电');
    _stopSound();
    await _callService.reject();
    _endCallAndClose();
  }

  Future<void> _endCall() async {
    logger.debug('📞 [Desktop UI] 挂断通话');
    _stopSound();
    
    if (_callService.callState == DesktopCallState.waiting && 
        _callService.callRole == DesktopCallRole.caller) {
      // 主叫在等待中取消
      await _callService.cancel();
    } else {
      await _callService.hangup();
    }
  }

  void _endCallAndClose() {
    logger.debug('📞 [CallPage] _endCallAndClose 被调用, _isClosing: $_isClosing');
    if (_isClosing) {
      logger.debug('📞 [CallPage] _isClosing 为 true，直接返回');
      return;
    }
    _isClosing = true;
    
    _stopSound();
    
    if (mounted) {
      final isLocalHangup = _callService.isLocalHangup;
      logger.debug('📞 [CallPage] DesktopCallPage 返回结果: {callEnded: true, callDuration: $_callDuration, isLocalHangup: $isLocalHangup}');
      Navigator.of(context).pop({
        'callEnded': true,
        'callDuration': _callDuration,
        'isLocalHangup': isLocalHangup,
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

  Future<void> _toggleCamera() async {
    final newCameraOn = !_isCameraOn;
    await _callService.toggleCamera(newCameraOn);
    setState(() {
      _isCameraOn = newCameraOn;
    });
  }

  Future<void> _toggleSpeaker() async {
    final newSpeakerOn = !_isSpeakerOn;
    await _callService.toggleSpeaker(newSpeakerOn);
    setState(() {
      _isSpeakerOn = newSpeakerOn;
    });
  }

  bool get _isConnected => _callService.callState == DesktopCallState.accept;
  bool get _isWaiting => _callService.callState == DesktopCallState.waiting;
  bool get _isIncomingWaiting => _isWaiting && _callService.callRole == DesktopCallRole.called;


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          children: [
            // 顶部信息栏
            _buildTopBar(),
            
            // 主内容区域
            Expanded(
              child: widget.isVideoCall ? _buildVideoCallContent() : _buildVoiceCallContent(),
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
            onPressed: () {
              if (_isConnected || _isWaiting) {
                _endCall();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          const Spacer(),
          // 通话状态/时长
          Column(
            children: [
              Text(
                _isConnected ? _formatDuration(_callDuration) : _statusText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (_isConnected)
                Text(
                  widget.isVideoCall ? '视频通话' : '语音通话',
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

  Widget _buildVoiceCallContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 头像
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[700],
              image: widget.targetAvatar != null && widget.targetAvatar!.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(widget.targetAvatar!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: widget.targetAvatar == null || widget.targetAvatar!.isEmpty
                ? Center(
                    child: Text(
                      widget.targetDisplayName.isNotEmpty 
                          ? widget.targetDisplayName[0].toUpperCase() 
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 24),
          // 用户名
          Text(
            widget.targetDisplayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          // 状态
          Text(
            _isConnected ? _formatDuration(_callDuration) : _statusText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoCallContent() {
    return Stack(
      children: [
        // 远端视频（大画面）
        Positioned.fill(
          child: _hasRemoteVideo && _isConnected
              ? TRTCCloudVideoView(
                  key: const ValueKey('remote_video'),
                  onViewCreated: (viewId) {
                    _callService.startRemoteView(
                      widget.targetUserId.toString(), 
                      viewId,
                    );
                  },
                )
              : _buildVoiceCallContent(),
        ),
        
        // 本地视频（小画面）
        if (_isCameraOn && _isConnected)
          Positioned(
            right: 20,
            top: 20,
            width: 160,
            height: 200,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3), 
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: TRTCCloudVideoView(
                  key: const ValueKey('local_video'),
                  onViewCreated: (viewId) {
                    _callService.openCamera(viewId);
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
      child: _isIncomingWaiting 
          ? _buildIncomingCallControls() 
          : _buildCallControls(),
    );
  }

  Widget _buildIncomingCallControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 拒绝
        _buildControlButton(
          icon: Icons.call_end,
          label: '拒绝',
          color: Colors.red,
          onPressed: _rejectCall,
        ),
        // 接听
        _buildControlButton(
          icon: Icons.call,
          label: '接听',
          color: Colors.green,
          onPressed: _acceptCall,
        ),
      ],
    );
  }

  Widget _buildCallControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 静音
        _buildControlButton(
          icon: _isMuted ? Icons.mic_off : Icons.mic,
          label: _isMuted ? '取消静音' : '静音',
          color: _isMuted ? Colors.red : Colors.white.withValues(alpha: 0.3),
          onPressed: _toggleMute,
        ),
        
        // 摄像头（仅视频通话）
        if (widget.isVideoCall)
          _buildControlButton(
            icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
            label: _isCameraOn ? '关闭摄像头' : '开启摄像头',
            color: _isCameraOn ? Colors.white.withValues(alpha: 0.3) : Colors.red,
            onPressed: _toggleCamera,
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
          label: _isWaiting ? '取消' : '挂断',
          color: Colors.red,
          onPressed: _endCall,
        ),
      ],
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

/// 显示桌面端通话页面
Future<Map<String, dynamic>?> showDesktopCallPage(
  BuildContext context, {
  required int targetUserId,
  required String targetDisplayName,
  String? targetAvatar,
  bool isIncoming = false,
  bool isVideoCall = false,
}) async {
  return await Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (context) => DesktopCallPage(
        targetUserId: targetUserId,
        targetDisplayName: targetDisplayName,
        targetAvatar: targetAvatar,
        isIncoming: isIncoming,
        isVideoCall: isVideoCall,
      ),
    ),
  );
}
