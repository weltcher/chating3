// TRTC 桌面端通话服务
// 用于 Windows/macOS/Linux 平台的音视频通话
// 参考 TUICallKit 的逻辑实现，使用腾讯云 TRTC SDK
// 使用腾讯云 IM SDK 发送信令，与移动端 TUICallKit 互通

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_cloud_chat_sdk/tencent_im_sdk_plugin.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSignalingListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import '../config/tencent_config.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'websocket_service.dart';
import 'api_service.dart';

/// 通话状态枚举（参考 TUICallKit 的 TUICallStatus）
enum DesktopCallState {
  idle,      // 空闲（none）
  waiting,   // 等待中（呼叫中/响铃中）
  accept,    // 已接听（通话中）
}

/// 通话类型枚举（参考 TUICallKit 的 TUICallMediaType）
enum DesktopCallType {
  audio, // 语音通话
  video, // 视频通话
}

/// 通话角色枚举（参考 TUICallKit 的 TUICallRole）
enum DesktopCallRole {
  none,   // 无
  caller, // 主叫
  called, // 被叫
}

/// 通话场景枚举（参考 TUICallKit 的 TUICallScene）
enum DesktopCallScene {
  singleCall, // 单人通话
  groupCall,  // 群组通话
}

/// 远程用户信息
class RemoteUser {
  String odId;           // 用户ID（字符串）
  int odUserId;          // 用户ID（整数）
  String nickname;       // 昵称
  String avatar;         // 头像
  DesktopCallState callStatus; // 通话状态
  bool videoAvailable;   // 视频是否可用
  bool audioAvailable;   // 音频是否可用
  int playOutVolume;     // 播放音量

  RemoteUser({
    this.odId = '',
    this.odUserId = 0,
    this.nickname = '',
    this.avatar = '',
    this.callStatus = DesktopCallState.waiting,
    this.videoAvailable = false,
    this.audioAvailable = false,
    this.playOutVolume = 0,
  });
}

/// TRTC 桌面端通话服务（参考 TUICallKit 的 CallManager + CallState）
class TRTCDesktopService {
  // 单例模式
  static final TRTCDesktopService _instance = TRTCDesktopService._internal();
  factory TRTCDesktopService() => _instance;
  TRTCDesktopService._internal();

  // TRTC 实例
  TRTCCloud? _trtcCloud;
  
  // ========== 通话状态（参考 CallState）==========
  // 自己的信息
  String _selfUserId = '';
  int _selfUserIdInt = 0;
  String _selfNickname = '';
  String _selfAvatar = '';
  DesktopCallState _selfCallStatus = DesktopCallState.idle;
  DesktopCallRole _selfCallRole = DesktopCallRole.none;
  
  // 远程用户列表
  final List<RemoteUser> _remoteUserList = [];
  
  // 通话信息
  DesktopCallType _mediaType = DesktopCallType.audio;
  DesktopCallScene _scene = DesktopCallScene.singleCall;
  int _roomId = 0;
  String _groupId = '';
  
  // 通话时间
  int _timeCount = 0;
  DateTime? _callStartTime;
  Timer? _timer;
  
  // 设备状态
  bool _isCameraOpen = false;
  bool _isMicrophoneMute = false;
  bool _isSpeakerOn = true;
  TRTCVideoMirrorType _mirrorType = TRTCVideoMirrorType.auto;
  
  // 本地挂断标识
  bool _isLocalHangup = false;
  
  // 🔴 群组通话相关状态
  bool _isGroupCallInitiator = false;  // 是否是群组通话发起者
  List<int>? _groupCallUserIds;  // 群组通话成员ID列表
  List<String>? _groupCallDisplayNames;  // 群组通话成员显示名称列表
  int? _groupCallGroupId;  // 群组通话的群组ID
  String? _groupCallChannelName;  // 群组通话的频道名称（用于同步成员状态）
  
  // WebSocket 服务（备用）
  final WebSocketService _wsService = WebSocketService();
  
  // 腾讯云 IM SDK
  final _im = TencentImSDKPlugin.v2TIMManager;
  bool _isIMLoggedIn = false;
  
  // 当前通话的 inviteId（用于信令）
  String? _currentInviteId;
  
  // 是否已初始化
  bool _isInitialized = false;
  
  // 视频渲染相关
  int? _localViewId;
  final Map<String, int> _remoteViewIds = {};
  
  // ========== 回调函数 ==========
  Function(DesktopCallState)? onCallStateChanged;
  Function(String odId, int odUserId)? onRemoteUserJoined;
  Function(String odId, int odUserId)? onRemoteUserLeft;
  Function(String)? onError;
  Function(int callerId, String callerName, DesktopCallType callType, int roomId)? onIncomingCall;
  // 🔴 新增：群组来电回调
  Function(int callerId, String callerName, DesktopCallType callType, int roomId, List<Map<String, dynamic>> members, int? groupId)? onIncomingGroupCall;
  Function()? onLocalVideoReady;
  Function(String odId)? onRemoteVideoReady;
  Function(int callDuration)? onCallEnded;
  Function(String odId, bool available)? onRemoteVideoAvailable;
  Function(String odId, bool available)? onRemoteAudioAvailable;
  Function(int timeCount)? onCallTimeUpdate;
  
  // 🔴 新增：群组通话房间已进入回调
  Function(int roomId, List<int> userIds, List<String> displayNames, DesktopCallType callType, int? groupId)? onGroupCallRoomEntered;
  
  // 🔴 新增：群组通话成员状态同步回调
  // 当接听群组通话后，从服务器获取到已连接成员列表时触发
  // connectedMembers: 已连接成员列表 [{user_id, username, display_name, avatar}]
  // totalInvited: 总邀请人数
  // callStartTime: 通话开始时间戳
  Function(List<Map<String, dynamic>> connectedMembers, int totalInvited, int callStartTime)? onGroupCallMembersSync;
  
  // 🔴 新增：通话取消回调（发起方取消通话时触发）
  // targetUserId: 被呼叫方的用户ID
  // callType: 通话类型（语音/视频）
  // isCaller: 是否是发起方取消（true=发起方取消，false=接收方收到取消通知）
  Function(int targetUserId, DesktopCallType callType, bool isCaller)? onCallCancelled;
  
  // 🔴 新增：通话中收到新来电被自动拒绝回调（用于发送"对方正在通话中"消息）
  // callerId: 来电者用户ID
  // callType: 通话类型（语音/视频）
  // 注意：仅一对一通话会触发此回调，群组通话直接拒绝不发送消息
  Function(int callerId, DesktopCallType callType)? onCallBusyRejected;

  // ========== Getters ==========
  bool get isInitialized => _isInitialized;
  DesktopCallState get callState => _selfCallStatus;
  DesktopCallType get callType => _mediaType;
  DesktopCallRole get callRole => _selfCallRole;
  DesktopCallScene get callScene => _scene;
  int get roomId => _roomId;
  String get groupId => _groupId;
  int get timeCount => _timeCount;
  DateTime? get callStartTime => _callStartTime;
  bool get isCameraOpen => _isCameraOpen;
  bool get isMicrophoneMute => _isMicrophoneMute;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isLocalHangup => _isLocalHangup;
  String get selfUserId => _selfUserId;
  int get selfUserIdInt => _selfUserIdInt;
  List<RemoteUser> get remoteUserList => _remoteUserList;
  TRTCCloud? get trtcCloud => _trtcCloud;
  String? get groupCallChannelName => _groupCallChannelName;  // 群组通话频道名称
  
  // 兼容旧接口
  int? get currentCallUserId => _remoteUserList.isNotEmpty ? _remoteUserList.first.odUserId : null;
  int? get myUserId => _selfUserIdInt;
  Set<int> get remoteUids => _remoteUserList.map((u) => u.odUserId).toSet();

  /// 生成 UserSig（仅用于测试，生产环境请使用服务端生成）
  String _genTestUserSig(String odUserId) {
    final currTime = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    
    final sigDoc = <String, dynamic>{
      'TLS.ver': '2.0',
      'TLS.identifier': odUserId,
      'TLS.sdkappid': TencentConfig.sdkAppId,
      'TLS.expire': TencentConfig.expireTime,
      'TLS.time': currTime,
    };

    final contentToBeSigned = 
        'TLS.identifier:$odUserId\n'
        'TLS.sdkappid:${TencentConfig.sdkAppId}\n'
        'TLS.time:$currTime\n'
        'TLS.expire:${TencentConfig.expireTime}\n';
    
    final hmacSha256 = Hmac(sha256, utf8.encode(TencentConfig.secretKey));
    final hmacSha256Digest = hmacSha256.convert(utf8.encode(contentToBeSigned));
    sigDoc['TLS.sig'] = base64.encode(hmacSha256Digest.bytes);
    
    final jsonStr = json.encode(sigDoc);
    final compress = zlib.encode(utf8.encode(jsonStr));
    return base64.encode(compress)
        .replaceAll('+', '*')
        .replaceAll('/', '-')
        .replaceAll('=', '_');
  }

  /// 生成房间号（基于用户ID生成唯一房间号）
  int _generateRoomId(int callerId, int calleeId) {
    final minId = callerId < calleeId ? callerId : calleeId;
    final maxId = callerId > calleeId ? callerId : calleeId;
    return ((minId * 10000 + maxId) % 2147483647) + 1;
  }

