// 通话服务适配器
// 此文件作为兼容层，根据平台选择不同的通话服务：
// - Android/iOS: 使用 TUICallKitService（腾讯云 TUICallKit）
// - Windows/macOS/Linux: 使用 TRTCDesktopService（腾讯云 TRTC SDK）
// 保持现有代码的兼容性

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'tuicallkit_service.dart';
import 'trtc_desktop_service.dart';
import 'websocket_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';

// 重新导出 CallState 和 CallType，保持兼容性
export 'tuicallkit_service.dart' show CallState, CallType;

/// 判断是否为桌面平台
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// 通话服务适配器（兼容层）
/// 根据平台自动选择 TUICallKitService 或 TRTCDesktopService
class AgoraService {
  // 单例模式
  static final AgoraService _instance = AgoraService._internal();
  factory AgoraService() => _instance;
  AgoraService._internal();

  // 内部服务 - 🔴 桌面端不创建 TUICallKitService，避免 SDK 自动初始化
  TUICallKitService? _tuiService;
  TRTCDesktopService? _desktopService;

  // 懒加载获取服务实例
  TUICallKitService get _tui {
    _tuiService ??= TUICallKitService();
    return _tuiService!;
  }

  TRTCDesktopService get _desktop {
    _desktopService ??= TRTCDesktopService();
    return _desktopService!;
  }

  // 获取当前使用的服务
  bool get isDesktop => _isDesktopPlatform;
  TRTCDesktopService get desktopService => _desktop;

  // 兼容性：engine 属性
  dynamic get engine => _isDesktopPlatform ? _desktop.trtcCloud : null;

  // 转发所有属性（根据平台选择）
  CallState get callState {
    if (_isDesktopPlatform) {
      // 转换桌面端状态到通用状态
      switch (_desktop.callState) {
        case DesktopCallState.idle:
          return CallState.idle;
        case DesktopCallState.waiting:
          // waiting 状态根据角色判断是 calling 还是 ringing
          if (_desktop.callRole == DesktopCallRole.caller) {
            return CallState.calling;
          } else {
            return CallState.ringing;
          }
        case DesktopCallState.accept:
          return CallState.connected;
      }
    }
    return _tui.callState;
  }

  CallType get callType {
    if (_isDesktopPlatform) {
      return _desktop.callType == DesktopCallType.video 
          ? CallType.video 
          : CallType.voice;
    }
    return _tui.callType;
  }

  int? get currentCallUserId => _isDesktopPlatform 
      ? _desktop.currentCallUserId 
      : _tui.currentCallUserId;
  
  int? get myUserId => _isDesktopPlatform 
      ? _desktop.myUserId 
      : _tui.myUserId;
  
  DateTime? get callStartTime => _isDesktopPlatform 
      ? _desktop.callStartTime 
      : _tui.callStartTime;
  
  int? get currentGroupId => _isDesktopPlatform ? null : _tui.currentGroupId;
  int? get lastGroupId => _isDesktopPlatform ? null : _tui.lastGroupId;
  
  CallType? get lastCallType {
    if (_isDesktopPlatform) {
      // 桌面端暂不保存上次通话类型
      return null;
    }
    return _tui.lastCallType;
  }
  
  int? get lastCallUserId => _isDesktopPlatform 
      ? null 
      : _tui.lastCallUserId;
  
  bool get isCallMinimized => _isDesktopPlatform ? false : _tui.isCallMinimized;
  bool get isMinimized => isCallMinimized;
  bool get isMinimizedGroupCall => _isDesktopPlatform ? false : _tui.minimizedIsGroupCall;
  int? get minimizedCallUserId => _isDesktopPlatform ? null : _tui.minimizedCallUserId;
  String? get minimizedCallDisplayName => _isDesktopPlatform ? null : _tui.minimizedCallDisplayName;
  CallType? get minimizedCallType => _isDesktopPlatform ? null : _tui.minimizedCallType;
  bool get minimizedIsGroupCall => _isDesktopPlatform ? false : _tui.minimizedIsGroupCall;
  int? get minimizedGroupId => _isDesktopPlatform ? null : _tui.minimizedGroupId;
  List<int>? get currentGroupCallUserIds => _isDesktopPlatform ? null : _tui.currentGroupCallUserIds;
  List<String>? get currentGroupCallDisplayNames => _isDesktopPlatform ? null : _tui.currentGroupCallDisplayNames;
  List<int>? get minimizedGroupCallUserIds => currentGroupCallUserIds;
  List<String>? get minimizedGroupCallDisplayNames => currentGroupCallDisplayNames;
  Set<int>? get connectedMemberIds => _isDesktopPlatform ? null : _tui.connectedMemberIds;
  
