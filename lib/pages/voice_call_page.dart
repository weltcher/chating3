import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/agora_service.dart';
import '../services/api_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import '../utils/responsive_helper.dart';
import '../widgets/mobile_add_call_member_dialog.dart';
import '../widgets/call_duration_widget.dart';

class VoiceCallPage extends StatefulWidget {
  final int targetUserId;
  final String targetDisplayName;
  final bool isIncoming; // 是否是来电
  final CallType callType; // 通话类型
  final String? targetAvatar; // 目标用户头像URL（可选）
  // 群组通话相关参数
  final List<int>? groupCallUserIds; // 群组通话的用户ID列表
  final List<String>? groupCallDisplayNames; // 群组通话的用户显示名列表
  final List<String?>? groupCallAvatarUrls; // 群组通话的用户头像URL列表（可选，与groupCallUserIds对应）
  final int? currentUserId; // 当前用户ID（用于群组通话标识自己）
  final int? groupId; // 群组ID（用于获取群组成员）
  final bool isJoiningExistingCall; // 是否是加入已存在的通话（区分发起新通话和加入已存在通话）
  final String? memberRole; // 当前用户在群组中的角色（owner/admin/member）

  const VoiceCallPage({
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
  State<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends State<VoiceCallPage> {
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
  // 群组通话：成员头像URL列表（与 _currentGroupCallUserIds 对应，可选）
  List<String?> _currentGroupCallAvatarUrls = [];

  // 当前用户头像（用于单人通话小头像和群组通话中“自己”的头像）
  String? _currentUserAvatarUrl;

  // 目标用户头像（单人通话时用于显示对方头像，支持运行时刷新）
  String? _targetAvatarUrl;

  // 视频控制器
  AgoraVideoView? _localVideoView;
  AgoraVideoView? _remoteVideoView;
  bool _isRemoteVideoMuted = false; // 🔴 新增：远程用户视频静音状态
  
  // 视频画面切换状态：true表示远程画面在大框，false表示本地画面在大框
  // 默认本地画面（自己的摄像头）在大框显示，方便调整角度和查看自己的状态
  bool _isRemoteVideoInMainView = false;

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
    logger.debug('📱 ========== VoiceCallPage.initState 开始 ==========');
    logger.debug('📱 页面参数:');
    logger.debug('  - targetUserId: ${widget.targetUserId}');
    logger.debug('  - targetDisplayName: ${widget.targetDisplayName}');
    logger.debug('  - targetAvatar: ${widget.targetAvatar}');
    logger.debug('  - isIncoming: ${widget.isIncoming}');
    logger.debug('  - callType: ${widget.callType}');
    logger.debug('  - groupCallUserIds: ${widget.groupCallUserIds}');
    logger.debug('  - groupCallDisplayNames: ${widget.groupCallDisplayNames}');
    logger.debug('  - currentUserId: ${widget.currentUserId}');
    logger.debug(
      '  - 是否群组通话: ${widget.groupCallUserIds != null && widget.groupCallUserIds!.length > 0}',
    );
    logger.debug(
      '  - groupCallUserIds length: ${widget.groupCallUserIds?.length ?? 0}',
    );
    logger.debug(
      '  - groupCallDisplayNames length: ${widget.groupCallDisplayNames?.length ?? 0}',
    );

    // 初始化目标用户头像（单人通话会尝试后续刷新）
    _targetAvatarUrl = widget.targetAvatar;
    
    // 输出初始视频画面状态
    logger.debug('📹 初始视频画面状态：${_isRemoteVideoInMainView ? "远程画面在大框，本地画面在小框" : "本地画面在大框，远程画面在小框"}');

    // 详细打印每个成员信息
    if (widget.groupCallUserIds != null &&
        widget.groupCallUserIds!.isNotEmpty) {
      logger.debug('📱 ========== 详细成员列表信息 ==========');
      for (int i = 0; i < widget.groupCallUserIds!.length; i++) {
        final userId = widget.groupCallUserIds![i];
        final displayName = i < (widget.groupCallDisplayNames?.length ?? 0)
            ? widget.groupCallDisplayNames![i]
            : 'Unknown';
        logger.debug('📱 成员[$i]: ID=$userId, 名称=$displayName');
      }
      logger.debug('📱 ========================================');
    } else {
      logger.debug('📱 ⚠️ 群组成员列表为空或null');
    }

    // 初始化可变的成员列表
    // 🔴 修复：加入已存在通话时，只初始化自己，不显示"正在呼叫..."的成员
    if (widget.groupCallUserIds != null) {
      if (widget.isJoiningExistingCall) {
        // 只添加自己到成员列表
        if (widget.currentUserId != null) {
          final selfIndex = widget.groupCallUserIds!.indexOf(widget.currentUserId!);
          if (selfIndex != -1 && 
              widget.groupCallDisplayNames != null && 
              selfIndex < widget.groupCallDisplayNames!.length) {
            _currentGroupCallUserIds = [widget.currentUserId!];
            _currentGroupCallDisplayNames = [widget.groupCallDisplayNames![selfIndex]];
          } else {
            _currentGroupCallUserIds = [widget.currentUserId!];
            _currentGroupCallDisplayNames = ['我'];
          }
        } else {
          _currentGroupCallUserIds = [];
          _currentGroupCallDisplayNames = [];
        }
        logger.debug('📱 加入已存在通话，只初始化自己: ${_currentGroupCallUserIds.length} 个成员');
      } else {
        _currentGroupCallUserIds = List<int>.from(widget.groupCallUserIds!);
        if (widget.groupCallDisplayNames != null) {
          _currentGroupCallDisplayNames = List<String>.from(
            widget.groupCallDisplayNames!,
          );
        }
      }
    }
    
    // 🔴 修复：移除重复的 groupCallDisplayNames 初始化
    // 已在上面的逻辑中处理

    // 初始化成员头像列表：如果外部传入了头像列表，则使用外部数据；否则保持与成员数量一致并填充为null
    if (widget.isJoiningExistingCall) {
      // 加入已存在通话时，只初始化自己的头像
      if (widget.currentUserId != null && widget.groupCallAvatarUrls != null) {
        final selfIndex = widget.groupCallUserIds?.indexOf(widget.currentUserId!) ?? -1;
        if (selfIndex != -1 && selfIndex < widget.groupCallAvatarUrls!.length) {
          _currentGroupCallAvatarUrls = [widget.groupCallAvatarUrls![selfIndex]];
        } else {
          _currentGroupCallAvatarUrls = [null];
        }
      } else {
        _currentGroupCallAvatarUrls = _currentGroupCallUserIds.isNotEmpty ? [null] : [];
      }
    } else if (widget.groupCallAvatarUrls != null &&
        widget.groupCallAvatarUrls!.isNotEmpty) {
      _currentGroupCallAvatarUrls =
          List<String?>.from(widget.groupCallAvatarUrls!);
    } else {
      _currentGroupCallAvatarUrls =
          List<String?>.filled(_currentGroupCallUserIds.length, null);
    }

    logger.debug('📱 可变成员列表已初始化: ${_currentGroupCallUserIds.length} 个成员');

    // 加载当前用户头像（用于单人/群组通话中展示“自己”的头像）
    _loadCurrentUserAvatar();

    // 尝试刷新目标用户头像（仅在非群组通话时）
    _loadTargetUserAvatarIfNeeded();

    logger.debug('📱 开始初始化音频播放器...');
    _initAudioPlayer();
    logger.debug('📱 音频播放器初始化完成');

    logger.debug('📱 开始设置Agora回调...');
    _setupAgoraCallbacks();
    logger.debug('📱 Agora回调设置完成');

    // 🔴 修改：群组通话来电时，不再预先标记发起者为已连接
    // 因为发起者可能在接听前就已经挂断了
    // 改为在加入频道后通过 Agora 的 remoteUids 来确定实际在线的成员
    if (widget.isIncoming &&
        widget.groupCallUserIds != null &&
        widget.groupCallUserIds!.isNotEmpty) {
      logger.debug('📱 群组通话来电：不预先标记发起者为已连接，等待 Agora 同步实际在线成员');
    }

    // 延迟启动通话，避免在 initState 中访问 inherited widgets
    // 🔴 修复：使用 Future.delayed 而不是 PostFrameCallback，因为在 showDialog 中
      // PostFrameCallback 可能不会被正确触发
    Future.delayed(Duration.zero, () async {
      if (mounted && !_disposed) {
        try {
          await _startCall();
        } catch (e, stackTrace) {
          logger.debug('📱 [DelayedCallback] ❌ _startCall 调用失败: $e');
          logger.debug('📱 [DelayedCallback] ❌ 堆栈跟踪: $stackTrace');
        }
        // 设备列表将在通话连接成功后自动加载（见 _setupAgoraCallbacks 中的 connected 状态处理）
      }
    });
  }

  /// 异步加载当前用户头像
  Future<void> _loadCurrentUserAvatar() async {
    try {
      final avatar = await Storage.getAvatar();
      logger.debug('🎭 当前用户头像加载结果: $avatar');
      if (!mounted) return;
      setState(() {
        _currentUserAvatarUrl = avatar;
      });
    } catch (e) {
      logger.debug('⚠️ 加载当前用户头像失败: $e');
    }
  }

  /// 在单人通话场景下异步刷新目标用户头像（PC 和移动端通用）
  Future<void> _loadTargetUserAvatarIfNeeded() async {
    try {
      // 仅在非群组通话时刷新目标头像
      final isGroupCall = widget.groupCallUserIds != null &&
          widget.groupCallUserIds!.isNotEmpty;
      if (isGroupCall) return;

      final token = await Storage.getToken();
      if (token == null || token.isEmpty) return;

      final response = await ApiService.getUserInfo(
        widget.targetUserId,
        token: token,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final data = response['data'] as Map<String, dynamic>;
        final serverAvatar = data['avatar']?.toString();
        logger.debug('📞 [_loadTargetUserAvatarIfNeeded] getUserInfo 返回头像: $serverAvatar');

        if (serverAvatar != null && serverAvatar.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _targetAvatarUrl = serverAvatar;
          });
        }
      } else {
        logger.debug(
          '⚠️ [_loadTargetUserAvatarIfNeeded] 获取用户信息失败: ${response['message']}',
        );
      }
    } catch (e) {
      logger.debug('⚠️ [_loadTargetUserAvatarIfNeeded] 获取目标用户头像失败: $e');
    }
  }

  // 初始化音频播放器
  void _initAudioPlayer() {
    logger.debug('🔊 音频播放器准备就绪');
  }

  @override
  void dispose() {
    logger.debug('🔄 开始清理通话页面资源');

    // 标记页面已销毁和正在关闭（必须第一步）
    _disposed = true;
    _isClosing = true;

    // 立即取消计时器
    _popupCloseTimer?.cancel();

    // 🔴 修复：恢复之前的监听器，而不是设置为 null
    // 这样可以保持聊天页面的监听器继续工作
    logger.debug(
      '📱 [VoiceCallPage] dispose - 恢复之前的监听器: ${_previousCallStateListener != null ? "存在" : "null"}',
    );
    _agoraService.onCallStateChanged = _previousCallStateListener;
    logger.debug('📱 [VoiceCallPage] dispose - 监听器已恢复');
    _agoraService.onRemoteUserJoined = null;
    _agoraService.onRemoteUserLeft = null;
    _agoraService.onError = null;

    // 停止并释放音频播放器（异步操作但不等待）
    _waitingPlayer?.stop().catchError((e) {
      logger.debug('⚠️ 停止等待音效失败: $e');
    });
    _waitingPlayer?.dispose().catchError((e) {
      logger.debug('⚠️ 释放等待音效播放器失败: $e');
    });

    // 释放滚动控制器
    _groupMembersScrollController.dispose();

    logger.debug('通话页面资源清理完成');
    super.dispose();
  }

  // 播放等待音效（循环播放）
  Future<void> _playWaitingSound() async {
    if (_disposed || !mounted) return; // 页面已销毁，不播放
    try {
      final assetPath = 'mp3/wait.mp3';
      logger.debug('==================== 等待音效播放调试（简化版本） ====================');
      logger.debug('📁 尝试加载的资源路径: $assetPath');
      logger.debug('📂 完整路径应该: assets/$assetPath');
      logger.debug('🧪 测试：使用极简配置（参考PC端来电铃声）');

      _waitingPlayer = AudioPlayer();
      
      // 🧪 简化版本：暂时移除AudioContext配置，测试是否能解决最后1秒丢失的问题
      // 参考PC端来电铃声的极简方式 - 只设置loop，不设置其他配置
      // if (defaultTargetPlatform == TargetPlatform.android ||
      //     defaultTargetPlatform == TargetPlatform.iOS) {
      //   logger.debug('🔊 移动端：设置音频上下文为扬声器模式');
      //   await _waitingPlayer!.setAudioContext(
      //     AudioContext(
      //       iOS: AudioContextIOS(
      //         category: AVAudioSessionCategory.playAndRecord,
      //         options: {
      //           AVAudioSessionOptions.defaultToSpeaker,
      //           AVAudioSessionOptions.mixWithOthers,
      //         },
      //       ),
      //       android: AudioContextAndroid(
      //         isSpeakerphoneOn: true,
      //         stayAwake: true,
      //         contentType: AndroidContentType.sonification,
      //         usageType: AndroidUsageType.voiceCommunication,
      //         audioFocus: AndroidAudioFocus.gain,
      //       ),
      //     ),
      //   );
      //   logger.debug('🔊 音频上下文设置完成');
      // }
      logger.debug('⚠️ 已移除AudioContext配置，使用系统默认设置');
      
      // 🔴 极简配置：只设置loop模式，不设置音量和监听器
      await _waitingPlayer!.setReleaseMode(ReleaseMode.loop);
      // await _waitingPlayer!.setVolume(0.15); // 暂时使用默认音量
      logger.debug('⚠️ 使用系统默认音量');
      
      // 🧪 暂时移除播放完成监听器，让系统自己处理循环
      // _waitingPlayer!.onPlayerComplete.listen((event) {
      //   if (!_disposed && mounted && (_callState == CallState.calling || _callState == CallState.ringing)) {
      //     logger.debug('⚠️ loop模式失效，手动重新播放');
      //     _waitingPlayer?.play(AssetSource(assetPath));
      //   }
      // });
      logger.debug('⚠️ 已移除播放完成监听器，让系统自动处理循环');

      if (_disposed || !mounted) return; // 检查页面是否还存在

      logger.debug('🎵 开始调用play方法...');
      logger.debug('🔄 播放模式: ReleaseMode.loop (极简配置，完全交给系统处理)');
      await _waitingPlayer!.play(AssetSource(assetPath));
      logger.debug('✅ 等待音效播放成功（极简配置版本）');
      logger.debug('========================================================');
    } catch (e) {
      logger.debug('==================== 等待音效播放失败 ====================');
      logger.debug('播放等待音效失败');
      logger.debug('错误信息: $e');
      logger.debug('错误类型: ${e.runtimeType}');
      logger.debug('错误详情: ${e.toString()}');
      logger.debug('========================================================');
    }
  }