  /// 初始化 TRTC（参考 CallManager.initEngine）
  Future<void> initialize(int currentUserId) async {
    try {
      logger.debug('========== 📞 TRTC Desktop 初始化开始 ==========');
      logger.debug('📞 用户ID: $currentUserId');

      _selfUserIdInt = currentUserId;
      _selfUserId = currentUserId.toString();
      
      // 获取用户信息
      _selfNickname = await Storage.getFullName() ?? _selfUserId;
      _selfAvatar = await Storage.getAvatar() ?? '';

      if (_isInitialized && _trtcCloud != null) {
        logger.debug('📞 TRTC 已初始化，跳过');
        return;
      }

      // 创建 TRTC 实例
      _trtcCloud = await TRTCCloud.sharedInstance();
      logger.debug('📞 TRTC 实例已创建');

      // 设置为海外环境（新加坡部署区域）
      // SDKAppID 20032098 部署在新加坡，需要设置为海外环境
      try {
        await _trtcCloud?.callExperimentalAPI(jsonEncode({
          "api": "setTrtcEnvType",
          "params": {"env_type": 1}  // 1 = 海外环境
        }));
        logger.debug('📞 已设置 TRTC 环境为海外区');
      } catch (e) {
        logger.debug('📞 设置 TRTC 环境失败: $e');
      }

      // 设置事件监听
      _setupTRTCListeners();

      // 初始化并登录腾讯云 IM（用于信令）
      await _initAndLoginIM();

      // 设置 WebSocket 监听（备用）
      _setupWebSocketListeners();

      _isInitialized = true;
      logger.debug('========== TRTC Desktop 初始化完成 ==========');
    } catch (e) {
      logger.debug('📞 TRTC Desktop 初始化失败: $e');
      onError?.call('初始化失败: $e');
    }
  }

  /// 初始化并登录腾讯云 IM
  Future<void> _initAndLoginIM() async {
    try {
      logger.debug('📞 [Desktop] 初始化腾讯云 IM...');
      
      // 初始化 IM SDK
      final initResult = await _im.initSDK(
        sdkAppID: TencentConfig.sdkAppId,
        loglevel: LogLevelEnum.V2TIM_LOG_INFO,
        listener: null,
      );
      
      if (initResult.code != 0) {
        logger.debug('📞 IM SDK 初始化失败: ${initResult.desc}');
        return;
      }
      logger.debug('📞 IM SDK 初始化成功');
      
      // 生成 UserSig
      final userSig = _genTestUserSig(_selfUserId);
      
      // 登录 IM
      final loginResult = await _im.login(
        userID: _selfUserId,
        userSig: userSig,
      );
      
      if (loginResult.code != 0) {
        logger.debug('📞 IM 登录失败: ${loginResult.desc}');
        return;
      }
      
      _isIMLoggedIn = true;
      logger.debug('📞 IM 登录成功');
      
      // 设置信令监听
      _setupIMSignalingListener();
      
    } catch (e) {
      logger.debug('📞 IM 初始化/登录失败: $e');
    }
  }

  /// 设置 IM 信令监听
  void _setupIMSignalingListener() {
    _im.getSignalingManager().addSignalingListener(
      listener: V2TimSignalingListener(
        // 收到邀请
        onReceiveNewInvitation: (inviteID, inviter, groupID, inviteeList, data) {
          logger.debug('📞 [Desktop] ========== 收到 IM 信令邀请 ==========');
          logger.debug('📞 [Desktop] inviteID: $inviteID');
          logger.debug('📞 [Desktop] inviter: $inviter');
          logger.debug('📞 [Desktop] groupID: $groupID');
          logger.debug('📞 [Desktop] inviteeList: $inviteeList');
          logger.debug('📞 [Desktop] 原始 data: $data');
          _handleIMInvitation(inviteID, inviter, groupID, inviteeList, data);
        },
        // 邀请被接受
        onInviteeAccepted: (inviteID, invitee, data) {
          logger.debug('📞 [Desktop] ========== IM 信令邀请被接受 ==========');
          logger.debug('📞 [Desktop] inviteID: $inviteID');
          logger.debug('📞 [Desktop] invitee: $invitee');
          logger.debug('📞 [Desktop] 原始 data: $data');
          _handleIMInviteeAccepted(inviteID, invitee, data);
        },
        // 邀请被拒绝
        onInviteeRejected: (inviteID, invitee, data) {
          logger.debug('📞 [Desktop] ========== IM 信令邀请被拒绝 ==========');
          logger.debug('📞 [Desktop] inviteID: $inviteID');
          logger.debug('📞 [Desktop] invitee: $invitee');
          logger.debug('📞 [Desktop] 原始 data: $data');
          _handleIMInviteeRejected(inviteID, invitee, data);
        },
        // 邀请被取消
        onInvitationCancelled: (inviteID, inviter, data) {
          logger.debug('📞 [Desktop] ========== IM 信令邀请被取消 ==========');
          logger.debug('📞 [Desktop] inviteID: $inviteID');
          logger.debug('📞 [Desktop] inviter: $inviter');
          logger.debug('📞 [Desktop] 原始 data: $data');
          _handleIMInvitationCancelled(inviteID, inviter, data);
        },
        // 邀请超时
        onInvitationTimeout: (inviteID, inviteeList) {
          logger.debug('📞 [Desktop] ========== IM 信令邀请超时 ==========');
          logger.debug('📞 [Desktop] inviteID: $inviteID');
          logger.debug('📞 [Desktop] inviteeList: $inviteeList');
          _handleIMInvitationTimeout(inviteID, inviteeList);
        },
      ),
    );
    logger.debug('📞 [Desktop] IM 信令监听已设置');
  }

  /// 处理 IM 信令邀请（来电）
  void _handleIMInvitation(String inviteID, String inviter, String? groupID, List<String>? inviteeList, String? data) {
    logger.debug('📞 [Desktop] _handleIMInvitation 被调用');
    logger.debug('📞 [Desktop] 当前状态: $_selfCallStatus');
    logger.debug('📞 [Desktop] groupID: $groupID');
    logger.debug('📞 [Desktop] inviteeList: $inviteeList');
    
    // 🔴 判断是否是群组通话（groupID 不为空或被叫用户数量 > 1）
    final isGroupCall = (groupID != null && groupID.isNotEmpty) || 
                        (inviteeList != null && inviteeList.length > 1);
    
    if (_selfCallStatus != DesktopCallState.idle) {
      logger.debug('📞 当前正在通话，自动处理新来电');
      
      if (isGroupCall) {
        // 🔴 群组通话：静默忽略，不做任何处理（避免影响当前通话）
        logger.debug('📞 [Desktop] 收到群组来电，静默忽略（不调用 reject，避免影响当前通话）');
        return;
      } else {
        // 🔴 一对一通话：自动拒绝并发送"对方正在通话中"消息
        logger.debug('📞 [Desktop] 收到一对一来电，自动拒绝并发送"对方正在通话中"消息');
        _rejectIMInvitation(inviteID);
        
        // 解析通话类型
        var callType = 'voice';
        try {
          final signalData = data != null ? jsonDecode(data) : {};
          var callTypeValue = signalData['call_type'] ?? signalData['callType'] ?? 1;
          if (callTypeValue is int) {
            callType = callTypeValue == 2 ? 'video' : 'voice';
          } else {
            callType = callTypeValue == 'video' ? 'video' : 'voice';
          }
        } catch (e) {
          logger.debug('📞 [Desktop] 解析通话类型失败: $e');
        }
        
        // 发送"对方正在通话中"消息
        final callerId = int.tryParse(inviter) ?? 0;
        if (callerId > 0) {
          onCallBusyRejected?.call(callerId, callType == 'video' ? DesktopCallType.video : DesktopCallType.audio);
        }
      }
      return;
    }
    
    try {
      // 解析信令数据
      final signalData = data != null ? jsonDecode(data) : {};
      
      // 🔴 检查 businessID，支持 av_call 和 rtc_call 两种格式
      final businessID = signalData['businessID'];
      if (businessID != null && businessID != 'av_call' && businessID != 'rtc_call') {
        logger.debug('📞 [Desktop] 非通话信令 businessID=$businessID，忽略');
        return;
      }
      
      // 🔴 检查是否为 hangup/cancel 等结束信令，不是真正的来电
      // TUICallKit 会发送 cmd=hangup 的信令表示通话结束
      final nestedData = signalData['data'];
      if (nestedData is Map) {
        final cmd = nestedData['cmd'];
        if (cmd == 'hangup' || cmd == 'cancel' || cmd == 'reject' || cmd == 'switchToAudio') {
          logger.debug('📞 [Desktop] 收到结束/控制信令 cmd=$cmd，忽略（不是新来电）');
          return;
        }
      }
      
      // 🔴 检查 call_end 字段，非零表示通话已结束
      final callEnd = signalData['call_end'];
      if (callEnd != null && callEnd != 0) {
        logger.debug('📞 [Desktop] call_end=$callEnd 非零，忽略（通话已结束信令）');
        return;
      }
      
      // 🔴 解析通话类型：支持数字和字符串格式
      var callType = signalData['call_type'] ?? signalData['callType'] ?? 1;
      if (callType is int) {
        // 1 = 语音, 2 = 视频
        callType = callType == 2 ? 'video' : 'audio';
      }
      
      final roomId = signalData['room_id'] ?? signalData['roomId'] ?? _generateRoomId(_selfUserIdInt, int.tryParse(inviter) ?? 0);
      
      _currentInviteId = inviteID;
      _mediaType = callType == 'video' ? DesktopCallType.video : DesktopCallType.audio;
      _roomId = roomId is int ? roomId : int.tryParse(roomId.toString()) ?? 0;
      _selfCallRole = DesktopCallRole.called;
      _selfCallStatus = DesktopCallState.waiting;
      
      // 🔴 判断是否为群组通话
      if (groupID != null && groupID.isNotEmpty) {
        _scene = DesktopCallScene.groupCall;
        _groupId = groupID;
        logger.debug('📞 [Desktop] 群组通话，groupID: $groupID');
      } else {
        _scene = DesktopCallScene.singleCall;
      }
      
      // 添加主叫用户到远程用户列表
      final callerId = int.tryParse(inviter) ?? 0;
      final callerUser = RemoteUser(
        odId: inviter,
        odUserId: callerId,
        nickname: signalData['caller_name'] ?? nestedData?['inviter'] ?? inviter,
        callStatus: DesktopCallState.waiting,
      );
      _remoteUserList.add(callerUser);
      
      logger.debug('📞 [Desktop] 来电信息: callerId=$callerId, roomId=$_roomId, callType=$callType');
      
      onCallStateChanged?.call(_selfCallStatus);
      onIncomingCall?.call(callerId, callerUser.nickname, _mediaType, _roomId);
      
    } catch (e) {
      logger.debug('📞 解析 IM 信令数据失败: $e');
    }
  }