  Set<int> get remoteUids => _isDesktopPlatform 
      ? _desktop.remoteUids 
      : _tui.remoteUids;
  
  bool get isLocalHangup => _isDesktopPlatform 
      ? _desktop.isLocalHangup 
      : _tui.isLocalHangup;
  
  String? get currentChannelName => null;
  String? get currentToken => null;

  // 转发所有回调（根据平台设置）
  set onCallStateChanged(Function(CallState)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onCallStateChanged = (DesktopCallState state) {
          CallState cs;
          switch (state) {
            case DesktopCallState.idle:
              cs = CallState.idle;
              break;
            case DesktopCallState.waiting:
              if (_desktop.callRole == DesktopCallRole.caller) {
                cs = CallState.calling;
              } else {
                cs = CallState.ringing;
              }
              break;
            case DesktopCallState.accept:
              cs = CallState.connected;
              break;
          }
          callback(cs);
        };
      }
    } else {
      _tui.onCallStateChanged = callback;
    }
  }
  Function(CallState)? get onCallStateChanged => _isDesktopPlatform ? null : _tui.onCallStateChanged;

  set onRemoteUserJoined(Function(int uid)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onRemoteUserJoined = (String odUserId, int uid) {
          callback(uid);
        };
      }
    } else {
      _tui.onRemoteUserJoined = callback;
    }
  }
  Function(int uid)? get onRemoteUserJoined => _isDesktopPlatform ? null : _tui.onRemoteUserJoined;

  set onRemoteUserLeft(Function(int uid)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onRemoteUserLeft = (String odUserId, int uid) {
          callback(uid);
        };
      }
    } else {
      _tui.onRemoteUserLeft = callback;
    }
  }
  Function(int uid)? get onRemoteUserLeft => _isDesktopPlatform ? null : _tui.onRemoteUserLeft;

  set onError(Function(String)? callback) {
    if (_isDesktopPlatform) {
      _desktop.onError = callback;
    } else {
      _tui.onError = callback;
    }
  }
  Function(String)? get onError => _isDesktopPlatform ? _desktop.onError : _tui.onError;

  set onIncomingCall(Function(int userId, String displayName, CallType callType)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onIncomingCall = (int userId, String displayName, DesktopCallType callType, int roomId) {
          callback(userId, displayName, callType == DesktopCallType.video ? CallType.video : CallType.voice);
        };
      }
    } else {
      _tui.onIncomingCall = callback;
    }
  }
  Function(int userId, String displayName, CallType callType)? get onIncomingCall => _isDesktopPlatform ? null : _tui.onIncomingCall;

  set onIncomingGroupCall(Function(
    int userId,
    String displayName,
    CallType callType,
    List<Map<String, dynamic>> members,
    int? groupId,
  )? callback) {
    if (_isDesktopPlatform) {
      // 🔴 桌面端也支持群组来电回调
      if (callback != null) {
        _desktop.onIncomingGroupCall = (int callerId, String callerName, DesktopCallType callType, int roomId, List<Map<String, dynamic>> members, int? groupId) {
          callback(callerId, callerName, callType == DesktopCallType.video ? CallType.video : CallType.voice, members, groupId);
        };
      } else {
        _desktop.onIncomingGroupCall = null;
      }
    } else {
      _tui.onIncomingGroupCall = callback;
    }
  }

  set onLocalVideoReady(Function()? callback) {
    if (_isDesktopPlatform) {
      _desktop.onLocalVideoReady = callback;
    } else {
      _tui.onLocalVideoReady = callback;
    }
  }
  Function()? get onLocalVideoReady => _isDesktopPlatform ? _desktop.onLocalVideoReady : _tui.onLocalVideoReady;

  set onRemoteVideoReady(Function(int uid)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onRemoteVideoReady = (String odUserId) {
          callback(int.tryParse(odUserId) ?? 0);
        };
      }
    } else {
      _tui.onRemoteVideoReady = callback;
    }
  }
  Function(int uid)? get onRemoteVideoReady => _isDesktopPlatform ? null : _tui.onRemoteVideoReady;

  set onCallEnded(Function(int callDuration)? callback) {
    if (_isDesktopPlatform) {
      _desktop.onCallEnded = callback;
    } else {
      _tui.onCallEnded = callback;
    }
  }
  Function(int callDuration)? get onCallEnded => _isDesktopPlatform ? _desktop.onCallEnded : _tui.onCallEnded;

  set onGroupCallMemberStatusChanged(Function(int userId, String status, String? displayName)? callback) {
    if (!_isDesktopPlatform) {
      _tui.onGroupCallMemberStatusChanged = callback;
    }
    // 桌面端暂不支持群组通话
  }

  set onRemoteVideoMuted(Function(int uid, bool isMuted)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onRemoteVideoAvailable = (String odUserId, bool available) {
          callback(int.tryParse(odUserId) ?? 0, !available);
        };
      }
    } else {
      _tui.onRemoteVideoMuted = callback;
    }
  }

  // 🔴 新增：通话取消回调
  set onCallCancelled(Function(int targetUserId, CallType callType, bool isCaller)? callback) {
    if (_isDesktopPlatform) {
      // 🔴 桌面端也支持通话取消回调
      if (callback != null) {
        _desktop.onCallCancelled = (int targetUserId, DesktopCallType callType, bool isCaller) {
          callback(targetUserId, callType == DesktopCallType.video ? CallType.video : CallType.voice, isCaller);
        };
      } else {
        _desktop.onCallCancelled = null;
      }
    } else {
      _tui.onCallCancelled = callback;
    }
  }
  Function(int targetUserId, CallType callType, bool isCaller)? get onCallCancelled => _isDesktopPlatform ? null : _tui.onCallCancelled;

  // 🔴 新增：接收方拒绝通话回调（接收方通过 TUICallKit 内置 UI 拒绝通话时触发）
  set onCallRejectedByMe(Function(int callerUserId, CallType callType)? callback) {
    if (_isDesktopPlatform) {
      // 桌面端暂不支持此回调
    } else {
      _tui.onCallRejectedByMe = callback;
    }
  }
  Function(int callerUserId, CallType callType)? get onCallRejectedByMe => _isDesktopPlatform ? null : _tui.onCallRejectedByMe;

  // 🔴 新增：群组通话房间已进入回调（使用 TRTC SDK 直接进入房间后触发）
  // 用于通知调用方导航到通话页面
  set onGroupCallRoomEntered(Function(int roomId, List<int> userIds, List<String> displayNames, CallType callType, int? groupId)? callback) {
    if (_isDesktopPlatform) {
      // 🔴 桌面端也支持群组通话回调
      if (callback != null) {
        _desktop.onGroupCallRoomEntered = (int roomId, List<int> userIds, List<String> displayNames, DesktopCallType callType, int? groupId) {
          callback(roomId, userIds, displayNames, callType == DesktopCallType.video ? CallType.video : CallType.voice, groupId);
        };
      }
    } else {
      _tui.onGroupCallRoomEntered = callback;
    }
  }
  Function(int roomId, List<int> userIds, List<String> displayNames, CallType callType, int? groupId)? get onGroupCallRoomEntered => _isDesktopPlatform ? null : _tui.onGroupCallRoomEntered;

  // 🔴 新增：TUICallKit 来电回调（收到来电时触发，用于准备显示遮盖层）
  set onTUICallReceived(Function(int callerId, String callerIdStr, CallType callType, bool isGroupCall, List<String> calleeIdList)? callback) {
    if (!_isDesktopPlatform) {
      _tui.onTUICallReceived = callback;
    }
  }
  Function(int callerId, String callerIdStr, CallType callType, bool isGroupCall, List<String> calleeIdList)? get onTUICallReceived => _isDesktopPlatform ? null : _tui.onTUICallReceived;

  // 🔴 新增：通话连接中回调（用户点击接听后、通话真正开始前触发）
  set onCallConnecting(Function()? callback) {
    if (!_isDesktopPlatform) {
      _tui.onCallConnecting = callback;
    }
  }
  Function()? get onCallConnecting => _isDesktopPlatform ? null : _tui.onCallConnecting;

  // 🔴 新增：通话已连接回调（通话真正开始时触发，用于隐藏遮盖层）
  set onCallConnected(Function()? callback) {
    if (!_isDesktopPlatform) {
      _tui.onCallConnected = callback;
    }
  }
  Function()? get onCallConnected => _isDesktopPlatform ? null : _tui.onCallConnected;

  // 🔴 新增：群组通话中用户离开但通话仍在继续回调
  // 用于在群组对话框中显示"加入通话"按钮
  set onGroupCallLeftButContinuing(Function(int groupId, CallType callType, int callDuration, String? callId)? callback) {
    if (!_isDesktopPlatform) {
      _tui.onGroupCallLeftButContinuing = callback;
    }
  }
  Function(int groupId, CallType callType, int callDuration, String? callId)? get onGroupCallLeftButContinuing => _isDesktopPlatform ? null : _tui.onGroupCallLeftButContinuing;

  // 🔴 新增：群组通话挂断回调
  // 用于发送通话时长消息给所有成员
  set onGroupCallHangup(Function(int groupId, CallType callType, int callDuration, bool isLastMember)? callback) {
    if (!_isDesktopPlatform) {
      _tui.onGroupCallHangup = callback;
    }
  }
  Function(int groupId, CallType callType, int callDuration, bool isLastMember)? get onGroupCallHangup => _isDesktopPlatform ? null : _tui.onGroupCallHangup;

  // 🔴 新增：通话中收到新来电被自动拒绝回调（用于发送"对方正在通话中"消息）
  // callerId: 来电者用户ID
  // callType: 通话类型（语音/视频）
  // 注意：仅一对一通话会触发此回调，群组通话直接拒绝不发送消息
  set onCallBusyRejected(Function(int callerId, CallType callType)? callback) {
    if (_isDesktopPlatform) {
      if (callback != null) {
        _desktop.onCallBusyRejected = (int callerId, DesktopCallType callType) {
          callback(callerId, callType == DesktopCallType.video ? CallType.video : CallType.voice);
        };
      } else {
        _desktop.onCallBusyRejected = null;
      }
    } else {
      _tui.onCallBusyRejected = callback;
    }
  }
  Function(int callerId, CallType callType)? get onCallBusyRejected => _isDesktopPlatform ? null : _tui.onCallBusyRejected;


  /// 设置来电信息（兼容性方法）
  void setIncomingCallInfo({
    required int callerId,
    required String channelName,
    required String token,
    required CallType callType,
    int? groupId,
  }) {
    logger.debug('📞 [通话适配器] setIncomingCallInfo 已弃用，通话服务自动处理来电');
  }

  /// 设置当前群组ID（用于在收到 join_voice_button 消息时保存群组ID）
  void setCurrentGroupId(int? groupId) {
    if (!_isDesktopPlatform) {
      _tui.setCurrentGroupId(groupId);
    }
  }

  /// 初始化
  Future<void> initialize(int currentUserId) async {
    if (_isDesktopPlatform) {
      // 🔴 桌面端只初始化 TRTCDesktopService，不创建 TUICallKitService
      await _desktop.initialize(currentUserId);
    } else {
      // 🔴 移动端只初始化 TUICallKitService
      await _tui.initialize(currentUserId);
    }
  }

  /// 重新配置代理（兼容性方法）
  Future<void> reconfigureProxy() async {
    logger.debug('📞 [通话适配器] reconfigureProxy 已弃用');
  }

  /// 发起语音通话
  Future<void> startVoiceCall(int targetUserId, String targetDisplayName) async {
    if (_isDesktopPlatform) {
      await _desktop.startVoiceCall(targetUserId, targetDisplayName);
    } else {
      await _tui.startVoiceCall(targetUserId, targetDisplayName);
    }
  }

  /// 发起视频通话
  Future<void> startVideoCall(int targetUserId, String targetDisplayName) async {
    if (_isDesktopPlatform) {
      await _desktop.startVideoCall(targetUserId, targetDisplayName);
    } else {
      await _tui.startVideoCall(targetUserId, targetDisplayName);
    }
  }

  /// 发起群组语音通话
  Future<void> startGroupVoiceCall(
    List<int> userIds,
    List<String> displayNames, {
    int? groupId,
  }) async {
    // 🔴 注意：不再由客户端发送 join_voice_button 消息
    // 服务器端在收到 incoming_group_call 信令时会自动发送（handleIncomingGroupCallSignal）
    // 这样可以避免消息重复
    
    if (_isDesktopPlatform) {
      // 🔴 PC 端使用 TRTC SDK 直接发起群组通话
      await _desktop.startGroupCall(userIds, displayNames, DesktopCallType.audio, groupId: groupId);
    } else {
      await _tui.startGroupCall(userIds, displayNames, CallType.voice, groupId: groupId);
    }
  }

  /// 发起群组视频通话
  Future<void> startGroupVideoCall(
    List<int> userIds,
    List<String> displayNames, {
    int? groupId,
  }) async {
    // 🔴 注意：不再由客户端发送 join_video_button 消息
    // 服务器端在收到 incoming_group_call 信令时会自动发送（handleIncomingGroupCallSignal）
    // 这样可以避免消息重复
    
    if (_isDesktopPlatform) {
      // 🔴 PC 端使用 TRTC SDK 直接发起群组通话
      await _desktop.startGroupCall(userIds, displayNames, DesktopCallType.video, groupId: groupId);
    } else {
      await _tui.startGroupCall(userIds, displayNames, CallType.video, groupId: groupId);
    }
  }

  /// 加入已存在的群组通话
  Future<void> joinGroupCall(
    List<int> userIds,
    List<String> displayNames,
    CallType callType, {
    int? groupId,
  }) async {
    if (_isDesktopPlatform) {
      // 🔴 PC 端暂不支持加入已存在的群组通话
      logger.debug('📞 [通话适配器] PC端暂不支持 joinGroupCall');
    } else {
      await _tui.joinGroupCall(userIds, displayNames, callType, groupId: groupId);
    }
  }

  /// 接听来电
  Future<void> acceptCall() async {
    if (_isDesktopPlatform) {
      await _desktop.acceptCall();
    } else {
      await _tui.acceptCall();
    }
  }

  /// 拒绝来电
  Future<void> rejectCall() async {
    if (_isDesktopPlatform) {
      await _desktop.rejectCall();
    } else {
      await _tui.rejectCall();
    }
  }

  /// 结束通话
  Future<void> endCall({bool isLocalHangup = true}) async {
    if (_isDesktopPlatform) {
      await _desktop.endCall(isLocalHangup: isLocalHangup);
    } else {
      await _tui.endCall(isLocalHangup: isLocalHangup);
    }
  }

  /// 群组通话中单个成员离开
  Future<Map<String, dynamic>> leaveGroupCallOnly() async {
    if (_isDesktopPlatform) {
      // 桌面端直接结束通话
      await _desktop.endCall();
      return {'callDuration': 0, 'isCallEnded': true};
    }
    return await _tui.leaveGroupCallOnly();
  }

  /// 切换麦克风静音
  Future<void> toggleMute(bool mute) async {
    if (_isDesktopPlatform) {
      await _desktop.toggleMicrophone(!mute);
    } else {
      await _tui.toggleMicrophone(!mute);
    }
  }

  /// 切换扬声器
  Future<void> toggleSpeaker(bool enable) async {
    if (_isDesktopPlatform) {
      await _desktop.toggleSpeaker(enable);
    } else {
      await _tui.toggleSpeaker(enable);
    }
  }

  /// 切换摄像头
  Future<void> toggleCamera(bool enable) async {
    if (_isDesktopPlatform) {
      await _desktop.toggleCamera(enable);
    } else {
      await _tui.toggleCamera(enable);
    }
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    if (_isDesktopPlatform) {
      // 桌面端没有前后摄像头概念
      logger.debug('📞 [Desktop] 桌面端不支持切换前后摄像头');
    } else {
      await _tui.switchCamera();
    }
  }

  /// 设置最小化状态
  void setMinimized({
    required bool isMinimized,
    int? callUserId,
    String? displayName,
    CallType? callType,
    bool isGroupCall = false,
    int? groupId,
  }) {
    if (!_isDesktopPlatform) {
      _tui.setMinimized(
        isMinimized: isMinimized,
        callUserId: callUserId,
        displayName: displayName,
        callType: callType,
        isGroupCall: isGroupCall,
        groupId: groupId,
      );
    }
    // 桌面端不支持最小化悬浮窗
  }

  /// 清除最小化状态
  void clearMinimizedState() {
    if (!_isDesktopPlatform) {
      _tui.clearMinimizedState();
    }
  }

  /// 设置麦克风音量（兼容性方法）
  Future<void> setMicrophoneVolume(int volume) async {
    logger.debug('📞 [通话适配器] setMicrophoneVolume 已弃用');
  }

  /// 设置扬声器音量（兼容性方法）
  Future<void> setSpeakerVolume(int volume) async {
    logger.debug('📞 [通话适配器] setSpeakerVolume 已弃用');
  }

  /// 获取麦克风设备列表
  Future<List<dynamic>> getMicrophoneDevices() async {
    if (_isDesktopPlatform) {
      return await _desktop.getMicrophoneDevices();
    }
    return [];
  }

  /// 获取扬声器设备列表
  Future<List<dynamic>> getSpeakerDevices() async {
    if (_isDesktopPlatform) {
      return await _desktop.getSpeakerDevices();
    }
    return [];
  }

  /// 获取摄像头设备列表
  Future<List<dynamic>> getCameraDevices() async {
    if (_isDesktopPlatform) {
      return await _desktop.getCameraDevices();
    }
    return [];
  }

  /// 设置麦克风设备
  Future<void> setMicrophoneDevice(String deviceId) async {
    if (_isDesktopPlatform) {
      await _desktop.setCurrentMicrophone(deviceId);
    }
  }

  /// 设置扬声器设备
  Future<void> setSpeakerDevice(String deviceId) async {
    if (_isDesktopPlatform) {
      await _desktop.setCurrentSpeaker(deviceId);
    }
  }

  /// 设置摄像头设备
  Future<void> setCameraDevice(String deviceId) async {
    if (_isDesktopPlatform) {
      await _desktop.setCurrentCamera(deviceId);
    }
  }

  /// 邀请成员加入群组通话（兼容性方法）
  Future<void> inviteToGroupCall(List<int> userIds, List<String> displayNames) async {
    logger.debug('📞 [通话适配器] inviteToGroupCall - 暂不支持');
  }

  /// 登出
  Future<void> logout() async {
    if (_isDesktopPlatform) {
      await _desktop.destroy();
    } else {
      await _tui.logout();
    }
  }

  /// 设置用户信息
  Future<void> setSelfInfo(String nickname, String avatar) async {
    if (!_isDesktopPlatform) {
      await _tui.setSelfInfo(nickname, avatar);
    }
    // 桌面端 TRTC 不需要设置用户信息
  }

  /// 🔴 更新用户头像（当用户更新头像后调用）
  /// 同时更新 TUICallKit 和腾讯 IM 服务器
  Future<void> updateUserAvatar(String avatar) async {
    if (!_isDesktopPlatform) {
      await _tui.updateUserAvatar(avatar);
    }
  }

  /// 设置来电铃声
  Future<void> setCallingBell(String assetName) async {
    if (!_isDesktopPlatform) {
      await _tui.setCallingBell(assetName);
    }
  }

  /// 启用/禁用静音模式
  Future<void> enableMuteMode(bool enable) async {
    if (!_isDesktopPlatform) {
      await _tui.enableMuteMode(enable);
    }
  }

  /// 启用/禁用悬浮窗
  Future<void> enableFloatWindow(bool enable) async {
    if (!_isDesktopPlatform) {
      await _tui.enableFloatWindow(enable);
    }
  }

  /// 启用/禁用虚拟背景
  Future<void> enableVirtualBackground(bool enable) async {
    if (!_isDesktopPlatform) {
      await _tui.enableVirtualBackground(enable);
    }
  }

  /// 设置群组通话频道信息（兼容性方法）
  void setGroupCallChannel(String channelName, String token, List<int> userIds, List<String> displayNames) {
    logger.debug('📞 [通话适配器] setGroupCallChannel 已弃用');
  }

  // ========== 桌面端专用方法 ==========

  /// 设置本地视频渲染视图（桌面端专用）
  Future<void> setLocalVideoView(int viewId) async {
    if (_isDesktopPlatform) {
      await _desktop.setLocalVideoView(viewId);
    }
  }

  /// 设置远端视频渲染视图（桌面端专用）
  Future<void> setRemoteVideoView(int userId, int viewId) async {
    if (_isDesktopPlatform) {
      await _desktop.setRemoteVideoView(userId, viewId);
    }
  }

  /// 停止远端视频渲染（桌面端专用）
  Future<void> stopRemoteVideoView(int userId) async {
    if (_isDesktopPlatform) {
      await _desktop.stopRemoteVideoView(userId);
    }
  }

  /// 静音/取消静音本地麦克风（桌面端专用）
  Future<void> muteMicrophone(bool mute) async {
    if (_isDesktopPlatform) {
      await _desktop.muteMicrophone(mute);
    }
  }

  /// 静音/取消静音本地视频（桌面端专用）
  Future<void> muteCamera(bool mute) async {
    if (_isDesktopPlatform) {
      await _desktop.muteCamera(mute);
    }
  }
}