  // 停止音效
  Future<void> _stopSound() async {
    try {
      logger.debug('🛑 ========== 停止等待音效 ==========');
      logger.debug('🛑 调用时间: ${DateTime.now()}');
      logger.debug('🛑 当前状态: $_callState');
      logger.debug('🛑 播放器状态: ${_waitingPlayer != null ? "存在" : "null"}');
      await _waitingPlayer?.stop();
      logger.debug('🔊 等待音效已停止');
      logger.debug('========================================================');
    } catch (e) {
      logger.debug('⚠️ 停止音效失败: $e');
    }
  }

  // 设置 Agora 回调
  void _setupAgoraCallbacks() {
    // 🔴 修复：保存之前的监听器（可能是聊天页面设置的）
    _previousCallStateListener = _agoraService.onCallStateChanged;
    logger.debug(
      '📱 [VoiceCallPage] 保存之前的监听器: ${_previousCallStateListener != null ? "存在" : "null"}',
    );

    _agoraService.onCallStateChanged = (state) {
      if (_disposed || !mounted || _isClosing) {
        logger.debug('📱 页面已销毁或正在关闭，忽略状态变化: $state');
        return;
      }

      logger.debug('📱 通话页面状态变化: $state');

      // 忽略 idle 状态（通常是清理后的状态）
      if (state == CallState.idle) {
        logger.debug('📱 忽略 idle 状态');
        return;
      }

      setState(() {
        _callState = state;
        _updateStatusText(state);
      });

      // 根据状态播放相应的音效
      if (state == CallState.calling || state == CallState.ringing) {
        // 呼叫中或收到来电时播放等待音效
        _playWaitingSound();
      } else if (state == CallState.connected) {
        // 通话接通时停止等待音效
        _stopSound();
        _startCallTimer();

        // 🔴 修复：立即同步已连接成员（从 Agora 的 remoteUids 中获取）
        final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
        if (isGroupCall) {
          logger.debug('📞 [状态变化-connected] 立即同步已连接成员，remoteUids: ${_agoraService.remoteUids}');
          for (final uid in _agoraService.remoteUids) {
            if (!_connectedMemberIds.contains(uid)) {
              _connectedMemberIds.add(uid);
              logger.debug('📞 [状态变化-connected] 添加已连接成员: $uid');
            }
          }
          // 同时将自己添加到已连接成员列表
          if (widget.currentUserId != null && !_connectedMemberIds.contains(widget.currentUserId!)) {
            _connectedMemberIds.add(widget.currentUserId!);
            logger.debug('📞 [状态变化-connected] 添加自己到已连接成员: ${widget.currentUserId}');
          }
          logger.debug('📞 [状态变化-connected] 当前已连接成员: $_connectedMemberIds');
        }

        // 🔴 修改：延迟同步已连接成员列表（二次同步，确保不遗漏）
        // 等待 Agora 的 remoteUids 更新后再同步，确保能正确检测已离开的成员
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !_disposed) {
            _syncConnectedMembers();
          }
        });