  /// 处理 IM 信令邀请被接受
  void _handleIMInviteeAccepted(String inviteID, String invitee, String? data) {
    if (_currentInviteId != inviteID) return;
    logger.debug('📞 [Desktop] 对方已接听');
    // 对方接听后会进入 TRTC 房间，通过 onRemoteUserEnterRoom 回调处理
  }

  /// 处理 IM 信令邀请被拒绝
  void _handleIMInviteeRejected(String inviteID, String invitee, String? data) {
    logger.debug('📞 [Desktop] _handleIMInviteeRejected 被调用');
    logger.debug('📞 [Desktop] inviteID: $inviteID, _currentInviteId: $_currentInviteId');
    logger.debug('📞 [Desktop] invitee: $invitee, data: $data');
    
    if (_currentInviteId != inviteID) {
      logger.debug('📞 [Desktop] inviteID 不匹配，忽略');
      return;
    }
    
    // 解析拒绝原因
    String rejectReason = '对方拒绝了通话';
    if (data != null && data.isNotEmpty) {
      try {
        final rejectData = jsonDecode(data);
        final reason = rejectData['reason'];
        if (reason == 'busy') {
          rejectReason = '对方正忙';
        } else if (reason == 'rejected') {
          rejectReason = '对方拒绝了通话';
        }
        logger.debug('📞 [Desktop] 拒绝原因: $reason');
      } catch (e) {
        logger.debug('📞 [Desktop] 解析拒绝数据失败: $e');
      }
    }
    
    logger.debug('📞 [Desktop] 对方拒绝通话');
    onError?.call(rejectReason);
    _stopTimer();
    _trtcCloud?.exitRoom();
    onCallEnded?.call(0);
    _cleanState();
  }

  /// 处理 IM 信令邀请被取消
  void _handleIMInvitationCancelled(String inviteID, String inviter, String? data) {
    if (_currentInviteId != inviteID) return;
    
    // 只有被叫方才需要处理取消信令
    // 主叫方取消通话时，自己也会收到这个回调，但不应该显示错误
    if (_selfCallRole != DesktopCallRole.called) {
      logger.debug('📞 [Desktop] 忽略取消信令（非被叫方）');
      return;
    }
    
    logger.debug('📞 [Desktop] 对方取消了通话');
    
    // 🔴 保存发起方用户ID和通话类型，用于触发回调
    final callerIdInt = int.tryParse(inviter) ?? 0;
    final currentCallType = _mediaType;
    
    onError?.call('对方取消了通话');
    _stopTimer();
    
    // 🔴 触发通话取消回调（接收方收到取消通知）
    if (callerIdInt > 0) {
      logger.debug('📞 [Desktop] 接收方收到取消通知，触发 onCallCancelled 回调: callerId=$callerIdInt');
      onCallCancelled?.call(callerIdInt, currentCallType, false);
    }
    
    onCallEnded?.call(0);
    _cleanState();
  }

  /// 处理 IM 信令邀请超时
  void _handleIMInvitationTimeout(String inviteID, List<String>? inviteeList) {
    if (_currentInviteId != inviteID) return;
    logger.debug('📞 [Desktop] 通话邀请超时');
    onError?.call('对方无响应');
    _stopTimer();
    _trtcCloud?.exitRoom();
    onCallEnded?.call(0);
    _cleanState();
  }

  /// 拒绝 IM 信令邀请
  Future<void> _rejectIMInvitation(String inviteID) async {
    try {
      await _im.getSignalingManager().reject(
        inviteID: inviteID,
        data: jsonEncode({'reason': 'busy'}),
      );
    } catch (e) {
      logger.debug('📞 拒绝 IM 信令失败: $e');
    }
  }


  /// 设置 TRTC 事件监听（参考 CallState.observer）
  void _setupTRTCListeners() {
    _trtcCloud?.registerListener(TRTCCloudListener(
      // 错误回调
      onError: (errCode, errMsg) {
        logger.debug('📞 TRTC 错误: code=$errCode, msg=$errMsg');
        onError?.call('TRTC 错误: $errMsg');
      },
      
      // 警告回调
      onWarning: (warningCode, warningMsg) {
        logger.debug('📞 TRTC 警告: code=$warningCode, msg=$warningMsg');
      },
      
      // 进入房间回调
      onEnterRoom: (result) {
        logger.debug('📞 进入房间结果: $result');
        if (result > 0) {
          // 进房成功
          // 开启麦克风
          if (!_isMicrophoneMute) {
            _trtcCloud?.startLocalAudio(TRTCAudioQuality.speech);
          }
          
          // 🔴 通知服务器：用户进入通话状态
          _updateServerCallStatus(inCall: true, callType: _mediaType == DesktopCallType.video ? 'video' : 'voice');
          
          // 🔴 如果是群组通话发起者，触发 onGroupCallRoomEntered 回调
          if (_isGroupCallInitiator && _scene == DesktopCallScene.groupCall) {
            logger.debug('📞 [Desktop] 群组通话发起者已进入房间，触发 onGroupCallRoomEntered 回调');
            _isGroupCallInitiator = false;  // 重置标记
            
            // 开始计时
            _callStartTime = DateTime.now();
            _selfCallStatus = DesktopCallState.accept;
            _startTimer();
            onCallStateChanged?.call(_selfCallStatus);
            
            // 触发回调，通知调用方导航到通话页面
            onGroupCallRoomEntered?.call(
              _roomId,
              _groupCallUserIds ?? [],
              _groupCallDisplayNames ?? [],
              _mediaType,
              _groupCallGroupId,
            );
            
            logger.debug('📞 进入房间成功，耗时: ${result}ms, 角色: $_selfCallRole (群组通话发起者)');
            return;
          }
          
          // 如果是被叫方，进房成功就表示接听成功，开始计时
          // 如果是主叫方，需要等对方进入房间后才开始计时
          if (_selfCallRole == DesktopCallRole.called) {
            _callStartTime = DateTime.now();
            _selfCallStatus = DesktopCallState.accept;
            _startTimer();
            onCallStateChanged?.call(_selfCallStatus);
          }
          // 主叫方保持 waiting 状态，等待对方进入房间
          
          logger.debug('📞 进入房间成功，耗时: ${result}ms, 角色: $_selfCallRole');
        } else {
          logger.debug('📞 进入房间失败，错误码: $result');
          onError?.call('进入房间失败: $result');
          _isGroupCallInitiator = false;  // 重置标记
          _cleanState();
        }
      },
      
      // 离开房间回调（参考 onCallEnd）
      onExitRoom: (reason) {
        logger.debug('📞 离开房间，原因: $reason');
        _stopTimer();
        final duration = _timeCount;
        // 🔴 先保存 isLocalHangup 的值，因为 _cleanState 会重置它
        final wasLocalHangup = _isLocalHangup;
        logger.debug('📞 [onExitRoom] isLocalHangup: $wasLocalHangup, duration: $duration');
        onCallEnded?.call(duration);
        _cleanState();
        // 🔴 注意：_cleanState 会重置 _isLocalHangup，但 onCallEnded 回调中已经读取了正确的值
      },
      
      // 远端用户进入房间（参考 onUserJoin）
      onRemoteUserEnterRoom: (odUserId) {
        logger.debug('📞 远端用户进入: $odUserId');
        
        // 查找或创建用户
        RemoteUser? user;
        for (var u in _remoteUserList) {
          if (u.odId == odUserId) {
            user = u;
            break;
          }
        }
        
        if (user != null) {
          user.callStatus = DesktopCallState.accept;
        } else {
          user = RemoteUser(
            odId: odUserId,
            odUserId: int.tryParse(odUserId) ?? 0,
            callStatus: DesktopCallState.accept,
          );
          _remoteUserList.add(user);
        }
        
        // 如果是主叫方且当前还在等待状态，对方进入房间表示接听成功，开始计时
        if (_selfCallRole == DesktopCallRole.caller && _selfCallStatus == DesktopCallState.waiting) {
          _callStartTime = DateTime.now();
          _selfCallStatus = DesktopCallState.accept;
          _startTimer();
          onCallStateChanged?.call(_selfCallStatus);
          logger.debug('📞 对方已接听，开始计时');
        }
        
        onRemoteUserJoined?.call(odUserId, user.odUserId);
      },
      
      // 远端用户离开房间（参考 onUserLeave）
      onRemoteUserLeaveRoom: (odUserId, reason) {
        logger.debug('📞 远端用户离开: $odUserId, 原因: $reason');
        
        final uid = int.tryParse(odUserId) ?? 0;
        _remoteUserList.removeWhere((u) => u.odId == odUserId);
        _remoteViewIds.remove(odUserId);
        
        onRemoteUserLeft?.call(odUserId, uid);
        
        // 如果所有远端用户都离开了，结束通话
        if (_remoteUserList.isEmpty && _selfCallStatus == DesktopCallState.accept) {
          logger.debug('📞 所有远端用户已离开，结束通话');
          hangup(isLocalHangup: false);
        }
      },
      
      // 远端用户视频可用（参考 onUserVideoAvailable）
      onUserVideoAvailable: (odUserId, available) {
        logger.debug('📞 用户视频可用: $odUserId, available=$available');
        
        for (var user in _remoteUserList) {
          if (user.odId == odUserId) {
            user.videoAvailable = available;
            break;
          }
        }
        
        if (available) {
          onRemoteVideoReady?.call(odUserId);
        }
        onRemoteVideoAvailable?.call(odUserId, available);
      },
      
      // 远端用户音频可用（参考 onUserAudioAvailable）
      onUserAudioAvailable: (odUserId, available) {
        logger.debug('📞 用户音频可用: $odUserId, available=$available');
        
        for (var user in _remoteUserList) {
          if (user.odId == odUserId) {
            user.audioAvailable = available;
            break;
          }
        }
        
        onRemoteAudioAvailable?.call(odUserId, available);
      },
      
      // 首帧本地视频
      onFirstVideoFrame: (odUserId, streamType, width, height) {
        logger.debug('📞 首帧视频: odUserId=$odUserId, size=${width}x$height');
        if (odUserId.isEmpty) {
          onLocalVideoReady?.call();
        }
      },
      
      // 网络质量
      onNetworkQuality: (localQuality, remoteQuality) {
        // 可以在这里处理网络质量变化
      },
      
      // 连接断开
      onConnectionLost: () {
        logger.debug('📞 网络连接断开');
        onError?.call('网络连接断开');
      },
      
      // 连接恢复
      onConnectionRecovery: () {
        logger.debug('📞 网络连接恢复');
      },
    ));
  }

