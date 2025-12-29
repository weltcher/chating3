import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/agora_service.dart';
import '../services/api_service.dart';
import '../utils/storage.dart';
import '../utils/responsive_helper.dart';
import '../utils/logger.dart';
import '../widgets/mobile_add_call_member_dialog.dart';
import '../widgets/call_duration_widget.dart';
import '../widgets/fullscreen_video_dialog.dart';

class GroupVideoCallPage extends StatefulWidget {
  final int targetUserId;
  final String targetDisplayName;
  final bool isIncoming; // 是否是来电
  // 群组通话相关参数
  final List<int>? groupCallUserIds; // 群组通话的用户ID列表
  final List<String>? groupCallDisplayNames; // 群组通话的用户显示名列表
  final int? currentUserId; // 当前用户ID（用于群组通话标识自己）
  final int? groupId; // 群组ID（用于获取群组成员）
  final String? memberRole; // 当前用户在群组中的角色（owner/admin/member）

  const GroupVideoCallPage({
    super.key,
    required this.targetUserId,
    required this.targetDisplayName,
    this.isIncoming = false,
    this.groupCallUserIds,
    this.groupCallDisplayNames,
    this.currentUserId,
    this.groupId,
    this.memberRole,
  });

  @override
  State<GroupVideoCallPage> createState() => _GroupVideoCallPageState();
}

class _GroupVideoCallPageState extends State<GroupVideoCallPage> {
  final AgoraService _agoraService = AgoraService();
  AudioPlayer? _waitingPlayer;

  CallState _callState = CallState.idle;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isCameraOn = true; // 摄像头状态
  int _callDuration = 0; // 通话时长（秒）
  bool _isClosing = false; // 是否正在关闭页面
  bool _disposed = false; // 页面是否已销毁
  // 远程用户 ID
  int? _remoteUid;

  // 🔴 修复：保存之前的监听器，避免覆盖聊天页面的监听器
  void Function(CallState)? _previousCallStateListener;

  // 群组通话成员滚动控制器
  final ScrollController _groupMembersScrollController = ScrollController();

  // 群组通话：已连接的成员 userId 集合
  final Set<int> _connectedMemberIds = {};

  // 群组通话：当前显示的成员列表（可动态修改）
  List<int> _currentGroupCallUserIds = [];
  List<String> _currentGroupCallDisplayNames = [];

  // 视频控制器 - 群组视频通话需要支持多个远程视频视图
  AgoraVideoView? _localVideoView;
  final Map<int, AgoraVideoView> _remoteVideoViews = {}; // 远程用户视频视图映射
  final Map<int, bool> _remoteVideoMuted = {}; // 🔴 新增：远程用户视频静音状态映射

  String _statusText = '正在连接...';
  String? _exitStatusText; // 退出状态文本（"正在退出..."或"正在最小化..."）

  // 麦克风设备相关
  List<AudioDeviceInfo> _microphoneDevices = [];
  String? _currentMicDeviceId;
  bool _showMicPopup = false;
  double _micVolume = 100; // 麦克风音量 (0-100)

  // 扬声器相关状态
  List<AudioDeviceInfo> _speakerDevices = [];
  String? _currentSpeakerDeviceId;
  bool _showSpeakerPopup = false;
  double _speakerVolume = 100; // 扬声器音量 (0-100)

  // 摄像头相关状态
  List<VideoDeviceInfo> _cameraDevices = [];
  String? _currentCameraDeviceId;
  bool _isCameraPopupShown = false;

  Timer? _popupCloseTimer; // 弹窗关闭延迟计时器

  bool _isLoadingConfig = false; // 是否正在加载配置（避免保存时触发循环）

  @override
  void initState() {
    super.initState();

    logger.debug('📹 [GroupVideoCallPage] ========== initState 开始 ==========');
    logger.debug('📹 [GroupVideoCallPage] 页面参数:');
    logger.debug(
      '📹 [GroupVideoCallPage]   - targetUserId: ${widget.targetUserId}',
    );
    logger.debug(
      '📹 [GroupVideoCallPage]   - targetDisplayName: ${widget.targetDisplayName}',
    );
    logger.debug(
      '📹 [GroupVideoCallPage]   - isIncoming: ${widget.isIncoming}',
    );
    logger.debug(
      '📹 [GroupVideoCallPage]   - groupCallUserIds: ${widget.groupCallUserIds}',
    );
    logger.debug(
      '📹 [GroupVideoCallPage]   - groupCallDisplayNames: ${widget.groupCallDisplayNames}',
    );
    logger.debug(
      '📹 [GroupVideoCallPage]   - currentUserId: ${widget.currentUserId}',
    );

    // 初始化群组通话成员列表
    if (widget.groupCallUserIds != null &&
        widget.groupCallDisplayNames != null) {
      _currentGroupCallUserIds = List.from(widget.groupCallUserIds!);
      _currentGroupCallDisplayNames = List.from(widget.groupCallDisplayNames!);
      logger.debug(
        '📹 [GroupVideoCallPage] 成员列表已初始化: ${_currentGroupCallUserIds.length} 个成员',
      );
    }

    // 初始化Agora服务回调
    logger.debug('📹 [GroupVideoCallPage] 开始初始化Agora回调...');
    _initializeAgoraCallbacks();

    // 🔴 BUG修复：精准判断 - 使用 isCallMinimized 标识判断是否从最小化恢复
    // 如果是从最小化恢复且频道还在，使用恢复方法（不重新发起通话）
    if (_agoraService.isCallMinimized &&
        _agoraService.currentChannelName != null) {
      // 🔴 修复：在调用异步方法前，先同步设置已知的状态，避免UI显示初始状态
      _callState = CallState.connected;
      _statusText = '正在恢复通话...';

      // 立即恢复通话时长（同步）
      if (_agoraService.callStartTime != null) {
        final elapsed = DateTime.now().difference(_agoraService.callStartTime!);
        _callDuration = elapsed.inSeconds;
      }

      // 🔴 修复：立即恢复已连接成员列表（从保存的状态中恢复）
      if (_agoraService.connectedMemberIds != null) {
        // 如果有保存的已连接成员ID集合，直接使用
        _connectedMemberIds.addAll(_agoraService.connectedMemberIds!);
      } else {
        // 兼容旧版本：如果没有保存的集合，从 remoteUids 恢复
        for (final uid in _agoraService.remoteUids) {
          _connectedMemberIds.add(uid);
        }
        if (widget.currentUserId != null) {
          _connectedMemberIds.add(widget.currentUserId!);
        }
      }

      // 然后再执行异步恢复操作（初始化设备、创建视频视图等）
      _resumeCallFromMinimized();
    } else {
      _startCall();
    }
  }

  // 辅助方法：截断显示名称，超过9个字符添加省略号
  String _truncateDisplayName(String name) {
    if (name.length > 9) {
      return '${name.substring(0, 9)}...';
    }
    return name;
  }

  @override
  void dispose() {
    _disposed = true;
    _isClosing = true;

    // 清理定时器
    _popupCloseTimer?.cancel();

    // 停止等待音效
    _waitingPlayer?.stop();

    // 清理视频视图
    _localVideoView = null;
    _remoteVideoViews.clear();
    _remoteVideoMuted.clear(); // 🔴 新增：清理远程视频静音状态

    // 🔴 优化：移除这里的 stopPreview 调用
    // 原因：
    // 1. endCall() 方法中已经会调用 stopPreview
    // 2. 重复调用会导致卡顿（每次耗时6-16秒）
    // 3. dispose 是同步方法，不应该执行耗时操作

    // 🔴 修复：只有在真正结束通话时才调用 endCall()
    // 如果是最小化返回（isCallMinimized=true），不结束通话
    if (!_agoraService.isCallMinimized) {
      _endCall();
    }

    // 🔴 修复：恢复之前的监听器，而不是设置为 null
    // 这样可以保持聊天页面的监听器继续工作
    _agoraService.onCallStateChanged = _previousCallStateListener;

    // 清理滚动控制器
    _groupMembersScrollController.dispose();

    super.dispose();
  }

