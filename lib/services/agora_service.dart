import 'dart:async';
import 'dart:io';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/agora_config.dart';
import 'websocket_service.dart';
import 'api_service.dart';
import 'native_call_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';

/// 通话状态枚举
enum CallState {
  idle, // 空闲
  calling, // 正在呼叫
  ringing, // 对方来电响铃中
  connected, // 已连接
  ended, // 已结束
}

/// 通话类型枚举
enum CallType {
  voice, // 语音通话
  video, // 视频通话
}

/// Agora 音视频通话服务
class AgoraService {
  // 单例模式
  static final AgoraService _instance = AgoraService._internal();
  factory AgoraService() => _instance;
  AgoraService._internal();

  // Agora 引擎
  RtcEngine? _engine;

  // 通话状态
  CallState _callState = CallState.idle;
  CallType _callType = CallType.voice;
  int? _currentCallUserId; // 当前通话的对方用户ID
  String? _currentChannelName; // 当前频道名称
  String? _currentAgoraToken; // 当前 Agora Token
  int? _myUserId; // 当前用户ID
  DateTime? _callStartTime; // 通话开始时间
  int? _currentGroupId; // 当前群组通话的群组ID（如果是群组通话）

  // 🔴 新增：保存最后一次通话的群组ID和通话类型（用于通话结束后仍能读取）
  int? _lastGroupId;
  CallType? _lastCallType;
  int? _lastCallUserId; // 🔴 新增：保存最后一次通话的对方用户ID

  // 🔴 新增：通话最小化标志和最小化通话的信息（用于通知UI显示悬浮按钮）
  bool _isCallMinimized = false;
  int? _minimizedCallUserId; // 最小化通话的对方用户ID
  String? _minimizedCallDisplayName; // 最小化通话的显示名称
  CallType? _minimizedCallType; // 最小化通话的类型
  bool _minimizedIsGroupCall = false; // 是否是群组通话
  int? _minimizedGroupId; // 群组ID（如果是群组通话）

  // 🔴 新增：保存当前群组通话的成员信息（用于恢复通话时显示群组样式）
  List<int>? _currentGroupCallUserIds;
  List<String>? _currentGroupCallDisplayNames;

  // 🔴 新增：保存已连接成员的ID集合（用于恢复时显示正确的连接状态）
  Set<int>? _connectedMemberIds;

  // 🔴 新增：防止重复调用 endCall 的标志位
  bool _isEndingCall = false;
  
  // 🔴 新增：标识是否是本地主动挂断（用于决定是否发送通话结束消息）
  bool _isLocalHangup = false;
  bool get isLocalHangup => _isLocalHangup;

  // 远程用户 ID 集合
  Set<int> _remoteUids = {};

  // WebSocket 服务
  final WebSocketService _wsService = WebSocketService();

  // 回调函数
  Function(CallState)? onCallStateChanged;
  Function(int uid)? onRemoteUserJoined;
  Function(int uid)? onRemoteUserLeft;
  Function(String)? onError;
  Function(int userId, String displayName, CallType callType)? onIncomingCall;
  // 群组来电回调：userId, displayName, callType, members (List<Map>: user_id, username, display_name), groupId
  Function(
    int userId,
    String displayName,
    CallType callType,
    List<Map<String, dynamic>> members,
    int? groupId,
  )?
  onIncomingGroupCall;
  Function()? onLocalVideoReady; // 本地视频准备就绪
  Function(int uid)? onRemoteVideoReady; // 远程视频准备就绪
  Function(int callDuration)? onCallEnded; // 通话结束回调（用于关闭对话框等），传递通话时长（秒）
  Function(int userId, String status, String? displayName)?
  onGroupCallMemberStatusChanged; // 群组通话成员状态变化回调
  Function(int uid, bool isMuted)? onRemoteVideoMuted; // 远程用户视频静音状态变化回调

  /// 初始化 Agora 引擎
  Future<void> initialize(int currentUserId) async {
    try {
      // logger.debug('========== 📞 Agora 初始化开始 ==========');
      // logger.debug('📞 收到的用户ID: $currentUserId');

      // 🔴 重要：始终更新用户ID（即使已经初始化过）
      _myUserId = currentUserId;
      // logger.debug('📞 已设置 _myUserId = $_myUserId');
      // logger.debug('📞 当前引擎状态: ${_engine == null ? "未创建" : "已存在"}');

      // 如果引擎已经创建，仅更新用户 ID 并重新设置
      if (_engine != null) {
        // logger.debug('📞 引擎已存在，仅更新用户ID 和重新设置');
        _setupWebSocketListeners(); // 重新设置 WebSocket 监听
        // logger.debug('========== Agora 初始化完成（仅更新） ==========');
        return;
      }

      // 创建 Agora 引擎
      // logger.debug('📞 开始创建 Agora 引擎...');
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(
        RtcEngineContext(
          appId: AgoraConfig.appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );
      // logger.debug('📞 Agora 引擎创建成功');

      // 注册事件处理
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onError: (ErrorCodeType err, String msg) {
            // logger.debug('📞 Agora 错误: $err, $msg');
            onError?.call('通话错误: $msg');
          },
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) async {
            // logger.debug('📞 成功加入频道: ${connection.channelId}, 用时: $elapsed ms');
            
            // 🔴 关键修复：在加入频道后立即启用扬声器（移动端）
            if (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS) {
              try {
                await _engine!.setEnableSpeakerphone(true);
                logger.debug('📞 ✅ 加入频道后已启用扬声器（移动端）');
              } catch (e) {
                logger.debug('⚠️ 启用扬声器失败: $e');
              }
            }
            
            if (_callState == CallState.calling) {
              // 主叫方加入成功，继续等待对方接听
              // logger.debug('📞 主叫方已进入频道，等待对方接听');
            }
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            logger.debug(
              '👤 [Agora] 远程用户加入: $remoteUid, channel=${connection.channelId}',
            );
            _remoteUids.add(remoteUid);

            // 当远程用户加入时，如果当前是 calling 状态，切换为 connected
            if (_callState == CallState.calling) {
              logger.debug('📞 [Agora] 对方已接听，通话连接成功');
              _updateCallState(CallState.connected);
            }

            logger.debug('👤 [Agora] 触发 onRemoteUserJoined 回调: $remoteUid');
            onRemoteUserJoined?.call(remoteUid);
          },
          onUserOffline:
              (
                RtcConnection connection,
                int remoteUid,
                UserOfflineReasonType reason,
              ) {
                // logger.debug('👤 远程用户离开: $remoteUid, 原因: $reason');
                _remoteUids.remove(remoteUid);
                onRemoteUserLeft?.call(remoteUid);

                // 🔴 修复：区分单人通话和群组通话
                // 只有在单人通话中，所有远程用户离开时才自动结束通话
                // 群组通话中成员离开不应该自动结束通话
                if (_remoteUids.isEmpty &&
                    _callState == CallState.connected &&
                    !_isGroupCall()) {
                  // logger.debug('📞 单人通话：对方已挂断，准备结束通话');
                  // 🔴 修复：在独立的异步任务中调用 endCall()，避免阻塞回调
                  // 🔴 对方离开导致的结束，不是本地主动挂断
                  Future.microtask(() async {
                    try {
                      await endCall(isLocalHangup: false);
                    } catch (e) {
                      // logger.debug('⚠️ 结束通话时出错: $e');
                    }
                  });
                } else if (_isGroupCall()) {
                  // logger.debug('📞 群组通话：成员 $remoteUid 离开，但不结束通话');
                }
              },
          onLeaveChannel: (RtcConnection connection, RtcStats stats) {
            // logger.debug('📞 离开频道: ${connection.channelId}');
            _remoteUids.clear();
          },
          onRemoteAudioStateChanged:
              (
                RtcConnection connection,
                int remoteUid,
                RemoteAudioState state,
                RemoteAudioStateReason reason,
                int elapsed,
              ) {
                // logger.debug(
                //   '🔊 远程音频状态变化: uid=$remoteUid, state=$state, reason=$reason',
                // );
              },
          onRemoteVideoStateChanged:
              (
                RtcConnection connection,
                int remoteUid,
                RemoteVideoState state,
                RemoteVideoStateReason reason,
                int elapsed,
              ) {
                logger.debug('============================================');
                logger.debug('📹 [Agora] 远程视频状态变化');
                logger.debug('   - remoteUid: $remoteUid');
                logger.debug('   - state: $state');
                logger.debug('   - reason: $reason');
                logger.debug('   - elapsed: ${elapsed}ms');
                logger.debug('   - channelId: ${connection.channelId}');
                logger.debug('============================================');

                if (state == RemoteVideoState.remoteVideoStateDecoding) {
                  // 远程视频开始解码，说明视频已准备好
                  logger.debug('📹 [Agora] 远程视频开始解码，触发onRemoteVideoReady回调');
                  onRemoteVideoReady?.call(remoteUid);
                  // 🔴 新增：通知远程用户视频已开启
                  onRemoteVideoMuted?.call(remoteUid, false);
                } else if (state == RemoteVideoState.remoteVideoStateStopped) {
                  logger.debug('📹 [Agora] 远程视频已停止');
                  // 🔴 新增：通知远程用户视频已关闭（静音）
                  if (reason == RemoteVideoStateReason.remoteVideoStateReasonRemoteMuted) {
                    logger.debug('📹 [Agora] 远程用户主动关闭了摄像头');
                    onRemoteVideoMuted?.call(remoteUid, true);
                  }
                } else if (state == RemoteVideoState.remoteVideoStateFrozen) {
                  logger.debug('📹 [Agora] 远程视频已冻结');
                } else if (state == RemoteVideoState.remoteVideoStateFailed) {
                  logger.debug('📹 [Agora] ❌ 远程视频失败');
                }
              },
          onLocalVideoStateChanged:
              (
                VideoSourceType source,
                LocalVideoStreamState state,
                LocalVideoStreamReason reason,
              ) {
                logger.debug('============================================');
                logger.debug('📹 [Agora] 本地视频状态变化');
                logger.debug('   - source: $source');
                logger.debug('   - state: $state');
                logger.debug('   - reason: $reason');
                logger.debug('   - 通话类型: $_callType');
                logger.debug('   - 通话状态: $_callState');
                logger.debug('============================================');

                if (state ==
                    LocalVideoStreamState.localVideoStreamStateCapturing) {
                  // 本地视频开始采集
                  logger.debug('📹 [Agora] 本地视频开始采集，触发onLocalVideoReady回调');
                  onLocalVideoReady?.call();
                } else if (state ==
                    LocalVideoStreamState.localVideoStreamStateStopped) {
                  logger.debug('📹 [Agora] 本地视频已停止');
                } else if (state ==
                    LocalVideoStreamState.localVideoStreamStateEncoding) {
                  logger.debug('📹 [Agora] 本地视频正在编码');
                } else if (state ==
                    LocalVideoStreamState.localVideoStreamStateFailed) {
                  logger.debug('📹 [Agora] ❌ 本地视频失败');

                  // 🔴 修复：如果本地视频失败（如没有摄像头设备），不立即结束通话
                  // 让通话继续，只是本地视频会显示为空页面
                  if (reason ==
                      LocalVideoStreamReason
                          .localVideoStreamReasonDeviceNotFound) {
                    // logger.debug('📹 ⚠️ 摄像头设备未找到，但继续通话（本地视频将显示为空页面）');
                    // 不调用 endCall()，让通话继续
                  }
                }
              },
          onAudioRoutingChanged: (routing) {
            // logger.debug('🔊 音频路由变化: $routing');
          },
        ),
      );