  /// 设置 WebSocket 监听（用于接收来电信令）
  void _setupWebSocketListeners() {
    _wsService.onWebRTCSignal = (data) async {
      logger.debug('📞 [Desktop] 收到 WebRTC 信令: ${data['type']}');

      try {
        switch (data['type']) {
          case 'call-request':
          case 'incoming_call':
            _handleIncomingCall(data);
            break;
          case 'incoming_group_call':
            _handleIncomingGroupCall(data);
            break;
          case 'call-accepted':
          case 'call_accepted':
            _handleCallAccepted(data);
            break;
          case 'call-rejected':
          case 'call_rejected':
            _handleCallRejected(data);
            break;
          case 'call-cancel':
          case 'call_cancel':
            // 🔴 处理移动端取消通话的信令
            _handleCallCancelFromWebSocket(data);
            break;
          case 'call-ended':
          case 'call_ended':
            _handleCallEnded(data);
            break;
          case 'call-busy':
            _handleCallBusy(data);
            break;
        }
      } catch (e) {
        logger.debug('📞 处理信令失败: $e');
        onError?.call('信令处理失败: $e');
      }
    };
  }

  /// 处理群组来电（来自移动端 TUICallKit 的 WebSocket 通知）
  void _handleIncomingGroupCall(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 收到群组来电: $data');
    
    final callerId = data['caller_id'] as int? ?? data['from_user_id'] as int?;
    final callerName = data['caller_name'] as String? ?? '未知用户';
    final callTypeStr = data['call_type'] as String? ?? 'voice';
    final groupId = data['group_id'];
    final roomId = data['room_id'] as int?;  // 🔴 获取 TRTC 房间号
    final channelName = data['channel_name'] as String?;  // 🔴 获取频道名称
    final members = data['members'] as List<dynamic>?;
    final source = data['source'] as String?;
    
    if (callerId == null) {
      logger.debug('📞 群组来电数据缺少 caller_id');
      return;
    }
    
    if (_selfCallStatus != DesktopCallState.idle) {
      logger.debug('📞 当前正在通话，忽略群组来电');
      return;
    }
    
    logger.debug('📞 [Desktop] 群组来电信息:');
    logger.debug('📞 [Desktop]   - callerId: $callerId');
    logger.debug('📞 [Desktop]   - callerName: $callerName');
    logger.debug('📞 [Desktop]   - callType: $callTypeStr');
    logger.debug('📞 [Desktop]   - groupId: $groupId');
    logger.debug('📞 [Desktop]   - roomId: $roomId');
    logger.debug('📞 [Desktop]   - channelName: $channelName');
    logger.debug('📞 [Desktop]   - source: $source');
    logger.debug('📞 [Desktop]   - members: $members');
    
    // 🔴 检查是否有 room_id，没有则无法加入通话
    if (roomId == null || roomId == 0) {
      logger.debug('📞 [Desktop] 群组来电缺少 room_id，无法加入通话');
      return;
    }
    
    // 设置通话状态
    _mediaType = callTypeStr == 'video' ? DesktopCallType.video : DesktopCallType.audio;
    _roomId = roomId;  // 🔴 保存 TRTC 房间号
    _groupCallChannelName = channelName;  // 🔴 保存频道名称（用于同步成员状态）
    _selfCallRole = DesktopCallRole.called;
    _selfCallStatus = DesktopCallState.waiting;
    _scene = DesktopCallScene.groupCall;
    
    if (groupId != null) {
      _groupId = groupId.toString();
    }
    
    // 添加主叫用户到远程用户列表
    final callerUser = RemoteUser(
      odId: callerId.toString(),
      odUserId: callerId,
      nickname: callerName,
      callStatus: DesktopCallState.waiting,
    );
    _remoteUserList.add(callerUser);
    
    // 添加其他成员到远程用户列表
    if (members != null) {
      for (final member in members) {
        final memberId = member['user_id'] as int?;
        final memberName = member['display_name'] as String? ?? '';
        if (memberId != null && memberId != callerId && memberId != _selfUserIdInt) {
          _remoteUserList.add(RemoteUser(
            odId: memberId.toString(),
            odUserId: memberId,
            nickname: memberName,
            callStatus: DesktopCallState.waiting,
          ));
        }
      }
    }
    
    onCallStateChanged?.call(_selfCallStatus);
    
    // 🔴 修复：调用群组来电回调而不是个人来电回调
    // 将成员列表转换为正确的格式
    final membersList = <Map<String, dynamic>>[];
    // 添加发起人
    membersList.add({
      'user_id': callerId,
      'display_name': callerName,
      'is_caller': true,
    });
    // 添加其他成员
    if (members != null) {
      for (final member in members) {
        final memberId = member['user_id'] as int?;
        final memberName = member['display_name'] as String? ?? '';
        if (memberId != null && memberId != callerId) {
          membersList.add({
            'user_id': memberId,
            'display_name': memberName,
          });
        }
      }
    }
    
    // 调用群组来电回调
    if (onIncomingGroupCall != null) {
      onIncomingGroupCall?.call(callerId, callerName, _mediaType, _roomId, membersList, groupId is int ? groupId : int.tryParse(groupId?.toString() ?? ''));
      logger.debug('📞 [Desktop] 群组来电已触发 onIncomingGroupCall 回调');
    } else {
      // 如果没有设置群组来电回调，回退到个人来电回调
      logger.debug('📞 [Desktop] 未设置 onIncomingGroupCall 回调，回退到 onIncomingCall');
      onIncomingCall?.call(callerId, callerName, _mediaType, _roomId);
    }
    
    logger.debug('📞 [Desktop] 群组来电已触发回调，roomId=$_roomId，等待用户响应');
  }