  // 初始化Agora服务回调
  void _initializeAgoraCallbacks() {
    // 🔴 修复：保存之前的监听器（可能是聊天页面设置的）
    _previousCallStateListener = _agoraService.onCallStateChanged;

    // 监听通话状态变化
    _agoraService.onCallStateChanged = (state) {
      if (mounted && !_disposed) {
        setState(() {
          _callState = state;
          if (state == CallState.connected) {
            _stopWaitingSound();
            
            // 🔴 修复：立即同步已连接成员（从 Agora 的 remoteUids 中获取）
            logger.debug('📹 [状态变化-connected] 立即同步已连接成员，remoteUids: ${_agoraService.remoteUids}');
            for (final uid in _agoraService.remoteUids) {
              if (!_connectedMemberIds.contains(uid)) {
                _connectedMemberIds.add(uid);
                logger.debug('📹 [状态变化-connected] 添加已连接成员: $uid');
              }
            }
            // 同时将自己添加到已连接成员列表
            if (widget.currentUserId != null && !_connectedMemberIds.contains(widget.currentUserId!)) {
              _connectedMemberIds.add(widget.currentUserId!);
              logger.debug('📹 [状态变化-connected] 添加自己到已连接成员: ${widget.currentUserId}');
            }
            logger.debug('📹 [状态变化-connected] 当前已连接成员: $_connectedMemberIds');
            
            _statusText = '通话中 (${_connectedMemberIds.length}人)';
            
            // 🔴 修改：延迟同步已连接成员列表（二次同步，确保不遗漏）
            // 等待 Agora 的 remoteUids 更新后再同步，确保能正确检测已离开的成员
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_disposed) {
                _syncConnectedMembers();
              }
            });
          }
        });
      }
    };

    // 监听用户加入
    _agoraService.onRemoteUserJoined = (uid) {
      logger.debug('📹 [群组视频] 远程用户加入: uid=$uid');
      if (mounted && !_disposed) {
        setState(() {
          _connectedMemberIds.add(uid);
          _statusText = '通话中 (${_connectedMemberIds.length}人)';
        });

        // 🔴 修复：立即创建远程用户的视频视图
        logger.debug('📹 [群组视频] 准备创建远程视频视图: uid=$uid');
        _createRemoteVideoView(uid);
      }
    };

    // 监听用户离开
    _agoraService.onRemoteUserLeft = (uid) {
      if (mounted && !_disposed) {
        setState(() {
          _connectedMemberIds.remove(uid);
          _remoteVideoViews.remove(uid); // 🔴 修复：移除视频视图
          _remoteVideoMuted.remove(uid); // 🔴 新增：移除视频静音状态
          _statusText = '通话中 (${_connectedMemberIds.length}人)';
        });
      }
    };

    // 本地视频准备就绪
    _agoraService.onLocalVideoReady = () {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📹 本地视频准备就绪，创建本地视频视图');

      // 创建本地视频视图
      _createLocalVideoView();
    };

    // 远程视频准备就绪
    _agoraService.onRemoteVideoReady = (uid) {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📹 远程视频准备就绪: uid=$uid');

      // 触发UI更新
      if (mounted && !_disposed) {
        setState(() {});
      }
    };

    // 群组成员状态变化回调
    _agoraService.onGroupCallMemberStatusChanged =
        (userId, status, displayName) {
          if (_disposed || !mounted) return;

          if (mounted && !_disposed) {
            setState(() {
              if (status == 'accepted') {
                _connectedMemberIds.add(userId);
                _statusText = '通话中 (${_connectedMemberIds.length}人)';

                // 🔴 修复：检查是否是新邀请的成员（不在当前显示列表中）
                if (!_currentGroupCallUserIds.contains(userId)) {
                  // 添加到显示列表中
                  _currentGroupCallUserIds.add(userId);

                  // 使用从消息中获取的显示名称，如果没有则使用默认名称
                  final memberDisplayName = displayName ?? '用户$userId';
                  _currentGroupCallDisplayNames.add(memberDisplayName);
                }

                // 创建远程用户的视频视图
                _createRemoteVideoView(userId);
              } else if (status == 'left') {
                // 从连接成员集合中移除
                _connectedMemberIds.remove(userId);

                // 移除视频视图
                _remoteVideoViews.remove(userId);
                _remoteVideoMuted.remove(userId); // 🔴 新增：移除视频静音状态

                // 🔴 修复：从显示列表中完全移除该成员
                final userIndex = _currentGroupCallUserIds.indexOf(userId);
                if (userIndex != -1) {
                  _currentGroupCallUserIds.removeAt(userIndex);
                  if (userIndex < _currentGroupCallDisplayNames.length) {
                    _currentGroupCallDisplayNames.removeAt(userIndex);
                  }
                }

                _statusText = '通话中 (${_connectedMemberIds.length}人)';
              }
            });
          }
        };

    // 🔴 新增：监听远程用户视频静音状态变化
    _agoraService.onRemoteVideoMuted = (uid, isMuted) {
      if (_disposed || !mounted) return;
      logger.debug('📹 [群组视频] 远程用户视频静音状态变化: uid=$uid, isMuted=$isMuted');
      
      setState(() {
        _remoteVideoMuted[uid] = isMuted;
      });
    };
  }

  // 创建远程用户的视频视图
  void _createRemoteVideoView(int uid) async {
    logger.debug('📹 [群组视频] _createRemoteVideoView 开始: uid=$uid');

    if (_agoraService.engine == null) {
      logger.debug('📹 [群组视频] ❌ Agora引擎为null');
      return;
    }

    if (_disposed) {
      logger.debug('📹 [群组视频] ❌ 页面已销毁');
      return;
    }

    // 🔴 修复：如果已存在视频视图，不重复创建
    if (_remoteVideoViews.containsKey(uid)) {
      logger.debug('📹 [群组视频] ⚠️ 视频视图已存在，跳过创建: uid=$uid');
      return;
    }

    try {
      logger.debug(
        '📹 [群组视频] 创建VideoViewController: uid=$uid, channel=${_agoraService.currentChannelName}',
      );

      final videoViewController = VideoViewController.remote(
        rtcEngine: _agoraService.engine!,
        useAndroidSurfaceView: true,
        useFlutterTexture: false,
        canvas: VideoCanvas(uid: uid),
        connection: RtcConnection(
          channelId: _agoraService.currentChannelName ?? '',
        ),
      );

      if (mounted && !_disposed) {
        setState(() {
          _remoteVideoViews[uid] = AgoraVideoView(
            controller: videoViewController,
          );
          logger.debug('📹 [群组视频] ✅ 远程视频视图已创建并添加到map: uid=$uid');
          logger.debug('📹 [群组视频] 当前远程视频视图数量: ${_remoteVideoViews.length}');
        });
      }
    } catch (e) {
      logger.debug('📹 [群组视频] ❌ 创建远程视频视图失败: uid=$uid, error=$e');
    }
  }

  // 开始通话
  Future<void> _startCall() async {
    logger.debug('📹 [GroupVideoCallPage] ========== _startCall 开始 ==========');
    logger.debug('📹 [GroupVideoCallPage] isIncoming: ${widget.isIncoming}');
    logger.debug(
      '📹 [GroupVideoCallPage] AgoraService状态: ${_agoraService.callState}',
    );
    logger.debug('📹 [GroupVideoCallPage] 远程用户列表: ${_agoraService.remoteUids}');

    try {
      // 初始化设备
      await _initializeDevices();

      // 如果是来电，需要检查是否已经被接听
      if (widget.isIncoming) {
        // 检查通话是否已经被接听（在home_page.dart中已经调用了acceptCall）
        if (_agoraService.callState == CallState.connected) {
          // 确保停止任何可能残留的等待音效
          _stopWaitingSound();

          setState(() {
            _callState = CallState.connected;
            _statusText = '通话中 (${_connectedMemberIds.length}人)';
            // 接听方添加自己到已连接成员列表（如果还没有的话）
            if (widget.currentUserId != null &&
                !_connectedMemberIds.contains(widget.currentUserId!)) {
              _connectedMemberIds.add(widget.currentUserId!);
            }
          });

          // 🔴 修复：检查是否已有远程用户在频道中（页面打开前就加入了）
          if (_agoraService.remoteUids.isNotEmpty) {
            logger.debug(
              '📹 [GroupVideoCallPage] 检测到已有 ${_agoraService.remoteUids.length} 个远程用户',
            );
            for (final uid in _agoraService.remoteUids) {
              logger.debug('📹 [GroupVideoCallPage] 为已存在的远程用户创建视频视图: uid=$uid');
              _connectedMemberIds.add(uid);
              _createRemoteVideoView(uid);
            }
          }
        } else {
          // 播放等待音效
          _playWaitingSound();
          setState(() {
            _callState = CallState.ringing;
            _statusText = '收到来电...';
          });
        }
      } else {
        // 检查是否已经有成员接听了（避免重复播放等待音效）
        if (_agoraService.callState == CallState.connected &&
            _connectedMemberIds.length > 1) {
          setState(() {
            _callState = CallState.connected;
            _statusText = '通话中 (${_connectedMemberIds.length}人)';
          });
        } else {
          // 播放等待音效
          _playWaitingSound();

          // 由 AgoraService 负责调用 initiateGroupCall 并加入频道
          final calleeIds = widget.groupCallUserIds ?? [widget.targetUserId];
          await _agoraService.startGroupVideoCall(
            calleeIds.whereType<int>().toList(),
          );
        }
      }

      // 创建本地视频视图
      await _createLocalVideoView();

      // 设置默认连接状态
      if (mounted && widget.currentUserId != null) {
        setState(() {
          if (!widget.isIncoming) {
            // 发起者：将自己添加到已连接成员列表
            _connectedMemberIds.add(widget.currentUserId!);
          }
          // 🔴 修改：接收者不再预先标记发起者为已连接
          // 因为发起者可能在接听前就已经挂断了
          // 改为在加入频道后通过 Agora 的 remoteUids 来确定实际在线的成员
          _statusText = '通话中 (${_connectedMemberIds.length}人)';
        });
      }

      if (mounted &&
          !_disposed &&
          _callState != CallState.connected &&
          _callState != CallState.ended) {
        setState(() {
          _callState = CallState.calling;
          if (widget.isIncoming) {
            _statusText = '收到来电...';
          } else {
            _statusText = '正在连接...';
          }
        });
      }
    } catch (e) {
      if (mounted && !_disposed) {
        setState(() {
          _statusText = '通话失败';
        });
      }
    }
  }

  // 🔴 新增：从最小化恢复通话（不重新发起通话请求）
  Future<void> _resumeCallFromMinimized() async {
    try {
      // 注意：通话时长和成员列表已经在 initState 中同步设置了
      logger.debug(
        '📞 开始恢复通话，当前时长: $_callDuration 秒，成员数: ${_connectedMemberIds.length}',
      );

      // 1. 初始化设备列表
      await _initializeDevices();

      // 2. 只在视频通话时创建本地视频视图
      if (_agoraService.callType == CallType.video) {
        await _createLocalVideoView();
      }

      // 3. 为已连接的远程成员创建视频视图（仅视频通话）
      if (_agoraService.callType == CallType.video) {
        for (final uid in _agoraService.remoteUids) {
          _createRemoteVideoView(uid);
        }
      }

      // 4. 更新UI状态为正式的通话中状态
      if (mounted && !_disposed) {
        setState(() {
          _callState = CallState.connected;
          _statusText = '通话中 (${_connectedMemberIds.length}人)';
        });
      }

      // 5. 清除最小化标识（已经恢复了）
      _agoraService.setCallMinimized(isMinimized: false);

      logger.debug('📞 通话恢复完成');
    } catch (e) {
      logger.error('📞 恢复通话失败: $e');
      if (mounted && !_disposed) {
        setState(() {
          _statusText = '恢复失败';
        });
      }
    }
  }

  // 创建本地视频视图
  Future<void> _createLocalVideoView() async {
    if (_agoraService.engine == null) {
      logger.debug('📹 Agora引擎未初始化，跳过创建本地视频视图');
      return;
    }

    // 如果已经创建过了，不重复创建
    if (_localVideoView != null) {
      logger.debug('📹 本地视频视图已存在，跳过重复创建');
      return;
    }

    // 🔴 修复：在移动端（Android/iOS），摄像头设备枚举可能返回空列表
    // 但这不影响摄像头的实际使用，因此在移动端跳过设备列表检查
    // 桌面端也可能存在设备枚举延迟的问题，所以允许先尝试创建视频视图
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile && _cameraDevices.isEmpty) {
      logger.debug('📹 ⚠️ 桌面端摄像头设备列表为空，但仍尝试创建视频视图');
      // 不直接return，而是继续尝试创建
    }

    try {
      logger.debug('📹 开始创建本地视频视图...');
      final videoViewController = VideoViewController(
        rtcEngine: _agoraService.engine!,
        useAndroidSurfaceView: true,
        useFlutterTexture: false,
        canvas: const VideoCanvas(uid: 0),
      );

      if (mounted && !_disposed) {
        setState(() {
          _localVideoView = AgoraVideoView(controller: videoViewController);
        });
        logger.debug('📹 ✅ 本地视频视图创建成功');
      }
    } catch (e) {
      logger.error('📹 ❌ 创建本地视频视图失败: $e');
      // 不抛出异常，让通话继续
    }
  }

  // 结束通话
  Future<void> _endCall() async {
    try {
      await _agoraService.endCall();

      if (mounted && !_disposed) {
        setState(() {
          _callState = CallState.ended;
          _statusText = '通话结束';
        });
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 播放等待音效
  void _playWaitingSound() async {
    try {
      _waitingPlayer = AudioPlayer();
      await _waitingPlayer!.setReleaseMode(ReleaseMode.loop);
      await _waitingPlayer!.play(AssetSource('mp3/wait.mp3'));
    } catch (e) {
      // 静默处理错误
    }
  }

  // 停止等待音效
  void _stopWaitingSound() {
    _waitingPlayer?.stop();
    _waitingPlayer = null;
  }

  // 切换麦克风
  void _toggleMute() async {
    if (_agoraService.engine != null && mounted && !_disposed) {
      setState(() {
        _isMuted = !_isMuted;
      });
      await _agoraService.engine!.muteLocalAudioStream(_isMuted);
      logger.debug('🎤 麦克风已${_isMuted ? "关闭" : "开启"}');
    }
  }

  // 切换扬声器
  void _toggleSpeaker() async {
    if (_agoraService.engine != null && mounted && !_disposed) {
      await _agoraService.engine!.setEnableSpeakerphone(!_isSpeakerOn);
      setState(() {
        _isSpeakerOn = !_isSpeakerOn;
      });
    }
  }

  // 切换摄像头
  void _toggleCamera() async {
    if (_agoraService.engine != null && mounted && !_disposed) {
      // muteLocalVideoStream(true) = 关闭视频，muteLocalVideoStream(false) = 开启视频
      // 当前 _isCameraOn=true 时，调用 mute(true) 关闭视频
      // 当前 _isCameraOn=false 时，调用 mute(false) 开启视频
      logger.debug('📹 [群组视频] 切换摄像头: 当前状态=$_isCameraOn, 调用mute($_isCameraOn)');
      await _agoraService.engine!.muteLocalVideoStream(_isCameraOn);
      setState(() {
        _isCameraOn = !_isCameraOn;
      });
      logger.debug('📹 [群组视频] 摄像头已${_isCameraOn ? "开启" : "关闭"}');
    }
  }

  // 显示麦克风弹窗
  void _showMicrophonePopup() {
    _popupCloseTimer?.cancel();
    if (!_showMicPopup && mounted) {
      setState(() {
        _showMicPopup = true;
      });
      // 如果设备列表为空，尝试重新加载
      if (_microphoneDevices.isEmpty) {
        _loadMicrophoneDevices();
      }
    }
  }

  // 显示扬声器弹窗
  void _showSpeakerTestPopup() {
    _popupCloseTimer?.cancel();
    if (!_showSpeakerPopup && mounted) {
      setState(() {
        _showSpeakerPopup = true;
      });
      // 如果设备列表为空，尝试重新加载
      if (_speakerDevices.isEmpty) {
        _loadSpeakerDevices();
      }
      logger.debug('🔊 扬声器弹窗显示');
    }
  }

  // 显示摄像头弹窗
  void _showCameraPopup() {
    _popupCloseTimer?.cancel();
    if (!_isCameraPopupShown && mounted) {
      setState(() {
        _isCameraPopupShown = true;
      });
      // 如果设备列表为空，尝试重新加载
      if (_cameraDevices.isEmpty) {
        _loadCameraDevices();
      }
    }
  }

  // 设置麦克风设备
  Future<void> _setMicrophoneDevice(String deviceId) async {
    try {
      final success = await _agoraService.setRecordingDevice(deviceId);

      if (success && mounted) {
        setState(() {
          _currentMicDeviceId = deviceId;
        });
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 设置麦克风音量
  Future<void> _setMicrophoneVolume(double volume) async {
    setState(() {
      _micVolume = volume;
    });
    try {
      final volumeInt = volume.toInt();
      if (_agoraService.engine != null) {
        await _agoraService.engine!.adjustRecordingSignalVolume(volumeInt);
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 设置扬声器设备
  Future<void> _setSpeakerDevice(String deviceId) async {
    try {
      final success = await _agoraService.setPlaybackDevice(deviceId);

      if (success && mounted) {
        setState(() {
          _currentSpeakerDeviceId = deviceId;
        });
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 设置扬声器音量
  Future<void> _setSpeakerVolume(double volume) async {
    setState(() {
      _speakerVolume = volume;
    });
    try {
      final volumeInt = volume.toInt();
      if (_agoraService.engine != null) {
        await _agoraService.engine!.adjustPlaybackSignalVolume(volumeInt);
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 设置摄像头设备
  Future<void> _setCameraDevice(String deviceId) async {
    try {
      if (_agoraService.engine != null) {
        // 🔴 优化：先停止视频预览，添加超时保护
        await _agoraService.engine!
            .stopPreview()
            .timeout(
              const Duration(milliseconds: 800),
              onTimeout: () {
                // 超时后强制继续
              },
            )
            .catchError((e) {
              // 静默处理错误
            });
        await Future.delayed(const Duration(milliseconds: 100));

        // 切换摄像头设备
        final deviceManager = _agoraService.engine!.getVideoDeviceManager();
        await deviceManager.setDevice(deviceId);

        // 更新当前设备ID
        if (mounted) {
          setState(() {
            _currentCameraDeviceId = deviceId;
          });
        }

        // 重新开启预览（如果摄像头是开启状态）
        if (_isCameraOn) {
          await _agoraService.engine!.startPreview();
        }
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 🔴 新增：同步已连接成员列表
  // 当成员接听成功后，从 Agora 的 remoteUids 同步已连接成员
  // 移除那些实际上已经不在通话中的成员
  void _syncConnectedMembers() {
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    if (!isGroupCall) return;

    logger.debug('📹 [同步成员] 开始同步已连接成员列表');
    logger.debug('📹 [同步成员] 当前页面显示的已连接成员: $_connectedMemberIds');
    logger.debug('📹 [同步成员] Agora remoteUids: ${_agoraService.remoteUids}');

    // 获取 Agora 中实际在线的远程用户
    final actualRemoteUids = _agoraService.remoteUids;

    // 找出需要移除的成员（在页面显示中但不在 Agora 中）
    final membersToRemove = <int>[];
    for (final memberId in _connectedMemberIds) {
      // 跳过自己（自己不在 remoteUids 中，但应该保留）
      if (memberId == widget.currentUserId) continue;
      
      if (!actualRemoteUids.contains(memberId)) {
        membersToRemove.add(memberId);
        logger.debug('📹 [同步成员] 成员 $memberId 不在 Agora 中，需要移除');
      }
    }

    // 移除不在通话中的成员
    if (membersToRemove.isNotEmpty) {
      setState(() {
        for (final memberId in membersToRemove) {
          _connectedMemberIds.remove(memberId);
          _remoteVideoViews.remove(memberId);
          
          // 从显示列表中也移除
          final userIndex = _currentGroupCallUserIds.indexOf(memberId);
          if (userIndex != -1) {
            _currentGroupCallUserIds.removeAt(userIndex);
            if (userIndex < _currentGroupCallDisplayNames.length) {
              _currentGroupCallDisplayNames.removeAt(userIndex);
            }
            logger.debug('📹 [同步成员] 已从显示列表移除成员: $memberId');
          }
        }
        _statusText = '通话中 (${_connectedMemberIds.length}人)';
      });
      logger.debug('📹 [同步成员] 同步完成，移除了 ${membersToRemove.length} 个成员');
    } else {
      logger.debug('📹 [同步成员] 同步完成，无需移除成员');
    }

    // 同时添加 Agora 中存在但页面未显示的成员
    for (final uid in actualRemoteUids) {
      if (!_connectedMemberIds.contains(uid)) {
        _connectedMemberIds.add(uid);
        _createRemoteVideoView(uid);
        logger.debug('📹 [同步成员] 添加 Agora 中存在的成员: $uid');
      }
    }

    logger.debug('📹 [同步成员] 最终已连接成员: $_connectedMemberIds');
  }

  // 挂断通话
  void _hangUp() async {
    // 立即显示"正在退出..."
    setState(() {
      _exitStatusText = '正在退出...';
    });

    // 🔴 优化：群组视频通话中挂断只离开自己，不结束整个通话
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    int callDuration = 0;
    bool isCallEnded = false;
    
    if (isGroupCall) {
      logger.debug('📹 群组视频通话挂断，只离开自己');
      final result = await _agoraService.leaveGroupCallOnly();
      callDuration = result['callDuration'] as int? ?? 0;
      isCallEnded = result['isCallEnded'] == true;
      logger.debug('📹 群组视频通话挂断完成，callDuration: $callDuration, isCallEnded: $isCallEnded');
    } else {
      // 单人通话：计算通话时长并结束通话
      if (_agoraService.callStartTime != null) {
        final elapsed = DateTime.now().difference(_agoraService.callStartTime!);
        callDuration = elapsed.inSeconds;
      }
      await _endCall();
    }

    if (mounted) {
      // 🔴 修复：返回完整的通话结束信息，包括时长和类型
      final result = {
        'callEnded': true,
        'callDuration': callDuration,
        'callType': CallType.video,
        'isCallEnded': isCallEnded, // 是否是最后一个成员离开
      };
      Navigator.of(context).pop(result);
    }
  }

  // 拒绝来电
  Future<void> _rejectCall() async {
    if (_isClosing) return; // 避免重复调用
    _isClosing = true; // 立即标记，防止状态变化回调重复处理

    // 停止等待音效
    _stopWaitingSound();

    // 🔴 优化：群组视频通话中拒绝只离开自己，不结束整个通话
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    if (isGroupCall) {
      logger.debug('📹 群组视频通话拒接，只离开自己');
      final result = await _agoraService.leaveGroupCallOnly();
      final isCallEnded = result['isCallEnded'] == true;
      logger.debug('📹 群组视频通话拒接完成，isCallEnded: $isCallEnded');
    } else {
      // 单人通话：拒绝通话
      await _agoraService.rejectCall();
    }

    // 返回拒绝状态
    if (mounted) {
      final result = {'callRejected': true};
      Navigator.of(context).pop(result);
    }
  }

  // 接听来电
  Future<void> _acceptCall() async {
    try {
      // 停止等待音效
      _stopWaitingSound();

      // 🔴 关键修复：对于群组视频通话，需要先初始化AgoraService
      if (widget.currentUserId != null) {
        await _agoraService.initialize(widget.currentUserId!);
      }

      // 接听通话
      await _agoraService.acceptCall();

      // 更新状态
      if (mounted) {
        setState(() {
          _callState = CallState.connected;
          // 接听方添加自己到已连接成员列表（如果还没有的话）
          if (widget.currentUserId != null &&
              !_connectedMemberIds.contains(widget.currentUserId!)) {
            _connectedMemberIds.add(widget.currentUserId!);
          }
          _statusText = '通话中 (${_connectedMemberIds.length}人)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _callState = CallState.ended;
          _statusText = '接听失败';
        });
      }
    }
  }

  // 初始化所有设备
  Future<void> _initializeDevices() async {
    // 加载麦克风设备
    await _loadMicrophoneDevices();

    // 加载扬声器设备
    await _loadSpeakerDevices();

    // 加载摄像头设备
    await _loadCameraDevices();
  }

  // 加载麦克风设备列表
  Future<void> _loadMicrophoneDevices() async {
    try {
      if (_agoraService.engine != null) {
        final devices = await _agoraService.engine!
            .getAudioDeviceManager()
            .enumerateRecordingDevices();

        if (mounted && !_disposed) {
          setState(() {
            _microphoneDevices = devices;
            if (devices.isNotEmpty && devices[0].deviceId != null) {
              _currentMicDeviceId = devices[0].deviceId;
            }
          });
        }
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 加载扬声器设备列表
  Future<void> _loadSpeakerDevices() async {
    try {
      if (_agoraService.engine != null) {
        final devices = await _agoraService.engine!
            .getAudioDeviceManager()
            .enumeratePlaybackDevices();

        if (mounted && !_disposed) {
          setState(() {
            _speakerDevices = devices;
            if (devices.isNotEmpty && devices[0].deviceId != null) {
              _currentSpeakerDeviceId = devices[0].deviceId;
            }
          });
        }
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  // 加载摄像头设备列表
  Future<void> _loadCameraDevices() async {
    try {
      if (_agoraService.engine != null) {
        final devices = await _agoraService.engine!
            .getVideoDeviceManager()
            .enumerateVideoDevices();

        if (mounted && !_disposed) {
          setState(() {
            _cameraDevices = devices;
            if (devices.isNotEmpty && devices[0].deviceId != null) {
              _currentCameraDeviceId = devices[0].deviceId;
            }
          });
        }
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // 禁止直接返回
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        // 用户尝试返回时，关闭通话页面但不挂断通话
        if (!_isClosing && _callState != CallState.ended) {
          // 🔴 优化：异步停止视频预览，不阻塞UI
          // 原因：stopPreview 可能耗时很长（6-16秒），会导致UI卡顿
          // 解决：使用 unawaited 异步执行，添加超时保护
          if (_agoraService.engine != null) {
            _agoraService.engine!
                .stopPreview()
                .timeout(
                  const Duration(milliseconds: 500),
                  onTimeout: () {
                    // 超时后强制继续，不影响后续流程
                  },
                )
                .catchError((e) {
                  // 静默处理错误
                });
          }

          // 🔴 新方案：在 AgoraService 中设置全局标识
          final isGroupCall =
              widget.groupCallUserIds != null &&
              widget.groupCallUserIds!.isNotEmpty;

          _agoraService.setCallMinimized(
            isMinimized: true,
            callUserId: widget.targetUserId,
            callDisplayName: widget.targetDisplayName,
            callType: CallType.video,
            isGroupCall: isGroupCall,
            groupId: widget.groupId,
            groupCallUserIds: isGroupCall ? widget.groupCallUserIds : null,
            groupCallDisplayNames: isGroupCall
                ? widget.groupCallDisplayNames
                : null,
            connectedMemberIds: _connectedMemberIds, // 🔴 新增：保存已连接成员ID集合
          );

          if (mounted) {
            // 🔴 修复：群组通话不显示悬浮按钮，因为群聊对话框中已有"加入通话"按钮
            if (isGroupCall) {
              logger.debug('📹 群组视频通话不显示悬浮按钮，直接返回');
              Navigator.of(context).pop(); // 不返回 showFloatingButton
            } else {
              Navigator.of(context).pop({'showFloatingButton': true}); // 单人通话显示悬浮按钮
            }
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF2C3E50),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildTopBar(),
                  Expanded(child: _buildMainContent()),
                  _buildControlButtons(),
                  const SizedBox(height: 60),
                ],
              ),

              // 透明背景遮罩（点击关闭弹窗）
              if (_showMicPopup || _isCameraPopupShown || _showSpeakerPopup)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _showMicPopup = false;
                        _isCameraPopupShown = false;
                        _showSpeakerPopup = false;
                      });
                    },
                    child: Container(color: Colors.transparent),
                  ),
                ),

              // 麦克风设置弹窗
              if (_showMicPopup) _buildMicrophonePopup(),

              // 摄像头设置弹窗
              if (_isCameraPopupShown) _buildCameraPopup(),

              // 扬声器设置弹窗
              if (_showSpeakerPopup) _buildSpeakerPopup(),
            ],
          ),
        ),
      ),
    );
  }

  // 构建主要内容
  Widget _buildMainContent() {
    // 群组视频通话始终使用群组样式
    return _buildGroupVideoCallContent();
  }

  // 构建群组视频通话内容
  Widget _buildGroupVideoCallContent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 状态文本 - 使用 CallDurationWidget
        if (_callState == CallState.connected)
          CallDurationWidget(
            initialDuration: _callDuration,
            isConnected: _callState == CallState.connected,
            overrideText: _exitStatusText,
            style: const TextStyle(fontSize: 16, color: Colors.white70),
          )
        else
          Text(
            _statusText,
            style: const TextStyle(fontSize: 16, color: Colors.white70),
          ),

        const SizedBox(height: 40),

        // 群组成员水平滚动区域（带左右箭头）- 显示视频 feeds
        _buildGroupMembersVideoScrollView(),

        const SizedBox(height: 40),
      ],
    );
  }

  // 构建群组成员水平滚动视图（带左右箭头按钮）- 显示视频 feeds
  Widget _buildGroupMembersVideoScrollView() {
    final memberCount = _currentGroupCallUserIds.length;
    // 总项目数包括成员数量 + 1个"+"按钮
    final totalItemCount = memberCount + 1;

    // 根据平台选择不同的尺寸（容器和箭头）
    final isMobile = ResponsiveHelper.isMobile(context);
    final horizontalPadding = isMobile ? 10.0 : 40.0;
    final arrowWidth = isMobile ? 60.0 : 100.0;
    final arrowSize = isMobile ? 28.0 : 32.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: SizedBox(
        height: isMobile ? 400.0 : 260.0,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 计算每个成员的宽度：视频120 + 左右padding 32 = 152
            const memberItemWidth = 152.0;

            // 计算成员列表的总宽度（包括首尾额外的padding和"+"按钮）
            final totalMembersWidth = totalItemCount * memberItemWidth + 40;

            // 判断是否需要显示箭头：内容宽度超过可用宽度
            final needArrows = totalMembersWidth > constraints.maxWidth;

            // 计算中心区域宽度
            final centerWidth = needArrows
                ? constraints.maxWidth - (2 * arrowWidth)
                : constraints.maxWidth;

            return Row(
              children: [
                // 左箭头按钮区域（只在需要时显示）
                if (needArrows)
                  SizedBox(
                    width: arrowWidth,
                    child: Center(
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios,
                          color: Colors.white,
                          size: arrowSize,
                        ),
                        onPressed: () {
                          // 向右滚动（查看左边隐藏的成员）
                          _groupMembersScrollController.animateTo(
                            _groupMembersScrollController.offset - 200,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        },
                      ),
                    ),
                  ),

                // 中间的成员列表区域（居中对齐）
                SizedBox(
                  width: centerWidth,
                  child: Center(
                    child: needArrows
                        ? SingleChildScrollView(
                            controller: _groupMembersScrollController,
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: _buildVideoMemberList(memberCount),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: _buildVideoMemberList(memberCount),
                          ),
                  ),
                ),

                // 右箭头按钮区域（只在需要时显示）
                if (needArrows)
                  SizedBox(
                    width: arrowWidth,
                    child: Center(
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_forward_ios,
                          color: Colors.white,
                          size: arrowSize,
                        ),
                        onPressed: () {
                          // 向左滚动（查看右边隐藏的成员）
                          _groupMembersScrollController.animateTo(
                            _groupMembersScrollController.offset + 200,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // 构建视频成员列表
  List<Widget> _buildVideoMemberList(int memberCount) {
    List<Widget> memberWidgets = List.generate(memberCount, (index) {
      final userId = _currentGroupCallUserIds[index];
      final displayName = index < _currentGroupCallDisplayNames.length
          ? _currentGroupCallDisplayNames[index]
          : 'User $userId';

      return Padding(
        padding: EdgeInsets.only(
          left: index == 0 ? 20 : 16,
          right: index == memberCount - 1 ? 20 : 16,
          top: 20,
          bottom: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 视频容器
            Container(
              width: 120,
              height: 145,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _buildMemberVideoWidget(userId, displayName),
              ),
            ),
            const SizedBox(height: 12),
            // 名称
            Text(
              _truncateDisplayName(displayName),
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            // 状态（根据实际连接状态显示）
            Text(
              _connectedMemberIds.contains(userId) ? '已连接' : '正在呼叫...',
              style: TextStyle(
                fontSize: 12,
                color: _connectedMemberIds.contains(userId)
                    ? Colors.greenAccent
                    : Colors.white70,
                fontWeight: _connectedMemberIds.contains(userId)
                    ? FontWeight.w500
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      );
    });

    // 添加"+"按钮到成员列表最后（仅群主和管理员可以邀请成员）
    if (widget.memberRole == 'owner' || widget.memberRole == 'admin') {
      memberWidgets.add(_buildAddMemberButton());
    }

    return memberWidgets;
  }

  // 构建成员视频 Widget
  Widget _buildMemberVideoWidget(int userId, String displayName) {
    // 如果是当前用户，显示本地视频
    if (widget.currentUserId != null && userId == widget.currentUserId) {
      // 🔴 修复：根据摄像头状态决定显示视频还是占位符
      if (_localVideoView != null && _isCameraOn) {
        return GestureDetector(
          onTap: () => _showFullscreenVideo(
            memberName: displayName,
            userId: userId,
            isLocalVideo: true,
          ),
          child: _localVideoView!,
        );
      } else {
        // 摄像头关闭或视频视图未创建时显示占位符
        return Container(
          color: Colors.black,
          child: const Center(
            child: Icon(Icons.videocam_off, size: 32, color: Colors.white54),
          ),
        );
      }
    }

    // 如果是远程用户，显示远程视频
    if (_remoteVideoViews.containsKey(userId)) {
      // 🔴 新增：检查远程用户是否关闭了摄像头
      final isRemoteMuted = _remoteVideoMuted[userId] ?? false;
      if (isRemoteMuted) {
        // 远程用户关闭了摄像头，显示占位符
        return Container(
          color: Colors.black,
          child: const Center(
            child: Icon(Icons.videocam_off, size: 32, color: Colors.white54),
          ),
        );
      }
      return GestureDetector(
        onTap: () => _showFullscreenVideo(
          memberName: displayName,
          userId: userId,
          isLocalVideo: false,
        ),
        child: _remoteVideoViews[userId]!,
      );
    } else {
      // 显示占位符
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Center(
                  child: Text(
                    () {
                      final truncatedName = _truncateDisplayName(displayName);
                      return truncatedName.length >= 2
                          ? truncatedName.substring(truncatedName.length - 2)
                          : truncatedName;
                    }(),
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '等待连接...',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
  }

  // 构建添加成员按钮
  Widget _buildAddMemberButton() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 20, top: 20, bottom: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // "+"按钮
          GestureDetector(
            onTap: _showAddMemberDialog,
            child: Container(
              width: 120,
              height: 145,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: const Center(
                child: Icon(Icons.add, size: 32, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 标签
          const Text(
            '邀请成员',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontWeight: FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          // 状态文本
          const Text(
            '点击添加',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  // 显示添加成员对话框
  Future<void> _showAddMemberDialog() async {
    try {
      logger.debug('📹 [邀请成员] 开始显示添加成员对话框');
      logger.debug('📹 [邀请成员] widget.groupId = ${widget.groupId}');

      // 获取用户token
      final userToken = await _getUserToken();
      if (userToken == null) {
        logger.debug('📹 [邀请成员] ❌ 用户token为空');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('用户未登录'), backgroundColor: Colors.red),
          );
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

      List<Map<String, dynamic>> availableMembers = [];

      // 🔴 修复：首先尝试通过群组ID获取群组成员
      if (widget.groupId != null) {
        logger.debug('📹 [邀请成员] 尝试通过群组ID获取成员: ${widget.groupId}');
        try {
          final response = await ApiService.getGroupDetail(
            token: userToken,
            groupId: widget.groupId!,
          );

          logger.debug(
            '📹 [邀请成员] API响应: code=${response['code']}, hasData=${response['data'] != null}',
          );

          if (response['code'] == 0 && response['data'] != null) {
            final membersData = response['data']['members'] as List?;
            logger.debug('📹 [邀请成员] 成员数据: ${membersData?.length ?? 0} 个成员');

            if (membersData != null && membersData.isNotEmpty) {
              // 转换群组成员数据
              availableMembers = membersData
                  .map(
                    (member) => {
                      'user_id': member['user_id'] as int,
                      'username': member['username'] as String? ?? 'unknown',
                      'full_name': member['full_name'] as String?,
                    },
                  )
                  .toList();
              logger.debug('📹 [邀请成员] ✅ 成功获取 ${availableMembers.length} 个群组成员');
            }
          } else {
            logger.debug(
              '📹 [邀请成员] ⚠️ API返回错误: ${response['message'] ?? '未知错误'}',
            );
          }
        } catch (e, stackTrace) {
          logger.error('📹 [邀请成员] ❌ 获取群组成员失败: $e');
          logger.error('📹 [邀请成员] 堆栈: $stackTrace');
        }
      } else {
        logger.debug('📹 [邀请成员] ⚠️ widget.groupId 为 null，跳过群组成员获取');
      }

      // 🔴 修复：如果群组成员获取失败，使用联系人列表作为备选方案
      if (availableMembers.isEmpty) {
        logger.debug('📹 [邀请成员] 群组成员为空，尝试使用联系人列表');
        try {
          final contactsResponse = await ApiService.getContacts(
            token: userToken,
          );
          final contacts =
              contactsResponse['data']['contacts'] as List<dynamic>;

          logger.debug('📹 [邀请成员] 联系人数量: ${contacts.length}');

          // 过滤出用户类型的联系人
          availableMembers = contacts
              .where((contact) => contact['type'] == 'user')
              .map(
                (contact) => {
                  'user_id': contact['user_id'] as int,
                  'username': contact['username'] as String,
                  'full_name': contact['full_name'] as String?,
                },
              )
              .toList();
          logger.debug('📹 [邀请成员] ✅ 成功获取 ${availableMembers.length} 个联系人');
        } catch (e, stackTrace) {
          logger.error('📹 [邀请成员] ❌ 获取联系人失败: $e');
          logger.error('📹 [邀请成员] 堆栈: $stackTrace');
        }
      }

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      logger.debug('📹 [邀请成员] 最终可用成员数量: ${availableMembers.length}');

      if (availableMembers.isEmpty) {
        logger.debug('📹 [邀请成员] ❌ 没有可邀请的成员');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('暂无可邀请的群组成员'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) return;

      // 显示选择成员对话框（不提前过滤，让对话框内部处理）
      final selectedUserIds = await showDialog<List<int>>(
        context: context,
        builder: (BuildContext context) {
          return _buildAddMemberDialog(availableMembers);
        },
      );

      // 处理选中的成员
      if (selectedUserIds != null && selectedUserIds.isNotEmpty) {
        _inviteMembers(selectedUserIds.toSet());
      }
    } catch (e) {
      // 关闭可能打开的加载对话框
      if (mounted) {
        try {
          Navigator.of(context).pop();
        } catch (_) {}

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取成员列表失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 🔴 修复：获取用户token，使用 Storage 类
  Future<String?> _getUserToken() async {
    try {
      return await Storage.getToken();
    } catch (e) {
      return null;
    }
  }

  // 🔴 修复：构建添加成员对话框，使用StatefulBuilder来管理选中状态
  Widget _buildAddMemberDialog(List<Map<String, dynamic>> members) {
    // 转换联系人数据为统一格式
    final allMembers = members.map((member) {
      final userId = member['user_id'] as int;
      final username = member['username'] as String? ?? 'unknown';
      final fullName = member['full_name'] as String?;
      final displayName = fullName?.isNotEmpty == true ? fullName! : username;
      final avatarText = displayName.length >= 2
          ? displayName.substring(displayName.length - 2)
          : displayName;
      return {
        'userId': userId,
        'username': username,
        'fullName': displayName,
        'displayName': displayName,
        'avatarText': avatarText,
      };
    }).toList();

    // 分离当前通话成员和其他成员
    final currentCallMembers = allMembers
        .where((member) => _currentGroupCallUserIds.contains(member['userId']))
        .toList();
    final availableMembers = allMembers
        .where((member) => !_currentGroupCallUserIds.contains(member['userId']))
        .toList();

    // 根据设备类型选择不同的对话框
    final isMobile = ResponsiveHelper.isMobile(context);

    if (isMobile) {
      // 移动端：使用垂直布局的对话框
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.75,
          child: MobileAddCallMemberDialog(
            availableMembers: availableMembers,
            currentCallMembers: currentCallMembers,
          ),
        ),
      );
    }

    // PC端：使用简单的AlertDialog
    final selectedMemberIds = <int>{};

    return StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: const Text('邀请成员加入通话'),
          content: SizedBox(
            width: 300,
            height: 400,
            child: availableMembers.isEmpty
                ? const Center(
                    child: Text(
                      '暂无可邀请成员',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: availableMembers.length,
                    itemBuilder: (context, index) {
                      final member = availableMembers[index];
                      final userId = member['userId'] as int;
                      final username = member['username'] as String;
                      final displayName = member['fullName'] as String;

                      final isSelected = selectedMemberIds.contains(userId);

                      return CheckboxListTile(
                        title: Text(displayName),
                        subtitle: Text('@$username'),
                        value: isSelected,
                        onChanged: (bool? value) {
                          setState(() {
                            if (value == true) {
                              selectedMemberIds.add(userId);
                            } else {
                              selectedMemberIds.remove(userId);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: selectedMemberIds.isEmpty
                  ? null
                  : () {
                      Navigator.of(context).pop(selectedMemberIds.toList());
                    },
              child: const Text('邀请'),
            ),
          ],
        );
      },
    );
  }

  // 🔴 修复：邀请成员加入现有的群组通话
  Future<void> _inviteMembers(Set<int> selectedUserIds) async {
    try {
      final userToken = await _getUserToken();
      if (userToken == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('用户未登录'), backgroundColor: Colors.red),
          );
        }
        return;
      }

      // 过滤出新成员（排除已在通话中的成员）
      final newMemberIds = selectedUserIds
          .where((id) => !_currentGroupCallUserIds.contains(id))
          .toList();

      if (newMemberIds.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('没有新成员需要邀请'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // 获取当前通话的频道名称
      final currentChannelName = _agoraService.currentChannelName;
      if (currentChannelName == null || currentChannelName.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('无法获取当前通话信息，请重试'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 🔴 修复：调用正确的API - inviteToGroupCall（邀请加入现有通话）
      final response = await ApiService.inviteToGroupCall(
        token: userToken,
        channelName: currentChannelName,
        calleeIds: newMemberIds,
        callType: 'video',
      );

      // 🔴 修复：不立即添加到本地列表，等待成员接听后再添加
      // 成员接听后会通过 onGroupCallMemberStatusChanged 回调自动添加

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已向 ${newMemberIds.length} 个成员发送视频通话邀请'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('邀请失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 构建顶部栏
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              // 点击返回按钮时，关闭通话页面但不挂断通话
              if (!_isClosing && _callState != CallState.ended) {
                // 🔴 优化：异步停止视频预览，不阻塞UI
                // 原因：stopPreview 可能耗时很长（6-16秒），会导致UI卡顿
                // 解决：使用异步执行，添加超时保护
                if (_agoraService.engine != null) {
                  _agoraService.engine!
                      .stopPreview()
                      .timeout(
                        const Duration(milliseconds: 500),
                        onTimeout: () {
                          // 超时后强制继续，不影响后续流程
                        },
                      )
                      .catchError((e) {
                        // 静默处理错误
                      });
                }

                // 🔴 新方案：在 AgoraService 中设置全局标识
                final isGroupCall =
                    widget.groupCallUserIds != null &&
                    widget.groupCallUserIds!.isNotEmpty;

                _agoraService.setCallMinimized(
                  isMinimized: true,
                  callUserId: widget.targetUserId,
                  callDisplayName: widget.targetDisplayName,
                  callType: CallType.video,
                  isGroupCall: isGroupCall,
                  groupId: widget.groupId,
                  groupCallUserIds:
                      isGroupCall && widget.groupCallUserIds != null
                      ? widget.groupCallUserIds
                      : null,
                  groupCallDisplayNames:
                      isGroupCall && widget.groupCallDisplayNames != null
                      ? widget.groupCallDisplayNames
                      : null,
                  connectedMemberIds: _connectedMemberIds, // 🔴 新增：保存已连接成员ID集合
                );

                // 🔴 修复：群组通话不显示悬浮按钮，因为群聊对话框中已有"加入通话"按钮
                logger.debug('📹 群组视频通话不显示悬浮按钮，直接返回');
                Navigator.of(context).pop(); // 不返回 showFloatingButton
              }
            },
            tooltip: '返回',
          ),
          Text(
            '群组视频通话',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          // 成员数量
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${_currentGroupCallUserIds.length} 人',
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建控制按钮
  Widget _buildControlButtons() {
    if (_callState == CallState.ringing && widget.isIncoming) {
      // 来电时显示接听和拒接按钮
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 拒接按钮
            GestureDetector(
              onTap: () {
                logger.debug('📹 用户点击拒接按钮');
                _rejectCall();
              },
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.call_end,
                  size: 28,
                  color: Colors.white,
                ),
              ),
            ),
            // 接听按钮
            GestureDetector(
              onTap: () {
                logger.debug('📹 用户点击接听按钮');
                _acceptCall();
              },
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: const Icon(Icons.call, size: 28, color: Colors.white),
              ),
            ),
          ],
        ),
      );
    } else {
      // 通话中显示控制按钮（使用带hover功能的新方法）
      return _buildBottomControls();
    }
  }

  // 构建主视频视图
  Widget _buildMainVideoView() {
    if (_remoteVideoViews.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _remoteVideoViews.values.first,
      );
    } else {
      // 显示占位符
      return Container(
        color: Colors.black,
        child: const Center(
          child: Icon(Icons.videocam_off, size: 64, color: Colors.white54),
        ),
      );
    }
  }

  // 构建成员视频网格
  Widget _buildMemberVideoGrid() {
    final allMembers = <Widget>[];

    // 添加本地视频
    if (_localVideoView != null) {
      allMembers.add(
        Container(
          margin: const EdgeInsets.only(right: 8),
          child: _buildMemberVideoItem(
            // 🔴 修复：根据摄像头状态决定显示视频还是占位符
            videoView: _isCameraOn
                ? _localVideoView!
                : Container(
                    color: Colors.black,
                    child: const Center(
                      child: Icon(Icons.videocam_off, size: 32, color: Colors.white54),
                    ),
                  ),
            displayName: '我',
            isLocal: true,
          ),
        ),
      );
    }

    // 添加远程视频
    for (final entry in _remoteVideoViews.entries) {
      final userId = entry.key;
      final videoView = entry.value;
      final displayName = _getMemberDisplayName(userId);

      allMembers.add(
        Container(
          margin: const EdgeInsets.only(right: 8),
          child: _buildMemberVideoItem(
            videoView: videoView,
            displayName: displayName,
            isLocal: false,
          ),
        ),
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      controller: _groupMembersScrollController,
      itemCount: allMembers.length,
      itemBuilder: (context, index) {
        return allMembers[index];
      },
    );
  }

  // 构建成员视频项
  Widget _buildMemberVideoItem({
    required Widget videoView,
    required String displayName,
    required bool isLocal,
  }) {
    return Container(
      width: 120,
      height: 145,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLocal
              ? Colors.green.withOpacity(0.5)
              : Colors.white.withOpacity(0.3),
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // 使用FittedBox确保视频视图正确适配
            Positioned.fill(
              child: FittedBox(fit: BoxFit.cover, child: videoView),
            ),

            // 显示名称标签
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                  ),
                ),
                child: Text(
                  _truncateDisplayName(displayName),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 获取成员显示名称
  String _getMemberDisplayName(int userId) {
    final index = _currentGroupCallUserIds.indexOf(userId);
    if (index != -1 && index < _currentGroupCallDisplayNames.length) {
      return _currentGroupCallDisplayNames[index];
    }
    return '用户$userId';
  }

  // 构建顶部状态栏（已弃用，现在使用CallDurationWidget）
  Widget _buildTopStatusBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.only(top: 40, left: 20, right: 20),
        child: Column(
          children: [
            // 通话状态
            Text(
              _statusText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // 构建底部控制栏（返回普通widget，用于Column）
  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 麦克风按钮（带hover弹窗）
          _buildControlButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            backgroundColor: _isMuted
                ? Colors.red.withOpacity(0.8)
                : Colors.white.withOpacity(0.2),
            onPressed: _toggleMute,
            onHover: () => _showMicrophonePopup(),
          ),

          // 摄像头按钮（带hover弹窗）
          _buildControlButton(
            icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
            backgroundColor: _isCameraOn
                ? Colors.white.withOpacity(0.2)
                : Colors.red.withOpacity(0.8),
            onPressed: _toggleCamera,
            onHover: () => _showCameraPopup(),
          ),

          // 扬声器按钮（带hover弹窗）
          _buildControlButton(
            icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
            backgroundColor: _isSpeakerOn
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.2),
            onPressed: _toggleSpeaker,
            onHover: () => _showSpeakerTestPopup(),
          ),

          // 挂断按钮（不需要弹窗）
          _buildControlButton(
            icon: Icons.call_end,
            backgroundColor: Colors.red,
            onPressed: _hangUp,
          ),
        ],
      ),
    );
  }

  // 构建控制按钮
  Widget _buildControlButton({
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onPressed,
    VoidCallback? onHover,
  }) {
    Widget button = GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
        ),
        child: Icon(icon, size: 32, color: Colors.white),
      ),
    );

    // 如果提供了onHover回调，包装MouseRegion
    if (onHover != null) {
      button = MouseRegion(onEnter: (_) => onHover(), child: button);
    }

    return button;
  }

  // 构建麦克风弹窗
  Widget _buildMicrophonePopup() {
    return Builder(
      builder: (context) {
        // 计算麦克风按钮的位置（第一个按钮）
        final screenWidth = MediaQuery.of(context).size.width;
        final estimatedButtonWidth = 80.0;
        final totalButtonsWidth = estimatedButtonWidth * 4; // 4个按钮
        final spaceWidth = (screenWidth - totalButtonsWidth) / 5;
        final buttonCenterX = spaceWidth + estimatedButtonWidth / 2;
        final popupLeft = buttonCenterX - 140;

        return Positioned(
          bottom: 120,
          left: popupLeft.clamp(10.0, screenWidth - 290),
          child: GestureDetector(
            onTap: () {}, // 拦截点击事件，防止穿透到背景遮罩
            child: MouseRegion(
              onExit: (_) {
                setState(() {
                  _showMicPopup = false;
                });
              },
              child: Material(
                color: Colors.transparent,
                elevation: 8,
                child: Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 选择麦克风标题
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '选择麦克风',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // 麦克风列表
                      if (_microphoneDevices.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              children: _microphoneDevices.map((device) {
                                final isSelected =
                                    device.deviceId == _currentMicDeviceId;
                                return InkWell(
                                  onTap: () {
                                    if (device.deviceId != null) {
                                      _setMicrophoneDevice(device.deviceId!);
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    color: isSelected
                                        ? const Color(0xFF525252)
                                        : Colors.transparent,
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            device.deviceName ?? '未知设备',
                                            style: TextStyle(
                                              color: isSelected
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontSize: 13,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            '未找到麦克风设备',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),

                      // 关闭/打开麦克风按钮
                      InkWell(
                        onTap: _toggleMute,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: Color(0xFF606060),
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _isMuted ? Icons.mic : Icons.mic_off,
                                color: Colors.white70,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _isMuted ? '打开麦克风' : '关闭麦克风',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 分隔线
                      const Divider(
                        color: Color(0xFF606060),
                        height: 1,
                        thickness: 1,
                      ),

                      // 音量标题
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '音量',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // 音量滑块
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.volume_down,
                              color: Colors.white70,
                              size: 20,
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: const SliderThemeData(
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Color(0xFF666666),
                                  thumbColor: Colors.white,
                                  overlayColor: Color(0x33FFFFFF),
                                  trackHeight: 3,
                                ),
                                child: Slider(
                                  value: _micVolume,
                                  min: 0,
                                  max: 100,
                                  onChanged: (value) =>
                                      _setMicrophoneVolume(value),
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.volume_up,
                              color: Colors.white70,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${_micVolume.toInt()}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // 构建摄像头弹窗
  Widget _buildCameraPopup() {
    return Builder(
      builder: (context) {
        // 计算摄像头按钮的位置（第二个按钮）
        final screenWidth = MediaQuery.of(context).size.width;
        final estimatedButtonWidth = 80.0;
        final totalButtonsWidth = estimatedButtonWidth * 4;
        final spaceWidth = (screenWidth - totalButtonsWidth) / 5;
        final buttonCenterX = spaceWidth * 2 + estimatedButtonWidth * 1.5;
        final popupLeft = buttonCenterX - 140;

        return Positioned(
          bottom: 120,
          left: popupLeft.clamp(10.0, screenWidth - 290),
          child: GestureDetector(
            onTap: () {}, // 拦截点击事件，防止穿透到背景遮罩
            child: MouseRegion(
              onExit: (_) {
                setState(() {
                  _isCameraPopupShown = false;
                });
              },
              child: Material(
                color: Colors.transparent,
                elevation: 8,
                child: Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 选择摄像头标题
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '选择摄像头',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // 摄像头列表
                      if (_cameraDevices.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              children: _cameraDevices.map((device) {
                                final isSelected =
                                    device.deviceId == _currentCameraDeviceId;
                                return InkWell(
                                  onTap: () {
                                    if (device.deviceId != null) {
                                      _setCameraDevice(device.deviceId!);
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    color: isSelected
                                        ? const Color(0xFF525252)
                                        : Colors.transparent,
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            device.deviceName ?? '未知设备',
                                            style: TextStyle(
                                              color: isSelected
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontSize: 13,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            '未找到摄像头设备',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),

                      // 关闭/打开摄像头按钮
                      InkWell(
                        onTap: _toggleCamera,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: Color(0xFF606060),
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _isCameraOn
                                    ? Icons.videocam_off
                                    : Icons.videocam,
                                color: Colors.white70,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _isCameraOn ? '关闭摄像头' : '打开摄像头',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
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
            ),
          ),
        );
      },
    );
  }

  // 构建扬声器弹窗
  Widget _buildSpeakerPopup() {
    return Builder(
      builder: (context) {
        // 计算扬声器按钮的位置（第三个按钮）
        final screenWidth = MediaQuery.of(context).size.width;
        final estimatedButtonWidth = 80.0;
        final totalButtonsWidth = estimatedButtonWidth * 4;
        final spaceWidth = (screenWidth - totalButtonsWidth) / 5;
        final buttonCenterX = spaceWidth * 3 + estimatedButtonWidth * 2.5;
        final popupLeft = buttonCenterX - 140;

        return Positioned(
          bottom: 120,
          left: popupLeft.clamp(10.0, screenWidth - 290),
          child: GestureDetector(
            onTap: () {}, // 拦截点击事件，防止穿透到背景遮罩
            child: MouseRegion(
              onExit: (_) {
                setState(() {
                  _showSpeakerPopup = false;
                });
              },
              child: Material(
                color: Colors.transparent,
                elevation: 8,
                child: Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 选择扬声器标题
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '选择扬声器',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // 扬声器设备列表
                      if (_speakerDevices.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              children: _speakerDevices.map((device) {
                                final isSelected =
                                    device.deviceId == _currentSpeakerDeviceId;
                                return InkWell(
                                  onTap: () {
                                    if (device.deviceId != null) {
                                      _setSpeakerDevice(device.deviceId!);
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    color: isSelected
                                        ? const Color(0xFF525252)
                                        : Colors.transparent,
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            device.deviceName ?? '未知设备',
                                            style: TextStyle(
                                              color: isSelected
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontSize: 13,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            '未找到扬声器设备',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),

                      // 切换扬声器/听筒按钮
                      InkWell(
                        onTap: _toggleSpeaker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: Color(0xFF606060),
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _isSpeakerOn
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                color: Colors.white70,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _isSpeakerOn ? '切换到听筒' : '切换到扬声器',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 分隔线
                      const Divider(
                        color: Color(0xFF606060),
                        height: 1,
                        thickness: 1,
                      ),

                      // 音量标题
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '音量',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // 音量滑块
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.volume_down,
                              color: Colors.white70,
                              size: 20,
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: const SliderThemeData(
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Color(0xFF666666),
                                  thumbColor: Colors.white,
                                  overlayColor: Color(0x33FFFFFF),
                                  trackHeight: 3,
                                ),
                                child: Slider(
                                  value: _speakerVolume,
                                  min: 0,
                                  max: 100,
                                  onChanged: (value) =>
                                      _setSpeakerVolume(value),
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.volume_up,
                              color: Colors.white70,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${_speakerVolume.toInt()}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 显示全屏视频对话框
  void _showFullscreenVideo({
    required String memberName,
    required int userId,
    required bool isLocalVideo,
  }) {
    logger.debug('📹 [全屏视频] 显示全屏视频 - 成员: $memberName, 用户ID: $userId, 本地视频: $isLocalVideo');
    
    // 获取当前频道ID
    final channelId = _agoraService.currentChannelName;
    logger.debug('📹 [全屏视频] 当前频道ID: $channelId');
    
    // PC端和移动端都支持全屏视频功能
    FullscreenVideoDialog.show(
      context: context,
      memberName: memberName,
      userId: userId,
      isLocalVideo: isLocalVideo,
      channelId: channelId,
      isMobile: ResponsiveHelper.isMobile(context), // 传递是否为移动端
    );
  }
}