        // 通话连接成功后，加载设备列表并应用保存的配置
        _initializeDevices();
      } else if (state == CallState.ended) {
        // 防止重复处理 ended 状态
        if (_isClosing) {
          logger.debug('📱 已经在关闭中，跳过重复处理');
          return;
        }
        _isClosing = true;

        logger.debug('📱 通话结束，开始关闭流程');

        // 停止音效
        _stopSound();

        // 🔴 修复：计算最终的通话时长
        // 如果计时器还在运行，使用当前的 _callDuration
        // 如果计时器已停止，尝试从 agoraService 获取通话开始时间来计算
        int finalCallDuration = _callDuration;
        if (finalCallDuration == 0 && _agoraService.callStartTime != null) {
          final elapsed = DateTime.now().difference(
            _agoraService.callStartTime!,
          );
          finalCallDuration = elapsed.inSeconds;
          logger.debug('📱 从 callStartTime 计算通话时长: $finalCallDuration 秒');
        }
        logger.debug('📱 最终通话时长: $finalCallDuration 秒');

        // 🔴 关键修复：获取是否是本地主动挂断的标识
        // 如果是对方挂断导致的 ended 状态，isLocalHangup 应该是 false
        final isLocalHangup = _agoraService.isLocalHangup;
        logger.debug('📱 是否本地主动挂断: $isLocalHangup');

        // 🔴 修改：立即关闭页面，返回 callEnded 标记、通话时长和是否本地挂断
        logger.debug('📱 准备关闭通话页面');
        if (mounted) {
          Navigator.of(
            context,
          ).pop({
            'callEnded': true, 
            'callDuration': finalCallDuration,
            'isLocalHangup': isLocalHangup, // 🔴 新增：传递是否本地挂断
          });
          logger.debug('📱 通话页面已关闭');
        } else {
          logger.debug('📱 通话页面未 mounted，无法关闭');
        }
      }
    };

    _agoraService.onRemoteUserJoined = (uid) {
      if (_disposed || !mounted || _isClosing) return;

      logger.debug('📹 远程用户加入: $uid');
      setState(() {
        _remoteUid = uid;

        // 群组通话：标记成员为已连接
        if (widget.groupCallUserIds != null &&
            widget.groupCallUserIds!.contains(uid)) {
          _connectedMemberIds.add(uid);
          logger.debug(
            '📞 群组成员已连接: $uid (已连接: ${_connectedMemberIds.length}/${widget.groupCallUserIds!.length})',
          );
          
          // 🔴 修复：如果成员不在显示列表中，添加到显示列表
          // 这对于 isJoiningExistingCall 场景很重要，因为初始化时只有自己
          if (!_currentGroupCallUserIds.contains(uid)) {
            _currentGroupCallUserIds.add(uid);
            // 尝试从原始传入的列表中获取显示名称
            final originalIndex = widget.groupCallUserIds?.indexOf(uid) ?? -1;
            if (originalIndex != -1 && 
                widget.groupCallDisplayNames != null && 
                originalIndex < widget.groupCallDisplayNames!.length) {
              _currentGroupCallDisplayNames.add(widget.groupCallDisplayNames![originalIndex]);
            } else {
              _currentGroupCallDisplayNames.add('用户$uid');
            }
            // 添加头像（尝试从原始列表获取）
            if (originalIndex != -1 && 
                widget.groupCallAvatarUrls != null && 
                originalIndex < widget.groupCallAvatarUrls!.length) {
              _currentGroupCallAvatarUrls.add(widget.groupCallAvatarUrls![originalIndex]);
            } else {
              _currentGroupCallAvatarUrls.add(null);
            }
            logger.debug('📞 已将成员 $uid 添加到显示列表');
          }
        }

        // 创建远程视频视图
        if (widget.callType == CallType.video && _agoraService.engine != null) {
          logger.debug('📹 创建远程视频视图，uid: $uid, channelId: ${_agoraService.currentChannelName}');
          _remoteVideoView = AgoraVideoView(
            controller: VideoViewController.remote(
              rtcEngine: _agoraService.engine!,
              canvas: VideoCanvas(uid: uid),
              connection: RtcConnection(
                channelId: _agoraService.currentChannelName,
              ),
            ),
          );
          logger.debug('📹 远程视频视图创建完成');
        }
      });
      
      // 触发UI重建以显示新的远程视频视图
      setState(() {});
    };

    _agoraService.onRemoteUserLeft = (uid) {
      if (_disposed || !mounted || _isClosing) {
        logger.debug('📹 页面已销毁/正在关闭，忽略远程用户离开: $uid');
        return;
      }

      logger.debug('📹 远程用户离开: $uid');
      if (_remoteUid == uid) {
        setState(() {
          _remoteUid = null;
          _remoteVideoView = null;

          // 群组通话：移除已连接标记
          if (widget.groupCallUserIds != null &&
              _connectedMemberIds.contains(uid)) {
            _connectedMemberIds.remove(uid);
            logger.debug(
              '📞 群组成员已断开: $uid (已连接: ${_connectedMemberIds.length}/${widget.groupCallUserIds!.length})',
            );
          }
        });
      }
    };

    _agoraService.onError = (error) {
      if (_disposed || !mounted || _isClosing) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    };

    // 本地视频准备就绪
    _agoraService.onLocalVideoReady = () {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📹 本地视频准备就绪');

      setState(() {
        // 🔴 修复：PC端视频通话时直接创建本地视频视图，不依赖摄像头设备枚举
        // 原因：onLocalVideoReady触发时，设备列表可能还没有加载完成，导致跳过视频视图创建
        if (widget.callType == CallType.video && _agoraService.engine != null) {
          logger.debug('📹 创建本地视频视图（本地视频已准备就绪）');
          _localVideoView = AgoraVideoView(
            controller: VideoViewController(
              rtcEngine: _agoraService.engine!,
              canvas: const VideoCanvas(uid: 0),
            ),
          );
        } else {
          logger.debug('📹 跳过创建本地视频视图（非视频通话或引擎未就绪）');
          logger.debug('   - 通话类型: ${widget.callType}');
          logger.debug('   - 引擎状态: ${_agoraService.engine != null ? "就绪" : "未就绪"}');
        }
      });
    };

    // 远程视频准备就绪
    _agoraService.onRemoteVideoReady = (uid) {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📹 远程视频准备就绪: $uid');
      logger.debug('📹 当前远程视频视图状态: ${_remoteVideoView != null ? "存在" : "null"}');
      
      // 如果远程视频视图还没创建，现在创建它
      if (_remoteVideoView == null && widget.callType == CallType.video && _agoraService.engine != null) {
        logger.debug('📹 远程视频准备就绪时创建视频视图，uid: $uid');
        _remoteVideoView = AgoraVideoView(
          controller: VideoViewController.remote(
            rtcEngine: _agoraService.engine!,
            canvas: VideoCanvas(uid: uid),
            connection: RtcConnection(
              channelId: _agoraService.currentChannelName,
            ),
          ),
        );
        logger.debug('📹 远程视频视图创建完成（在onRemoteVideoReady中）');
      }
      
      setState(() {});
    };

    // 🔴 新增：监听远程用户视频静音状态变化
    _agoraService.onRemoteVideoMuted = (uid, isMuted) {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📹 远程用户视频静音状态变化: uid=$uid, isMuted=$isMuted');
      
      setState(() {
        _isRemoteVideoMuted = isMuted;
      });
    };

    // 群组通话成员状态变化
    _agoraService
        .onGroupCallMemberStatusChanged = (userId, status, displayName) {
      if (_disposed || !mounted || _isClosing) return;
      logger.debug('📞 群组成员状态变化: 用户$userId -> $status (显示名: $displayName)');

      if (status == 'accepted') {
        // 🔴 修复：当有成员接听时，停止等待音效并更新状态
        logger.debug('📞 收到成员接听通知: $userId ($displayName)');

        // 如果当前状态是 calling（等待接听），且这是第一个接听的成员，则停止音效并更新状态
        if (_callState == CallState.calling && _connectedMemberIds.isEmpty) {
          logger.debug('📞 第一个成员接听，停止等待音效并更新状态为 connected');
          _stopSound(); // 停止等待音效
          setState(() {
            _callState = CallState.connected;
            _statusText = '通话中';
          });
          // 启动通话计时器
          _startCallTimer();
        }

        setState(() {
          _connectedMemberIds.add(userId);

          // 检查是否是新邀请的成员（不在当前显示列表中）
          if (!_currentGroupCallUserIds.contains(userId)) {
            // 添加到显示列表中
            _currentGroupCallUserIds.add(userId);

            // 使用从消息中获取的显示名称，如果没有则使用默认名称
            final memberDisplayName = displayName ?? 'User$userId';
            _currentGroupCallDisplayNames.add(memberDisplayName);

            logger.debug('📞 新成员已加入并添加到显示列表: $userId -> $memberDisplayName');
          }

          logger.debug(
            '📞 群组成员已连接: $userId (已连接: ${_connectedMemberIds.length}/${_currentGroupCallUserIds.length})',
          );
        });
      } else if (status == 'left') {
        setState(() {
          // 从连接成员集合中移除
          _connectedMemberIds.remove(userId);

          // 从显示列表中完全移除该成员
          final userIndex = _currentGroupCallUserIds.indexOf(userId);
          if (userIndex != -1) {
            _currentGroupCallUserIds.removeAt(userIndex);
            if (userIndex < _currentGroupCallDisplayNames.length) {
              _currentGroupCallDisplayNames.removeAt(userIndex);
            }
            logger.debug(
              '📞 群组成员已从页面移除: $userId (剩余显示: ${_currentGroupCallUserIds.length})',
            );
          } else {
            logger.debug('📞 群组成员已离开: $userId (未在显示列表中找到)');
          }
        });
      }
    };
  }

  // 开始通话
  Future<void> _startCall() async {
    logger.debug('📞 ========== _startCall 开始 ==========');
    logger.debug('📞 参数信息:');
    logger.debug('  - isIncoming: ${widget.isIncoming}');
    logger.debug('  - targetUserId: ${widget.targetUserId}');
    logger.debug('  - targetDisplayName: ${widget.targetDisplayName}');
    logger.debug('  - callType: ${widget.callType}');
    logger.debug('  - groupCallUserIds: ${widget.groupCallUserIds}');
    logger.debug('  - groupCallDisplayNames: ${widget.groupCallDisplayNames}');
    logger.debug('  - currentUserId: ${widget.currentUserId}');
    logger.debug('📞 当前状态:');
    logger.debug('  - AgoraService状态: ${_agoraService.callState}');
    logger.debug('  - VoiceCallPage._callState: $_callState');
    logger.debug('  - isCallMinimized: ${_agoraService.isCallMinimized}');
    logger.debug('  - mounted: $mounted');
    logger.debug('  - _disposed: $_disposed');
    logger.debug(
      '📞 是否群组通话: ${widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty}',
    );

    // 🔴 新增：精准判断 - 如果是从最小化恢复且通话还在频道中，直接恢复通话状态
    if (_agoraService.isCallMinimized &&
        _agoraService.currentChannelName != null) {
      logger.debug('📞 ========== 【从最小化恢复】 ==========');
      logger.debug('📞 检测到最小化标识，且频道仍存在: ${_agoraService.currentChannelName}');
      _resumeMinimizedCall();
      return;
    }

    if (widget.isIncoming) {
      logger.debug('📞 【来电流程】');
      // 来电，检查当前状态
      if (_agoraService.callState == CallState.connected) {
        logger.debug('📞 通话已在弹窗中接听，当前状态: connected');

        // 计算已经通话的时长
        if (_agoraService.callStartTime != null) {
          final elapsed = DateTime.now().difference(
            _agoraService.callStartTime!,
          );
          _callDuration = elapsed.inSeconds;
          logger.debug('📞 恢复通话时长: $_callDuration 秒');
        }

        // 🔴 修复：同步已连接的成员（从 Agora 的 remoteUids 中获取）
        // 因为 onRemoteUserJoined 回调可能在页面创建之前就已经触发了
        final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
        if (isGroupCall) {
          logger.debug('📞 [来电-已连接] 同步已连接成员，remoteUids: ${_agoraService.remoteUids}');
          for (final uid in _agoraService.remoteUids) {
            if (!_connectedMemberIds.contains(uid)) {
              _connectedMemberIds.add(uid);
              logger.debug('📞 [来电-已连接] 添加已连接成员: $uid');
            }
          }
          // 同时将自己添加到已连接成员列表
          if (widget.currentUserId != null && !_connectedMemberIds.contains(widget.currentUserId!)) {
            _connectedMemberIds.add(widget.currentUserId!);
            logger.debug('📞 [来电-已连接] 添加自己到已连接成员: ${widget.currentUserId}');
          }
          logger.debug('📞 [来电-已连接] 最终已连接成员: $_connectedMemberIds');
        }

        setState(() {
          _callState = CallState.connected;
          _statusText = '通话中';
        });
        _startCallTimer();

        // 🔴 修复：通话已经连接，需要初始化设备列表
        _initializeDevices();
      } else if (_agoraService.callState == CallState.ringing) {
        // 如果ringing 状态，说明还未接听
        logger.debug('📞 当前状态为ringing，设置UI状态');
        setState(() {
          _callState = CallState.ringing;
          _statusText = '收到来电...';
        });

        // 延迟一小段时间后自动接听
        logger.debug('📞 检测到来电状态，将自动接听...');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && _callState == CallState.ringing) {
            logger.debug('📞 自动接听来电');
            _acceptCall();
          }
        });
      } else {
        // 其他状态，等待用户接听
        logger.debug('📞 其他状态，等待用户接听');
        setState(() {
          _callState = CallState.ringing;
          _statusText = '收到来电...';
        });
      }
    } else {
      logger.debug('📞 【去电流程】');
      // 去电，检查当前状态
      if (_agoraService.callState == CallState.connected) {
        // 通话已经接通，直接恢复通话状态
        logger.debug('📞 通话已接通，恢复通话状态');

        // 计算已经通话的时长
        if (_agoraService.callStartTime != null) {
          final elapsed = DateTime.now().difference(
            _agoraService.callStartTime!,
          );
          _callDuration = elapsed.inSeconds;
          logger.debug('📞 恢复通话时长: $_callDuration 秒');
        }

        setState(() {
          _callState = CallState.connected;
          _statusText = '通话中';
        });
        _startCallTimer();

        // 🔴 修复：通话已经连接，需要初始化设备列表
        _initializeDevices();
      } else if (_agoraService.callState == CallState.calling) {
        // 正在呼叫中，恢复呼叫状态
        logger.debug('📞 正在呼叫中，恢复呼叫状态');
        setState(() {
          _callState = CallState.calling;
          _statusText = '正在呼叫...';
        });
        _playWaitingSound();
      } else {
        // 检查是否是群组通话
        final isGroupCall =
            widget.groupCallUserIds != null &&
            widget.groupCallUserIds!.isNotEmpty;

        logger.debug('📞 检查是否为群组通话: $isGroupCall');
        logger.debug('📞 widget.groupCallUserIds: ${widget.groupCallUserIds}');
        logger.debug(
          '📞 groupCallUserIds长度: ${widget.groupCallUserIds?.length ?? 0}',
        );

        logger.debug('🎨 VoiceCallPage._buildVoiceCallContent targetAvatar: ${widget.targetAvatar}');

    if (isGroupCall) {
          // 🔴 群组通话：不调用 startVoiceCall/startVideoCall
          // 因为 HomePage 已经调用了群组通话 API，频道已经创建
          logger.debug('📞 ========== 群组通话流程开始 ==========');
          logger.debug('📞 群组通话：跳过调用 AgoraService.startVoiceCall');
          logger.debug('📞 群组通话频道已在 HomePage 中创建，此处直接加入频道');
          logger.debug('📞 isJoiningExistingCall: ${widget.isJoiningExistingCall}');
          logger.debug(
            '📞 当前AgoraService频道: ${_agoraService.currentChannelName}',
          );
          logger.debug('📞 当前AgoraService用户ID: ${_agoraService.myUserId}');

          // 🔴 修复：区分发起新通话和加入已存在通话的UI状态
          if (widget.isJoiningExistingCall) {
            // 主动加入已存在的通话：直接连接，不显示"正在呼叫..."
            logger.debug('📞 主动加入已存在通话：设置UI状态为connecting...');
            setState(() {
              _callState = CallState.calling; // 保持calling状态，但不播放等待音效
              _statusText = '正在连接...'; // 显示"正在连接..."而不是"正在呼叫..."
            });
            logger.debug('📞 UI状态已设置（不播放等待音效）');
          } else {
            // 发起新的群组通话：显示"正在呼叫..."并播放等待音效
            logger.debug('📞 发起新群组通话：设置UI状态为calling...');
            setState(() {
              _callState = CallState.calling;
              _statusText = '正在呼叫...';
            });
            logger.debug('📞 UI状态已设置');

            logger.debug('📞 播放等待音效...');
            _playWaitingSound();
            logger.debug('📞 等待音效已启动');
          }

          // 直接加入 AgoraService 中已设置的频道
          logger.debug('📞 准备调用 joinGroupCallChannel()...');
          try {
            await _agoraService.joinGroupCallChannel();
            logger.debug('📞 ✅ joinGroupCallChannel() 调用成功');
          } catch (e, stackTrace) {
            logger.debug('📞 ❌ joinGroupCallChannel() 调用失败: $e');
            logger.debug('📞 ❌ 堆栈跟踪: $stackTrace');
            rethrow;
          }
          logger.debug('📞 ========== 群组通话流程结束 ==========');
        } else {
          // 单人通话：需要调用 startVoiceCall/startVideoCall 来创建频道
          logger.debug('📞 主动发起新的通话');
          logger.debug('📞 设置UI状态为calling...');
          setState(() {
            _callState = CallState.calling;
            _statusText = '正在呼叫...';
          });

          // 立即播放等待音效
          logger.debug('📞 播放等待音效...');
          _playWaitingSound();

          logger.debug('📞 准备调用AgoraService启动通话...');
          logger.debug('📞 callType: ${widget.callType}');
          if (widget.callType == CallType.voice) {
            logger.debug('📞 调用 startVoiceCall...');
            await _agoraService.startVoiceCall(
              widget.targetUserId,
              widget.targetDisplayName,
            );
            logger.debug('📞 startVoiceCall 调用完成');
          } else {
            logger.debug('📞 调用 startVideoCall...');
            await _agoraService.startVideoCall(
              widget.targetUserId,
              widget.targetDisplayName,
            );
            logger.debug('📞 startVideoCall 调用完成');
          }
        }
      }
    }
    logger.debug('📞 ========== _startCall 结束 ==========');
  }

  // 🔴 新增：从最小化恢复通话（不发起新通话）
  Future<void> _resumeMinimizedCall() async {
    logger.debug('📞 ========== 从最小化恢复通话 ==========');
    logger.debug('📞 通话类型: ${widget.callType}');
    logger.debug('📞 当前频道: ${_agoraService.currentChannelName}');
    logger.debug('📞 minimizedCallType: ${_agoraService.minimizedCallType}');
    logger.debug('📞 是否群组通话: ${widget.groupCallUserIds?.isNotEmpty ?? false}');

    // 1. 恢复通话时长
    if (_agoraService.callStartTime != null) {
      final elapsed = DateTime.now().difference(_agoraService.callStartTime!);
      _callDuration = elapsed.inSeconds;
      logger.debug('📞 恢复通话时长: $_callDuration 秒');
    }

    // 2. 🔴 修复：从 Agora 的 remoteUids 获取真正在线的成员，而不是使用保存的旧数据
    // 因为在后台期间可能有成员退出了
    logger.debug('📞 [恢复通话] Agora remoteUids: ${_agoraService.remoteUids}');
    for (final uid in _agoraService.remoteUids) {
      _connectedMemberIds.add(uid);
    }
    // 将自己添加到已连接成员列表
    if (widget.currentUserId != null) {
      _connectedMemberIds.add(widget.currentUserId!);
    }
    logger.debug('📞 [恢复通话] 已连接成员: $_connectedMemberIds');

    // 🔴 修复：同时更新显示列表，只保留真正在线的成员
    if (widget.groupCallUserIds != null && widget.groupCallDisplayNames != null) {
      final newUserIds = <int>[];
      final newDisplayNames = <String>[];
      final newAvatarUrls = <String?>[];
      
      for (int i = 0; i < widget.groupCallUserIds!.length; i++) {
        final userId = widget.groupCallUserIds![i];
        // 只添加自己和真正在线的成员
        if (userId == widget.currentUserId || _agoraService.remoteUids.contains(userId)) {
          newUserIds.add(userId);
          if (i < widget.groupCallDisplayNames!.length) {
            newDisplayNames.add(widget.groupCallDisplayNames![i]);
          }
          if (widget.groupCallAvatarUrls != null && i < widget.groupCallAvatarUrls!.length) {
            newAvatarUrls.add(widget.groupCallAvatarUrls![i]);
          } else {
            newAvatarUrls.add(null);
          }
        }
      }
      
      _currentGroupCallUserIds = newUserIds;
      _currentGroupCallDisplayNames = newDisplayNames;
      _currentGroupCallAvatarUrls = newAvatarUrls;
      logger.debug('📞 [恢复通话] 更新显示列表: ${_currentGroupCallUserIds.length} 个成员');
    }

    // 3. 设置UI状态为已连接
    setState(() {
      _callState = CallState.connected;
      _statusText = '通话中';
    });

    // 4. 启动计时器
    _startCallTimer();

    // 5. 初始化设备列表（会自动创建视频视图）
    await _initializeDevices();

    // 6. 清除最小化标识（已经恢复了）
    _agoraService.setCallMinimized(isMinimized: false);
    logger.debug('📞 已清除最小化标识');

    logger.debug('📞 ========== 恢复完成 ==========');
  }

  // 更新状态文本
  void _updateStatusText(CallState state) {
    switch (state) {
      case CallState.idle:
        _statusText = '空闲';
        break;
      case CallState.calling:
        _statusText = '正在呼叫...';
        break;
      case CallState.ringing:
        _statusText = '收到来电';
        break;
      case CallState.connected:
        _statusText = '通话中';
        break;
      case CallState.ended:
        _statusText = '通话结束';
        break;
    }
  }

  // 辅助方法：截断显示名称，超过9个字符添加省略号
  String _truncateDisplayName(String name) {
    if (name.length > 9) {
      return '${name.substring(0, 9)}...';
    }
    return name;
  }

  // 开始计时 - 现在为空实现，计时逻辑已移至 CallDurationWidget
  void _startCallTimer() {
    // 计时逻辑已移至 CallDurationWidget 组件
  }

  // 🔴 新增：同步已连接成员列表
  // 当成员接听成功后，从 Agora 的 remoteUids 同步已连接成员
  // 移除那些实际上已经不在通话中的成员
  void _syncConnectedMembers() {
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    if (!isGroupCall) return;

    logger.debug('📞 [同步成员] 开始同步已连接成员列表');
    logger.debug('📞 [同步成员] 当前页面显示的已连接成员: $_connectedMemberIds');
    logger.debug('📞 [同步成员] Agora remoteUids: ${_agoraService.remoteUids}');

    // 获取 Agora 中实际在线的远程用户
    final actualRemoteUids = _agoraService.remoteUids;

    // 🔴 修复：如果 Agora remoteUids 为空，但页面显示有成员（除了自己），
    // 说明成员可能还在加入过程中，跳过本次同步，避免误删
    final otherConnectedMembers = _connectedMemberIds.where((id) => id != widget.currentUserId).toList();
    if (actualRemoteUids.isEmpty && otherConnectedMembers.isNotEmpty) {
      logger.debug('📞 [同步成员] ⚠️ Agora remoteUids 为空但页面有成员，跳过同步（成员可能正在加入）');
      return;
    }

    // 找出需要移除的成员（在页面显示中但不在 Agora 中）
    final membersToRemove = <int>[];
    for (final memberId in _connectedMemberIds) {
      // 跳过自己（自己不在 remoteUids 中，但应该保留）
      if (memberId == widget.currentUserId) continue;
      
      if (!actualRemoteUids.contains(memberId)) {
        membersToRemove.add(memberId);
        logger.debug('📞 [同步成员] 成员 $memberId 不在 Agora 中，需要移除');
      }
    }

    // 移除不在通话中的成员
    if (membersToRemove.isNotEmpty) {
      setState(() {
        for (final memberId in membersToRemove) {
          _connectedMemberIds.remove(memberId);
          
          // 从显示列表中也移除
          final userIndex = _currentGroupCallUserIds.indexOf(memberId);
          if (userIndex != -1) {
            _currentGroupCallUserIds.removeAt(userIndex);
            if (userIndex < _currentGroupCallDisplayNames.length) {
              _currentGroupCallDisplayNames.removeAt(userIndex);
            }
            if (userIndex < _currentGroupCallAvatarUrls.length) {
              _currentGroupCallAvatarUrls.removeAt(userIndex);
            }
            logger.debug('📞 [同步成员] 已从显示列表移除成员: $memberId');
          }
        }
      });
      logger.debug('📞 [同步成员] 同步完成，移除了 ${membersToRemove.length} 个成员');
    } else {
      logger.debug('📞 [同步成员] 同步完成，无需移除成员');
    }

    // 同时添加 Agora 中存在但页面未显示的成员
    for (final uid in actualRemoteUids) {
      if (!_connectedMemberIds.contains(uid)) {
        _connectedMemberIds.add(uid);
        logger.debug('📞 [同步成员] 添加 Agora 中存在的成员: $uid');
      }
    }

    logger.debug('📞 [同步成员] 最终已连接成员: $_connectedMemberIds');
  }

  // 接听
  Future<void> _acceptCall() async {
    await _agoraService.acceptCall();
  }

  // 拒接
  Future<void> _rejectCall() async {
    if (_isClosing) return; // 避免重复调用
    _isClosing = true; // 立即标记，防止状态变化回调重复处理

    // 停止等待音效
    await _stopSound();

    // 🔴 优化：群组通话中拒绝只离开自己，不结束整个通话
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    if (isGroupCall) {
      logger.debug('📱 群组通话拒接，只离开自己');
      final result = await _agoraService.leaveGroupCallOnly();
      final isCallEnded = result['isCallEnded'] == true;
      logger.debug('📱 群组通话拒接完成，isCallEnded: $isCallEnded');
    } else {
      // 单人通话：拒绝通话
      await _agoraService.rejectCall();
    }

    // 🔴 修改：立即关闭页面，返回拒绝状态和通话类型
    logger.debug('📱 拒接通话，立即关闭页面');
    if (mounted) {
      Navigator.of(context).pop({
        'callRejected': true,
        'callType': widget.callType, // 返回通话类型
      });
    }
  }

  // 挂断
  Future<void> _endCall() async {
    if (_isClosing) return; // 避免重复调用
    _isClosing = true; // 立即标记，防止状态变化回调重复处理

    // 立即显示"正在退出..."
    setState(() {
      _exitStatusText = '正在退出...';
    });

    // 停止等待音效
    await _stopSound();

    // 🔴 修复：判断是否是取消通话（发起方在 calling 状态下挂断）
    final isCancelled = !widget.isIncoming && _callState == CallState.calling;

    // 🔴 优化：群组通话中挂断只离开自己，不结束整个通话
    final isGroupCall = widget.groupCallUserIds != null && widget.groupCallUserIds!.isNotEmpty;
    int finalCallDuration = 0;
    bool isCallEnded = false;
    
    if (isGroupCall) {
      logger.debug('📱 群组通话挂断，只离开自己');
      final result = await _agoraService.leaveGroupCallOnly();
      finalCallDuration = result['callDuration'] as int? ?? 0;
      isCallEnded = result['isCallEnded'] == true;
      logger.debug('📱 群组通话挂断完成，callDuration: $finalCallDuration, isCallEnded: $isCallEnded');
    } else {
      // 单人通话：计算通话时长并结束通话
      finalCallDuration = _callDuration;
      if (finalCallDuration == 0 && _agoraService.callStartTime != null) {
        final elapsed = DateTime.now().difference(_agoraService.callStartTime!);
        finalCallDuration = elapsed.inSeconds;
        logger.debug('📱 从 callStartTime 计算通话时长: $finalCallDuration 秒');
      }
      logger.debug('📱 最终通话时长: $finalCallDuration 秒');

      // 结束通话（用户主动挂断，isLocalHangup = true）
      await _agoraService.endCall(isLocalHangup: true);
    }

    // 🔴 修改：立即关闭页面，返回相应的标记和通话类型
    logger.debug('📱 主动挂断，立即关闭页面');
    if (mounted) {
      if (isCancelled) {
        // 发起方取消通话（对方未接听）
        Navigator.of(context).pop({
          'callCancelled': true,
          'callType': widget.callType, // 返回通话类型
        });
      } else {
        // 正常结束通话（已接通）
        Navigator.of(context).pop({
          'callEnded': true,
          'callDuration': finalCallDuration,
          'callType': widget.callType, // 返回通话类型
          'isLocalHangup': true, // 🔴 新增：用户主动挂断
        });
      }
    }
  }

  // 切换静音
  void _toggleMute() async {
    setState(() {
      _isMuted = !_isMuted;
    });
    if (_agoraService.engine != null) {
      await _agoraService.engine!.muteLocalAudioStream(_isMuted);
      logger.debug('🎤 麦克风已${_isMuted ? "关闭" : "开启"}');
    }
  }

  // 切换扬声器
  void _toggleSpeaker() async {
    await _agoraService.toggleSpeaker();
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
  }

  // 切换摄像头
  void _toggleCamera() async {
    if (_agoraService.engine != null) {
      await _agoraService.engine!.muteLocalVideoStream(_isCameraOn);
      setState(() {
        _isCameraOn = !_isCameraOn;
      });
      logger.debug('📹 摄像头已${_isCameraOn ? "开启" : "关闭"}');
    }
  }

  // 切换视频画面显示（大小框互换）
  void _swapVideoViews() {
    logger.debug('📹 点击小框，准备切换画面...');
    logger.debug('📹 切换前状态：${_isRemoteVideoInMainView ? "远程画面在大框，本地画面在小框" : "本地画面在大框，远程画面在小框"}');
    
    setState(() {
      _isRemoteVideoInMainView = !_isRemoteVideoInMainView;
    });
    
    logger.debug('📹 切换后状态：${_isRemoteVideoInMainView ? "远程画面在大框，本地画面在小框" : "本地画面在大框，远程画面在小框"}');
    logger.debug('📹 当前视频状态 - 本地视频: ${_localVideoView != null ? "存在" : "null"}, 远程视频: ${_remoteVideoView != null ? "存在" : "null"}');
  }

  // 初始化所有设备（在通话连接成功后调用）
  Future<void> _initializeDevices() async {
    logger.debug('============================================');
    logger.debug('🔧 开始初始化设备列表');
    logger.debug('   - 通话类型: ${widget.callType}');
    logger.debug('   - mounted: $mounted');
    logger.debug('   - _disposed: $_disposed');
    logger.debug('============================================');

    // 延迟一小段时间，确保 Agora 引擎完全就绪
    logger.debug('🔧 等待300ms确保引擎就绪...');
    await Future.delayed(const Duration(milliseconds: 300));
    logger.debug('🔧 等待完成');

    if (!mounted || _disposed) {
      logger.debug('🔧 ⚠️ 页面已销毁或未mounted，终止设备初始化');
      return;
    }

    // 加载设备列表
    logger.debug('🔧 开始加载麦克风设备...');
    await _loadMicrophoneDevices();

    logger.debug('🔧 开始加载扬声器设备...');
    await _loadSpeakerDevices();

    if (widget.callType == CallType.video) {
      logger.debug('🔧 开始加载摄像头设备（视频通话）...');
      await _loadCameraDevices();
    } else {
      logger.debug('🔧 跳过摄像头设备加载（语音通话）');
    }

    logger.debug('============================================');
    logger.debug('🔧 设备列表初始化完成');
    logger.debug('   - 麦克风数量: ${_microphoneDevices.length}');
    logger.debug('   - 扬声器数量: ${_speakerDevices.length}');
    logger.debug('   - 摄像头数量: ${_cameraDevices.length}');

    // 🔴 修复：如果是视频通话，从最小化恢复时主动创建视频视图
    if (widget.callType == CallType.video && _agoraService.engine != null) {
      if (mounted && !_disposed) {
        setState(() {
          // 创建本地视频视图（如果尚未创建且是视频通话）
          if (_localVideoView == null && widget.callType == CallType.video) {
            logger.debug('🔧 主动创建本地视频视图（设备初始化完成）');
            _localVideoView = AgoraVideoView(
              controller: VideoViewController(
                rtcEngine: _agoraService.engine!,
                canvas: const VideoCanvas(uid: 0),
              ),
            );
            logger.debug('🔧 ✅ 本地视频视图创建完成');
          }

          // 创建远程视频视图（如果已有远程用户且尚未创建）
          // 优先使用 _remoteUid，如果为 null 则使用 currentCallUserId
          final remoteUid = _remoteUid ?? _agoraService.currentCallUserId;
          if (remoteUid != null && _remoteVideoView == null) {
            logger.debug('🔧 主动创建远程视频视图（从最小化恢复，remoteUid: $remoteUid）');
            _remoteVideoView = AgoraVideoView(
              controller: VideoViewController.remote(
                rtcEngine: _agoraService.engine!,
                canvas: VideoCanvas(uid: remoteUid),
                connection: RtcConnection(
                  channelId: _agoraService.currentChannelName,
                ),
              ),
            );
            // 更新 _remoteUid
            if (_remoteUid == null) {
              _remoteUid = remoteUid;
              logger.debug('🔧 已设置 _remoteUid = $remoteUid');
            }
            logger.debug('🔧 ✅ 远程视频视图创建完成');
          }
        });
      }
    }
    logger.debug('   - 当前摄像头ID: $_currentCameraDeviceId');
    logger.debug('============================================');
  }

  // 加载麦克风设备列表
  Future<void> _loadMicrophoneDevices() async {
    try {
      final devices = await _agoraService.getRecordingDevices();
      if (mounted && !_disposed) {
        setState(() {
          _microphoneDevices = devices;
          // 如果有设备，设置第一个为当前设备
          if (devices.isNotEmpty && devices[0].deviceId != null) {
            _currentMicDeviceId = devices[0].deviceId;
          }
        });
        logger.debug('🎤 加载了 ${devices.length} 个麦克风设备');

        // 只在首次加载时应用保存的配置
        if (_microphoneDevices.isNotEmpty && !_isLoadingConfig) {
          await _loadSavedDeviceConfig();
        }
      }
    } catch (e) {
      logger.debug('⚠️ 加载麦克风设备失败: $e');
    }
  }

  // 加载保存的设备配置
  Future<void> _loadSavedDeviceConfig() async {
    // 防止重复加载
    if (_isLoadingConfig) return;

    _isLoadingConfig = true;
    try {
      final config = widget.callType == CallType.voice
          ? await Storage.getVoiceCallDeviceConfig()
          : await Storage.getVideoCallDeviceConfig();

      if (config != null && mounted && !_disposed) {
        // 恢复麦克风配置
        if (config['microphoneDeviceId'] != null) {
          final micDeviceId = config['microphoneDeviceId'] as String;
          // 检查设备是否存在
          if (_microphoneDevices.any((d) => d.deviceId == micDeviceId)) {
            await _setMicrophoneDevice(micDeviceId);
            logger.debug('🎤 恢复麦克风设备: $micDeviceId');
          }
        }
        if (config['microphoneVolume'] != null) {
          final volume = (config['microphoneVolume'] as num).toDouble();
          await _setMicrophoneVolume(volume);
          logger.debug('🎤 恢复麦克风音量: $volume');
        }

        // 恢复扬声器配置（如果已加载扬声器设备）
        if (_speakerDevices.isNotEmpty) {
          if (config['speakerDeviceId'] != null) {
            final speakerDeviceId = config['speakerDeviceId'] as String;
            if (_speakerDevices.any((d) => d.deviceId == speakerDeviceId)) {
              await _setSpeakerDevice(speakerDeviceId);
              logger.debug('🔊 恢复扬声器设备: $speakerDeviceId');
            }
          }
          if (config['speakerVolume'] != null) {
            final volume = (config['speakerVolume'] as num).toDouble();
            await _setSpeakerVolume(volume);
            logger.debug('🔊 恢复扬声器音量: $volume');
          }
        }

        // 恢复摄像头配置（仅视频通话）
        if (widget.callType == CallType.video && _cameraDevices.isNotEmpty) {
          logger.debug('📹 [配置恢复] 开始恢复摄像头配置...');
          logger.debug('   - 摄像头设备数量: ${_cameraDevices.length}');
          if (config['cameraDeviceId'] != null) {
            final cameraDeviceId = config['cameraDeviceId'] as String;
            logger.debug('   - 保存的摄像头ID: $cameraDeviceId');

            final deviceExists = _cameraDevices.any(
              (d) => d.deviceId == cameraDeviceId,
            );
            logger.debug('   - 设备是否存在: $deviceExists');

            if (deviceExists) {
              logger.debug('📹 [配置恢复] 开始恢复摄像头设备: $cameraDeviceId');
              await _setCameraDevice(cameraDeviceId);
              logger.debug('📹 [配置恢复] ✅ 摄像头设备恢复完成');
            } else {
              logger.debug('📹 [配置恢复] ⚠️ 保存的摄像头设备不存在，使用默认设备');
            }
          } else {
            logger.debug('📹 [配置恢复] 没有保存的摄像头配置');
          }
        } else {
          if (widget.callType != CallType.video) {
            logger.debug('📹 [配置恢复] 跳过摄像头配置（不是视频通话）');
          } else {
            logger.debug('📹 [配置恢复] 跳过摄像头配置（设备列表为空）');
          }
        }
      }
    } catch (e) {
      logger.debug('⚠️ 加载保存的设备配置失败: $e');
    } finally {
      _isLoadingConfig = false;
    }
  }

  // 保存当前设备配置到本地
  Future<void> _saveCurrentDeviceConfig() async {
    // 如果正在加载配置，不保存（避免循环）
    if (_isLoadingConfig) {
      logger.debug('💾 跳过保存设备配置（正在加载配置中）');
      return;
    }

    try {
      logger.debug('💾 准备保存设备配置...');
      final config = <String, dynamic>{
        'microphoneDeviceId': _currentMicDeviceId,
        'microphoneVolume': _micVolume,
        'speakerDeviceId': _currentSpeakerDeviceId,
        'speakerVolume': _speakerVolume,
      };

      // 如果是视频通话，还需要保存摄像头配置
      if (widget.callType == CallType.video) {
        config['cameraDeviceId'] = _currentCameraDeviceId;
        logger.debug('💾 添加摄像头配置到保存列表: $_currentCameraDeviceId');
      }

      logger.debug('💾 设备配置内容:');
      logger.debug('   - 麦克风ID: ${config['microphoneDeviceId']}');
      logger.debug('   - 麦克风音量: ${config['microphoneVolume']}');
      logger.debug('   - 扬声器ID: ${config['speakerDeviceId']}');
      logger.debug('   - 扬声器音量: ${config['speakerVolume']}');
      if (widget.callType == CallType.video) {
        logger.debug('   - 摄像头ID: ${config['cameraDeviceId']}');
      }

      if (widget.callType == CallType.voice) {
        await Storage.saveVoiceCallDeviceConfig(config);
        logger.debug('💾 ✅ 语音通话设备配置已保存');
      } else {
        await Storage.saveVideoCallDeviceConfig(config);
        logger.debug('💾 ✅ 视频通话设备配置已保存');
      }
    } catch (e, stackTrace) {
      logger.debug('⚠️ 保存设备配置失败: $e');
      logger.debug('   堆栈: $stackTrace');
    }
  }

  // 设置麦克风设备
  Future<void> _setMicrophoneDevice(String deviceId) async {
    try {
      logger.debug('🎤 开始切换麦克风到: $deviceId');
      final success = await _agoraService.setRecordingDevice(deviceId);

      if (success && mounted) {
        setState(() {
          _currentMicDeviceId = deviceId;
        });
        logger.debug('✅ 麦克风切换成功，UI已更新');

        // 保存配置到本地
        await _saveCurrentDeviceConfig();
      } else if (!success) {
        logger.debug('❌ 麦克风切换失败');
      }
    } catch (e) {
      logger.debug('❌ 设置麦克风设备异常: $e');
    }
  }

  // 设置麦克风音量
  Future<void> _setMicrophoneVolume(double volume) async {
    setState(() {
      _micVolume = volume;
    });
    // 这里可以调用 Agora API 设置音量
    // 注意：Agora SDK 可能需要使用不同的 API
    try {
      // 音量范围通常是 0-100
      final volumeInt = volume.toInt();
      if (_agoraService.engine != null) {
        await _agoraService.engine!.adjustRecordingSignalVolume(volumeInt);
        logger.debug('🎤 设置麦克风音量: $volumeInt');
      }
      // 保存配置到本地
      await _saveCurrentDeviceConfig();
    } catch (e) {
      logger.debug('⚠️ 设置麦克风音量失败: $e');
    }
  }

  // 加载扬声器设备列表
  Future<void> _loadSpeakerDevices() async {
    try {
      final devices = await _agoraService.getPlaybackDevices();
      if (mounted && !_disposed) {
        setState(() {
          _speakerDevices = devices;
          // 如果有设备，设置第一个为当前设备
          if (devices.isNotEmpty && devices[0].deviceId != null) {
            _currentSpeakerDeviceId = devices[0].deviceId;
          }
        });
        logger.debug('🔊 加载了 ${devices.length} 个扬声器设备');
      }
    } catch (e) {
      logger.debug('⚠️ 加载扬声器设备失败: $e');
    }
  }

  // 设置扬声器设备
  Future<void> _setSpeakerDevice(String deviceId) async {
    try {
      logger.debug('🔊 开始切换扬声器到: $deviceId');
      final success = await _agoraService.setPlaybackDevice(deviceId);

      if (success && mounted) {
        setState(() {
          _currentSpeakerDeviceId = deviceId;
        });
        logger.debug('✅ 扬声器切换成功，UI已更新');

        // 保存配置到本地
        await _saveCurrentDeviceConfig();
      } else if (!success) {
        logger.debug('❌ 扬声器切换失败');
      }
    } catch (e) {
      logger.debug('❌ 设置扬声器设备异常: $e');
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
        logger.debug('🔊 扬声器音量已设置为: $volumeInt');
      }
      // 保存配置到本地
      await _saveCurrentDeviceConfig();
    } catch (e) {
      logger.debug('⚠️ 设置扬声器音量失败: $e');
    }
  }

  // 加载摄像头设备列表
  Future<void> _loadCameraDevices() async {
    try {
      logger.debug('📹 开始加载摄像头设备列表...');
      if (_agoraService.engine != null) {
        final deviceManager = _agoraService.engine!.getVideoDeviceManager();
        logger.debug('📹 已获取VideoDeviceManager');

        final devices = await deviceManager.enumerateVideoDevices();
        logger.debug('📹 枚举到 ${devices.length} 个摄像头设备');

        if (mounted && !_disposed) {
          setState(() {
            _cameraDevices = devices;
            // 如果有设备，设置第一个为当前设备
            if (devices.isNotEmpty && devices[0].deviceId != null) {
              final oldDeviceId = _currentCameraDeviceId;
              _currentCameraDeviceId = devices[0].deviceId;
              logger.debug(
                '📹 设置默认摄像头: $oldDeviceId -> ${_currentCameraDeviceId}',
              );
            }
          });

          logger.debug('📹 摄像头设备列表:');
          for (var i = 0; i < devices.length; i++) {
            logger.debug(
              '   [$i] ${devices[i].deviceName} (ID: ${devices[i].deviceId})',
            );
          }
        } else {
          logger.debug('📹 ⚠️ 页面已销毁或未mounted，跳过设备列表更新');
        }
      } else {
        logger.debug('📹 ⚠️ Agora引擎为null，无法加载摄像头设备');
      }
    } catch (e, stackTrace) {
      logger.debug('⚠️ 加载摄像头设备失败: $e');
      logger.debug('   堆栈: $stackTrace');
    }
  }

  // 设置摄像头设备
  Future<void> _setCameraDevice(String deviceId) async {
    try {
      if (_agoraService.engine != null && widget.callType == CallType.video) {
        logger.debug('============================================');
        logger.debug('📹 开始摄像头切换流程');
        logger.debug('============================================');
        logger.debug('📹 [步骤0] 切换前的状态:');
        logger.debug('   - 目标设备ID: $deviceId');
        logger.debug('   - 当前设备ID: $_currentCameraDeviceId');
        logger.debug('   - 摄像头开关状态: $_isCameraOn');
        logger.debug('   - 本地视频视图: ${_localVideoView != null ? "存在" : "null"}');
        logger.debug('   - mounted状态: $mounted');
        logger.debug('   - _disposed状态: $_disposed');

        // 打印所有可用的摄像头设备
        logger.debug('📹 当前所有摄像头设备:');
        for (var i = 0; i < _cameraDevices.length; i++) {
          final device = _cameraDevices[i];
          final isCurrent = device.deviceId == _currentCameraDeviceId;
          final isTarget = device.deviceId == deviceId;
          logger.debug(
            '   [$i] ${device.deviceName} (ID: ${device.deviceId}) ${isCurrent ? "[当前]" : ""} ${isTarget ? "[目标]" : ""}',
          );
        }

        // 🔴 重要：先停止当前视频预览
        logger.debug('📹 [步骤1] 准备停止视频预览...');
        await _agoraService.engine!.stopPreview();
        logger.debug('📹 [步骤1] ✅ 视频预览已停止');

        // 延迟一下，确保停止操作完成
        logger.debug('📹 [步骤2] 等待100ms确保预览停止完成...');
        await Future.delayed(const Duration(milliseconds: 100));
        logger.debug('📹 [步骤2] ✅ 等待完成');

        // 切换摄像头设备
        logger.debug('📹 [步骤3] 准备切换摄像头设备...');
        final deviceManager = _agoraService.engine!.getVideoDeviceManager();
        logger.debug('📹 [步骤3] 已获取VideoDeviceManager');

        await deviceManager.setDevice(deviceId);
        logger.debug('📹 [步骤3] ✅ setDevice调用完成: $deviceId');

        // 验证设备是否切换成功
        try {
          logger.debug('📹 [步骤3-验证] 验证设备切换...');
          final currentDevice = await deviceManager.getDevice();
          logger.debug('📹 [步骤3-验证] 当前设备ID: $currentDevice');
          if (currentDevice == deviceId) {
            logger.debug('📹 [步骤3-验证] ✅ 设备切换验证成功');
          } else {
            logger.debug(
              '📹 [步骤3-验证] ⚠️ 设备ID不匹配! 期望: $deviceId, 实际: $currentDevice',
            );
          }
        } catch (e) {
          logger.debug('📹 [步骤3-验证] ⚠️ 无法验证设备切换: $e');
        }

        // 延迟一下，确保设备切换完成
        logger.debug('📹 [步骤4] 等待100ms确保设备切换完成...');
        await Future.delayed(const Duration(milliseconds: 100));
        logger.debug('📹 [步骤4] ✅ 等待完成');

        // 🔴 重要：重新启动视频预览
        logger.debug('📹 [步骤5] 准备重新启动视频预览...');
        await _agoraService.engine!.startPreview();
        logger.debug('📹 [步骤5] ✅ 视频预览已重新启动');

        if (mounted) {
          logger.debug('📹 [步骤6] 准备更新UI状态...');
          setState(() {
            final oldDeviceId = _currentCameraDeviceId;
            _currentCameraDeviceId = deviceId;
            logger.debug('📹 [步骤6] 设备ID已更新: $oldDeviceId -> $deviceId');

            // 🔴 重要：重新创建本地视频视图以确保显示新摄像头的画面
            if (_agoraService.engine != null) {
              logger.debug('📹 [步骤6] 准备重新创建本地视频视图...');
              final oldView = _localVideoView;
              _localVideoView = AgoraVideoView(
                controller: VideoViewController(
                  rtcEngine: _agoraService.engine!,
                  canvas: const VideoCanvas(uid: 0),
                ),
              );
              logger.debug(
                '📹 [步骤6] ✅ 本地视频视图已重新创建 (旧视图: ${oldView != null ? "存在" : "null"})',
              );
            }
          });

          logger.debug('📹 [步骤7] 保存设备配置到本地...');
          await _saveCurrentDeviceConfig();
          logger.debug('📹 [步骤7] ✅ 配置已保存');

          logger.debug('============================================');
          logger.debug('📹 摄像头切换完成总结:');
          logger.debug('   - 最终设备ID: $_currentCameraDeviceId');
          logger.debug(
            '   - 本地视频视图: ${_localVideoView != null ? "存在" : "null"}',
          );
          logger.debug('   - 切换成功: ✅');
          logger.debug('============================================');
        } else {
          logger.debug('📹 ⚠️ 页面未mounted，跳过UI更新');
        }
      } else {
        logger.debug('📹 ⚠️ 无法切换摄像头:');
        logger.debug('   - engine存在: ${_agoraService.engine != null}');
        logger.debug('   - 通话类型: ${widget.callType}');
      }
    } catch (e, stackTrace) {
      logger.debug('============================================');
      logger.debug('📹 ❌ 设置摄像头设备失败');
      logger.debug('   - 错误: $e');
      logger.debug('   - 堆栈: $stackTrace');
      logger.debug('============================================');

      // 即使失败，也尝试重新启动预览
      try {
        logger.debug('📹 [恢复] 尝试重新启动预览...');
        if (_agoraService.engine != null) {
          await _agoraService.engine!.startPreview();
          logger.debug('📹 [恢复] ✅ 预览已重新启动');
        }
      } catch (e2) {
        logger.debug('📹 [恢复] ❌ 重启预览失败: $e2');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    logger.debug('📱 [build] VoiceCallPage.build 被调用，当前状态: $_callState');

    // 在每次build时都打印成员列表信息
    final isGroupCall = _currentGroupCallUserIds.isNotEmpty;
    logger.debug('📱 [build] 是否群组通话: $isGroupCall');
    if (isGroupCall) {
      logger.debug('📱 [build] 群组成员数量: ${_currentGroupCallUserIds.length}');
      logger.debug('📱 [build] 群组成员ID: ${_currentGroupCallUserIds}');
      logger.debug('📱 [build] 群组成员名称: ${_currentGroupCallDisplayNames}');
    }
    return PopScope(
      canPop: false, // 禁止直接返回
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        // 用户尝试返回时，关闭通话页面但不挂断通话，让主页面显示悬浮按钮
        if (!_isClosing && _callState != CallState.ended) {
          // 🔴 新方案：在 AgoraService 中设置全局标识
          final isGroupCall = _currentGroupCallUserIds.isNotEmpty;

          // 🔴 修复：群组通话时不显示悬浮按钮，因为群聊对话框中已有"加入通话"按钮
          if (isGroupCall) {
            logger.debug('📱 ========== PopScope: 群组通话返回 ==========');
            logger.debug('📱 群组通话不显示悬浮按钮，直接返回');
            
            // 设置最小化状态（保持通话继续）
            _agoraService.setCallMinimized(
              isMinimized: true,
              callUserId: widget.targetUserId,
              callDisplayName: widget.targetDisplayName,
              callType: widget.callType,
              isGroupCall: true,
              groupId: widget.groupId,
              groupCallUserIds: _currentGroupCallUserIds,
              groupCallDisplayNames: _currentGroupCallDisplayNames,
              connectedMemberIds: _connectedMemberIds,
            );

            if (mounted) {
              // 🔴 群组通话：不返回 showFloatingButton，不显示悬浮按钮
              Navigator.of(context).pop();
              logger.debug('📱 ========== PopScope: 群组通话返回完成 ==========');
            }
            return;
          }

          // 立即显示"正在最小化..."（仅单人通话）
          setState(() {
            _exitStatusText = '正在最小化...';
          });

          logger.debug('📱 ========== PopScope: 用户尝试返回 ==========');
          logger.debug('📱 widget.targetUserId: ${widget.targetUserId}');
          logger.debug(
            '📱 widget.targetDisplayName: ${widget.targetDisplayName}',
          );
          logger.debug('📱 widget.groupId: ${widget.groupId}');

          logger.debug('📱 准备调用 setCallMinimized (PopScope):');
          logger.debug('  - isGroupCall: $isGroupCall');

          _agoraService.setCallMinimized(
            isMinimized: true,
            callUserId: widget.targetUserId,
            callDisplayName: widget.targetDisplayName,
            callType: widget.callType,
            isGroupCall: isGroupCall,
            groupId: widget.groupId,
            groupCallUserIds: isGroupCall ? _currentGroupCallUserIds : null,
            groupCallDisplayNames: isGroupCall
                ? _currentGroupCallDisplayNames
                : null,
            connectedMemberIds: _connectedMemberIds, // 🔴 修复：保存已连接成员ID集合
          );

          logger.debug('📱 验证 AgoraService 状态 (PopScope):');
          logger.debug('  - isCallMinimized: ${_agoraService.isCallMinimized}');
          logger.debug(
            '  - minimizedCallUserId: ${_agoraService.minimizedCallUserId}',
          );

          if (mounted) {
            logger.debug('📱 准备关闭页面 (PopScope)');
            Navigator.of(
              context,
            ).pop({'showFloatingButton': true}); // 返回结果，告诉主页面显示悬浮按钮
            logger.debug('📱 ========== PopScope: 返回操作完成 ==========');
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF2C3E50),
        body: SafeArea(
          child: Stack(
            children: [
              // 🔴 视频区域全屏背景
              Positioned.fill(
                child: _buildMainContent(),
              ),

              // 🔴 顶部信息栏（浮在视频上方）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildTopBar(),
              ),

              // 🔴 底部控制按钮（浮在视频上方）
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildControlButtons(),
              ),

              // 麦克风设置弹窗 - 在最外层Stack中，确保可以点击
              if (_showMicPopup)
                Builder(
                  builder: (context) {
                    // 精确计算麦克风按钮的中心位置
                    final screenWidth = MediaQuery.of(context).size.width;
                    // 控制按钮区域：左右padding各40px
                    // Row with spaceEvenly: 三个按钮均匀分布
                    // 麦克风按钮的实际宽度包括文字，约80-90px
                    // 对于spaceEvenly布局，第一个按钮大约在可用宽度的1/5位置
                    final availableWidth = screenWidth - 80;
                    final estimatedButtonWidth = 85; // 麦克风按钮估计宽度（圆形56px + 文字宽度）
                    // spaceEvenly: [space] btn1 [space] btn2 [space] btn3 [space]
                    // 4个space，3个button
                    final totalButtonsWidth = estimatedButtonWidth * 3;
                    final spaceWidth = (availableWidth - totalButtonsWidth) / 4;
                    final buttonCenterX =
                        40 + spaceWidth + estimatedButtonWidth / 2;
                    // 弹窗宽度280px，让弹窗中心对齐按钮中心
                    final popupLeft = buttonCenterX - 140;

                    return Positioned(
                      bottom: widget.callType == CallType.voice
                          ? 60
                          : 170, // 语音通话更近，视频通话稍远
                      left: popupLeft, // 弹窗左边距
                      child: MouseRegion(
                        onExit: (_) {
                          logger.debug('🖱️ 鼠标移出整个hover区域，关闭弹窗');
                          setState(() {
                            _showMicPopup = false;
                          });
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 灰色弹窗
                            Material(
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
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        16,
                                        8,
                                      ),
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
                                        constraints: const BoxConstraints(
                                          maxHeight: 200,
                                        ),
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: _microphoneDevices.map((
                                              device,
                                            ) {
                                              final isSelected =
                                                  device.deviceId ==
                                                  _currentMicDeviceId;
                                              return InkWell(
                                                onTap: () {
                                                  logger.debug(
                                                    '🎤 点击麦克风设备: ${device.deviceName}',
                                                  );
                                                  if (device.deviceId != null) {
                                                    _setMicrophoneDevice(
                                                      device.deviceId!,
                                                    );
                                                  }
                                                },
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
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
                                                            ? Icons
                                                                  .radio_button_checked
                                                            : Icons
                                                                  .radio_button_unchecked,
                                                        color: Colors.white70,
                                                        size: 18,
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          device.deviceName ??
                                                              '未知设备',
                                                          style: TextStyle(
                                                            color: isSelected
                                                                ? Colors.white
                                                                : Colors
                                                                      .white70,
                                                            fontSize: 13,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
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
                                      onTap: () {
                                        logger.debug('🎤 点击切换静音');
                                        _toggleMute();
                                      },
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
                                              _isMuted
                                                  ? Icons.mic
                                                  : Icons.mic_off,
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
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        16,
                                        8,
                                      ),
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
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        16,
                                      ),
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
                                                inactiveTrackColor: Color(
                                                  0xFF666666,
                                                ),
                                                thumbColor: Colors.white,
                                                overlayColor: Color(0x33FFFFFF),
                                                trackHeight: 3,
                                              ),
                                              child: Slider(
                                                value: _micVolume,
                                                min: 0,
                                                max: 100,
                                                onChanged: (value) {
                                                  logger.debug(
                                                    '🎤 调节音量: $value',
                                                  );
                                                  _setMicrophoneVolume(value);
                                                },
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

                            const SizedBox(height: 8), // 弹窗与按钮之间的小间距
                            // 透明覆盖区域 - 覆盖按钮，使整个区域连贯，可点击切换麦克风
                            Align(
                              alignment: Alignment.center,
                              child: GestureDetector(
                                onTap: () {
                                  logger.debug('🎤 点击透明区域切换麦克风');
                                  _toggleMute();
                                },
                                child: Container(
                                  width: 80, // 按钮宽度
                                  height: 76, // 按钮高度（56圆形 + 8间距 + 12文字高度）
                                  color: Colors.transparent, // 透明背景
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

              // 扬声器设置弹窗 - 在最外层Stack中，确保可以点击
              if (_showSpeakerPopup)
                Builder(
                  builder: (context) {
                    // 精确计算扬声器按钮的中心位置
                    final screenWidth = MediaQuery.of(context).size.width;
                    final availableWidth = screenWidth - 80;
                    final estimatedButtonWidth = 85;
                    // spaceEvenly: [space] btn1 [space] btn2 [space] btn3 [space]
                    final totalButtonsWidth = estimatedButtonWidth * 3;
                    final spaceWidth = (availableWidth - totalButtonsWidth) / 4;
                    // 扬声器是第三个按钮（右侧5/6位置）
                    final buttonCenterX =
                        40 + spaceWidth * 3 + estimatedButtonWidth * 2.5;
                    final popupLeft = buttonCenterX - 140;

                    return Positioned(
                      bottom: widget.callType == CallType.voice
                          ? 60
                          : 170, // 语音通话更近，视频通话稍远
                      left: popupLeft, // 弹窗左边距
                      child: MouseRegion(
                        onExit: (_) {
                          logger.debug('🖱️ 鼠标移出扬声器hover区域，关闭弹窗');
                          setState(() {
                            _showSpeakerPopup = false;
                          });
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 灰色弹窗
                            Material(
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
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        16,
                                        8,
                                      ),
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
                                        constraints: const BoxConstraints(
                                          maxHeight: 200,
                                        ),
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: _speakerDevices.map((
                                              device,
                                            ) {
                                              final isSelected =
                                                  device.deviceId ==
                                                  _currentSpeakerDeviceId;
                                              return InkWell(
                                                onTap: () {
                                                  logger.debug(
                                                    '🔊 点击扬声器设备: ${device.deviceName}',
                                                  );
                                                  if (device.deviceId != null) {
                                                    _setSpeakerDevice(
                                                      device.deviceId!,
                                                    );
                                                  }
                                                },
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
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
                                                            ? Icons
                                                                  .radio_button_checked
                                                            : Icons
                                                                  .radio_button_unchecked,
                                                        color: Colors.white70,
                                                        size: 18,
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          device.deviceName ??
                                                              '未知设备',
                                                          style: TextStyle(
                                                            color: isSelected
                                                                ? Colors.white
                                                                : Colors
                                                                      .white70,
                                                            fontSize: 13,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
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
                                      onTap: () {
                                        logger.debug('🔊 点击切换扬声器/听筒');
                                        _toggleSpeaker();
                                      },
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
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        16,
                                        8,
                                      ),
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
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        16,
                                      ),
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
                                                inactiveTrackColor: Color(
                                                  0xFF666666,
                                                ),
                                                thumbColor: Colors.white,
                                                overlayColor: Color(0x33FFFFFF),
                                                trackHeight: 3,
                                              ),
                                              child: Slider(
                                                value: _speakerVolume,
                                                min: 0,
                                                max: 100,
                                                onChanged: (value) {
                                                  logger.debug(
                                                    '🔊 调节音量: $value',
                                                  );
                                                  _setSpeakerVolume(value);
                                                },
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

                            const SizedBox(height: 8), // 弹窗与按钮之间的小间距
                            // 透明覆盖区域 - 覆盖按钮，使整个区域连贯，可点击切换扬声器
                            Align(
                              alignment: Alignment.center,
                              child: GestureDetector(
                                onTap: () {
                                  logger.debug('🔊 点击透明区域切换扬声器');
                                  _toggleSpeaker();
                                },
                                child: Container(
                                  width: 80, // 按钮宽度
                                  height: 76, // 按钮高度（56圆形 + 8间距 + 12文字高度）
                                  color: Colors.transparent, // 透明背景
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

              // 摄像头设置弹窗 - 在最外层Stack中，确保可以点击
              if (_isCameraPopupShown)
                Builder(
                  builder: (context) {
                    // 精确计算摄像头按钮的中心位置（视频通话时在中间位置）
                    final screenWidth = MediaQuery.of(context).size.width;
                    final availableWidth = screenWidth - 80;
                    final estimatedButtonWidth = 85;
                    final totalButtonsWidth = estimatedButtonWidth * 3;
                    final spaceWidth = (availableWidth - totalButtonsWidth) / 4;
                    // 摄像头是第二个按钮（中间位置，3/6）
                    final buttonCenterX =
                        40 + spaceWidth * 2 + estimatedButtonWidth * 1.5;
                    final popupLeft = buttonCenterX - 140;

                    return Positioned(
                      bottom: 170, // 视频通话摄像头弹窗位置
                      left: popupLeft, // 弹窗左边距
                      child: MouseRegion(
                        onExit: (_) {
                          logger.debug(
                            '============================================',
                          );
                          logger.debug('🖱️ 鼠标移出摄像头hover区域，关闭弹窗');
                          logger.debug('   - 当前摄像头状态: $_isCameraOn');
                          logger.debug('   - 当前设备ID: $_currentCameraDeviceId');
                          logger.debug(
                            '============================================',
                          );
                          setState(() {
                            _isCameraPopupShown = false;
                          });
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 灰色弹窗
                            Material(
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
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        16,
                                        8,
                                      ),
                                      child: Text(
                                        '选择摄像头',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),

                                    // 摄像头设备列表
                                    if (_cameraDevices.isNotEmpty)
                                      Container(
                                        constraints: const BoxConstraints(
                                          maxHeight: 200,
                                        ),
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: _cameraDevices.map((
                                              device,
                                            ) {
                                              final isSelected =
                                                  device.deviceId ==
                                                  _currentCameraDeviceId;
                                              return InkWell(
                                                onTap: () {
                                                  logger.debug(
                                                    '============================================',
                                                  );
                                                  logger.debug('📹 用户点击摄像头设备');
                                                  logger.debug(
                                                    '   - 设备名称: ${device.deviceName}',
                                                  );
                                                  logger.debug(
                                                    '   - 设备ID: ${device.deviceId}',
                                                  );
                                                  logger.debug(
                                                    '   - 当前设备ID: $_currentCameraDeviceId',
                                                  );
                                                  logger.debug(
                                                    '   - 是否相同: ${device.deviceId == _currentCameraDeviceId}',
                                                  );
                                                  logger.debug(
                                                    '============================================',
                                                  );

                                                  if (device.deviceId != null) {
                                                    if (device.deviceId ==
                                                        _currentCameraDeviceId) {
                                                      logger.debug(
                                                        '📹 ⚠️ 点击的是当前正在使用的设备，跳过切换',
                                                      );
                                                    } else {
                                                      _setCameraDevice(
                                                        device.deviceId!,
                                                      );
                                                    }
                                                  } else {
                                                    logger.debug(
                                                      '📹 ⚠️ 设备ID为null，无法切换',
                                                    );
                                                  }
                                                },
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
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
                                                            ? Icons
                                                                  .radio_button_checked
                                                            : Icons
                                                                  .radio_button_unchecked,
                                                        color: Colors.white70,
                                                        size: 18,
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          device.deviceName ??
                                                              '未知设备',
                                                          style: TextStyle(
                                                            color: isSelected
                                                                ? Colors.white
                                                                : Colors
                                                                      .white70,
                                                            fontSize: 13,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
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

                                    // 开关摄像头按钮
                                    InkWell(
                                      onTap: () {
                                        logger.debug('📹 点击切换摄像头开关');
                                        _toggleCamera();
                                      },
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

                            const SizedBox(height: 8), // 弹窗与按钮之间的小间距
                            // 透明覆盖区域 - 覆盖按钮，使整个区域连贯，可点击切换摄像头
                            Align(
                              alignment: Alignment.center,
                              child: GestureDetector(
                                onTap: () {
                                  logger.debug('📹 点击透明区域切换摄像头');
                                  _toggleCamera();
                                },
                                child: Container(
                                  width: 80, // 按钮宽度
                                  height: 76, // 按钮高度（56圆形 + 8间距 + 12文字高度）
                                  color: Colors.transparent, // 透明背景
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 顶部信息
  Widget _buildTopBar() {
    return Container(
      // 添加渐变背景，从顶部深色渐变到透明，确保文字清晰可见
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.5),
            Colors.transparent,
          ],
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              logger.debug('📱 ========== 返回按钮被点击 ==========');
              logger.debug('📱 _isClosing: $_isClosing');
              logger.debug('📱 _callState: $_callState');
              logger.debug('📱 mounted: $mounted');
              logger.debug('📱 widget.targetUserId: ${widget.targetUserId}');
              logger.debug(
                '📱 widget.targetDisplayName: ${widget.targetDisplayName}',
              );
              logger.debug('📱 widget.callType: ${widget.callType}');
              logger.debug('📱 widget.groupId: ${widget.groupId}');
              logger.debug(
                '📱 _currentGroupCallUserIds: $_currentGroupCallUserIds',
              );

              // 点击返回按钮时，关闭通话页面但不挂断通话，让主页面显示悬浮按钮
              if (!_isClosing && _callState != CallState.ended) {
                logger.debug('📱 ✅ 条件满足，准备设置最小化标识');

                // 🔴 新方案：在 AgoraService 中设置全局标识
                final isGroupCall = _currentGroupCallUserIds.isNotEmpty;

                // 🔴 修复：群组通话时不显示悬浮按钮，因为群聊对话框中已有"加入通话"按钮
                if (isGroupCall) {
                  logger.debug('📱 群组通话不显示悬浮按钮，直接返回');
                  
                  _agoraService.setCallMinimized(
                    isMinimized: true,
                    callUserId: widget.targetUserId,
                    callDisplayName: widget.targetDisplayName,
                    callType: widget.callType,
                    isGroupCall: true,
                    groupId: widget.groupId,
                    groupCallUserIds: _currentGroupCallUserIds,
                    groupCallDisplayNames: _currentGroupCallDisplayNames,
                    connectedMemberIds: _connectedMemberIds,
                  );

                  Navigator.of(context).pop(); // 不返回 showFloatingButton
                  logger.debug('📱 ========== 群组通话返回完成 ==========');
                  return;
                }

                logger.debug('📱 准备调用 setCallMinimized:');
                logger.debug('  - isMinimized: true');
                logger.debug('  - callUserId: ${widget.targetUserId}');
                logger.debug(
                  '  - callDisplayName: ${widget.targetDisplayName}',
                );
                logger.debug('  - callType: ${widget.callType}');
                logger.debug('  - isGroupCall: $isGroupCall');
                logger.debug('  - groupId: ${widget.groupId}');

                _agoraService.setCallMinimized(
                  isMinimized: true,
                  callUserId: widget.targetUserId,
                  callDisplayName: widget.targetDisplayName,
                  callType: widget.callType,
                  isGroupCall: isGroupCall,
                  groupId: widget.groupId,
                  groupCallUserIds: isGroupCall
                      ? _currentGroupCallUserIds
                      : null,
                  groupCallDisplayNames: isGroupCall
                      ? _currentGroupCallDisplayNames
                      : null,
                  connectedMemberIds: _connectedMemberIds, // 🔴 修复：保存已连接成员ID集合
                );

                logger.debug('📱 ✅ setCallMinimized 调用完成');
                logger.debug('📱 验证 AgoraService 状态:');
                logger.debug(
                  '  - isCallMinimized: ${_agoraService.isCallMinimized}',
                );
                logger.debug(
                  '  - minimizedCallUserId: ${_agoraService.minimizedCallUserId}',
                );
                logger.debug(
                  '  - minimizedCallDisplayName: ${_agoraService.minimizedCallDisplayName}',
                );
                logger.debug(
                  '  - minimizedCallType: ${_agoraService.minimizedCallType}',
                );

                logger.debug(
                  '📱 准备关闭通话页面，返回结果: {\'showFloatingButton\': true}',
                );
                Navigator.of(context).pop({'showFloatingButton': true});
                logger.debug('📱 ========== 返回操作完成 ==========');
              } else {
                logger.debug('📱 ❌ 不能返回，因为页面正在关闭或通话已结束');
              }
            },
            tooltip: '返回',
          ),
          Text(
            widget.callType == CallType.voice ? '语音通话' : '视频通话',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 48), // 占位
        ],
      ),
    );
  }

  // 主要内容区域
  Widget _buildMainContent() {
    if (widget.callType == CallType.video &&
        _callState == CallState.connected) {
      // 视频通话界面
      return _buildVideoCallContent();
    } else {
      // 语音通话界面
      return _buildVoiceCallContent();
    }
  }

  // 语音通话内容
  Widget _buildVoiceCallContent() {
    // 检查是否是群组通话
    final isGroupCall = _currentGroupCallUserIds.isNotEmpty;

    logger.debug('🎨 _buildVoiceCallContent 被调用');
    logger.debug('🎨 _currentGroupCallUserIds: ${_currentGroupCallUserIds}');
    logger.debug(
      '🎨 _currentGroupCallUserIds.isNotEmpty: ${_currentGroupCallUserIds.isNotEmpty}',
    );
    logger.debug('🎨 isGroupCall: $isGroupCall');

    if (isGroupCall) {
      logger.debug('🎨 显示群组通话界面');
      // 群组通话界面
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 状态文本
          _callState == CallState.connected
              ? CallDurationWidget(
                  initialDuration: _callDuration,
                  isConnected: true,
                  overrideText: _exitStatusText,
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                )
              : Text(
                  _statusText,
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                ),

          const SizedBox(height: 40),

          // 群组成员水平滚动区域（带左右箭头）
          _buildGroupMembersScrollView(),

          const SizedBox(height: 40),
        ],
      );
    } else {
      logger.debug('🎨 显示单人通话界面');
      // 单人通话界面：中间显示对方头像/名称，右下角增加自己头像的小圆角
      return Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 对方头像 - 居中显示
              Center(
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2),
                    borderRadius: BorderRadius.circular(60),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(60),
                    child: (_targetAvatarUrl != null &&
                            _targetAvatarUrl!.isNotEmpty)
                        ? Image.network(
                            _targetAvatarUrl!,
                            fit: BoxFit.cover,
                          )
                        : Center(
                            child: Text(
                              () {
                                final truncatedName = _truncateDisplayName(
                                  widget.targetDisplayName,
                                );
                                return truncatedName.length >= 2
                                    ? truncatedName
                                        .substring(truncatedName.length - 2)
                                    : truncatedName;
                              }(),
                              style: const TextStyle(
                                fontSize: 40,
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 名称 - 超过9个字符添加省略号
              Center(
                child: Text(
                  _truncateDisplayName(widget.targetDisplayName),
                  style: const TextStyle(
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

              const SizedBox(height: 12),

              // 状态文本或通话时长
              _callState == CallState.connected
                  ? CallDurationWidget(
                      initialDuration: _callDuration,
                      isConnected: true,
                      overrideText: _exitStatusText,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    )
                  : Text(
                      _statusText,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
            ],
          ),

          // 右上角显示当前用户的小头像（如果有）
          if (_currentUserAvatarUrl != null &&
              _currentUserAvatarUrl!.isNotEmpty)
            Positioned(
              right: 16,
              top: 60,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white70, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Image.network(
                    _currentUserAvatarUrl!,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
        ],
      );
    }
  }

  // 构建群组成员水平滚动视图（带左右箭头按钮）
  Widget _buildGroupMembersScrollView() {
    // 🔴 修改：显示所有成员（包括未连接的），与群组视频通话保持一致
    final memberCount = _currentGroupCallUserIds.length;
    
    // 总项目数包括所有成员数量 + 1个"+"按钮
    final totalItemCount = memberCount + 1;

    logger.debug('🎨 ========== _buildGroupMembersScrollView 开始构建 ==========');
    logger.debug('🎨 总成员数量: $memberCount');
    logger.debug('🎨 已连接成员数量: ${_connectedMemberIds.length}');
    logger.debug('🎨 totalItemCount: $totalItemCount');
    logger.debug(
      '🎨 _currentGroupCallUserIds.length: ${_currentGroupCallUserIds.length}',
    );
    logger.debug(
      '🎨 _currentGroupCallDisplayNames.length: ${_currentGroupCallDisplayNames.length}',
    );

    // 根据平台选择不同的尺寸
    final isMobile = ResponsiveHelper.isMobile(context);
    final containerHeight = isMobile ? 400.0 : 200.0;
    final horizontalPadding = isMobile ? 10.0 : 40.0;
    final arrowWidth = isMobile ? 60.0 : 100.0;
    final arrowSize = isMobile ? 28.0 : 32.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 计算每个成员的宽度（统一为112）
          const memberItemWidth = 112.0;
          // 计算成员列表的总宽度（包括首尾额外的padding和"+"按钮）
          final totalMembersWidth = totalItemCount * memberItemWidth + 40;

          // 判断是否需要显示箭头：内容宽度超过可用宽度
          final needArrows = totalMembersWidth > constraints.maxWidth;

          // 计算中间区域的宽度
          final centerWidth = needArrows
              ? constraints.maxWidth - arrowWidth * 2
              : constraints.maxWidth;

          return SizedBox(
            height: containerHeight,
            child: Row(
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
                              children: _buildMemberList(),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: _buildMemberList(),
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
            ),
          );
        },
      ),
    );
  }

  // 构建成员列表
  List<Widget> _buildMemberList() {
    logger.debug('🎨 ========== _buildMemberList 开始构建 ==========');
    logger.debug('🎨 _currentGroupCallUserIds: ${_currentGroupCallUserIds}');
    logger.debug(
      '🎨 _currentGroupCallDisplayNames: ${_currentGroupCallDisplayNames}',
    );

    // 🔴 修改：显示所有成员（包括未连接的），与群组视频通话保持一致
    final memberCount = _currentGroupCallUserIds.length;
    logger.debug('🎨 总成员数量: $memberCount');
    logger.debug('🎨 已连接成员ID: $_connectedMemberIds');

    // 根据平台选择不同的尺寸
    final isMobile = ResponsiveHelper.isMobile(context);
    // 头像和文字尺寸保持一致（移动端和PC端相同）
    const avatarSize = 80.0;
    const avatarRadius = 40.0;
    const avatarFontSize = 24.0;
    const nameFontSize = 14.0;
    const nameFontWeight = FontWeight.w400;
    const statusFontSize = 12.0;
    const verticalSpacing1 = 12.0;
    const verticalSpacing2 = 8.0;

    List<Widget> memberWidgets = List.generate(memberCount, (index) {
      final userId = _currentGroupCallUserIds[index];
      final displayName = index < _currentGroupCallDisplayNames.length
          ? _currentGroupCallDisplayNames[index]
          : 'User $userId';

      // 获取头像URL
      String? avatarUrl;
      if (index < _currentGroupCallAvatarUrls.length) {
        avatarUrl = _currentGroupCallAvatarUrls[index];
      }
      // 如果是当前用户且没头像URL，使用当前用户头像
      if ((widget.currentUserId != null && userId == widget.currentUserId) &&
          (avatarUrl == null || avatarUrl.isEmpty)) {
        avatarUrl = _currentUserAvatarUrl;
      }

      // 🔴 修改：判断成员是否已连接（当前用户始终视为已连接）
      final isConnected = (widget.currentUserId != null && userId == widget.currentUserId) || 
                         _connectedMemberIds.contains(userId);

      logger.debug('🎨 构建成员[$index]: ID=$userId, 名称=$displayName, 已连接=$isConnected');

      final itemPaddingLeft = isMobile
          ? (index == 0 ? 12.0 : 8.0)
          : (index == 0 ? 20.0 : 16.0);
      final itemPaddingRight = isMobile
          ? (index == memberCount - 1 ? 12.0 : 8.0)
          : (index == memberCount - 1 ? 20.0 : 16.0);

      return Padding(
        padding: EdgeInsets.only(
          left: itemPaddingLeft,
          right: itemPaddingRight,
          top: 20,
          bottom: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 头像 - 优先显示头像URL，否则回退到名称缩写
            Center(
              child: Container(
                width: avatarSize,
                height: avatarSize,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  borderRadius: BorderRadius.circular(avatarRadius),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(avatarRadius),
                  child: (avatarUrl != null && avatarUrl.isNotEmpty)
                      ? Image.network(
                          avatarUrl,
                          fit: BoxFit.cover,
                        )
                      : Center(
                          child: Text(
                            () {
                              final truncatedName =
                                  _truncateDisplayName(displayName);
                              return truncatedName.length >= 2
                                  ? truncatedName.substring(
                                      truncatedName.length - 2,
                                    )
                                  : truncatedName;
                            }(),
                            style: TextStyle(
                              fontSize: avatarFontSize,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                ),
              ),
            ),
            SizedBox(height: verticalSpacing1),
            // 名称 - 超过9个字符添加省略号
            SizedBox(
              width: 112, // 固定宽度，确保文本居中
              child: Text(
                _truncateDisplayName(displayName),
                style: TextStyle(
                  fontSize: nameFontSize,
                  color: Colors.white,
                  fontWeight: nameFontWeight,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
            SizedBox(height: verticalSpacing2),
            // 🔴 修改：根据实际连接状态显示（与群组视频通话保持一致）
            Text(
              isConnected ? '已连接' : '正在呼叫...',
              style: TextStyle(
                fontSize: statusFontSize,
                color: isConnected ? Colors.greenAccent : Colors.white70,
                fontWeight: isConnected ? FontWeight.w500 : FontWeight.normal,
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

  // 构建添加成员按钮
  Widget _buildAddMemberButton() {
    // 根据平台选择不同的尺寸
    final isMobile = ResponsiveHelper.isMobile(context);
    // 按钮尺寸保持一致（移动端和PC端相同）
    const buttonSize = 80.0;
    const buttonRadius = 40.0;
    const iconSize = 32.0;
    const labelFontSize = 14.0;
    const labelFontWeight = FontWeight.w400;
    const verticalSpacing = 12.0;
    const bottomSpacing = 20.0;
    final paddingLeft = isMobile ? 8.0 : 16.0;
    final paddingRight = isMobile ? 12.0 : 20.0;

    return Padding(
      padding: EdgeInsets.only(
        left: paddingLeft,
        right: paddingRight,
        top: 20,
        bottom: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // "+"按钮
          GestureDetector(
            onTap: _showAddMemberDialog,
            child: Container(
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(buttonRadius),
                border: Border.all(
                  color: Colors.white.withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: Center(
                child: Icon(Icons.add, size: iconSize, color: Colors.white),
              ),
            ),
          ),
          SizedBox(height: verticalSpacing),
          // 标签
          Text(
            '邀请成员',
            style: TextStyle(
              fontSize: labelFontSize,
              color: Colors.white,
              fontWeight: labelFontWeight,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: bottomSpacing), // 占位，保持与其他成员对齐
        ],
      ),
    );
  }

  // 视频通话内容
  // 🔴 新增：构建本地视频或摄像头关闭占位符
  Widget _buildLocalVideoOrPlaceholder() {
    if (_isCameraOn && _localVideoView != null) {
      return _localVideoView!;
    } else {
      // 摄像头关闭时显示占位符
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off, size: 48, color: Colors.white54),
              SizedBox(height: 8),
              Text(
                '摄像头已关闭',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
  }

  // 🔴 新增：构建远程视频或摄像头关闭占位符
  Widget _buildRemoteVideoOrPlaceholder({bool isSmallView = false}) {
    if (!_isRemoteVideoMuted && _remoteVideoView != null) {
      return _remoteVideoView!;
    } else {
      // 远程用户摄像头关闭时显示占位符
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.videocam_off,
                size: isSmallView ? 32 : 48,
                color: Colors.white54,
              ),
              if (!isSmallView) ...[
                const SizedBox(height: 8),
                const Text(
                  '对方摄像头已关闭',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ],
          ),
        ),
      );
    }
  }

  Widget _buildVideoCallContent() {
    logger.debug('📹 [布局调试] 开始构建视频布局');
    logger.debug('📹 [布局调试] _isRemoteVideoInMainView: $_isRemoteVideoInMainView');
    logger.debug('📹 [布局调试] _localVideoView: ${_localVideoView != null ? "存在" : "null"}');
    logger.debug('📹 [布局调试] _remoteVideoView: ${_remoteVideoView != null ? "存在" : "null"}');
    logger.debug('📹 [布局调试] _isCameraOn: $_isCameraOn');
    logger.debug('📹 [布局调试] _isRemoteVideoMuted: $_isRemoteVideoMuted');
    
    return Stack(
      fit: StackFit.expand,
      children: [
        // 大框视频 - 直接使用条件判断，避免null问题
        // 🔴 修复：远程视频在大框时，根据远程摄像头状态显示视频或占位符
        if (_isRemoteVideoInMainView)
          Positioned.fill(child: _buildRemoteVideoOrPlaceholder())
        else if (!_isRemoteVideoInMainView)
          // 🔴 修复：本地视频在大框时，根据摄像头状态显示视频或占位符
          Positioned.fill(child: _buildLocalVideoOrPlaceholder())
        else
          // 如果没有对应的视频，显示黑色背景
          Container(
            color: Colors.black,
            child: Center(
              child: Text(
                _isRemoteVideoInMainView ? '等待对方视频...' : '等待本地视频...',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
            ),
          ),

        // 小框视频 - 直接使用条件判断，避免null问题
        // 🔴 修复：本地视频在小框时，根据摄像头状态显示视频或占位符
        if (_isRemoteVideoInMainView)
          Positioned(
            top: 20,
            right: 20,
            child: GestureDetector(
              onTap: () {
                logger.debug('📹 [点击事件] 本地视频小框被点击，准备切换画面');
                _swapVideoViews();
              },
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildLocalVideoOrPlaceholder(),
                ),
              ),
            ),
          )
        // 🔴 修复：远程视频在小框时，根据远程摄像头状态显示视频或占位符
        else if (!_isRemoteVideoInMainView)
          Positioned(
            top: 20,
            right: 20,
            child: GestureDetector(
              onTap: () {
                logger.debug('📹 [点击事件] 远程视频小框被点击，准备切换画面');
                _swapVideoViews();
              },
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildRemoteVideoOrPlaceholder(isSmallView: true),
                ),
              ),
            ),
          ),

        // 顶部信息（视频模式）
        Positioned(
          top: 20,
          left: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _truncateDisplayName(widget.targetDisplayName),
                style: const TextStyle(
                  fontSize: 20,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                ),
              ),
              const SizedBox(height: 4),
              CallDurationWidget(
                initialDuration: _callDuration,
                isConnected: _callState == CallState.connected,
                overrideText: _exitStatusText,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),


      ],
    );
  }

  // 控制按钮区域
  Widget _buildControlButtons() {
    if (_callState == CallState.ringing && widget.isIncoming) {
      // 来电时显示接听和拒接按钮
      return Container(
        // 添加渐变背景，从底部深色渐变到透明，确保按钮清晰可见
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withOpacity(0.5),
              Colors.transparent,
            ],
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 拒接按钮
            _buildCircleButton(
              icon: Icons.call_end,
              color: Colors.red,
              size: 64,
              onPressed: _rejectCall,
            ),
            // 接听按钮
            _buildCircleButton(
              icon: Icons.call,
              color: Colors.green,
              size: 64,
              onPressed: _acceptCall,
            ),
          ],
        ),
      );
    } else {
      // 通话中显示控制按钮
      if (widget.callType == CallType.video) {
        // 视频通话：两排布局
        return Container(
          // 添加渐变背景，从底部深色渐变到透明
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.5),
                Colors.transparent,
              ],
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 第一排：麦克风、摄像头、扬声器
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 麦克风按钮（带悬停弹窗）
                  _buildMicrophoneButton(),

                  // 摄像头按钮
                  _buildCameraButton(),

                  // 扬声器按钮
                  _buildSpeakerButton(),
                ],
              ),

              const SizedBox(height: 30), // 两排之间的间距
              // 第二排：挂断按钮（居中）
              Column(
                children: [
                  _buildCircleButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    size: 56,
                    onPressed: _endCall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '挂断',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        );
      } else {
        // 语音通话：单排布局
        return Container(
          // 添加渐变背景，从底部深色渐变到透明
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.5),
                Colors.transparent,
              ],
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 麦克风按钮（带悬停弹窗）
              _buildMicrophoneButton(),

              // 挂断按钮
              Column(
                children: [
                  _buildCircleButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    size: 56,
                    onPressed: _endCall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '挂断',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),

              // 扬声器按钮
              _buildSpeakerButton(),
            ],
          ),
        );
      }
    }
  }

  // 圆形按钮（带点击反馈效果）
  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    Color? iconColor,
    required double size,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(size / 2),
        splashColor: Colors.white.withOpacity(0.3), // 点击水波纹颜色
        highlightColor: Colors.white.withOpacity(0.1), // 按下时的高亮颜色
        child: Ink(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(size / 2),
          ),
          child: Center(
            child: Icon(
              icon,
              color: iconColor ?? Colors.white,
              size: size * 0.5,
            ),
          ),
        ),
      ),
    );
  }

  // 显示麦克风弹窗
  void _showMicrophonePopup() {
    _popupCloseTimer?.cancel();
    if (!_showMicPopup && mounted) {
      setState(() {
        _showMicPopup = true;
      });
    }
  }

  // 显示扬声器弹窗
  void _showSpeakerTestPopup() {
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
    logger.debug('📹 尝试显示摄像头弹窗');
    logger.debug('   - 当前弹窗状态: $_isCameraPopupShown');
    logger.debug('   - mounted状态: $mounted');
    logger.debug('   - 设备数量: ${_cameraDevices.length}');
    logger.debug('   - 当前设备ID: $_currentCameraDeviceId');

    if (!_isCameraPopupShown && mounted) {
      setState(() {
        _isCameraPopupShown = true;
      });
      // 如果设备列表为空，尝试重新加载
      if (_cameraDevices.isEmpty) {
        logger.debug('📹 设备列表为空，重新加载...');
        _loadCameraDevices();
      }
      logger.debug('📹 ✅ 摄像头弹窗已显示');
    } else {
      logger.debug('📹 ⚠️ 无法显示摄像头弹窗（弹窗已显示或页面未mounted）');
    }
  }

  // 麦克风按钮（可点击切换状态，悬停显示弹窗）
  Widget _buildMicrophoneButton() {
    return MouseRegion(
      onEnter: (_) {
        logger.debug('🖱️ 鼠标悬停在麦克风按钮上');
        _showMicrophonePopup();
      },
      child: Column(
        children: [
          _buildCircleButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            color: _isMuted ? Colors.white24 : Colors.white,
            iconColor: _isMuted ? Colors.white : Colors.black87,
            size: 56,
            onPressed: _toggleMute,
          ),
          const SizedBox(height: 8),
          Text(
            _isMuted ? '麦克风已关' : '麦克风已开',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // 扬声器按钮（简化版，只负责hover触发）
  Widget _buildSpeakerButton() {
    return MouseRegion(
      onEnter: (_) {
        logger.debug('🖱️ 鼠标悬停在扬声器按钮上');
        _showSpeakerTestPopup();
      },
      child: Column(
        children: [
          _buildCircleButton(
            icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
            color: _isSpeakerOn ? Colors.white : Colors.white24,
            iconColor: _isSpeakerOn ? Colors.black : Colors.white,
            size: 56,
            onPressed: _toggleSpeaker,
          ),
          const SizedBox(height: 8),
          Text(
            _isSpeakerOn ? '扬声器' : '听筒',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // 摄像头按钮（简化版，只负责hover触发）
  Widget _buildCameraButton() {
    return MouseRegion(
      onEnter: (_) {
        logger.debug('============================================');
        logger.debug('🖱️ 鼠标悬停在摄像头按钮上');
        logger.debug('   - 当前摄像头状态: $_isCameraOn');
        logger.debug('   - 当前设备ID: $_currentCameraDeviceId');
        logger.debug('   - 设备数量: ${_cameraDevices.length}');
        logger.debug('============================================');
        _showCameraPopup();
      },
      child: Column(
        children: [
          _buildCircleButton(
            icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
            color: _isCameraOn ? Colors.white : Colors.white24,
            iconColor: _isCameraOn ? Colors.black : Colors.white,
            size: 56,
            onPressed: _toggleCamera,
          ),
          const SizedBox(height: 8),
          Text(
            _isCameraOn ? '摄像头已开' : '摄像头已关',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // 显示添加成员对话框
  Future<void> _showAddMemberDialog() async {
    logger.debug('📞 显示添加成员对话框');
    logger.debug('📞 当前群组ID: ${widget.groupId}');

    try {
      // 获取用户token
      final userToken = await Storage.getToken();
      if (userToken == null) {
        logger.debug('⚠️ 用户token为空，无法获取群组成员列表');
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

      // 如果有群组ID，获取群组成员
      if (widget.groupId != null) {
        try {
          logger.debug('📞 获取群组 ${widget.groupId} 的成员列表');
          final response = await ApiService.getGroupDetail(
            token: userToken,
            groupId: widget.groupId!,
          );

          if (response['code'] == 0 && response['data'] != null) {
            final membersData = response['data']['members'] as List?;
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

              logger.debug('📞 从群组获取到成员数量: ${availableMembers.length}');
            }
          } else {
            logger.debug('⚠️ 获取群组详情失败: ${response['message']}');
          }
        } catch (e) {
          logger.debug('⚠️ 获取群组成员失败: $e');
        }
      }

      // 如果群组成员获取失败，使用联系人列表作为备选方案
      if (availableMembers.isEmpty) {
        logger.debug('📞 群组成员为空，尝试使用联系人列表');
        try {
          final contactsResponse = await ApiService.getContacts(
            token: userToken,
          );
          final contacts =
              contactsResponse['data']['contacts'] as List<dynamic>;

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

          logger.debug('📞 从联系人列表获取到成员数量: ${availableMembers.length}');
        } catch (e) {
          logger.debug('⚠️ 获取联系人列表失败: $e');
        }
      }

      // 如果还是为空，创建测试数据
      if (availableMembers.isEmpty) {
        logger.debug('📞 所有数据源都为空，创建测试数据');
        availableMembers = [
          {'user_id': 100, 'username': 'test_user1', 'full_name': '测试用户1'},
          {'user_id': 101, 'username': 'test_user2', 'full_name': '测试用户2'},
          {'user_id': 102, 'username': 'test_user3', 'full_name': '测试用户3'},
        ];
      }

      logger.debug('📞 最终可用成员数量: ${availableMembers.length}');
      logger.debug('📞 当前通话成员: $_currentGroupCallUserIds');

      // 关闭加载对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (availableMembers.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂无可邀请的群组成员')));
        }
        return;
      }

      if (!mounted) return;

      // 显示选择成员对话框
      final selectedUserIds = await showDialog<List<int>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _buildAddMemberDialog(availableMembers),
      );

      if (selectedUserIds != null && selectedUserIds.isNotEmpty) {
        await _inviteMembers(selectedUserIds);
      }
    } catch (e) {
      logger.debug('⚠️ 获取成员列表失败: $e');
      // 关闭可能存在的加载对话框
      if (mounted) {
        try {
          Navigator.of(context).pop();
        } catch (_) {}
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取成员列表失败: $e')));
      }
    }
  }

  // 构建添加成员对话框
  Widget _buildAddMemberDialog(List<Map<String, dynamic>> contacts) {
    logger.debug('📞 [_buildAddMemberDialog] 开始构建对话框');
    logger.debug('📞 [_buildAddMemberDialog] 传入联系人数量: ${contacts.length}');
    logger.debug(
      '📞 [_buildAddMemberDialog] 当前通话成员: $_currentGroupCallUserIds',
    );

    // 转换联系人数据为统一格式
    final allMembers = contacts.map((contact) {
      final userId = contact['user_id'] as int;
      final username = contact['username'] as String;
      final fullName = contact['full_name'] as String?;
      return {
        'userId': userId,
        'username': username,
        'fullName': fullName?.isNotEmpty == true ? fullName! : username,
        'displayName': fullName?.isNotEmpty == true ? fullName! : username,
        'avatarText':
            (fullName?.isNotEmpty == true ? fullName! : username).length >= 2
            ? (fullName?.isNotEmpty == true ? fullName! : username).substring(
                (fullName?.isNotEmpty == true ? fullName! : username).length -
                    2,
              )
            : (fullName?.isNotEmpty == true ? fullName! : username),
      };
    }).toList();

    logger.debug('📞 [_buildAddMemberDialog] 转换后成员数量: ${allMembers.length}');

    // 分离当前通话成员和其他成员
    final currentCallMembers = allMembers
        .where((member) => _currentGroupCallUserIds.contains(member['userId']))
        .toList();
    final availableMembers = allMembers
        .where((member) => !_currentGroupCallUserIds.contains(member['userId']))
        .toList();

    logger.debug(
      '📞 [_buildAddMemberDialog] 当前通话成员数量: ${currentCallMembers.length}',
    );
    logger.debug(
      '📞 [_buildAddMemberDialog] 可邀请成员数量: ${availableMembers.length}',
    );

    // 打印可邀请成员的详细信息
    for (int i = 0; i < availableMembers.length; i++) {
      final member = availableMembers[i];
      logger.debug(
        '📞 [_buildAddMemberDialog] 可邀请成员[$i]: ID=${member['userId']}, 名称=${member['fullName']}',
      );
    }

    // 根据设备类型选择不同的对话框
    final isMobile = ResponsiveHelper.isMobile(context);

    if (isMobile) {
      // 移动端：使用垂直布局的对话框
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: MobileAddCallMemberDialog(
          availableMembers: availableMembers,
          currentCallMembers: currentCallMembers,
        ),
      );
    }

    // PC端：使用左右分栏布局的对话框
    final Set<int> newSelectedIds = <int>{}; // 新选中的成员

    return StatefulBuilder(
      builder: (context, setState) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            width: 800,
            height: 600,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // 标题
                const Text(
                  '邀请成员加入通话',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 20),
                // 主要内容区域（左右布局）
                Expanded(
                  child: Row(
                    children: [
                      // 左侧：可邀请成员列表
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE5E5E5)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 左侧标题
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xFFE5E5E5),
                                    ),
                                  ),
                                ),
                                child: const Text(
                                  '可邀请成员',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF333333),
                                  ),
                                ),
                              ),
                              // 可邀请成员列表
                              Expanded(
                                child: availableMembers.isEmpty
                                    ? const Center(
                                        child: Text(
                                          '暂无可邀请成员',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF999999),
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: availableMembers.length,
                                        itemBuilder: (context, index) {
                                          final member =
                                              availableMembers[index];
                                          final userId =
                                              member['userId'] as int;
                                          final isSelected = newSelectedIds
                                              .contains(userId);

                                          return InkWell(
                                            onTap: () {
                                              setState(() {
                                                if (isSelected) {
                                                  newSelectedIds.remove(userId);
                                                } else {
                                                  newSelectedIds.add(userId);
                                                }
                                              });
                                            },
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 10,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: isSelected
                                                    ? const Color(0xFFE8F4FD)
                                                    : Colors.white,
                                                border: const Border(
                                                  bottom: BorderSide(
                                                    color: Color(0xFFF5F5F5),
                                                  ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  // 复选框
                                                  Checkbox(
                                                    value: isSelected,
                                                    onChanged: (value) {
                                                      setState(() {
                                                        if (value == true) {
                                                          newSelectedIds.add(
                                                            userId,
                                                          );
                                                        } else {
                                                          newSelectedIds.remove(
                                                            userId,
                                                          );
                                                        }
                                                      });
                                                    },
                                                    activeColor: const Color(
                                                      0xFF4A90E2,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  // 头像
                                                  CircleAvatar(
                                                    radius: 20,
                                                    backgroundColor:
                                                        const Color(0xFF4A90E2),
                                                    child: Text(
                                                      member['avatarText']
                                                          as String,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  // 名称信息
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          member['fullName']
                                                              as String,
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 14,
                                                                color: Color(
                                                                  0xFF333333,
                                                                ),
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        Text(
                                                          '@${member['username']}',
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                                color: Color(
                                                                  0xFF999999,
                                                                ),
                                                              ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // 右侧：已选择成员列表
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE5E5E5)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 右侧标题
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xFFE5E5E5),
                                    ),
                                  ),
                                ),
                                child: Text(
                                  '已选择 (${currentCallMembers.length + newSelectedIds.length})',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF333333),
                                  ),
                                ),
                              ),
                              // 已选择成员列表
                              Expanded(
                                child: ListView(
                                  children: [
                                    // 当前通话成员（不可删除）
                                    ...currentCallMembers.map((member) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFF8F9FA),
                                          border: Border(
                                            bottom: BorderSide(
                                              color: Color(0xFFF5F5F5),
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            // 头像
                                            CircleAvatar(
                                              radius: 20,
                                              backgroundColor: const Color(
                                                0xFF4A90E2,
                                              ),
                                              child: Text(
                                                member['avatarText'] as String,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            // 名称信息
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    member['fullName']
                                                        as String,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      color: Color(0xFF333333),
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  Text(
                                                    '@${member['username']}',
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Color(0xFF999999),
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // 通话中标签
                                            Container(
                                              margin: const EdgeInsets.only(
                                                left: 8,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF28A745),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                '通话中',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                    // 新选中的成员（可删除）
                                    ...newSelectedIds.map((userId) {
                                      final member = availableMembers
                                          .firstWhere(
                                            (m) => m['userId'] == userId,
                                          );
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        decoration: const BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: Color(0xFFF5F5F5),
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            // 头像
                                            CircleAvatar(
                                              radius: 20,
                                              backgroundColor: const Color(
                                                0xFF4A90E2,
                                              ),
                                              child: Text(
                                                member['avatarText'] as String,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            // 名称信息
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    member['fullName']
                                                        as String,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      color: Color(0xFF333333),
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  Text(
                                                    '@${member['username']}',
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Color(0xFF999999),
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // 删除按钮
                                            IconButton(
                                              icon: const Icon(
                                                Icons.close,
                                                size: 18,
                                                color: Color(0xFF999999),
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  newSelectedIds.remove(userId);
                                                });
                                              },
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // 底部按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: newSelectedIds.isEmpty
                          ? null
                          : () {
                              Navigator.of(
                                context,
                              ).pop(newSelectedIds.toList());
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4A90E2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        disabledBackgroundColor: const Color(0xFFCCCCCC),
                      ),
                      child: const Text('确定', style: TextStyle(fontSize: 14)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 邀请成员加入通话
  Future<void> _inviteMembers(List<int> selectedUserIds) async {
    logger.debug('📞 邀请成员加入通话: $selectedUserIds');

    try {
      final userToken = await Storage.getToken();
      if (userToken == null) {
        logger.debug('⚠️ 用户token为空，无法邀请成员');
        return;
      }

      // 过滤出新成员（不包含已经在通话中的成员）
      final newMemberIds = selectedUserIds
          .where((id) => !_currentGroupCallUserIds.contains(id))
          .toList();

      if (newMemberIds.isNotEmpty) {
        logger.debug('📞 向新成员发起群组通话: $newMemberIds');
        logger.debug('📞 当前通话频道: ${AgoraService().currentChannelName}');

        // 获取当前通话的频道名称
        final currentChannelName = AgoraService().currentChannelName;
        if (currentChannelName == null || currentChannelName.isEmpty) {
          logger.debug('⚠️ 无法获取当前通话频道名称');
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('无法获取当前通话信息，请重试')));
          }
          return;
        }

        // 邀请新成员加入现有的群组通话
        final response = await ApiService.inviteToGroupCall(
          token: userToken,
          channelName: currentChannelName,
          calleeIds: newMemberIds,
          callType: widget.callType == CallType.voice ? 'voice' : 'video',
        );

        logger.debug('📞 群组通话邀请发送成功: ${response['message']}');

        // 🔴 修复：不需要额外发送群组消息通知，服务器API已经处理了推送
        // 删除 _notifyExistingMembers 调用，避免在聊天记录中显示系统消息

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已向 ${newMemberIds.length} 个成员发送邀请')),
          );
        }
      } else {
        logger.debug('📞 没有新成员需要邀请');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有新成员需要邀请')));
        }
      }
    } catch (e) {
      logger.debug('⚠️ 邀请成员失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('邀请成员失败')));
      }
    }
  }
}