  /// 处理来电（参考 onCallReceived）
  void _handleIncomingCall(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 收到来电: $data');
    
    final callerId = data['caller_id'] as int? ?? data['from_user_id'] as int?;
    final callerName = data['caller_name'] as String? ?? data['display_name'] as String? ?? '未知用户';
    final callTypeStr = data['call_type'] as String? ?? 'audio';
    final roomId = data['room_id'] as int?;
    
    if (callerId == null) {
      logger.debug('📞 来电数据缺少 caller_id');
      return;
    }
    
    if (_selfCallStatus != DesktopCallState.idle) {
      logger.debug('📞 当前正在通话，发送忙线信号');
      _wsService.sendWebRTCSignal({
        'type': 'call-busy',
        'to_user_id': callerId,
        'from_user_id': _selfUserIdInt,
      });
      return;
    }
    
    // 设置通话状态
    _mediaType = callTypeStr == 'video' ? DesktopCallType.video : DesktopCallType.audio;
    _roomId = roomId ?? _generateRoomId(_selfUserIdInt, callerId);
    _selfCallRole = DesktopCallRole.called;
    _selfCallStatus = DesktopCallState.waiting;
    _scene = DesktopCallScene.singleCall;
    
    // 添加主叫用户到远程用户列表
    final callerUser = RemoteUser(
      odId: callerId.toString(),
      odUserId: callerId,
      nickname: callerName,
      callStatus: DesktopCallState.waiting,
    );
    _remoteUserList.add(callerUser);
    
    onCallStateChanged?.call(_selfCallStatus);
    onIncomingCall?.call(callerId, callerName, _mediaType, _roomId);
  }

  /// 处理对方接听
  void _handleCallAccepted(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 对方已接听: $data');
    // 对方接听后会进入房间，通过 onRemoteUserEnterRoom 回调处理
  }

  /// 处理对方拒绝（参考 onUserReject）
  void _handleCallRejected(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 对方拒绝通话');
    onError?.call('对方拒绝了通话');
    _stopTimer();
    onCallEnded?.call(0);
    _cleanState();
  }

  /// 处理通话结束
  void _handleCallEnded(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 收到通话结束信令');
    hangup(isLocalHangup: false);
  }

  /// 处理来自 WebSocket 的通话取消信令（移动端取消通话时发送）
  void _handleCallCancelFromWebSocket(Map<String, dynamic> data) {
    final fromUserId = data['from_user_id'] as int?;
    logger.debug('📞 [Desktop] 收到 WebSocket 取消通话信令: fromUserId=$fromUserId');
    
    // 只有在 ringing 状态（来电响铃中）才处理取消
    if (_selfCallStatus != DesktopCallState.waiting) {
      logger.debug('📞 [Desktop] 当前状态不是 waiting，忽略取消信令: $_selfCallStatus');
      return;
    }
    
    // 检查是否是被叫方
    if (_selfCallRole != DesktopCallRole.called) {
      logger.debug('📞 [Desktop] 不是被叫方，忽略取消信令');
      return;
    }
    
    // 检查是否是当前来电的发起方取消
    final currentCallerId = _remoteUserList.isNotEmpty ? _remoteUserList.first.odUserId : 0;
    if (fromUserId != null && fromUserId == currentCallerId) {
      logger.debug('📞 [Desktop] 来电发起方取消了通话，结束来电');
      
      // 保存通话类型
      final currentCallType = _mediaType;
      
      // 触发取消回调（接收方收到取消通知）
      onCallCancelled?.call(fromUserId, currentCallType, false);
      
      // 停止计时器
      _stopTimer();
      
      // 触发通话结束回调
      onCallEnded?.call(0);
      
      // 清理状态
      _cleanState();
    } else {
      logger.debug('📞 [Desktop] 取消信令的发送者与当前来电发起方不匹配，忽略');
    }
  }

  /// 处理对方忙线（参考 onUserLineBusy）
  void _handleCallBusy(Map<String, dynamic> data) {
    logger.debug('📞 [Desktop] 对方忙线');
    onError?.call('对方正忙');
    _stopTimer();
    onCallEnded?.call(0);
    _cleanState();
  }


  /// 发起通话（参考 CallManager.call）
  Future<bool> call(int targetUserId, String targetDisplayName, DesktopCallType callType) async {
    logger.debug('========== 📞 [Desktop] 发起通话 ==========');
    logger.debug('📞 目标用户: $targetUserId ($targetDisplayName)');
    logger.debug('📞 通话类型: ${callType == DesktopCallType.audio ? '语音' : '视频'}');
    logger.debug('📞 当前状态: $_selfCallStatus');
    logger.debug('📞 当前角色: $_selfCallRole');
    logger.debug('📞 当前 inviteId: $_currentInviteId');

    if (targetUserId == _selfUserIdInt) {
      logger.debug('📞 不能给自己打电话');
      onError?.call('不能给自己打电话');
      return false;
    }

    if (_selfCallStatus != DesktopCallState.idle) {
      logger.debug('📞 当前正在通话，状态: $_selfCallStatus');
      onError?.call('当前正在通话');
      return false;
    }

    _isLocalHangup = false;

    try {
      // 设置通话状态
      _mediaType = callType;
      _roomId = _generateRoomId(_selfUserIdInt, targetUserId);
      _selfCallRole = DesktopCallRole.caller;
      _selfCallStatus = DesktopCallState.waiting;
      _scene = DesktopCallScene.singleCall;
      
      // 添加被叫用户到远程用户列表
      final calleeUser = RemoteUser(
        odId: targetUserId.toString(),
        odUserId: targetUserId,
        nickname: targetDisplayName,
        callStatus: DesktopCallState.waiting,
      );
      _remoteUserList.add(calleeUser);
      
      onCallStateChanged?.call(_selfCallStatus);

      // 使用腾讯云 IM 信令发送通话邀请
      if (_isIMLoggedIn) {
        // 🔴 使用 TUICallKit 标准信令格式（av_call）
        // 完全按照移动端发送的格式构建，确保移动端 TUICallKit 可以正确识别
        // 移动端格式参考：
        // {
        //   "businessID": "av_call",
        //   "call_end": 0,
        //   "call_type": 1,  // 1=语音, 2=视频
        //   "data": {
        //     "cmd": "audioCall",
        //     "excludeFromHistoryMessage": true,
        //     "inviter": "102",
        //     "message": "",
        //     "room_id": 129316570,
        //     "str_room_id": "",
        //     "userIDs": ["103"]
        //   },
        //   "platform": "GLK-AL00",
        //   "room_id": 129316570,
        //   "userData": "",
        //   "version": 4
        // }
        
        final cmdType = callType == DesktopCallType.video ? 'videoCall' : 'audioCall';
        final callTypeValue = callType == DesktopCallType.video ? 2 : 1;  // 1=语音, 2=视频
        
        final tuiCallSignalData = jsonEncode({
          'businessID': 'av_call',  // TUICallKit 标准标识
          'call_end': 0,  // 通话未结束
          'call_type': callTypeValue,  // 1=语音, 2=视频
          'data': {
            'cmd': cmdType,
            'excludeFromHistoryMessage': true,
            'inviter': _selfUserId,
            'message': '',
            'room_id': _roomId,
            'str_room_id': '',
            'userIDs': [targetUserId.toString()],
          },
          'platform': Platform.operatingSystem,  // windows/macos/linux
          'room_id': _roomId,
          'userData': '',
          'version': 4,  // TUICallKit 版本
        });
        
        final inviteResult = await _im.getSignalingManager().invite(
          invitee: targetUserId.toString(),
          data: tuiCallSignalData,
          timeout: 60,
          onlineUserOnly: false,
        );
        
        if (inviteResult.code == 0 && inviteResult.data != null) {
          _currentInviteId = inviteResult.data;
          logger.debug('📞 [Desktop] IM 信令邀请已发送, inviteID: $_currentInviteId');
        } else {
          logger.debug('📞 [Desktop] IM 信令邀请发送失败: ${inviteResult.desc}');
          // 降级到 WebSocket
          _sendWebSocketSignal(targetUserId, callType);
        }
      } else {
        // IM 未登录，使用 WebSocket 信令
        logger.debug('📞 [Desktop] IM 未登录，使用 WebSocket 信令');
        _sendWebSocketSignal(targetUserId, callType);
      }

      // 进入 TRTC 房间
      await _enterRoom();
      
      logger.debug('📞 [Desktop] 通话请求已发送，房间号: $_roomId');
      return true;
    } catch (e) {
      logger.debug('📞 发起通话失败: $e');
      onError?.call('发起通话失败: $e');
      _cleanState();
      return false;
    }
  }

  /// 使用 WebSocket 发送信令（备用）
  void _sendWebSocketSignal(int targetUserId, DesktopCallType callType) {
    _wsService.sendWebRTCSignal({
      'type': 'call-request',
      'to_user_id': targetUserId,
      'from_user_id': _selfUserIdInt,
      'caller_name': _selfNickname,
      'call_type': callType == DesktopCallType.video ? 'video' : 'audio',
      'room_id': _roomId,
    });
  }

  /// 发起语音通话
  Future<bool> startVoiceCall(int targetUserId, String targetDisplayName) async {
    return await call(targetUserId, targetDisplayName, DesktopCallType.audio);
  }

  /// 发起视频通话
  Future<bool> startVideoCall(int targetUserId, String targetDisplayName) async {
    return await call(targetUserId, targetDisplayName, DesktopCallType.video);
  }