      // 🔴 关键：初始化后立即启用音频（参考 Agora 示例）
      await _engine!.enableAudio();

      // 设置默认音频配置（参考 join_channel_audio.dart L97-100）
      await _engine!.setAudioProfile(
        profile: AudioProfileType.audioProfileDefault,
        scenario: AudioScenarioType.audioScenarioGameStreaming,
      );

      // logger.debug('📞 音频已启用，使用游戏串流场景');

      // 🔴 重要：初始化时禁用视频，只在需要时启用（避免语音通话时也采集视频）
      await _engine!.disableVideo();
      // logger.debug('📞 视频已禁用（默认状态）');

      // 设置 WebSocket 监听
      _setupWebSocketListeners();

      // logger.debug('========== Agora 初始化完成 ==========');
      // logger.debug('📞 最终用户ID: $_myUserId');
      // logger.debug('📞 引擎状态: 已创建');
      // logger.debug('===========================================');
    } catch (e) {
      // logger.debug('📞 Agora 初始化失败: $e');
      onError?.call('初始化失败: $e');
    }
  }

  /// 设置 WebSocket 监听
  void _setupWebSocketListeners() {
    _wsService.onWebRTCSignal = (data) async {
      // logger.debug('📞 收到 WebRTC 信令: ${data['type']}');

      try {
        switch (data['type']) {
          case 'call-request':
            _handleIncomingCall(data);
            break;
          case 'incoming_call': // 服务器发送的来电通知（新版）
            _handleIncomingCallFromServer(data);
            break;
          case 'incoming_group_call': // 群组来电通知
            _handleIncomingGroupCallFromServer(data);
            break;
          case 'group_call_member_accepted': // 群组通话成员接听通知
            // logger.debug('📞 [WebSocket] 收到群组通话成员接听通知，开始处理...');
            _handleGroupCallMemberAccepted(data);
            break;
          case 'group_call_member_left': // 群组通话成员离开通知
            // logger.debug('📞 [WebSocket] 收到群组通话成员离开通知，开始处理...');
            _handleGroupCallMemberLeft(data);
            break;
          case 'group_call_ended': // 🔴 群组通话结束通知（通知未接听成员关闭来电弹窗）
            _handleGroupCallEnded(data);
            break;
          case 'call-accepted':
            await _handleCallAccepted(data);
            break;
          case 'call-rejected':
          case 'call_rejected': // 服务器发送的拒绝通知
            _handleCallRejected(data);
            break;
          case 'call-ended':
          case 'call_ended': // 服务器发送的结束通知
            // 🔴 修复：区分单人通话和群组通话
            if (_isGroupCall()) {
              // logger.debug(
              // '📞 群组通话：收到挂断信令，但不结束通话（由专门的group_call_member_left处理）',
              // );
              // 群组通话中的挂断由 group_call_member_left 消息处理，这里不做任何操作
            } else {
              // logger.debug('📞 单人通话：收到对方挂断信令，准备结束通话');
              // 🔴 收到对方挂断信令，不是本地主动挂断
              await endCall(isLocalHangup: false);
              // endCall() 内部会触发 onCallEnded 回调
            }
            break;
        }
      } catch (e) {
        // logger.debug('📞 处理信令失败: $e');
        onError?.call('信令处理失败: $e');
      }
    };
  }

  /// 请求权限
  Future<bool> _requestPermissions(CallType callType) async {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      // 语音通话只需要麦克风权限
      final permissions = [Permission.microphone];

      // 视频通话还需要摄像头权限
      if (callType == CallType.video) {
        permissions.add(Permission.camera);
      }

      final statuses = await permissions.request();

      for (var status in statuses.values) {
        if (!status.isGranted) {
          // logger.debug('📞 权限被拒绝');
          onError?.call('请授予麦克风${callType == CallType.video ? '和摄像头' : ''}权限');
          return false;
        }
      }
    }

    return true;
  }

  /// 发起语音通话
  Future<void> startVoiceCall(
    int targetUserId,
    String targetDisplayName,
  ) async {
    await _startCall(targetUserId, targetDisplayName, CallType.voice);
  }

  /// 发起视频通话
  Future<void> startVideoCall(
    int targetUserId,
    String targetDisplayName,
  ) async {
    await _startCall(targetUserId, targetDisplayName, CallType.video);
  }

  /// 发起通话
  Future<void> _startCall(
    int targetUserId,
    String targetDisplayName,
    CallType callType,
  ) async {
    // logger.debug('========== 📞 开始发起通话 ==========');
    // logger.debug('📞 目标用户: $targetUserId ($targetDisplayName)');
    // logger.debug('📞 当前用户ID (_myUserId): $_myUserId');
    // logger.debug('📞 通话类型: ${callType == CallType.voice ? '语音' : '视频'}');

    // 🔴 重置本地挂断标识（新通话开始时）
    _isLocalHangup = false;
    
    logger.debug('📞 [_startCall] 开始发起通话，目标用户ID: $targetUserId');

    // 检查是否在给自己打电话
    if (targetUserId == _myUserId) {
      logger.debug('📞 不能给自己打电话');
      onError?.call('不能给自己打电话');
      return;
    }

    if (_callState != CallState.idle) {
      onError?.call('当前正在通话');
      return;
    }

    if (_engine == null) {
      logger.debug('📞 Agora 引擎未初始化');
      onError?.call('Agora 引擎未初始化');
      return;
    }

    try {
      // logger.debug('📞 所有检查通过，准备加入频道...');

      // 请求权限
      final hasPermission = await _requestPermissions(callType);
      if (!hasPermission) {
        return;
      }

      _currentCallUserId = targetUserId;
      _callType = callType;
      _updateCallState(CallState.calling);
      logger.debug('📞 [_startCall] 已设置 _currentCallUserId: $_currentCallUserId');

      // 🔴 调用服务器API获取频道名称和Token
      // logger.debug('📞 调用服务器API获取频道和Token...');
      final userToken = await Storage.getToken();
      if (userToken == null) {
        throw Exception('用户未登录');
      }

      final callData = await ApiService.initiateCall(
        token: userToken,
        calleeId: targetUserId,
        callType: callType == CallType.voice ? 'voice' : 'video',
      );

      _currentChannelName = callData['channel_name'];
      _currentAgoraToken = callData['token'];
      // logger.debug('📞 服务器返回频道: $_currentChannelName');
      // logger.debug('📞 服务器返回Token: ${_currentAgoraToken?.substring(0, 20)}...');

      // 配置视频（仅视频通话需要）
      if (callType == CallType.video) {
        // logger.debug('📹 [视频配置] 开始配置视频通话...');

        // logger.debug('📹 [视频配置] 步骤1: 启用视频...');
        await _engine!.enableVideo();
        // logger.debug('📹 [视频配置] 步骤1: ✅ 视频已启用');

        // logger.debug('📹 [视频配置] 步骤2: 启动预览...');
        try {
          await _engine!.startPreview();
          // logger.debug('📹 [视频配置] 步骤2: ✅ 预览已启动');
        } catch (e) {
          // 🔴 修复：如果 startPreview() 失败（如没有摄像头设备），不抛出异常
          // 让通话继续，只是本地视频会显示为空页面
          // logger.debug('📹 [视频配置] 步骤2: ⚠️ 预览启动失败: $e');
          // logger.debug('📹 [视频配置] 步骤2: 继续通话流程（本地视频将显示为空页面）');
          // 不抛出异常，让通话继续
        }

        // 设置视频编码配置
        // logger.debug('📹 [视频配置] 步骤3: 设置视频编码配置...');
        await _engine!.setVideoEncoderConfiguration(
          const VideoEncoderConfiguration(
            dimensions: VideoDimensions(width: 640, height: 480),
            frameRate: 15,
            bitrate: 0, // 使用默认码率
          ),
        );
        // logger.debug('📹 [视频配置] 步骤3: ✅ 编码配置已设置');
        // logger.debug('📹 [视频配置] ✅ 视频通话配置完成');
      }

      // 🔴 注意：扬声器启用必须在 onJoinChannelSuccess 回调中进行
      // 因为在加入频道前调用 setEnableSpeakerphone 会返回 -3 失败
      // 请不要移动该逻辑！

      // 🔴 关键：使用服务器返回的Token加入频道
      // logger.debug('📞 使用服务器Token加入频道...');

      // 🔴 修复：检查参数有效性
      if (_myUserId == null || _myUserId == 0) {
        throw Exception('用户ID无效: $_myUserId，请确保已正确初始化 Agora 服务');
      }

      if (_currentChannelName == null || _currentChannelName!.isEmpty) {
        throw Exception('频道名称无效');
      }

      if (_currentAgoraToken == null || _currentAgoraToken!.isEmpty) {
        throw Exception('Token 无效，服务器未返回有效的 Token');
      }

      // logger.debug('📞 [发起] 准备加入频道:');
      // logger.debug('   - 频道名称: $_currentChannelName');
      // logger.debug('   - 用户ID: $_myUserId');
      // logger.debug('   - Token: ${_currentAgoraToken!.substring(0, 20)}...');

      await _engine!.joinChannel(
        token: _currentAgoraToken!,
        channelId: _currentChannelName!,
        uid: _myUserId!,
        options: ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          // 🔴 关键：显式启用音频发布和订阅
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
        ),
      );

      // 发送通话请求（通知对方，服务器已经通过WebSocket发送了来电通知）
      // 注意：服务器端API已经自动发送了来电通知，这里的WebSocket信令可以作为备用
      // logger.debug('📞 发送WebSocket通话请求信令...');
      _wsService.sendWebRTCSignal({
        'type': 'call-request',
        'targetUserId': targetUserId,
        'callType': callType == CallType.voice ? 'voice' : 'video',
        'callerName': targetDisplayName,
        'channelName': _currentChannelName,
      });

      // logger.debug('📞 通话请求已发送');
    } catch (e) {
      // logger.debug('📞 发起通话失败: $e');
      onError?.call('发起通话失败: $e');
      await endCall();
    }
  }

  /// 接听来电
  Future<void> acceptCall() async {
    if (_callState != CallState.ringing) {
      // logger.debug('📞 当前没有来电');
      return;
    }

    if (_engine == null) {
      onError?.call('Agora 引擎未初始化');
      return;
    }

    // 🔴 重置本地挂断标识（接听来电时）
    _isLocalHangup = false;

    try {
      // logger.debug('📞 接听来电');

      // 请求权限
      final hasPermission = await _requestPermissions(_callType);
      if (!hasPermission) {
        await rejectCall();
        return;
      }

      // 配置视频（仅视频通话需要）
      if (_callType == CallType.video) {
        //logger.debug('📹 [接听-视频配置] 开始配置视频通话...');

        // logger.debug('📹 [接听-视频配置] 步骤1: 启用视频...');
        await _engine!.enableVideo();
        // logger.debug('📹 [接听-视频配置] 步骤1: ✅ 视频已启用');

        // logger.debug('📹 [接听-视频配置] 步骤2: 启动预览...');
        try {
          await _engine!.startPreview();
          // logger.debug('📹 [接听-视频配置] 步骤2: ✅ 预览已启动');
        } catch (e) {
          // 🔴 修复：如果 startPreview() 失败（如没有摄像头设备），不抛出异常
          // 让通话继续，只是本地视频会显示为空页面
          // logger.debug('📹 [接听-视频配置] 步骤2: ⚠️ 预览启动失败: $e');
          // logger.debug('📹 [接听-视频配置] 步骤2: 继续通话流程（本地视频将显示为空页面）');
          // 不抛出异常，让通话继续
        }

        // logger.debug('📹 [接听-视频配置] 步骤3: 设置视频编码配置...');
        await _engine!.setVideoEncoderConfiguration(
          const VideoEncoderConfiguration(
            dimensions: VideoDimensions(width: 640, height: 480),
            frameRate: 15,
            bitrate: 0,
          ),
        );
        // logger.debug('📹 [接听-视频配置] 步骤3: ✅ 编码配置已设置');
        // logger.debug('📹 [接听-视频配置] ✅ 视频通话配置完成');
      }

      // 🔴 关键：配置音频输出设备（移动端启用扬声器）
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          // 移动端默认使用扬声器（而不是听筒）
          await _engine!.setEnableSpeakerphone(true);
          // logger.debug('📞 已启用扬声器（移动端）');
        } catch (e) {
          // logger.debug('⚠️ 启用扬声器失败: $e');
        }
      }

      // 🔴 关键：使用服务器提供的Token加入频道
      // logger.debug('📞 接听 - 使用服务器Token加入频道...');
      // logger.debug('   - Token: ${_currentAgoraToken?.substring(0, 20)}...');
      // logger.debug('   - 频道: $_currentChannelName');
      // logger.debug('   - UID: $_myUserId');

      // 🔴 修复：确保 token 参数正确（Agora 在无 token 模式下使用空字符串）
      String tokenToUse;
      if (_currentAgoraToken != null && _currentAgoraToken!.isNotEmpty) {
        tokenToUse = _currentAgoraToken!;
        // logger.debug(
        // '📞 [接听] 使用服务器提供的 Token: ${tokenToUse.substring(0, 20)}...',
        // );
      } else if (AgoraConfig.token.isNotEmpty) {
        tokenToUse = AgoraConfig.token;
        // logger.debug('📞 [接听] 使用配置文件中的 Token');
      } else {
        tokenToUse = ''; // 不使用 token 认证，传递空字符串
        // logger.debug('📞 [接听] 使用无 Token 模式加入频道（空字符串）');
      }

      // 🔴 修复：检查 uid 是否有效（Agora 不接受 uid 为 0）
      if (_myUserId == null || _myUserId == 0) {
        throw Exception('用户ID无效: $_myUserId，请确保已正确初始化 Agora 服务');
      }

      // logger.debug('📞 [接听] 准备加入频道:');
      // logger.debug('   - 频道名称: $_currentChannelName');
      // logger.debug('   - 用户ID: $_myUserId');
      // logger.debug(
      //   '   - Token: ${tokenToUse.isEmpty ? "(无Token模式)" : "${tokenToUse.substring(0, 20)}..."}',
      // );

      // 🔴 修复：根据通话类型动态配置音视频参数
      final isVideoCall = _callType == CallType.video;

      await _engine!.joinChannel(
        token: tokenToUse,
        channelId: _currentChannelName!,
        uid: _myUserId!,
        options: ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          // 🔴 关键：显式启用音频发布和订阅
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
          // 🔴 修复：视频通话时启用摄像头发布和视频订阅
          publishCameraTrack: isVideoCall,
          autoSubscribeVideo: isVideoCall,
        ),
      );

      // 通知对方已接受通话
      _wsService.sendWebRTCSignal({
        'type': 'call-accepted',
        'targetUserId': _currentCallUserId,
        'channelName': _currentChannelName,
      });

      // 🔴 新增：如果是群组通话，调用服务器API通知其他成员
      if (_isGroupCall()) {
        // logger.debug('📞 群组通话接听，调用服务器API通知其他成员');
        try {
          final userToken = await Storage.getToken();
          if (userToken != null && _currentChannelName != null) {
            await ApiService.acceptGroupCall(
              token: userToken,
              channelName: _currentChannelName!,
            );
            // logger.debug('📞 群组通话接听通知已发送');
          }
        } catch (e) {
          // logger.debug('⚠️ 发送群组通话接听通知失败: $e');
        }
      }

      _updateCallState(CallState.connected);
      // logger.debug('📞 已接听来电');
    } catch (e) {
      // logger.debug('📞 接听来电失败: $e');
      onError?.call('接听来电失败: $e');
      await endCall();
    }
  }

  /// 拒绝来电
  Future<void> rejectCall() async {
    if (_callState != CallState.ringing) {
      // logger.debug('📞 当前没有来电');
      return;
    }

    // logger.debug('📞 拒绝来电');

    _wsService.sendWebRTCSignal({
      'type': 'call-rejected',
      'targetUserId': _currentCallUserId,
    });

    await endCall(isLocalHangup: false);
  }

  /// 🔴 新增：群组通话中单个成员离开（只离开频道，不结束整个通话）
  /// 用于群组通话中点击"挂断"或"拒绝"时，只关闭自己的通话弹窗
  /// 返回 Map 包含：
  /// - callDuration: 通话时长（秒）
  /// - isCallEnded: 是否是最后一个成员离开（通话已结束）
  Future<Map<String, dynamic>> leaveGroupCallOnly() async {
    logger.debug('📞 [leaveGroupCallOnly] 群组通话成员离开，当前状态: $_callState');

    // 计算通话时长
    int callDuration = 0;
    if (_callStartTime != null) {
      final elapsed = DateTime.now().difference(_callStartTime!);
      callDuration = elapsed.inSeconds;
      logger.debug('📞 [leaveGroupCallOnly] 通话时长: $callDuration 秒');
    }

    // 关闭原生来电弹窗
    try {
      final nativeCallService = NativeCallService();
      await nativeCallService.dismissCallOverlay();
      logger.debug('📱 [leaveGroupCallOnly] 原生来电弹窗已关闭');
    } catch (e) {
      logger.debug('⚠️ [leaveGroupCallOnly] 关闭原生来电弹窗失败: $e');
    }

    // 调用服务器API通知其他成员自己离开了
    // 服务器会检查是否是最后一个成员，如果是则发送通话结束消息和删除加入按钮
    bool isCallEnded = false;
    if (_currentChannelName != null) {
      try {
        final userToken = await Storage.getToken();
        if (userToken != null) {
          final response = await ApiService.leaveGroupCall(
            token: userToken,
            channelName: _currentChannelName!,
            groupId: _currentGroupId,
            callType: _callType == CallType.video ? 'video' : 'voice',
            checkEndCall: true, // 让服务器检查是否是最后一个成员
          );
          logger.debug('✅ [leaveGroupCallOnly] 群组通话离开消息发送成功');
          
          // 检查服务器返回是否表示通话已结束（最后一个成员离开）
          if (response['data'] != null && response['data']['is_call_ended'] == true) {
            isCallEnded = true;
            logger.debug('📞 [leaveGroupCallOnly] 服务器确认：这是最后一个成员，通话已结束');
          }
        }
      } catch (e) {
        logger.debug('⚠️ [leaveGroupCallOnly] 发送群组通话离开消息失败: $e');
      }
    }

    // 离开频道（带超时保护）
    if (_engine != null && _currentChannelName != null) {
      try {
        // 视频通话时，先停止预览并禁用视频
        if (_callType == CallType.video) {
          await _engine!
              .stopPreview()
              .timeout(const Duration(milliseconds: 800))
              .catchError((e) {});
          await _engine!
              .disableVideo()
              .timeout(const Duration(milliseconds: 500))
              .catchError((e) {});
        }

        // 离开频道
        await _engine!
            .leaveChannel()
            .timeout(const Duration(seconds: 2))
            .catchError((e) {});

        logger.debug('📞 [leaveGroupCallOnly] 已离开频道');
      } catch (e) {
        logger.debug('⚠️ [leaveGroupCallOnly] 离开频道失败: $e');
      }
    }

    // 保存最后通话信息
    _lastGroupId = _currentGroupId;
    _lastCallType = _callType;
    if (_currentCallUserId != null) {
      _lastCallUserId = _currentCallUserId;
    }

    // 清除通话状态
    _currentCallUserId = null;
    _currentChannelName = null;
    _currentAgoraToken = null;
    _currentGroupId = null;
    _remoteUids.clear();
    _callStartTime = null;

    // 清除最小化标识
    _isCallMinimized = false;
    _minimizedCallUserId = null;
    _minimizedCallDisplayName = null;
    _minimizedCallType = null;
    _minimizedIsGroupCall = false;
    _minimizedGroupId = null;

    // 重置状态为 idle
    _updateCallState(CallState.idle);
    logger.debug('📞 [leaveGroupCallOnly] 已离开群组通话，状态重置为 idle, isCallEnded: $isCallEnded');

    return {
      'callDuration': callDuration,
      'isCallEnded': isCallEnded,
    };
  }

  /// 结束通话
  /// [isLocalHangup] 是否是本地主动挂断（用于决定是否发送通话结束消息）
  Future<void> endCall({bool isLocalHangup = true}) async {
    logger.debug('📞 结束通话，当前状态: $_callState, 是否本地挂断: $isLocalHangup, _currentCallUserId: $_currentCallUserId');
    
    // 🔴 关键修复：在任何早期返回之前，立即保存最后一次通话的用户ID
    // 这样即使 endCall 被多次调用，第一次调用时的用户ID也会被保存
    if (_currentCallUserId != null) {
      _lastCallUserId = _currentCallUserId;
      logger.debug('📞 [早期保存] _lastCallUserId: $_lastCallUserId');
    }

    // 关闭原生来电弹窗（无论什么状态都要关闭）
    try {
      final nativeCallService = NativeCallService();
      await nativeCallService.dismissCallOverlay();
      logger.debug('📱 原生来电弹窗已关闭');
    } catch (e) {
      logger.debug('⚠️ 关闭原生来电弹窗失败: $e');
    }

    // 🔴 优化：使用标志位防止重复调用
    // 即使在异步清理过程中再次调用 endCall，也会立即返回
    if (_isEndingCall) {
      logger.debug('📞 正在结束通话中，跳过重复调用 (但 _lastCallUserId 已保存: $_lastCallUserId)');
      return;
    }

    // 防止重复调用
    if (_callState == CallState.idle || _callState == CallState.ended) {
      logger.debug('📞 通话已结束，跳过重复调用 (但 _lastCallUserId 已保存: $_lastCallUserId)');
      return;
    }

    // 🔴 关键修复：只有在第一次有效调用时才设置 isLocalHangup
    // 这样后续的重复调用不会覆盖这个值
    _isLocalHangup = isLocalHangup;
    logger.debug('📞 设置 _isLocalHangup: $_isLocalHangup');

    // 设置标志位，防止重复调用
    _isEndingCall = true;

    // logger.debug('📞 结束通话');

    // 🔴 修复：在清除 callStartTime 之前先计算通话时长
    int callDuration = 0;
    if (_callStartTime != null) {
      final elapsed = DateTime.now().difference(_callStartTime!);
      callDuration = elapsed.inSeconds;
      // logger.debug('📞 计算通话时长: $callDuration 秒');
    }

    // 立即标记为 ended 状态，防止重复调用
    final previousState = _callState;
    _updateCallState(CallState.ended);

    // 🔴 新增：在清空通话信息前，保存最后一次的群组ID和通话类型
    // 这样在 onCallEnded 回调中仍能读取到这些信息
    _lastGroupId = _currentGroupId;
    _lastCallType = _callType;
    // 注意：_lastCallUserId 已在方法开头保存，这里只是确保不会被覆盖为 null
    if (_currentCallUserId != null) {
      _lastCallUserId = _currentCallUserId;
    }
    logger.debug('📞 保存最后通话信息 - 群组ID: $_lastGroupId, 通话类型: $_lastCallType, 用户ID: $_lastCallUserId');

    // 🔴 修复：触发通话结束回调，通知UI关闭来电对话框，传递通话时长
    // logger.debug('📞 触发 onCallEnded 回调，通知UI关闭对话框，通话时长: $callDuration 秒');
    onCallEnded?.call(callDuration);

    // 🔴 新增：如果是群组通话，调用服务器API通知其他成员
    if (_isGroupCall() &&
        _currentChannelName != null &&
        (previousState == CallState.connected ||
            previousState == CallState.calling ||
            previousState == CallState.ringing)) {
      // logger.debug('📞 群组通话结束，调用服务器API通知其他成员');
      try {
        final userToken = await Storage.getToken();
        if (userToken != null) {
          await ApiService.leaveGroupCall(
            token: userToken,
            channelName: _currentChannelName!,
            groupId: _currentGroupId,
            callType: _callType == CallType.video ? 'video' : 'voice',
          );
          // logger.debug('✅ 群组通话离开消息发送成功');
        } else {
          // logger.debug('⚠️ 用户token为空，无法发送群组通话离开消息');
        }
      } catch (e) {
        // logger.debug('⚠️ 发送群组通话离开消息失败: $e');
      }
    }
    // 通知对方挂断（仅在单人通话且之前是 connected 或 calling 状态时）
    else if (_currentCallUserId != null &&
        (previousState == CallState.connected ||
            previousState == CallState.calling)) {
      try {
        _wsService.sendWebRTCSignal({
          'type': 'call-ended',
          'targetUserId': _currentCallUserId,
        });
      } catch (e) {
        // logger.debug('⚠️ 发送挂断信令失败: $e');
      }
    }

    // 离开频道（带超时保护）
    if (_engine != null && _currentChannelName != null) {
      try {
        // logger.debug('📞 准备离开频道...');

        // 🔴 优化：视频通话时，先停止预览并禁用视频，再离开频道
        // 原因：先释放摄像头资源可以避免清理时的卡顿
        if (_callType == CallType.video) {
          // logger.debug('📹 [通话结束] 准备停止视频预览...');
          // 🔴 优化：缩短超时时间为 800ms，避免长时间卡顿
          await _engine!
              .stopPreview()
              .timeout(
                const Duration(milliseconds: 800),
                onTimeout: () {
                  // logger.debug('⚠️ 停止预览超时（800ms），强制继续');
                },
              )
              .catchError((e) {
                // logger.debug('⚠️ 停止预览失败: $e');
              });
          // logger.debug('📹 [通话结束] ✅ 视频预览已停止');

          // 🔴 优化：禁用视频也添加超时保护
          await _engine!
              .disableVideo()
              .timeout(
                const Duration(milliseconds: 500),
                onTimeout: () {
                  // logger.debug('⚠️ 禁用视频超时（500ms），强制继续');
                },
              )
              .catchError((e) {
                // logger.debug('⚠️ 禁用视频失败: $e');
              });
          // logger.debug('📹 [通话结束] ✅ 视频已禁用');
        }

        // 🔴 优化：缩短 leaveChannel 超时时间为 2 秒
        await _engine!
            .leaveChannel()
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                // logger.debug('⚠️ 离开频道超时（2秒），强制继续');
              },
            )
            .catchError((e) {
              // logger.debug('⚠️ 离开频道失败: $e');
            });

        // logger.debug('📞 已离开频道');
      } catch (e) {
        // logger.debug('⚠️ 离开频道失败: $e');
      }
    }

    _currentCallUserId = null;
    _currentChannelName = null;
    _currentAgoraToken = null;
    _currentGroupId = null;
    _remoteUids.clear();

    // 🔴 清除最小化标识（通话结束时）
    _isCallMinimized = false;
    _minimizedCallUserId = null;
    _minimizedCallDisplayName = null;
    _minimizedCallType = null;
    _minimizedIsGroupCall = false;
    _minimizedGroupId = null;
    // logger.debug('📞 已清除最小化标识');

    // 🔴 注意：不清除 _currentGroupCallUserIds 和 _currentGroupCallDisplayNames
    // 因为这些信息在通话结束后仍然需要用于UI显示
    // 下次通话时会被自动覆盖

    // 延迟重置 idle 状态
    await Future.delayed(const Duration(milliseconds: 500));
    _updateCallState(CallState.idle);
    // logger.debug('📞 通话已完全结束，状态重置为 idle');

    // 🔴 优化：清除标志位，允许下次调用
    _isEndingCall = false;
    // 🔴 重置本地挂断标识（在下次通话前）
    // 注意：不在这里重置，因为 onCallEnded 回调可能还需要读取这个值
  }

  /// 处理来电（旧版WebSocket信令）
  void _handleIncomingCall(Map<String, dynamic> data) {
    // logger.debug('📞 收到来电（旧版信令）: $data');

    // 🔴 检查是否已经收到了来电通知（避免重复显示对话框）
    final channelName = data['channelName'];
    if (_callState == CallState.ringing && _currentChannelName == channelName) {
      // logger.debug('📞 已经收到过该频道的来电通知，跳过重复处理: $channelName');
      return;
    }

    _currentCallUserId = data['fromUserId'];
    _callType = data['callType'] == 'video' ? CallType.video : CallType.voice;
    _currentChannelName = data['channelName'];
    _updateCallState(CallState.ringing);

    onIncomingCall?.call(
      _currentCallUserId!,
      data['callerName'] ?? '未知用户',
      _callType,
    );
  }

  /// 处理来电（服务器API发送的通知，包含Token）
  void _handleIncomingCallFromServer(Map<String, dynamic> data) async {
    // logger.debug('📞 收到来电（服务器通知）: $data');

    // 🔴 检查是否已经收到了来电通知（避免重复显示对话框）
    final channelName = data['channel_name'];
    if (_callState == CallState.ringing && _currentChannelName == channelName) {
      // logger.debug('📞 已经收到过该频道的来电通知，跳过重复处理: $channelName');
      return;
    }

    _currentCallUserId = data['caller_id'];
    _callType = data['call_type'] == 'video' ? CallType.video : CallType.voice;
    _currentChannelName = data['channel_name'];
    _currentAgoraToken = data['token']; // 🔴 保存服务器提供的Token
    _updateCallState(CallState.ringing);

    // logger.debug('📞 保存来电信息:');
    // logger.debug('   - 主叫用户ID: $_currentCallUserId');
    // logger.debug('   - 频道名称: $_currentChannelName');
    // logger.debug(
    //   '   - Agora Token: ${_currentAgoraToken?.substring(0, 20)}...',
    // );
    // logger.debug('   - 通话类型: $_callType');

    final callerName = data['caller_display_name'] ?? data['caller_username'] ?? '未知用户';
    
    // 🔴 检查应用是否在后台，如果在后台则显示原生弹窗
    final isAppInBackground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    
    if (Platform.isAndroid && isAppInBackground) {
      // 应用在后台，显示原生来电弹窗
      logger.debug('📱 应用在后台，显示原生来电弹窗');
      try {
        await NativeCallService().showCallOverlay(
          callerName: callerName,
          callerId: _currentCallUserId!,
          callType: _callType == CallType.video ? 'video' : 'voice',
          channelName: _currentChannelName!,
        );
      } catch (e) {
        logger.debug('❌ 显示原生来电弹窗失败: $e');
        // 失败时回退到 Flutter 回调
        onIncomingCall?.call(_currentCallUserId!, callerName, _callType);
      }
    } else {
      // 应用在前台，使用 Flutter 回调
      logger.debug('📱 应用在前台，使用 Flutter 来电页面');
      onIncomingCall?.call(_currentCallUserId!, callerName, _callType);
    }
  }

  /// 处理群组来电（服务器API发送的通知，包含Token和成员列表）
  void _handleIncomingGroupCallFromServer(Map<String, dynamic> data) async {
    // logger.debug('📞 收到群组来电（服务器通知）: $data');

    // 🔴 检查是否已经收到了来电通知（避免重复显示对话框）
    final channelName = data['channel_name'];
    if (_callState == CallState.ringing && _currentChannelName == channelName) {
      // logger.debug('📞 已经收到过该频道的来电通知，跳过重复处理: $channelName');
      return;
    }

    _currentCallUserId = data['caller_id'];
    _callType = data['call_type'] == 'video' ? CallType.video : CallType.voice;
    _currentChannelName = data['channel_name'];
    _currentAgoraToken = data['token']; // 🔴 保存服务器提供的Token
    _updateCallState(CallState.ringing);

    // 解析群组ID
    final groupId = data['group_id'] as int?;
    _currentGroupId = groupId; // 🔴 保存群组ID，用于后续发送通话结束消息

    // 解析成员列表
    // logger.debug('📞 开始解析成员列表...');
    // logger.debug('📞 原始 members 数据类型: ${data['members'].runtimeType}');
    // logger.debug('📞 原始 members 数据: ${data['members']}');
    final members =
        (data['members'] as List?)
            ?.map((m) => Map<String, dynamic>.from(m as Map))
            .toList() ??
        [];

    // 🔴 新增：保存群组成员信息，用于恢复通话时显示群组样式
    _currentGroupCallUserIds = members.map((m) => m['user_id'] as int).toList();
    _currentGroupCallDisplayNames = members
        .map((m) => m['display_name'] as String)
        .toList();
    
    final callerName = data['caller_display_name'] ?? data['caller_username'] ?? '未知用户';
    
    // 🔴 检查应用是否在后台，如果在后台则显示原生弹窗
    final isAppInBackground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    
    if (Platform.isAndroid && isAppInBackground) {
      // 应用在后台，显示原生来电弹窗
      logger.debug('📱 应用在后台，显示原生群组来电弹窗');
      logger.debug('📱 群组ID: $groupId, 成员数: ${members.length}');
      try {
        await NativeCallService().showCallOverlay(
          callerName: callerName,
          callerId: _currentCallUserId!,
          callType: _callType == CallType.video ? 'video' : 'voice',
          channelName: _currentChannelName!,
          isGroupCall: true,
          groupId: groupId,
          members: members,
        );
      } catch (e) {
        logger.debug('❌ 显示原生来电弹窗失败: $e');
        // 失败时回退到 Flutter 回调
        onIncomingGroupCall?.call(_currentCallUserId!, callerName, _callType, members, groupId);
      }
    } else {
      // 应用在前台，使用 Flutter 回调
      logger.debug('📱 应用在前台，使用 Flutter 群组来电页面');
      onIncomingGroupCall?.call(_currentCallUserId!, callerName, _callType, members, groupId);
    }
  }

  /// 处理群组通话成员接听通知
  void _handleGroupCallMemberAccepted(Map<String, dynamic> data) {
    // logger.debug('📞 收到群组通话成员接听通知: $data');

    final accepterUserId = data['accepter_user_id'] as int?;
    final accepterDisplayName = data['accepter_display_name'] as String?;
    final channelName = data['channel_name'] as String?;
    final callerUserId = data['caller_user_id'] as int?;

    if (accepterUserId == null ||
        accepterDisplayName == null ||
        channelName == null) {
      // logger.debug('⚠️ 群组通话成员接听通知数据不完整');
      return;
    }

    // 检查是否是当前通话的频道
    if (_currentChannelName != channelName) {
      // logger.debug('⚠️ 收到的频道名称与当前通话不匹配: $channelName vs $_currentChannelName');
      return;
    }

    // 检查当前用户是否参与此通话
    // 简化逻辑：只要当前有活跃的群组通话，就处理成员接听通知
    if (_callState != CallState.calling &&
        _callState != CallState.connected &&
        _callState != CallState.ringing) {
      // logger.debug('⚠️ 当前没有活跃的通话，忽略成员接听通知');
      return;
    }

    // 额外检查：如果当前用户是发起者或参与者，确保处理消息
    // 触发群组成员状态更新回调
    onGroupCallMemberStatusChanged?.call(
      accepterUserId,
      'accepted',
      accepterDisplayName,
    );
  }

  /// 处理群组通话成员离开通知
  void _handleGroupCallMemberLeft(Map<String, dynamic> data) {
    // logger.debug('📞 收到群组通话成员离开通知: $data');

    final leftUserId = data['left_user_id'] as int?;
    final leftDisplayName = data['left_display_name'] as String?;
    final channelName = data['channel_name'] as String?;

    if (leftUserId == null || leftDisplayName == null || channelName == null) {
      // logger.debug('⚠️ 群组通话成员离开通知数据不完整');
      return;
    }

    // 检查是否是当前通话的频道
    if (_currentChannelName != channelName) {
      // logger.debug('⚠️ 收到的频道名称与当前通话不匹配: $channelName vs $_currentChannelName');
      return;
    }

    // 检查当前用户是否参与此通话
    if (_callState != CallState.calling &&
        _callState != CallState.connected &&
        _callState != CallState.ringing) {
      // logger.debug('⚠️ 当前没有活跃的通话，忽略成员离开通知');
      return;
    }

    // logger.debug('📞 群组成员 $leftDisplayName ($leftUserId) 已离开通话');

    // 触发群组成员状态更新回调
    onGroupCallMemberStatusChanged?.call(leftUserId, 'left', leftDisplayName);
  }

  /// 🔴 处理群组通话结束通知（通知未接听成员关闭来电弹窗）
  void _handleGroupCallEnded(Map<String, dynamic> data) {
    logger.debug('📞 收到群组通话结束通知: $data');

    final channelName = data['channel_name'] as String?;

    if (channelName == null) {
      logger.debug('⚠️ 群组通话结束通知数据不完整');
      return;
    }

    // 检查是否是当前正在响铃的通话
    if (_currentChannelName != channelName) {
      logger.debug('⚠️ 收到的频道名称与当前通话不匹配: $channelName vs $_currentChannelName');
      return;
    }

    // 只有在响铃状态（来电弹窗显示中）时才需要处理
    if (_callState != CallState.ringing) {
      logger.debug('⚠️ 当前不是响铃状态，忽略通话结束通知');
      return;
    }

    logger.debug('📞 群组通话已结束，关闭来电弹窗');

    // 重置通话状态
    _updateCallState(CallState.idle);
    _currentChannelName = null;
    _currentCallUserId = null;
    _currentAgoraToken = null;
    _currentGroupId = null;
    _currentGroupCallUserIds = null;
    _currentGroupCallDisplayNames = null;

    // 触发通话结束回调，通知 UI 关闭来电弹窗
    // 通话时长为 0（因为未接听）
    onCallEnded?.call(0);

    // 🔴 如果是 Android 且显示了原生来电弹窗，需要关闭它
    if (Platform.isAndroid) {
      try {
        NativeCallService().dismissCallOverlay();
        logger.debug('📞 已关闭原生来电弹窗');
      } catch (e) {
        logger.debug('⚠️ 关闭原生来电弹窗失败: $e');
      }
    }
  }

  /// 处理对方接受通话
  Future<void> _handleCallAccepted(Map<String, dynamic> data) async {
    // logger.debug('📞 对方已接受通话');

    // 立即更新状态为已连接，提供即时反馈
    if (_callState == CallState.calling) {
      // logger.debug('📞 更新状态: calling -> connected');
      _updateCallState(CallState.connected);
    }

    // onUserJoined 回调仍然会被触发，但由于状态已经是 connected，不会重复处理
    // 这样可以确保即使 onUserJoined 有延迟，UI 也能立即响应
  }

  /// 处理对方拒绝通话
  void _handleCallRejected(Map<String, dynamic> data) {
    logger.debug('📞 收到拒绝通话消息: $data');
    
    // 🔴 修复：群组通话中，有人拒绝不应该结束整个通话
    // 只需要更新该成员的状态，让UI显示该成员已拒绝
    if (_isGroupCall()) {
      logger.debug('📞 群组通话：有成员拒绝，不结束通话，只更新成员状态');
      
      // 从消息中获取拒绝者的信息
      final rejecterId = data['rejecter_user_id'] as int? ?? data['from_user_id'] as int?;
      final rejecterName = data['rejecter_display_name'] as String? ?? '未知用户';
      
      if (rejecterId != null) {
        // 触发群组成员状态更新回调，通知UI更新该成员状态为"已拒绝"
        onGroupCallMemberStatusChanged?.call(rejecterId, 'left', rejecterName);
        logger.debug('📞 群组通话：成员 $rejecterName ($rejecterId) 已拒绝');
      }
      
      // 不调用 endCall()，让通话继续
      return;
    }
    
    // 单人通话：对方拒绝，结束通话
    logger.debug('📞 单人通话：对方拒绝了通话');
    onError?.call('对方拒绝了通话');
    // 🔴 对方拒绝，不是本地主动挂断
    endCall(isLocalHangup: false);
  }

  /// 更新通话状态
  void _updateCallState(CallState newState) {
    _callState = newState;

    // 记录通话开始时间
    if (newState == CallState.connected && _callStartTime == null) {
      _callStartTime = DateTime.now();
      logger.debug('📞 记录通话开始时间: $_callStartTime');
    }

    // 清除通话开始时间
    if (newState == CallState.ended || newState == CallState.idle) {
      _callStartTime = null;
      logger.debug('📞 清除通话开始时间');
    }

    onCallStateChanged?.call(newState);
    logger.debug('📞 通话状态变化: $newState');
  }

  // 静音状态（由于 Agora SDK 没有直接获取静音状态的方法，需要自己维护）
  bool _isMuted = false;

  /// 切换静音
  Future<void> toggleMute() async {
    if (_engine != null) {
      try {
        _isMuted = !_isMuted;
        await _engine!.muteLocalAudioStream(_isMuted);
        logger.debug('📞 ${_isMuted ? '静音' : '取消静音'}');
      } catch (e) {
        logger.debug('⚠️ 切换静音失败: $e');
      }
    }
  }

  /// 获取当前静音状态
  bool get isMuted => _isMuted;

  /// 切换扬声器
  /// 移动端：在听筒和扬声器之间切换
  /// PC端：使用系统默认音频输出设备（通常是扬声器）
  Future<void> toggleSpeaker() async {
    if (_engine != null) {
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        // 移动端：切换听筒/扬声器
        try {
          final isSpeakerOn = await _engine!.isSpeakerphoneEnabled();
          await _engine!.setEnableSpeakerphone(!isSpeakerOn);
          logger.debug('📞 ${isSpeakerOn ? '关闭' : '开启'}扬声器（移动端）');
        } catch (e) {
          logger.debug('⚠️ 切换扬声器失败: $e');
        }
      } else if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux) {
        // PC端：调整音频路由到默认播放设备
        try {
          // 获取音频设备管理器
          final audioDeviceManager = _engine!.getAudioDeviceManager();
          final devices = await audioDeviceManager.enumeratePlaybackDevices();
          if (devices.isNotEmpty && devices[0].deviceId != null) {
            // 使用第一个设备（通常是默认扬声器）
            await audioDeviceManager.setPlaybackDevice(devices[0].deviceId!);
            logger.debug('📞 PC端音频输出设置为: ${devices[0].deviceName}');
          } else {
            logger.debug('⚠️ 未找到音频播放设备');
          }
        } catch (e) {
          logger.debug('⚠️ PC端音频设备设置失败: $e');
          // PC端通常会自动使用系统默认设备，失败也不影响通话
        }
      }
    }
  }

  /// 获取所有音频播放设备（PC端）
  Future<List<AudioDeviceInfo>> getPlaybackDevices() async {
    if (_engine != null &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        final audioDeviceManager = _engine!.getAudioDeviceManager();
        final devices = await audioDeviceManager.enumeratePlaybackDevices();
        logger.debug('📢 找到 ${devices.length} 个音频播放设备');
        for (var device in devices) {
          logger.debug('  - ${device.deviceName} (ID: ${device.deviceId})');
        }
        return devices;
      } catch (e) {
        logger.debug('⚠️ 获取播放设备列表失败: $e');
        return [];
      }
    }
    return [];
  }

  /// 设置音频播放设备（PC端）
  Future<bool> setPlaybackDevice(String deviceId) async {
    if (_engine != null &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        logger.debug('🔊 开始切换扬声器设备: $deviceId');
        final audioDeviceManager = _engine!.getAudioDeviceManager();

        // 设置新的播放设备
        await audioDeviceManager.setPlaybackDevice(deviceId);
        logger.debug('🔊 扬声器设备已设置');

        // 延迟一下确保设备切换完成
        await Future.delayed(const Duration(milliseconds: 50));

        // 验证设备是否切换成功
        try {
          final currentDeviceId = await audioDeviceManager.getPlaybackDevice();
          logger.debug('🔊 当前扬声器设备ID: $currentDeviceId');
          if (currentDeviceId == deviceId) {
            logger.debug('✅ 扬声器设备切换成功验证');
          } else {
            logger.debug('⚠️ 扬声器设备ID不匹配: 期望=$deviceId, 实际=$currentDeviceId');
          }
        } catch (e) {
          logger.debug('⚠️ 无法验证扬声器设备切换: $e');
        }

        return true;
      } catch (e) {
        logger.debug('⚠️ 设置播放设备失败: $e');
        return false;
      }
    }
    return false;
  }

  /// 获取所有音频录制设备（PC端）
  Future<List<AudioDeviceInfo>> getRecordingDevices() async {
    if (_engine != null &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        final audioDeviceManager = _engine!.getAudioDeviceManager();
        final devices = await audioDeviceManager.enumerateRecordingDevices();
        logger.debug('🎤 找到 ${devices.length} 个音频录制设备');
        for (var device in devices) {
          logger.debug('  - ${device.deviceName} (ID: ${device.deviceId})');
        }
        return devices;
      } catch (e) {
        logger.debug('⚠️ 获取录制设备列表失败: $e');
        return [];
      }
    }
    return [];
  }

  /// 设置音频录制设备（PC端）
  Future<bool> setRecordingDevice(String deviceId) async {
    if (_engine != null &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        logger.debug('🎤 开始切换麦克风设备: $deviceId');
        final audioDeviceManager = _engine!.getAudioDeviceManager();

        // 设置新的录制设备
        await audioDeviceManager.setRecordingDevice(deviceId);
        logger.debug('🎤 麦克风设备已设置');

        // 延迟一下确保设备切换完成
        await Future.delayed(const Duration(milliseconds: 50));

        // 验证设备是否切换成功
        try {
          final currentDeviceId = await audioDeviceManager.getRecordingDevice();
          logger.debug('🎤 当前麦克风设备ID: $currentDeviceId');
          if (currentDeviceId == deviceId) {
            logger.debug('✅ 麦克风设备切换成功验证');
          } else {
            logger.debug('⚠️ 麦克风设备ID不匹配: 期望=$deviceId, 实际=$currentDeviceId');
          }
        } catch (e) {
          logger.debug('⚠️ 无法验证麦克风设备切换: $e');
        }

        return true;
      } catch (e) {
        logger.debug('⚠️ 设置录制设备失败: $e');
        return false;
      }
    }
    return false;
  }

  /// 切换摄像头（前后摄像头）
  Future<void> switchCamera() async {
    if (_engine != null && _callType == CallType.video) {
      try {
        await _engine!.switchCamera();
        logger.debug('📹 切换摄像头');
      } catch (e) {
        logger.debug('⚠️ 切换摄像头失败: $e');
      }
    }
  }

  /// 获取 RTC 引擎（用于视频渲染）
  RtcEngine? get engine => _engine;

  /// 设置群组通话的频道信息（用于群组通话发起）
  void setGroupCallChannel(
    String channelName,
    String token,
    CallType callType, {
    int? groupId,
    List<int>? memberUserIds,
    List<String>? memberDisplayNames,
  }) {
    _currentChannelName = channelName;
    _currentAgoraToken = token;
    _callType = callType;
    _currentGroupId = groupId;

    // 🔴 新增：保存群组成员信息
    _currentGroupCallUserIds = memberUserIds;
    _currentGroupCallDisplayNames = memberDisplayNames;

    // 🔴 修复：不在这里改变callState，让VoiceCallPage的_startCall来处理
    // 这样可以确保正确进入群组通话流程并调用joinGroupCallChannel
    // _updateCallState(CallState.calling);  // 注释掉，避免提前改变状态
    // logger.debug('📞 群组通话频道信息已保存（不改变callState，由VoiceCallPage处理）');
  }

  /// 加入群组通话频道（用于群组通话发起者）
  Future<void> joinGroupCallChannel() async {
    if (_engine == null) {
      // logger.debug('📞 Agora 引擎未初始化');
      onError?.call('Agora 引擎未初始化');
      return;
    }

    if (_currentChannelName == null || _currentAgoraToken == null) {
      // logger.debug('📞 频道信息不完整，无法加入');
      onError?.call('频道信息不完整');
      return;
    }

    // 🔴 修复：检查用户ID有效性（与一对一通话保持一致）
    if (_myUserId == null || _myUserId == 0) {
      // logger.debug('❌ 用户ID无效: $_myUserId，无法加入群组通话');
      onError?.call('用户ID无效，请确保已正确初始化 Agora 服务');
      throw Exception('用户ID无效: $_myUserId，请确保已正确初始化 Agora 服务');
    }

    // logger.debug('📞 加入群组通话频道:');
    // logger.debug('  - 频道名称: $_currentChannelName');
    // logger.debug('  - 用户ID: $_myUserId');
    // logger.debug('  - Token: ${_currentAgoraToken!.substring(0, 20)}...');
    // logger.debug('  - 当前callState: $_callState');

    // 🔴 修复：更新状态为 calling，确保可以接收群组成员的接听通知
    _updateCallState(CallState.calling);
    logger.debug('📞 已更新 callState 为 calling');

    // 🔴 修复：根据通话类型动态配置音视频参数
    final isVideoCall = _callType == CallType.video;
    logger.debug('📞 通话类型: ${isVideoCall ? "视频" : "语音"}');

    // 🔴 修复：视频通话时需要启用视频和预览（与 startGroupVideoCall 保持一致）
    if (isVideoCall) {
      logger.debug('📹 [joinGroupCallChannel] 启用视频...');
      await _engine!.enableVideo();
      
      try {
        logger.debug('📹 [joinGroupCallChannel] 启动视频预览...');
        await _engine!.startPreview();
      } catch (e) {
        logger.debug('📹 [joinGroupCallChannel] 视频预览启动失败: $e');
      }
      
      await _engine!.setVideoEncoderConfiguration(
        const VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: 640, height: 480),
          frameRate: 15,
          bitrate: 0,
        ),
      );
      logger.debug('📹 [joinGroupCallChannel] 视频配置完成');
    }

    await _engine!.joinChannel(
      token: _currentAgoraToken!,
      channelId: _currentChannelName!,
      uid: _myUserId!,
      options: ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        // 🔴 关键：显式启用音频发布和订阅
        publishMicrophoneTrack: true,
        // 🔴 修复：视频通话时启用摄像头发布
        publishCameraTrack: isVideoCall,
        autoSubscribeAudio: true,
        // 🔴 修复：视频通话时启用视频订阅
        autoSubscribeVideo: isVideoCall,
      ),
    );

    logger.debug('📞 ✅ 已成功调用joinChannel，等待onJoinChannelSuccess回调');
  }

  Future<void> startGroupVideoCall(List<int> calleeIds, {int? groupId}) async {
    if (_engine == null) {
      logger.debug('📞 Agora 引擎未初始化');
      onError?.call('Agora 引擎未初始化');
      return;
    }

    try {
      logger.debug('📞 开始发起群组视频通话, calleeIds=$calleeIds');
      
      // 🔴 修复：如果传入了 groupId，使用传入的值；否则使用已保存的 _currentGroupId
      final effectiveGroupId = groupId ?? _currentGroupId;
      logger.debug('📞 使用的 groupId: $effectiveGroupId (传入: $groupId, 已保存: $_currentGroupId)');
      
      // 🔴 保存 groupId
      if (groupId != null) {
        _currentGroupId = groupId;
      }

      final userToken = await Storage.getToken();
      if (userToken == null) {
        throw Exception('用户未登录');
      }

      _callType = CallType.video;
      _updateCallState(CallState.calling);

      final callData = await ApiService.initiateGroupCall(
        token: userToken,
        calleeIds: calleeIds,
        callType: 'video',
        groupId: effectiveGroupId, // 🔴 修复：传递群组ID
      );

      _currentChannelName = callData['channel_name'];
      _currentAgoraToken = callData['token'];
      logger.debug('📞 群组视频通话频道: $_currentChannelName');

      await _engine!.enableVideo();

      try {
        await _engine!.startPreview();
      } catch (e) {
        logger.debug('📹 群组视频预览启动失败: $e');
      }

      await _engine!.setVideoEncoderConfiguration(
        const VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: 640, height: 480),
          frameRate: 15,
          bitrate: 0,
        ),
      );

      if (_myUserId == null || _myUserId == 0) {
        throw Exception('用户ID无效: $_myUserId');
      }

      if (_currentChannelName == null || _currentChannelName!.isEmpty) {
        throw Exception('频道名称无效');
      }

      if (_currentAgoraToken == null || _currentAgoraToken!.isEmpty) {
        throw Exception('Token 无效，服务器未返回有效的 Token');
      }

      await _engine!.joinChannel(
        token: _currentAgoraToken!,
        channelId: _currentChannelName!,
        uid: _myUserId!,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: true,
          publishCameraTrack: true,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
    } catch (e) {
      onError?.call('发起群组视频通话失败: $e');
    }
  }

  /// 获取当前用户 ID
  int? get myUserId => _myUserId;

  /// 获取远程用户 ID 列表
  Set<int> get remoteUids => _remoteUids;

  /// 获取当前状态和信息的 getter 方法
  CallState get callState => _callState;
  CallType get callType => _callType;
  String? get currentChannelName => _currentChannelName;
  int? get currentCallUserId => _currentCallUserId;
  DateTime? get callStartTime => _callStartTime;
  int? get currentGroupId => _currentGroupId; // 🔴 新增：获取当前群组通话的群组ID

  // 🔴 新增：获取最后一次通话的群组ID和通话类型
  int? get lastGroupId => _lastGroupId;
  CallType? get lastCallType => _lastCallType;
  int? get lastCallUserId => _lastCallUserId; // 🔴 新增：获取最后一次通话的对方用户ID

  // 🔴 新增：获取当前群组通话的成员信息
  List<int>? get currentGroupCallUserIds => _currentGroupCallUserIds;
  List<String>? get currentGroupCallDisplayNames =>
      _currentGroupCallDisplayNames;

  // 🔴 新增：获取最小化通话信息
  bool get isCallMinimized => _isCallMinimized;
  int? get minimizedCallUserId => _minimizedCallUserId;
  String? get minimizedCallDisplayName => _minimizedCallDisplayName;
  CallType? get minimizedCallType => _minimizedCallType;
  bool get minimizedIsGroupCall => _minimizedIsGroupCall;
  int? get minimizedGroupId => _minimizedGroupId;
  Set<int>? get connectedMemberIds => _connectedMemberIds; // 🔴 新增：获取已连接成员ID集合
  bool get isMinimized => _isCallMinimized; // 是否有通话被最小化
  
  // 🔴 新增：缺失的 getter 方法
  bool get isMinimizedGroupCall => _minimizedIsGroupCall;
  List<int>? get minimizedGroupCallUserIds => _currentGroupCallUserIds;
  List<String>? get minimizedGroupCallDisplayNames => _currentGroupCallDisplayNames;

  /// 设置通话最小化状态
  void setCallMinimized({
    required bool isMinimized,
    int? callUserId,
    String? callDisplayName,
    CallType? callType,
    bool isGroupCall = false,
    int? groupId,
    List<int>? groupCallUserIds,
    List<String>? groupCallDisplayNames,
    Set<int>? connectedMemberIds, // 🔴 新增：保存已连接成员ID集合
  }) {
    _isCallMinimized = isMinimized;
    _minimizedCallUserId = callUserId;
    _minimizedCallDisplayName = callDisplayName;
    _minimizedCallType = callType;
    _minimizedIsGroupCall = isGroupCall;
    _minimizedGroupId = groupId;

    // 🔴 修复：如果是最小化群组通话，保存群组成员信息
    if (isMinimized &&
        isGroupCall &&
        groupCallUserIds != null &&
        groupCallDisplayNames != null) {
      _currentGroupCallUserIds = List<int>.from(groupCallUserIds);
      _currentGroupCallDisplayNames = List<String>.from(groupCallDisplayNames);

      // 🔴 新增：保存已连接成员ID集合
      if (connectedMemberIds != null) {
        _connectedMemberIds = Set<int>.from(connectedMemberIds);
      }
    }
  }

  /// 判断是否为群组通话
  bool _isGroupCall() {
    // 通过频道名称判断是否为群组通话
    // 群组通话频道名格式: group_call_${callerId}_${timestamp}
    return _currentChannelName != null &&
        _currentChannelName!.startsWith('group_call_');
  }

  /// 清理资源
  Future<void> dispose() async {
    await endCall();

    if (_engine != null) {
      await _engine!.leaveChannel();
      await _engine!.release();
      _engine = null;
    }

    _wsService.onWebRTCSignal = null;
  }
}