  /// 发起群组通话
  /// 使用 TRTC SDK 直接进入房间，通过 WebSocket 通知所有参与者
  Future<bool> startGroupCall(
    List<int> userIds,
    List<String> displayNames,
    DesktopCallType callType, {
    int? groupId,
  }) async {
    logger.debug('========== 📞 [Desktop] 发起群组通话 ==========');
    logger.debug('📞 目标用户: $userIds');
    logger.debug('📞 通话类型: ${callType == DesktopCallType.audio ? '语音' : '视频'}');
    logger.debug('📞 群组ID: $groupId');
    logger.debug('📞 当前状态: $_selfCallStatus');

    if (userIds.isEmpty) {
      logger.debug('📞 没有目标用户');
      onError?.call('请选择至少一个成员');
      return false;
    }

    if (_selfCallStatus != DesktopCallState.idle) {
      logger.debug('📞 当前正在通话，状态: $_selfCallStatus');
      onError?.call('当前正在通话');
      return false;
    }

    _isLocalHangup = false;

    try {
      // 设置通话状态
      _mediaType = callType;
      _roomId = _generateGroupCallRoomId();
      _selfCallRole = DesktopCallRole.caller;
      _selfCallStatus = DesktopCallState.waiting;
      _scene = DesktopCallScene.groupCall;
      _groupId = groupId?.toString() ?? '';
      
      // 🔴 保存群组通话参数，用于 onEnterRoom 回调中触发 onGroupCallRoomEntered
      _isGroupCallInitiator = true;
      _groupCallUserIds = List.from(userIds);
      _groupCallDisplayNames = List.from(displayNames);
      _groupCallGroupId = groupId;
      
      logger.debug('📞 [Desktop] 生成群组通话房间号: $_roomId');
      
      // 添加所有被叫用户到远程用户列表
      for (int i = 0; i < userIds.length; i++) {
        final userId = userIds[i];
        final displayName = i < displayNames.length ? displayNames[i] : userId.toString();
        
        final calleeUser = RemoteUser(
          odId: userId.toString(),
          odUserId: userId,
          nickname: displayName,
          callStatus: DesktopCallState.waiting,
        );
        _remoteUserList.add(calleeUser);
      }
      
      onCallStateChanged?.call(_selfCallStatus);

      // 通过 WebSocket 发送群组通话通知给所有参与者
      await _notifyAllParticipantsGroupCall(userIds, displayNames, callType, groupId, _roomId);

      // 进入 TRTC 房间（异步，结果通过 onEnterRoom 回调返回）
      await _enterRoom();
      
      // 开启麦克风
      await openMicrophone();
      
      logger.debug('📞 [Desktop] 群组通话请求已发送，等待进入房间...');
      
      // 🔴 不在这里触发 onGroupCallRoomEntered，等待 onEnterRoom 回调
      // onEnterRoom 回调会检查 _isGroupCallInitiator 标记并触发回调
      
      return true;
    } catch (e) {
      logger.debug('📞 [Desktop] 发起群组通话失败: $e');
      onError?.call('发起群组通话失败: $e');
      _cleanState();
      return false;
    }
  }

  /// 生成群组通话房间号
  int _generateGroupCallRoomId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final userId = _selfUserIdInt;
    // 确保房间号在有效范围内 (1 ~ 2147483647)
    return ((timestamp % 1000000) * 1000 + (userId % 1000)) % 2147483647 + 1;
  }

  /// 通过 WebSocket 通知所有参与者群组通话
  Future<void> _notifyAllParticipantsGroupCall(
    List<int> userIds,
    List<String> displayNames,
    DesktopCallType callType,
    int? groupId,
    int roomId,
  ) async {
    try {
      // 构建成员列表（包含发起人自己）
      final members = <Map<String, dynamic>>[];
      
      // 🔴 首先添加发起人自己
      members.add({
        'user_id': _selfUserIdInt,
        'display_name': _selfNickname,
        'is_caller': true,  // 标记为发起人
      });
      
      // 然后添加被邀请的成员
      for (int i = 0; i < userIds.length; i++) {
        members.add({
          'user_id': userIds[i],
          'display_name': i < displayNames.length ? displayNames[i] : userIds[i].toString(),
          'is_caller': false,
        });
      }
      
      // 向每个被叫用户发送 WebSocket 通知
      for (final userId in userIds) {
        _wsService.sendWebRTCSignal({
          'type': 'incoming_group_call',
          'caller_id': _selfUserIdInt,
          'caller_name': _selfNickname,
          'call_type': callType == DesktopCallType.video ? 'video' : 'voice',
          'group_id': groupId,
          'room_id': roomId,
          'members': members,
          'to_user_id': userId,
          'from_user_id': _selfUserIdInt,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'source': 'trtc_desktop',
        });
        logger.debug('📞 [Desktop] 已发送群组通话通知给用户 $userId, roomId=$roomId');
      }
      
      logger.debug('📞 [Desktop] ✅ 已通知所有参与者群组通话: userIds=$userIds, roomId=$roomId');
    } catch (e) {
      logger.debug('⚠️ [Desktop] 发送群组通话通知失败: $e');
    }
  }

  /// 进入 TRTC 房间
  Future<void> _enterRoom() async {
    if (_trtcCloud == null || _selfUserId.isEmpty || _roomId == 0) {
      throw Exception('TRTC 未初始化或参数缺失');
    }

    final userSig = _genTestUserSig(_selfUserId);
    
    // 设置进房参数
    final params = TRTCParams(
      sdkAppId: TencentConfig.sdkAppId,
      userId: _selfUserId,
      userSig: userSig,
      roomId: _roomId,
      role: TRTCRoleType.anchor,
    );

    // 设置场景
    final scene = _mediaType == DesktopCallType.video 
        ? TRTCAppScene.videoCall 
        : TRTCAppScene.audioCall;

    logger.debug('📞 进入房间: roomId=$_roomId, odUserId=$_selfUserId, scene=$scene');
    
    // 进入房间
    _trtcCloud!.enterRoom(params, scene);
  }

  /// 接听来电（参考 CallManager.accept）
  Future<bool> accept() async {
    if (_selfCallStatus != DesktopCallState.waiting || _selfCallRole != DesktopCallRole.called) {
      logger.debug('📞 当前状态不允许接听: $_selfCallStatus, $_selfCallRole');
      return false;
    }

    _isLocalHangup = false;

    try {
      logger.debug('📞 [Desktop] 接听来电, scene=$_scene, roomId=$_roomId');
      
      // 🔴 群组通话：通过 WebSocket 通知其他参与者
      if (_scene == DesktopCallScene.groupCall) {
        logger.debug('📞 [Desktop] 接听群组通话');
        
        // 通知所有参与者我已接听
        for (var user in _remoteUserList) {
          _wsService.sendWebRTCSignal({
            'type': 'group_call_member_accepted',
            'user_id': _selfUserIdInt,
            'display_name': _selfNickname,
            'room_id': _roomId,
            'to_user_id': user.odUserId,
            'from_user_id': _selfUserIdInt,
          });
        }
        
        // 进入 TRTC 房间
        await _enterRoom();
        
        // 🔴 接听后同步成员连接状态
        if (_groupCallChannelName != null && _groupCallChannelName!.isNotEmpty) {
          logger.debug('📞 [Desktop] 准备同步群组通话成员状态，channelName=$_groupCallChannelName');
          _syncGroupCallMemberStatus();
        } else {
          logger.debug('📞 [Desktop] 没有 channelName，跳过成员状态同步');
        }
        
        logger.debug('📞 [Desktop] 已接听群组通话，roomId=$_roomId');
        return true;
      }
      
      // 🔴 单人通话：使用 IM 信令接受邀请
      if (_isIMLoggedIn && _currentInviteId != null) {
        // 使用 TUICallKit 标准信令格式接受通话
        final cmdType = _mediaType == DesktopCallType.video ? 'videoCall' : 'audioCall';
        final callTypeValue = _mediaType == DesktopCallType.video ? 2 : 1;
        
        final acceptSignalData = jsonEncode({
          'businessID': 'av_call',
          'call_end': 0,
          'call_type': callTypeValue,
          'data': {
            'cmd': cmdType,
            'room_id': _roomId,
            'str_room_id': '',
          },
          'platform': Platform.operatingSystem,
          'room_id': _roomId,
          'userData': '',
          'version': 4,
        });
        
        final acceptResult = await _im.getSignalingManager().accept(
          inviteID: _currentInviteId!,
          data: acceptSignalData,
        );
        
        if (acceptResult.code == 0) {
          logger.debug('📞 [Desktop] IM 信令接受成功');
        } else {
          logger.debug('📞 [Desktop] IM 信令接受失败: ${acceptResult.desc}');
        }
      } else if (_remoteUserList.isNotEmpty) {
        // 降级到 WebSocket
        _wsService.sendWebRTCSignal({
          'type': 'call-accepted',
          'to_user_id': _remoteUserList.first.odUserId,
          'from_user_id': _selfUserIdInt,
          'room_id': _roomId,
        });
      }

      // 进入 TRTC 房间
      await _enterRoom();
      
      logger.debug('📞 已接听来电');
      return true;
    } catch (e) {
      logger.debug('📞 接听来电失败: $e');
      onError?.call('接听来电失败: $e');
      _cleanState();
      return false;
    }
  }

  /// 拒绝来电（参考 CallManager.reject）
  Future<bool> reject() async {
    if (_selfCallStatus != DesktopCallState.waiting || _selfCallRole != DesktopCallRole.called) {
      logger.debug('📞 当前状态不允许拒绝: $_selfCallStatus, $_selfCallRole');
      return false;
    }

    logger.debug('📞 [Desktop] 拒绝来电');

    // 使用 IM 信令拒绝邀请
    if (_isIMLoggedIn && _currentInviteId != null) {
      try {
        await _im.getSignalingManager().reject(
          inviteID: _currentInviteId!,
          data: jsonEncode({
            'call_action': 2, // 2 = 拒绝通话
          }),
        );
        logger.debug('📞 [Desktop] IM 信令拒绝成功');
      } catch (e) {
        logger.debug('📞 [Desktop] IM 信令拒绝失败: $e');
      }
    }
    
    // 🔴 同时发送 WebSocket 信令（确保移动端也能收到拒绝通知）
    // 参考 cancel() 方法的逻辑，拒绝时也需要通过 WebSocket 通知对方
    if (_remoteUserList.isNotEmpty) {
      for (var user in _remoteUserList) {
        _wsService.sendWebRTCSignal({
          'type': 'call-rejected',
          'to_user_id': user.odUserId,
          'from_user_id': _selfUserIdInt,
        });
        logger.debug('📞 [Desktop] WebSocket 拒绝信令已发送给: ${user.odUserId}');
      }
    }

    _cleanState();
    return true;
  }

  /// 挂断通话（参考 CallManager.hangup）
  Future<bool> hangup({bool isLocalHangup = true}) async {
    logger.debug('📞 [Desktop] 挂断通话, isLocalHangup: $isLocalHangup');

    _isLocalHangup = isLocalHangup;

    try {
      // 发送结束信令
      if (isLocalHangup) {
        // 如果是主叫且对方还没接听，使用取消信令
        if (_selfCallRole == DesktopCallRole.caller && _selfCallStatus == DesktopCallState.waiting) {
          await cancel();
          return true;
        }
        
        // 使用 IM 信令发送挂断（通过自定义消息）
        if (_isIMLoggedIn && _remoteUserList.isNotEmpty) {
          for (var user in _remoteUserList) {
            try {
              // 发送挂断信令消息
              await _im.getMessageManager().sendMessage(
                id: await _im.getMessageManager().createCustomMessage(
                  data: jsonEncode({
                    'businessID': 'av_call',
                    'call_action': 3, // 3 = 挂断通话
                    'call_id': _currentInviteId ?? '',
                    'room_id': _roomId,
                  }),
                ).then((v) => v.data?.id ?? ''),
                receiver: user.odId,
                groupID: '',
              );
            } catch (e) {
              logger.debug('📞 发送挂断信令失败: $e');
            }
          }
        }
        
        // 同时发送 WebSocket 信令（兼容）
        for (var user in _remoteUserList) {
          _wsService.sendWebRTCSignal({
            'type': 'call-ended',
            'to_user_id': user.odUserId,
            'from_user_id': _selfUserIdInt,
          });
        }
      }

      // 停止本地音视频
      _trtcCloud?.stopLocalAudio();
      _trtcCloud?.stopLocalPreview();
      
      // 离开房间
      // 🔴 注意：exitRoom() 会触发 onExitRoom 回调，在回调中会调用 onCallEnded 和 _cleanState
      // 所以这里不需要再调用它们，避免重复调用
      _trtcCloud?.exitRoom();
    } catch (e) {
      logger.debug('⚠️ 挂断通话失败: $e');
    }

    // 🔴 移除这里的 onCallEnded 和 _cleanState 调用
    // 因为 exitRoom() 会触发 onExitRoom 回调，在回调中已经处理了
    // _stopTimer();
    // onCallEnded?.call(callDuration);
    // _cleanState();
    
    return true;
  }

  /// 取消呼叫（主叫在对方接听前取消）
  Future<bool> cancel() async {
    if (_selfCallRole != DesktopCallRole.caller || _selfCallStatus != DesktopCallState.waiting) {
      return false;
    }

    logger.debug('📞 [Desktop] 取消呼叫');
    
    // 🔴 保存目标用户ID和通话类型，用于触发回调
    final targetUserId = _remoteUserList.isNotEmpty ? _remoteUserList.first.odUserId : 0;
    final currentCallType = _mediaType;

    // 使用 IM 信令取消邀请
    if (_isIMLoggedIn && _currentInviteId != null) {
      try {
        await _im.getSignalingManager().cancel(
          inviteID: _currentInviteId!,
          data: jsonEncode({
            'call_action': 4, // 4 = 取消通话
          }),
        );
        logger.debug('📞 [Desktop] IM 信令取消成功');
      } catch (e) {
        logger.debug('📞 [Desktop] IM 信令取消失败: $e');
      }
    }
    
    // 同时发送 WebSocket 信令（兼容）
    for (var user in _remoteUserList) {
      _wsService.sendWebRTCSignal({
        'type': 'call-cancel',
        'to_user_id': user.odUserId,
        'from_user_id': _selfUserIdInt,
      });
    }

    // 离开房间
    _trtcCloud?.exitRoom();
    
    // 🔴 触发通话取消回调（发起方取消）
    if (targetUserId > 0) {
      logger.debug('📞 [Desktop] 发起方取消通话，触发 onCallCancelled 回调: targetUserId=$targetUserId');
      onCallCancelled?.call(targetUserId, currentCallType, true);
    }
    
    _cleanState();
    return true;
  }

  // 兼容旧接口
  Future<void> endCall({bool isLocalHangup = true}) async {
    await hangup(isLocalHangup: isLocalHangup);
  }

  Future<void> acceptCall() async {
    await accept();
  }

  Future<void> rejectCall() async {
    await reject();
  }


  /// 开启摄像头（参考 CallManager.openCamera）
  Future<bool> openCamera(int viewId) async {
    try {
      logger.debug('📞 开启摄像头, viewId=$viewId');
      _localViewId = viewId;
      _trtcCloud?.startLocalPreview(true, viewId);
      _isCameraOpen = true;
      onLocalVideoReady?.call();
      return true;
    } catch (e) {
      logger.debug('⚠️ 开启摄像头失败: $e');
      return false;
    }
  }

  /// 关闭摄像头（参考 CallManager.closeCamera）
  Future<void> closeCamera() async {
    try {
      logger.debug('📞 关闭摄像头');
      _trtcCloud?.stopLocalPreview();
      _isCameraOpen = false;
    } catch (e) {
      logger.debug('⚠️ 关闭摄像头失败: $e');
    }
  }

  /// 切换摄像头
  Future<void> switchCamera() async {
    try {
      // 桌面端通常没有前后摄像头概念，这里可以切换不同的摄像头设备
      logger.debug('📞 切换摄像头（桌面端）');
      // TODO: 实现摄像头设备切换
    } catch (e) {
      logger.debug('⚠️ 切换摄像头失败: $e');
    }
  }

  /// 开启麦克风（参考 CallManager.openMicrophone）
  Future<bool> openMicrophone() async {
    try {
      logger.debug('📞 开启麦克风');
      _trtcCloud?.startLocalAudio(TRTCAudioQuality.speech);
      _isMicrophoneMute = false;
      return true;
    } catch (e) {
      logger.debug('⚠️ 开启麦克风失败: $e');
      return false;
    }
  }

  /// 关闭麦克风（参考 CallManager.closeMicrophone）
  Future<void> closeMicrophone() async {
    try {
      logger.debug('📞 关闭麦克风');
      _trtcCloud?.stopLocalAudio();
      _isMicrophoneMute = true;
    } catch (e) {
      logger.debug('⚠️ 关闭麦克风失败: $e');
    }
  }

  /// 切换麦克风状态
  Future<void> toggleMicrophone(bool enable) async {
    if (enable) {
      await openMicrophone();
    } else {
      await closeMicrophone();
    }
  }

  /// 切换摄像头状态
  Future<void> toggleCamera(bool enable) async {
    if (enable) {
      if (_localViewId != null) {
        await openCamera(_localViewId!);
      }
    } else {
      await closeCamera();
    }
  }

  /// 切换扬声器（参考 CallManager.selectAudioPlaybackDevice）
  Future<void> toggleSpeaker(bool enable) async {
    try {
      // 桌面端通过静音/取消静音远端用户来实现
      for (final user in _remoteUserList) {
        _trtcCloud?.muteRemoteAudio(user.odId, !enable);
      }
      _isSpeakerOn = enable;
      logger.debug('📞 扬声器已${enable ? '开启' : '关闭'}');
    } catch (e) {
      logger.debug('⚠️ 切换扬声器失败: $e');
    }
  }

  /// 静音/取消静音本地麦克风（不停止采集）
  Future<void> muteMicrophone(bool mute) async {
    try {
      _trtcCloud?.muteLocalAudio(mute);
      _isMicrophoneMute = mute;
      logger.debug('📞 本地麦克风已${mute ? '静音' : '取消静音'}');
    } catch (e) {
      logger.debug('⚠️ 静音麦克风失败: $e');
    }
  }

  /// 静音/取消静音本地视频（不停止采集）
  Future<void> muteCamera(bool mute) async {
    try {
      _trtcCloud?.muteLocalVideo(TRTCVideoStreamType.big, mute);
      logger.debug('📞 本地视频已${mute ? '静音' : '取消静音'}');
    } catch (e) {
      logger.debug('⚠️ 静音视频失败: $e');
    }
  }

  /// 设置本地视频渲染视图
  Future<void> setLocalVideoView(int viewId) async {
    _localViewId = viewId;
    if (_isCameraOpen && _trtcCloud != null) {
      _trtcCloud!.startLocalPreview(true, viewId);
      logger.debug('📞 本地视频预览已开启, viewId=$viewId');
    }
  }

  /// 开始订阅远端视频（参考 CallManager.startRemoteView）
  Future<void> startRemoteView(String odUserId, int viewId) async {
    _remoteViewIds[odUserId] = viewId;
    if (_trtcCloud != null) {
      _trtcCloud!.startRemoteView(
        odUserId,
        TRTCVideoStreamType.big,
        viewId,
      );
      logger.debug('📞 远端视频预览已开启, odUserId=$odUserId, viewId=$viewId');
    }
  }

  /// 停止订阅远端视频（参考 CallManager.stopRemoteView）
  Future<void> stopRemoteView(String odUserId) async {
    _remoteViewIds.remove(odUserId);
    if (_trtcCloud != null) {
      _trtcCloud!.stopRemoteView(
        odUserId,
        TRTCVideoStreamType.big,
      );
      logger.debug('📞 远端视频预览已停止, odUserId=$odUserId');
    }
  }

  // 兼容旧接口
  Future<void> setRemoteVideoView(int odUserId, int viewId) async {
    await startRemoteView(odUserId.toString(), viewId);
  }

  Future<void> stopRemoteVideoView(int odUserId) async {
    await stopRemoteView(odUserId.toString());
  }

  /// 获取摄像头设备列表
  Future<List<dynamic>> getCameraDevices() async {
    logger.debug('📞 获取摄像头列表');
    // TODO: 实现设备列表获取
    return [];
  }

  /// 获取麦克风设备列表
  Future<List<dynamic>> getMicrophoneDevices() async {
    logger.debug('📞 获取麦克风列表');
    return [];
  }

  /// 获取扬声器设备列表
  Future<List<dynamic>> getSpeakerDevices() async {
    logger.debug('📞 获取扬声器列表');
    return [];
  }

  /// 设置当前使用的摄像头
  Future<void> setCurrentCamera(String deviceId) async {
    logger.debug('📞 设置摄像头: $deviceId');
  }

  /// 设置当前使用的麦克风
  Future<void> setCurrentMicrophone(String deviceId) async {
    logger.debug('📞 设置麦克风: $deviceId');
  }

  /// 设置当前使用的扬声器
  Future<void> setCurrentSpeaker(String deviceId) async {
    logger.debug('📞 设置扬声器: $deviceId');
  }

  /// 开始计时（参考 CallState.startTimer）
  void _startTimer() {
    _timeCount = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_selfCallStatus == DesktopCallState.accept) {
        _timeCount++;
        onCallTimeUpdate?.call(_timeCount);
      } else {
        _stopTimer();
      }
    });
  }

  /// 停止计时（参考 CallState.stopTimer）
  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 清理状态（参考 CallState.cleanState）
  void _cleanState() {
    logger.debug('📞 [Desktop] _cleanState 被调用');
    logger.debug('📞 [Desktop] 清理前状态: $_selfCallStatus, 角色: $_selfCallRole, inviteId: $_currentInviteId');
    logger.debug('📞 [Desktop] 清理前 isLocalHangup: $_isLocalHangup');
    
    // 🔴 保存 isLocalHangup 的值，因为 onCallStateChanged 回调中可能需要读取它
    final savedIsLocalHangup = _isLocalHangup;
    
    // 🔴 通知服务器：用户退出通话状态
    _updateServerCallStatus(inCall: false);
    
    _selfCallStatus = DesktopCallState.idle;
    _selfCallRole = DesktopCallRole.none;
    _remoteUserList.clear();
    _mediaType = DesktopCallType.audio;
    _timeCount = 0;
    _roomId = 0;
    _groupId = '';
    _isCameraOpen = false;
    _isMicrophoneMute = false;
    _callStartTime = null;
    _localViewId = null;
    _remoteViewIds.clear();
    // 🔴 暂时不重置 _isLocalHangup，等 onCallStateChanged 回调完成后再重置
    _currentInviteId = null;
    
    // 🔴 重置群组通话相关状态
    _isGroupCallInitiator = false;
    _groupCallUserIds = null;
    _groupCallDisplayNames = null;
    _groupCallGroupId = null;
    _groupCallChannelName = null;  // 🔴 清理频道名称
    
    logger.debug('📞 [Desktop] 清理后状态: $_selfCallStatus, 角色: $_selfCallRole, inviteId: $_currentInviteId');
    
    // 🔴 先触发 onCallStateChanged 回调，让 UI 层读取 isLocalHangup
    onCallStateChanged?.call(_selfCallStatus);
    
    // 🔴 回调完成后再重置 isLocalHangup
    _isLocalHangup = false;
    logger.debug('📞 [Desktop] isLocalHangup 已重置为 false');
  }

  /// 销毁 TRTC 实例
  Future<void> destroy() async {
    try {
      await hangup();
      _trtcCloud?.unRegisterListener(TRTCCloudListener());
      TRTCCloud.destroySharedInstance();
      _trtcCloud = null;
      _isInitialized = false;
      logger.debug('📞 TRTC Desktop 已销毁');
    } catch (e) {
      logger.debug('⚠️ 销毁 TRTC 失败: $e');
    }
  }

  /// 同步群组通话成员状态
  /// 在接听群组通话后调用，从服务器获取当前已连接的成员列表
  Future<void> _syncGroupCallMemberStatus() async {
    if (_groupCallChannelName == null || _groupCallChannelName!.isEmpty) {
      logger.debug('📞 [Desktop] 没有 channelName，无法同步成员状态');
      return;
    }

    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        logger.debug('📞 [Desktop] 没有 token，无法同步成员状态');
        return;
      }

      logger.debug('📞 [Desktop] 开始同步群组通话成员状态，channelName=$_groupCallChannelName');

      // 调用 API 获取已连接成员列表
      final response = await ApiService.getGroupCallConnectedMembers(
        token: token,
        channelName: _groupCallChannelName!,
      );

      if (response['error'] != null) {
        logger.debug('📞 [Desktop] 同步成员状态失败: ${response['error']}');
        return;
      }

      final connectedMembers = response['connected_members'] as List<dynamic>? ?? [];
      final totalInvited = response['total_invited'] as int? ?? 0;
      final callStartTime = response['call_start_time'] as int? ?? 0;

      logger.debug('📞 [Desktop] 同步成员状态成功:');
      logger.debug('📞 [Desktop]   - 已连接成员数: ${connectedMembers.length}');
      logger.debug('📞 [Desktop]   - 总邀请人数: $totalInvited');
      logger.debug('📞 [Desktop]   - 通话开始时间: $callStartTime');

      // 更新本地成员状态
      for (final member in connectedMembers) {
        final memberId = member['user_id'] as int? ?? 0;
        if (memberId > 0 && memberId != _selfUserIdInt) {
          // 查找并更新远程用户状态
          for (var remoteUser in _remoteUserList) {
            if (remoteUser.odUserId == memberId) {
              remoteUser.callStatus = DesktopCallState.accept;
              logger.debug('📞 [Desktop] 更新成员 $memberId 状态为已连接');
              break;
            }
          }
        }
      }

      // 触发回调通知 UI 更新
      final membersList = connectedMembers.map((m) => {
        'user_id': m['user_id'] as int? ?? 0,
        'username': m['username'] as String? ?? '',
        'display_name': m['display_name'] as String? ?? '',
        'avatar': m['avatar'] as String? ?? '',
      }).toList();

      onGroupCallMembersSync?.call(membersList, totalInvited, callStartTime);
      logger.debug('📞 [Desktop] 已触发 onGroupCallMembersSync 回调');
    } catch (e) {
      logger.debug('📞 [Desktop] 同步成员状态异常: $e');
    }
  }

  /// 🔴 更新服务器上的用户通话状态
  /// [inCall] 是否在通话中
  /// [callType] 通话类型（voice/video）
  Future<void> _updateServerCallStatus({
    required bool inCall,
    String? callType,
  }) async {
    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        logger.debug('📞 [Desktop] 没有 token，无法更新服务器通话状态');
        return;
      }

      logger.debug('📞 [Desktop] 更新服务器通话状态: inCall=$inCall, callType=$callType');

      // 获取当前通话对象
      int? targetUserId;
      if (_remoteUserList.isNotEmpty) {
        targetUserId = _remoteUserList.first.odUserId;
      }
      
      // 获取群组ID
      int? groupId;
      if (_groupId.isNotEmpty) {
        groupId = int.tryParse(_groupId);
      }

      final response = await ApiService.updateCallStatus(
        token: token,
        inCall: inCall,
        callType: callType,
        targetUserId: targetUserId,
        groupId: groupId,
      );

      if (response['code'] == 0) {
        logger.debug('📞 [Desktop] 服务器通话状态更新成功');
      } else {
        logger.debug('📞 [Desktop] 服务器通话状态更新失败: ${response['message']}');
      }
    } catch (e) {
      logger.debug('📞 [Desktop] 更新服务器通话状态异常: $e');
    }
  }
}
