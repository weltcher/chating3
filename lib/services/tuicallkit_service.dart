import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:tencent_calls_uikit/tencent_calls_uikit.dart';
import 'package:tencent_calls_uikit/src/ui/call_navigator_observer.dart';
import 'package:tencent_cloud_chat_sdk/tencent_im_sdk_plugin.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSignalingListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_cloud_uikit_core/tencent_cloud_uikit_core.dart';
import '../config/tencent_config.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'websocket_service.dart';
import 'api_service.dart';

/// 通话状态枚举（兼容旧代码）
enum CallState {
  idle, // 空闲
  calling, // 正在呼叫
  ringing, // 对方来电响铃中
  connected, // 已连接
  ended, // 已结束
}

/// 通话类型枚举（兼容旧代码）
enum CallType {
  voice, // 语音通话
  video, // 视频通话
}

/// TUICallKit 音视频通话服务
/// 替代原有的 AgoraService
class TUICallKitService {
  // 单例模式
  static final TUICallKitService _instance = TUICallKitService._internal();
  factory TUICallKitService() => _instance;
  TUICallKitService._internal();

  // 通话状态
  CallState _callState = CallState.idle;
  CallType _callType = CallType.voice;
  int? _currentCallUserId;
  String? _currentCallUserIdStr; // TUICallKit 使用字符串 userId
  int? _myUserId;
  String? _myUserIdStr;
  DateTime? _callStartTime;
  int? _currentGroupId;
  
  // 🔴 新增：当前通话的 callId（用于群组通话挂断后显示"加入通话"按钮）
  String? _currentCallId;

  // 保存最后一次通话信息
  int? _lastGroupId;
  CallType? _lastCallType;
  int? _lastCallUserId;

  // 🔴 新增：来电连接中状态
  Timer? _connectingCheckTimer; // 用于检查是否需要显示遮盖层的定时器
  bool _isWaitingForCallBegin = false; // 是否正在等待 onCallBegin 回调

  // 最小化相关
  bool _isCallMinimized = false;
  int? _minimizedCallUserId;
  String? _minimizedCallDisplayName;
  CallType? _minimizedCallType;
  bool _minimizedIsGroupCall = false;
  int? _minimizedGroupId;

  // 群组通话成员信息
  List<int>? _currentGroupCallUserIds;
  List<String>? _currentGroupCallDisplayNames;
  Set<int>? _connectedMemberIds;
  
  // 🔴 群组通话房间号（使用 TRTC SDK 直接进入房间时使用）
  int? _currentGroupCallRoomId;
  
  // 🔴 群组通话频道名称（用于同步成员状态）
  String? _currentGroupCallChannelName;
  
  // 🔴 标记是否是群组通话发起者（用于在 onEnterRoom 回调中触发 onGroupCallRoomEntered）
  bool _isGroupCallInitiator = false;
  
  // 🔴 标记当前是否是群组通话（通过 TUICallKit 来电回调检测）
  bool _isInGroupCall = false;
  bool get isInGroupCall => _isInGroupCall;
  

  
  // 🔴 标记是否使用 TRTC SDK 直接进入房间（用于 endCall 时判断使用哪种方式退出）
  bool _usedTRTCSDKDirectly = false;

  // 本地挂断标识
  bool _isEndingCall = false;
  bool _isLocalHangup = false;
  bool get isLocalHangup => _isLocalHangup;

  // 🔴 标记是否收到了对方的拒绝信令（用于避免在 default 分支重复发送消息）
  bool _receivedRejectSignal = false;
  
  // 🔴 标记接收方是否主动拒绝了通话（用于在 default 分支发送"已拒绝"消息）
  bool _isLocalReject = false;

  // 远程用户集合
  Set<int> _remoteUids = {};

  // WebSocket 服务
  final WebSocketService _wsService = WebSocketService();

  // 是否已登录
  bool _isLoggedIn = false;
  bool get isLoggedIn => _isLoggedIn;
  
  // 记录上次登录使用的 SDKAppID 和 userId，用于检测配置变化或用户切换
  int? _lastLoginSdkAppId;
  int? _lastLoginUserId;

  // 回调函数
  Function(CallState)? onCallStateChanged;
  Function(int uid)? onRemoteUserJoined;
  Function(int uid)? onRemoteUserLeft;
  Function(String)? onError;
  Function(int userId, String displayName, CallType callType)? onIncomingCall;
  Function(
    int userId,
    String displayName,
    CallType callType,
    List<Map<String, dynamic>> members,
    int? groupId,
  )? onIncomingGroupCall;
  Function()? onLocalVideoReady;
  Function(int uid)? onRemoteVideoReady;
  Function(int callDuration)? onCallEnded;
  Function(int userId, String status, String? displayName)? onGroupCallMemberStatusChanged;
  Function(int uid, bool isMuted)? onRemoteVideoMuted;
  
  // 🔴 新增：通话取消回调（发起方取消通话时触发）
  // targetUserId: 被呼叫方的用户ID
  // callType: 通话类型（语音/视频）
  // isCaller: 是否是发起方取消（true=发起方取消，false=接收方收到取消通知）
  Function(int targetUserId, CallType callType, bool isCaller)? onCallCancelled;
  
  // 🔴 新增：接收方拒绝通话回调（接收方通过 TUICallKit 内置 UI 拒绝通话时触发）
  // callerUserId: 发起方的用户ID
  // callType: 通话类型（语音/视频）
  Function(int callerUserId, CallType callType)? onCallRejectedByMe;
  
  // 🔴 新增：群组通话房间已进入回调（使用 TRTC SDK 直接进入房间后触发）
  // 用于通知调用方导航到通话页面
  // roomId: TRTC 房间号
  // userIds: 被叫用户ID列表
  // displayNames: 被叫用户显示名称列表
  // callType: 通话类型（语音/视频）
  // groupId: 群组ID（可选）
  Function(int roomId, List<int> userIds, List<String> displayNames, CallType callType, int? groupId)? onGroupCallRoomEntered;
  
  // 🔴 新增：来电回调（TUICallKit 内置 UI 收到来电时触发）
  // 用于在 mobile_home_page 中显示自定义来电弹窗
  // callerId: 来电者用户ID
  // callerIdStr: 来电者用户ID字符串
  // callType: 通话类型（语音/视频）
  // isGroupCall: 是否是群组通话
  // calleeIdList: 被叫用户ID列表（群组通话时有多个）
  Function(int callerId, String callerIdStr, CallType callType, bool isGroupCall, List<String> calleeIdList)? onTUICallReceived;
  
  // 🔴 新增：通话连接中回调（用户点击接听后、通话真正开始前触发）
  // 用于显示"正在连接中"覆盖层
  Function()? onCallConnecting;
  
  // 🔴 新增：通话已连接回调（通话真正开始时触发）
  // 用于隐藏"正在连接中"覆盖层
  Function()? onCallConnected;
  
  // 🔴 新增：群组通话中用户离开但通话仍在继续回调
  // 用于在群组对话框中显示"加入通话"按钮
  // groupId: 群组ID
  // callType: 通话类型（语音/视频）
  // callDuration: 本次通话时长（秒）
  // callId: 通话ID（用于重新加入通话）
  Function(int groupId, CallType callType, int callDuration, String? callId)? onGroupCallLeftButContinuing;
  
  // 🔴 新增：群组通话挂断回调（用于发送通话时长消息）
  // groupId: 群组ID
  // callType: 通话类型（语音/视频）
  // callDuration: 通话时长（秒）
  // isLastMember: 是否是最后一个成员
  Function(int groupId, CallType callType, int callDuration, bool isLastMember)? onGroupCallHangup;

  // Getters
  CallState get callState => _callState;
  CallType get callType => _callType;
  int? get currentCallUserId => _currentCallUserId;
  int? get myUserId => _myUserId;
  DateTime? get callStartTime => _callStartTime;
  int? get currentGroupId => _currentGroupId;
  int? get lastGroupId => _lastGroupId;
  CallType? get lastCallType => _lastCallType;
  int? get lastCallUserId => _lastCallUserId;
  bool get isCallMinimized => _isCallMinimized;
  int? get minimizedCallUserId => _minimizedCallUserId;
  String? get minimizedCallDisplayName => _minimizedCallDisplayName;
  CallType? get minimizedCallType => _minimizedCallType;
  bool get minimizedIsGroupCall => _minimizedIsGroupCall;
  int? get minimizedGroupId => _minimizedGroupId;
  List<int>? get currentGroupCallUserIds => _currentGroupCallUserIds;
  List<String>? get currentGroupCallDisplayNames => _currentGroupCallDisplayNames;
  Set<int>? get connectedMemberIds => _connectedMemberIds;
  Set<int> get remoteUids => _remoteUids;

  /// 设置当前群组ID（用于在收到 join_voice_button 消息时保存群组ID）
  void setCurrentGroupId(int? groupId) {
    logger.debug('📞 [TUICallKitService] setCurrentGroupId: $groupId');
    _currentGroupId = groupId;
  }


  /// 生成 UserSig（仅用于测试，生产环境请使用服务端生成）
  String _genTestUserSig(String userId) {
    final currTime = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    
    final sigDoc = <String, dynamic>{
      'TLS.ver': '2.0',
      'TLS.identifier': userId,
      'TLS.sdkappid': TencentConfig.sdkAppId,
      'TLS.expire': TencentConfig.expireTime,
      'TLS.time': currTime,
    };

    final contentToBeSigned = 
        'TLS.identifier:$userId\n'
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

  /// 初始化并登录 TUICallKit
  Future<void> initialize(int currentUserId) async {
    try {
      logger.debug('========== 📞 TUICallKit 初始化开始 ==========');
      logger.debug('📞 收到的用户ID: $currentUserId');
      logger.debug('📞 当前通话状态: $_callState');

      // 🔴 初始化时确保状态是 idle
      if (_callState != CallState.idle) {
        logger.debug('📞 初始化时检测到非 idle 状态，强制重置');
        _resetCallState();
      }

      _myUserId = currentUserId;
      _myUserIdStr = currentUserId.toString();
      logger.debug('📞 已设置 _myUserId = $_myUserId');

      // 🔴 启用 TUICallKit 内置 UI（使用 TUICallKit 自带的通话界面）
      TUICallKitNavigatorObserver.disableBuiltInUI = false;
      logger.debug('📞 已启用 TUICallKit 内置 UI (disableBuiltInUI=false)');

      // 🔴 检查是否需要重新登录（SDKAppID 变化、用户切换、或未登录）
      final needRelogin = !_isLoggedIn || 
                          _lastLoginSdkAppId != TencentConfig.sdkAppId ||
                          _lastLoginUserId != currentUserId;
      
      if (!needRelogin) {
        logger.debug('📞 TUICallKit 已登录且用户未变化，跳过重复登录');
        // 🔴 即使跳过登录，也要确保配置生效
        await _configureCallKit();
        _setupWebSocketListeners();
        return;
      }
      
      // 如果已登录但需要重新登录（用户切换或 SDKAppID 变化），需要先登出
      if (_isLoggedIn) {
        logger.debug('📞 需要重新登录 (SDKAppID: $_lastLoginSdkAppId -> ${TencentConfig.sdkAppId}, userId: $_lastLoginUserId -> $currentUserId)');
        try {
          await TUICallKit.instance.logout();
          _isLoggedIn = false;
          logger.debug('📞 已登出旧的 TUICallKit 会话');
        } catch (e) {
          logger.debug('⚠️ 登出失败: $e');
          _isLoggedIn = false;
        }
      }

      // 🔴 根据配置设置接入点（国内/海外）
      final isOverseas = TencentConfig.isOverseas;
      logger.debug('📞 当前配置: ${isOverseas ? "海外版" : "国内版"}');
      
      if (isOverseas) {
        // 海外版不需要禁用 GDPR，保持默认行为
        logger.debug('📞 海外版，保持默认 GDPR 设置');
      } else {
        // 国内版：尝试禁用 GDPR 检测
        try {
          await TUICallEngine.instance.callExperimentalAPI({
            "api": "disableGDPR",
            "params": {"disable": true}
          });
          logger.debug('📞 已尝试禁用 GDPR 模式');
        } catch (e) {
          logger.debug('⚠️ 禁用 GDPR 模式失败: $e');
        }
      }
      
      try {
        // 设置环境类型
        // 0 = 默认（国内）, 1 = 海外
        final envType = isOverseas ? 1 : 0;
        await TUICallEngine.instance.callExperimentalAPI({
          "api": "setTrtcEnvType",
          "params": {"envType": envType}
        });
        logger.debug('📞 已设置环境类型: ${isOverseas ? "海外" : "国内"}');
      } catch (e) {
        logger.debug('⚠️ 设置环境类型失败: $e');
      }
      
      try {
        // 设置接入点
        // 0 = 中国, 1 = 海外（新加坡等）
        final accessPoint = isOverseas ? 1 : 0;
        await TUICallEngine.instance.callExperimentalAPI({
          "api": "setAccessPoint",
          "params": {"accessPoint": accessPoint}
        });
        logger.debug('📞 已设置接入点: ${isOverseas ? "海外" : "中国"}');
      } catch (e) {
        logger.debug('⚠️ 设置接入点失败: $e');
      }

      // 生成 UserSig
      final userSig = _genTestUserSig(_myUserIdStr!);
      logger.debug('📞 UserSig 已生成');

      // 登录 TUICallKit
      final result = await TUICallKit.instance.login(
        TencentConfig.sdkAppId,
        _myUserIdStr!,
        userSig,
      );

      if (result.code.isEmpty) {
        _isLoggedIn = true;
        _lastLoginSdkAppId = TencentConfig.sdkAppId;
        _lastLoginUserId = currentUserId;
        logger.debug('📞 TUICallKit 登录成功，SDKAppID: ${TencentConfig.sdkAppId}, userId: $currentUserId');

        // 配置 TUICallKit
        await _configureCallKit();
      } else {
        logger.debug('📞 TUICallKit 登录失败: ${result.message}');
        onError?.call('TUICallKit 登录失败: ${result.message}');
      }

      // 设置 WebSocket 监听
      _setupWebSocketListeners();

      // 添加通话观察者
      _setupCallObserver();
      
      // 添加 IM 信令监听（用于接收 PC 端的通话请求）
      _setupIMSignalingListener();
      
      // 🔴 注册群组通话挂断事件监听
      _setupGroupCallHangupListener();

      logger.debug('========== TUICallKit 初始化完成 ==========');
    } catch (e) {
      logger.debug('📞 TUICallKit 初始化失败: $e');
      onError?.call('初始化失败: $e');
    }
  }

  /// 配置 TUICallKit
  Future<void> _configureCallKit() async {
    try {
      logger.debug('📞 ========== 开始配置 TUICallKit ==========');
      
      // 🔴 启用悬浮窗功能
      logger.debug('📞 正在启用悬浮窗...');
      await TUICallKit.instance.enableFloatWindow(true);
      logger.debug('📞 ✅ 悬浮窗已启用（enableFloatWindow=true）');

      // 🔴 启用来电横幅
      logger.debug('📞 正在启用来电横幅...');
      TUICallKit.instance.enableIncomingBanner(true);
      logger.debug('📞 ✅ 来电横幅已启用（enableIncomingBanner=true）');

      // 设置用户信息
      final nickname = await Storage.getFullName();
      final avatar = await Storage.getAvatar();
      if (nickname != null && nickname.isNotEmpty) {
        await TUICallKit.instance.setSelfInfo(
          nickname,
          avatar ?? '',
        );
        logger.debug('📞 ✅ TUICallKit 用户信息已设置: $nickname');
        
        // 🔴 同步用户头像到腾讯 IM 服务器
        // 这样其他用户在通话时可以看到正确的头像
        await _syncUserProfileToIM(nickname, avatar ?? '');
      }
      
      logger.debug('📞 ========== TUICallKit 配置完成 ==========');
    } catch (e) {
      logger.debug('⚠️ 配置 TUICallKit 失败: $e');
    }
  }

  /// 设置通话观察者
  void _setupCallObserver() {
    TUICallEngine.instance.addObserver(TUICallObserver(
      onCallReceived: (String callId, String callerId, List<String> calleeIdList, 
          TUICallMediaType callMediaType, CallObserverExtraInfo info) {
        logger.debug('📞 收到来电: callId=$callId, callerId=$callerId, mediaType=$callMediaType');
        logger.debug('📞 被叫用户列表: $calleeIdList (共 ${calleeIdList.length} 人)');
        logger.debug('📞 extraInfo: ${info.toString()}');
        logger.debug('📞 extraInfo.chatGroupId: ${info.chatGroupId}');
        
        // 🔴 判断是否是群组通话（被叫用户数量 > 1 或 chatGroupId 不为空）
        final hasGroupId = info.chatGroupId.isNotEmpty;
        final isGroupCall = calleeIdList.length > 1 || hasGroupId;
        logger.debug('📞 是否群组通话: $isGroupCall (hasGroupId=$hasGroupId, calleeCount=${calleeIdList.length})');
        
        // 🔴 保存来电者信息，用于后续拒绝时发送消息
        // 注意：不要在这里更新 _callState，因为 TUICallKit 内置 UI 会自动处理来电
        // 如果在这里设置 ringing 状态，会导致 _handleIMInvitation 误判为正在通话中
        final callerIdInt = int.tryParse(callerId) ?? 0;
        if (callerIdInt > 0 && callerIdInt != _myUserId) {
          _currentCallUserId = callerIdInt;
          _currentCallUserIdStr = callerId;
          _callType = callMediaType == TUICallMediaType.video ? CallType.video : CallType.voice;
          
          // 🔴 如果是群组通话，设置群组通话标志和群组ID
          if (isGroupCall) {
            _isInGroupCall = true;
            // 🔴 保存被叫用户ID列表
            _currentGroupCallUserIds = calleeIdList.map((id) => int.tryParse(id) ?? 0).where((id) => id > 0).toList();
            
            // 🔴 关键修复：从 extraInfo.chatGroupId 中提取群组ID
            if (hasGroupId) {
              _currentGroupId = int.tryParse(info.chatGroupId);
              logger.debug('📞 已从 extraInfo.chatGroupId 设置 _currentGroupId: $_currentGroupId');
            }
            
            logger.debug('📞 已设置群组通话标志: _isInGroupCall=true, 成员IDs=$_currentGroupCallUserIds, groupId=$_currentGroupId');
          } else {
            _isInGroupCall = false;
            _currentGroupCallUserIds = null;
            _currentGroupId = null;
          }
          
          // 🔴 不调用 _updateCallState(CallState.ringing)，避免与 _handleIMInvitation 冲突
          logger.debug('📞 已保存来电者信息: _currentCallUserId=$_currentCallUserId, _callType=$_callType');
          
          // 🔴 触发来电回调，通知 mobile_home_page 准备显示遮盖层
          logger.debug('📞 触发 onTUICallReceived 回调');
          onTUICallReceived?.call(callerIdInt, callerId, _callType, isGroupCall, calleeIdList);
        }
      },
      onCallCancelled: (String callerId) {
        logger.debug('📞 通话已取消: callerId=$callerId');
        logger.debug(
            '📞 当前状态: $_callState, 目标用户: $_currentCallUserId, 我的ID: $_myUserId');

        final callerIdInt = int.tryParse(callerId) ?? 0;

        // 🔴 保存目标用户ID，因为后面 _updateCallState 会重置它
        final targetUserId = _currentCallUserId;
        final currentCallType = _callType;

        // 🔴 判断本机角色：
        // - 如果 _callState == calling，说明本机是发起方
        // - 如果 _callState == ringing，说明本机是接收方
        // - 如果 _callState == idle，可能是状态已经被重置，需要根据 callerId 判断
        final isCaller = _callState == CallState.calling;
        final isReceiver = _callState == CallState.ringing ||
            (callerIdInt > 0 && callerIdInt != _myUserId);

        if (isCaller && targetUserId != null && targetUserId > 0) {
          // 🔴 本机是发起方，本机取消了通话
          // 需要发送"已取消"消息给对方
          logger.debug(
              '📞 发起方取消通话（onCallCancelled），触发 onCallCancelled 回调: targetUserId=$targetUserId');
          onCallCancelled?.call(targetUserId, currentCallType, true);
        } else if (isReceiver && callerIdInt > 0 && callerIdInt != _myUserId) {
          // 🔴 本机是接收方，对方（发起方）取消了通话
          // 不需要发送消息，因为对方会发送
          logger.debug(
              '📞 接收方收到取消通知，触发 onCallCancelled 回调: callerId=$callerIdInt');
          onCallCancelled?.call(callerIdInt, currentCallType, false);
        } else {
          logger.debug(
              '📞 无法确定角色或参数无效，跳过 onCallCancelled 回调 (isCaller=$isCaller, isReceiver=$isReceiver, targetUserId=$targetUserId, callerIdInt=$callerIdInt)');
        }

        _updateCallState(CallState.ended);
      },
      onCallBegin: (String callId, TUICallMediaType callMediaType, 
          CallObserverExtraInfo info) {
        logger.debug('📞 通话开始: callId=$callId, mediaType=$callMediaType');
        logger.debug('📞 通话开始 extraInfo: ${info.toString()}');
        _callStartTime = DateTime.now();
        
        // 🔴 保存当前通话的 callId（用于群组通话挂断后显示"加入通话"按钮）
        _currentCallId = callId;
        logger.debug('📞 已保存 _currentCallId: $_currentCallId');
        
        // 🔴 触发通话连接中回调（显示遮盖层）
        // 虽然此时连接已经建立，但用户在点击接听后可能没有看到任何反馈
        // 所以我们在这里显示一个短暂的"正在连接中"提示
        logger.debug('📞 触发 onCallConnecting 回调（显示遮盖层）');
        onCallConnecting?.call();
        
        // 🔴 延迟 500ms 后触发通话已连接回调（隐藏遮盖层）
        // 这样用户可以看到"正在连接中"的提示
        Future.delayed(const Duration(milliseconds: 500), () {
          logger.debug('📞 触发 onCallConnected 回调（隐藏遮盖层）');
          onCallConnected?.call();
        });
        
        _updateCallState(CallState.connected);
        
        // 🔴 通话开始后，通过 WebSocket 发送房间信息给 PC 端
        // 这样 PC 端可以加入同一个 TRTC 房间
        _notifyPCCallStarted(callId, callMediaType);
        
        // 🔴 如果是群组通话，同步成员连接状态
        if (_isInGroupCall && _currentGroupCallChannelName != null) {
          logger.debug('📞 [Mobile] 群组通话开始，准备同步成员状态');
          _syncGroupCallMemberStatus();
        }
      },
      onCallEnd: (String callId, TUICallMediaType callMediaType, 
          CallEndReason reason, String userId, double totalTime, CallObserverExtraInfo info) {
        logger.debug('📞 ========== onCallEnd 回调开始 ==========');
        logger.debug('📞 [onCallEnd] callId: $callId');
        logger.debug('📞 [onCallEnd] callMediaType: $callMediaType');
        logger.debug('📞 [onCallEnd] reason: $reason');
        logger.debug('📞 [onCallEnd] userId (挂断方): $userId');
        logger.debug('📞 [onCallEnd] totalTime: $totalTime');
        logger.debug('📞 [onCallEnd] 当前用户ID (_myUserIdStr): $_myUserIdStr');
        logger.debug('📞 [onCallEnd] 目标用户ID (_currentCallUserId): $_currentCallUserId');
        logger.debug('📞 [onCallEnd] 当前 _isLocalHangup: $_isLocalHangup');
        logger.debug('📞 [onCallEnd] 当前 _isInGroupCall: $_isInGroupCall');
        logger.debug('📞 [onCallEnd] 当前 _currentGroupId: $_currentGroupId');
        logger.debug('📞 [onCallEnd] 当前 _lastGroupId: $_lastGroupId');
        logger.debug('📞 [onCallEnd] 当前 _remoteUids: $_remoteUids');
        logger.debug('📞 [onCallEnd] 当前 _currentGroupCallUserIds: $_currentGroupCallUserIds');
        
        final duration = totalTime.toInt();
        
        // 🔴 判断是否是本地挂断
        // 方案1：如果 _isLocalHangup 已经被 endCall 方法设置为 true，则保持
        // 方案2：如果 userId 等于对方的ID，说明是对方挂断
        // 方案3：如果 reason 是 hangup 且 userId 为空或等于自己的ID，说明是本地挂断
        if (!_isLocalHangup) {
          // 如果 _isLocalHangup 还没有被设置，尝试根据 userId 判断
          // TUICallKit 的 onCallEnd 回调中，userId 通常是挂断方的 ID
          final userIdInt = int.tryParse(userId) ?? 0;
          final targetUserId = _currentCallUserId ?? 0;
          
          logger.debug('📞 [onCallEnd] 判断挂断方: userIdInt=$userIdInt, targetUserId=$targetUserId');
          
          if (userId.isEmpty) {
            // userId 为空，可能是本地挂断（通过 TUICallKit 内置 UI）
            _isLocalHangup = true;
            logger.debug('📞 [onCallEnd] userId 为空，视为本地挂断');
          } else if (userId == _myUserIdStr) {
            // userId 等于自己的ID，是本地挂断
            _isLocalHangup = true;
            logger.debug('📞 [onCallEnd] userId 等于自己的ID，是本地挂断');
          } else if (userIdInt == targetUserId && targetUserId > 0) {
            // userId 等于对方的ID，是对方挂断
            _isLocalHangup = false;
            logger.debug('📞 [onCallEnd] userId 等于对方的ID，是对方挂断');
          } else {
            // 无法确定，默认视为本地挂断（保守策略，确保消息被发送）
            _isLocalHangup = true;
            logger.debug('📞 [onCallEnd] 无法确定挂断方，默认视为本地挂断');
          }
        }
        
        logger.debug('📞 [onCallEnd] 最终 isLocalHangup: $_isLocalHangup');
        
        // 🔴 检查是否是群组通话，如果是且本地挂断，可能需要显示"加入通话"按钮
        // 保存群组通话信息，因为 _resetCallState 会清除这些信息
        final wasGroupCall = _isInGroupCall;
        final groupId = _currentGroupId ?? _lastGroupId;
        final currentCallType = _callType;
        final currentCallId = _currentCallId; // 🔴 保存 callId
        final remoteUidsCount = _remoteUids.length;
        
        logger.debug('📞 [onCallEnd] 群组通话检查:');
        logger.debug('📞 [onCallEnd]   - wasGroupCall: $wasGroupCall');
        logger.debug('📞 [onCallEnd]   - groupId: $groupId');
        logger.debug('📞 [onCallEnd]   - currentCallType: $currentCallType');
        logger.debug('📞 [onCallEnd]   - callId: $currentCallId');
        logger.debug('📞 [onCallEnd]   - remoteUidsCount: $remoteUidsCount');
        
        onCallEnded?.call(duration);
        
        // 🔴 判断是否还有其他成员在通话
        // 群组通话结束条件：只剩1个或0个已连接成员（remoteUidsCount <= 1）
        // 群组通话继续条件：还有2个或更多已连接成员（remoteUidsCount > 1）
        if (wasGroupCall && groupId != null && groupId > 0) {
          if (remoteUidsCount > 1) {
            // 还有2个或更多人在通话，群组通话继续
            logger.debug('📞 [onCallEnd] 群组通话仍在继续，还有 $remoteUidsCount 个已连接成员（>1）');
            
            // 🔴 关闭 TUICallKit 内置通话弹窗（让用户可以看到聊天页面的"加入通话"按钮）
            logger.debug('📞 [onCallEnd] 关闭 TUICallKit 内置通话弹窗');
            TUICallKitNavigatorObserver.getInstance().exitCallingPage();
            
            logger.debug('📞 [onCallEnd] 触发 onGroupCallLeftButContinuing 回调');
            onGroupCallLeftButContinuing?.call(groupId, currentCallType ?? CallType.voice, duration, currentCallId);
            
            // 🔴 群组通话仍在继续，保留 _currentCallId 以便用户可以重新加入
            logger.debug('📞 [onCallEnd] 准备调用 _resetCallState(preserveCallId: true)');
            _resetCallState(preserveCallId: true);
          } else {
            // 只剩1个或0个已连接成员，群组通话结束
            // 需要发送通话时长消息给所有群组成员
            final isLastMember = remoteUidsCount == 0;
            logger.debug('📞 [onCallEnd] 群组通话结束：只剩 $remoteUidsCount 个已连接成员（<=1）');
            logger.debug('📞 [onCallEnd] isLastMember: $isLastMember');
            
            // 🔴 触发 onGroupCallHangup 回调，发送通话时长消息给所有群组成员
            logger.debug('📞 [onCallEnd] 触发 onGroupCallHangup 回调，发送通话时长消息');
            onGroupCallHangup?.call(groupId, currentCallType ?? CallType.voice, duration, isLastMember);
            
            logger.debug('📞 [onCallEnd] 准备发送 group_call_ended 信号给服务器');
            _sendGroupCallEndedSignal(groupId, currentCallType);
            logger.debug('📞 [onCallEnd] group_call_ended 信号已发送');
            
            // 🔴 群组通话完全结束，清空 _currentCallId
            logger.debug('📞 [onCallEnd] 准备调用 _resetCallState()');
            _resetCallState();
          }
        } else {
          logger.debug('📞 [onCallEnd] 不是群组通话或 groupId 无效，跳过');
          logger.debug('📞 [onCallEnd] 准备调用 _resetCallState()');
          _resetCallState();
        }
        
        logger.debug('📞 ========== onCallEnd 回调结束 ==========');
      },
      // 🔴 新增：对方拒绝通话回调
      onUserReject: (String userId) {
        logger.debug('📞 对方拒绝了通话: userId=$userId');
        onError?.call('对方拒绝了通话');
        _updateCallState(CallState.ended);
      },
      // 🔴 新增：对方无响应回调
      onUserNoResponse: (String userId) {
        logger.debug('📞 对方无响应: userId=$userId');
        onError?.call('对方无响应');
        _updateCallState(CallState.ended);
      },
      // 🔴 新增：对方忙线回调
      onUserLineBusy: (String userId) {
        logger.debug('📞 对方忙线: userId=$userId');
        onError?.call('对方忙线');
        _updateCallState(CallState.ended);
      },
      // 🔴 新增：通话未接通回调（包括拒绝、超时等情况）
      onCallNotConnected: (String callId, TUICallMediaType mediaType, 
          CallEndReason reason, String userId, CallObserverExtraInfo info) {
        logger.debug('📞 通话未接通: callId=$callId, reason=$reason, userId=$userId');
        logger.debug('📞 当前通话状态: $_callState, 目标用户: $_currentCallUserId');
        logger.debug('📞 mediaType: $mediaType');
        String errorMsg = '通话未接通';
        
        // 🔴 保存目标用户ID，因为后面 _updateCallState 会重置它
        final targetUserId = _currentCallUserId;
        final currentCallType = _callType;
        
        // 🔴 判断本机角色：
        // - 如果 _callState == calling，说明本机是发起方
        // - 如果 _callState != calling（idle 或其他），说明本机是接收方
        final isCaller = _callState == CallState.calling;
        
        switch (reason) {
          case CallEndReason.reject:
            if (isCaller) {
              // 本机是发起方，对方拒绝了通话
              // 不需要发送消息，因为对方（PC端）会发送"对方已拒绝"消息
              errorMsg = '对方拒绝了通话';
              logger.debug('📞 发起方收到拒绝通知，不发送消息（由对方发送）');
            } else {
              // 本机是接收方，本机拒绝了通话
              // 需要发送"对方已拒绝"消息给发起方
              errorMsg = '已拒绝';
              if (targetUserId != null && targetUserId > 0) {
                logger.debug('📞 接收方拒绝通话（reason=reject），触发 onCallRejectedByMe 回调: callerUserId=$targetUserId');
                onCallRejectedByMe?.call(targetUserId, currentCallType);
              }
            }
            break;
          case CallEndReason.noResponse:
            errorMsg = '对方无响应';
            break;
          case CallEndReason.lineBusy:
            errorMsg = '对方忙线';
            break;
          case CallEndReason.canceled:
            if (isCaller) {
              // 本机是发起方，本机取消了通话
              errorMsg = '已取消';
              if (targetUserId != null && targetUserId > 0) {
                logger.debug('📞 发起方取消通话（reason=canceled），触发 onCallCancelled 回调: targetUserId=$targetUserId');
                onCallCancelled?.call(targetUserId, currentCallType, true);
              }
            } else {
              // 本机是接收方，对方取消了通话
              // 不需要发送消息，因为对方会发送
              errorMsg = '对方已取消';
              logger.debug('📞 接收方收到取消通知，不发送消息（由对方发送）');
            }
            break;
          case CallEndReason.hangup:
            errorMsg = '通话已挂断';
            break;
          default:
            // 🔴 unknown 或其他原因
            // 🔴 关键修复：通过 userId 判断是谁触发的未接通
            // 如果 userId == _myUserIdStr（自己的ID），说明是本地操作（拒绝或取消）
            final userIdInt = int.tryParse(userId) ?? 0;
            final isLocalAction = userId == _myUserIdStr || userIdInt == _myUserId;
            
            logger.debug('📞 unknown 原因分析: userId=$userId, _myUserIdStr=$_myUserIdStr, isLocalAction=$isLocalAction, isCaller=$isCaller');
            
            if (isCaller) {
              // 本机是发起方
              // 🔴 检查是否收到了拒绝信令，如果收到了就不发送消息
              if (_receivedRejectSignal) {
                errorMsg = '对方拒绝了通话';
                logger.debug('📞 发起方收到未知原因的未接通通知（reason=$reason），但已收到拒绝信令，不发送消息');
              } else {
                // 🔴 修复：当发起方收到 unknown 原因且没有收到拒绝信令时，很可能是发起方主动取消了通话
                // 因为 TUICallKit 在某些情况下会返回 unknown 而不是 canceled
                // 所以这里也触发 onCallCancelled 回调，发送"已取消"消息
                errorMsg = '已取消';
                if (targetUserId != null && targetUserId > 0) {
                  logger.debug('📞 发起方收到未知原因的未接通通知（reason=$reason），视为取消，触发 onCallCancelled 回调: targetUserId=$targetUserId');
                  onCallCancelled?.call(targetUserId, currentCallType, true);
                }
              }
            } else {
              // 本机是接收方
              // 🔴 关键修复：如果 userId 是自己的ID，说明是本地拒绝（通过 TUICallKit 内置 UI）
              // 或者 _isLocalReject 已经被设置为 true
              if (_isLocalReject || isLocalAction) {
                // 接收方主动拒绝，需要发送"已拒绝"消息
                errorMsg = '已拒绝';
                if (targetUserId != null && targetUserId > 0) {
                  logger.debug('📞 接收方主动拒绝通话（reason=$reason, isLocalAction=$isLocalAction），触发 onCallRejectedByMe 回调: callerUserId=$targetUserId');
                  onCallRejectedByMe?.call(targetUserId, currentCallType);
                } else {
                  logger.debug('📞 接收方主动拒绝通话，但 targetUserId 无效: $targetUserId');
                }
              } else {
                // 可能是对方取消了通话，不发送消息
                errorMsg = '通话未接通';
                logger.debug('📞 接收方收到未知原因的未接通通知（reason=$reason），不发送消息（可能是对方取消）');
              }
            }
        }
        onError?.call(errorMsg);
        _updateCallState(CallState.ended);
      },
      onUserJoin: (String userId) {
        logger.debug('📞 ========== onUserJoin 回调 ==========');
        logger.debug('📞 [onUserJoin] userId: $userId');
        final uid = int.tryParse(userId) ?? 0;
        logger.debug('📞 [onUserJoin] 解析后的 uid: $uid');
        logger.debug('📞 [onUserJoin] 加入前 _remoteUids: $_remoteUids');
        _remoteUids.add(uid);
        logger.debug('📞 [onUserJoin] 加入后 _remoteUids: $_remoteUids');
        logger.debug('📞 [onUserJoin] 当前 _isInGroupCall: $_isInGroupCall');
        logger.debug('📞 [onUserJoin] 当前 _currentGroupId: $_currentGroupId');
        onRemoteUserJoined?.call(uid);
      },
      onUserLeave: (String userId) {
        logger.debug('📞 ========== onUserLeave 回调 ==========');
        logger.debug('📞 [onUserLeave] userId: $userId');
        final uid = int.tryParse(userId) ?? 0;
        logger.debug('📞 [onUserLeave] 解析后的 uid: $uid');
        logger.debug('📞 [onUserLeave] 离开前 _remoteUids: $_remoteUids');
        _remoteUids.remove(uid);
        logger.debug('📞 [onUserLeave] 离开后 _remoteUids: $_remoteUids');
        logger.debug('📞 [onUserLeave] 当前 _isInGroupCall: $_isInGroupCall');
        logger.debug('📞 [onUserLeave] 当前 _currentGroupId: $_currentGroupId');
        logger.debug('📞 [onUserLeave] 剩余远端用户数: ${_remoteUids.length}');
        onRemoteUserLeft?.call(uid);
      },
      onUserVideoAvailable: (String userId, bool isVideoAvailable) {
        logger.debug('📞 用户视频状态: $userId, available=$isVideoAvailable');
        final uid = int.tryParse(userId) ?? 0;
        if (isVideoAvailable) {
          onRemoteVideoReady?.call(uid);
        }
        onRemoteVideoMuted?.call(uid, !isVideoAvailable);
      },
      onError: (int code, String message) {
        logger.debug('📞 TUICallKit 错误: code=$code, message=$message');
        onError?.call('通话错误: $message');
      },
    ));
  }

  /// 处理来电
  void _handleIncomingCall(String callerId, TUICallMediaType mediaType, String? groupId) {
    final callerIdInt = int.tryParse(callerId) ?? 0;
    _currentCallUserId = callerIdInt;
    _currentCallUserIdStr = callerId;
    _callType = mediaType == TUICallMediaType.video ? CallType.video : CallType.voice;
    
    if (groupId != null && groupId.isNotEmpty) {
      _currentGroupId = int.tryParse(groupId);
    }

    _updateCallState(CallState.ringing);
    
    // 触发来电回调
    onIncomingCall?.call(callerIdInt, callerId, _callType);
  }


  /// 设置 WebSocket 监听
  void _setupWebSocketListeners() {
    _wsService.onWebRTCSignal = (data) async {
      logger.debug('📞 收到 WebRTC 信令: ${data['type']}');

      try {
        switch (data['type']) {
          case 'call-request':
          case 'incoming_call':
            // TUICallKit 会自动处理来电，这里仅作为备用
            break;
          case 'incoming_group_call':
            _handleIncomingGroupCallFromServer(data);
            break;
          case 'group_call_member_accepted':
            _handleGroupCallMemberAccepted(data);
            break;
          case 'group_call_member_left':
            _handleGroupCallMemberLeft(data);
            break;
          case 'group_call_ended':
            _handleGroupCallEnded(data);
            break;
          case 'call-rejected':
          case 'call_rejected':
            _handleCallRejected(data);
            break;
          case 'call-cancel':
          case 'call_cancel':
            // 🔴 处理 PC 端取消通话的信令
            _handleCallCancelFromWebSocket(data);
            break;
          case 'call-ended':
          case 'call_ended':
            if (!_isGroupCall()) {
              await endCall(isLocalHangup: false);
            }
            break;
        }
      } catch (e) {
        logger.debug('📞 处理信令失败: $e');
        onError?.call('信令处理失败: $e');
      }
    };
  }

  /// 处理来自 WebSocket 的通话取消信令（PC 端取消通话时发送）
  void _handleCallCancelFromWebSocket(Map<String, dynamic> data) {
    final fromUserId = data['from_user_id'] as int?;
    logger.debug('📞 [Mobile] 收到 WebSocket 取消通话信令: fromUserId=$fromUserId');
    
    // 只有在 ringing 状态（来电响铃中）才处理取消
    if (_callState != CallState.ringing) {
      logger.debug('📞 [Mobile] 当前状态不是 ringing，忽略取消信令: $_callState');
      return;
    }
    
    // 检查是否是当前来电的发起方取消
    if (fromUserId != null && fromUserId == _currentCallUserId) {
      logger.debug('📞 [Mobile] 来电发起方取消了通话，结束来电');
      
      // 触发取消回调（接收方收到取消通知）
      onCallCancelled?.call(fromUserId, _callType, false);
      
      // 更新状态
      _updateCallState(CallState.ended);
      
      // 重置通话状态
      _resetCallState();
    } else {
      logger.debug('📞 [Mobile] 取消信令的发送者与当前来电发起方不匹配，忽略');
    }
  }

  /// 处理来自 WebSocket 的群组来电通知
  /// 🔴 新流程：收到通知后，触发来电回调，用户接听后使用 joinInGroupCall 加入房间
  void _handleIncomingGroupCallFromServer(Map<String, dynamic> data) {
    logger.debug('📞 [Mobile] 收到群组来电通知: $data');
    
    // 🔴 检查是否是 PC 端专用通知，移动端应该忽略
    // 因为移动端会通过 TUICallKit 的 IM 信令收到来电通知
    final forPcOnly = data['for_pc_only'] as bool? ?? false;
    final source = data['source'] as String?;
    if (forPcOnly && source == 'tuicallkit_mobile') {
      logger.debug('📞 [Mobile] 这是 PC 端专用的群组来电通知，移动端忽略（将通过 TUICallKit IM 信令收到通知）');
      return;
    }
    
    final callerId = data['caller_id'] as int? ?? data['from_user_id'] as int?;
    final callerName = data['caller_name'] as String? ?? '未知用户';
    final callTypeStr = data['call_type'] as String? ?? 'voice';
    final groupId = data['group_id'];
    final roomId = data['room_id'] as int?;
    final channelName = data['channel_name'] as String?;  // 🔴 获取频道名称
    final members = data['members'] as List<dynamic>?;
    
    if (callerId == null) {
      logger.debug('📞 [Mobile] 群组来电数据缺少 caller_id');
      return;
    }
    
    // 忽略自己发起的通话
    if (callerId == _myUserId) {
      logger.debug('📞 [Mobile] 忽略自己发起的群组通话');
      return;
    }
    
    // 🔴 检查是否有残留的通话状态需要清理
    // 如果 _callState 不是 idle，但实际上没有进行中的通话，则重置状态
    if (_callState != CallState.idle) {
      logger.debug('📞 [Mobile] 当前状态不是 idle: $_callState');
      logger.debug('📞 [Mobile]   - _currentCallUserId: $_currentCallUserId');
      logger.debug('📞 [Mobile]   - _currentGroupId: $_currentGroupId');
      logger.debug('📞 [Mobile]   - _currentGroupCallRoomId: $_currentGroupCallRoomId');
      
      // 🔴 检查是否是残留状态（没有实际的通话用户或房间）
      // 如果是 ringing 状态但没有有效的通话信息，可能是之前的来电没有正确处理
      if (_callState == CallState.ringing && _currentCallUserId == null && _currentGroupCallRoomId == null) {
        logger.debug('📞 [Mobile] 检测到残留的 ringing 状态，强制重置');
        _resetCallState();
      } else if (_callState == CallState.calling && _currentCallUserId == null && _currentGroupCallRoomId == null) {
        logger.debug('📞 [Mobile] 检测到残留的 calling 状态，强制重置');
        _resetCallState();
      } else {
        // 确实有进行中的通话，忽略新来电
        logger.debug('📞 [Mobile] 当前正在通话，忽略群组来电');
        return;
      }
    }
    
    logger.debug('📞 [Mobile] 群组来电信息:');
    logger.debug('📞 [Mobile]   - callerId: $callerId');
    logger.debug('📞 [Mobile]   - callerName: $callerName');
    logger.debug('📞 [Mobile]   - callType: $callTypeStr');
    logger.debug('📞 [Mobile]   - groupId: $groupId');
    logger.debug('📞 [Mobile]   - roomId: $roomId');
    logger.debug('📞 [Mobile]   - channelName: $channelName');
    logger.debug('📞 [Mobile]   - members: $members');
    
    // 设置通话状态
    _callType = callTypeStr == 'video' ? CallType.video : CallType.voice;
    _currentCallUserId = callerId;
    _currentCallUserIdStr = callerId.toString();
    _currentGroupId = groupId is int ? groupId : int.tryParse(groupId?.toString() ?? '');
    _currentGroupCallRoomId = roomId;
    _currentGroupCallChannelName = channelName;  // 🔴 保存频道名称
    
    // 解析成员列表
    if (members != null) {
      _currentGroupCallUserIds = [];
      _currentGroupCallDisplayNames = [];
      for (final member in members) {
        final memberId = member['user_id'] as int?;
        final memberName = member['display_name'] as String? ?? '';
        if (memberId != null && memberId != _myUserId) {
          _currentGroupCallUserIds!.add(memberId);
          _currentGroupCallDisplayNames!.add(memberName);
        }
      }
    }
    
    _updateCallState(CallState.ringing);
    
    // 构建成员信息列表用于回调
    final membersList = <Map<String, dynamic>>[];
    if (members != null) {
      for (final member in members) {
        membersList.add({
          'user_id': member['user_id'],
          'display_name': member['display_name'] ?? '',
        });
      }
    }
    
    // 触发群组来电回调
    onIncomingGroupCall?.call(
      callerId,
      callerName,
      _callType,
      membersList,
      _currentGroupId,
    );
    
    logger.debug('📞 [Mobile] 群组来电已触发回调，等待用户响应');
  }

  void _handleGroupCallMemberAccepted(Map<String, dynamic> data) {
    final userId = data['user_id'] as int?;
    final displayName = data['display_name'] as String?;
    if (userId != null) {
      _connectedMemberIds ??= {};
      _connectedMemberIds!.add(userId);
      onGroupCallMemberStatusChanged?.call(userId, 'accepted', displayName);
    }
  }

  void _handleGroupCallMemberLeft(Map<String, dynamic> data) {
    final userId = data['user_id'] as int?;
    final displayName = data['display_name'] as String?;
    if (userId != null) {
      _connectedMemberIds?.remove(userId);
      onGroupCallMemberStatusChanged?.call(userId, 'left', displayName);
    }
  }

  void _handleGroupCallEnded(Map<String, dynamic> data) {
    logger.debug('📞 群组通话已结束');
    _updateCallState(CallState.ended);
  }

  void _handleCallRejected(Map<String, dynamic> data) {
    logger.debug('📞 通话被拒绝');
    logger.debug('📞 [Mobile] _handleCallRejected 数据: $data');
    logger.debug('📞 [Mobile] 当前状态: $_callState, 目标用户: $_currentCallUserId');
    
    // 🔴 获取拒绝方的用户ID
    final fromUserId = data['from_user_id'] as int?;
    logger.debug('📞 [Mobile] 拒绝方用户ID: $fromUserId');
    
    // 🔴 只有在 calling 状态（发起方等待对方接听）才处理拒绝信令
    if (_callState != CallState.calling) {
      logger.debug('📞 [Mobile] 当前状态不是 calling，忽略拒绝信令: $_callState');
      return;
    }
    
    // 🔴 检查是否是当前通话的目标用户拒绝
    if (fromUserId != null && fromUserId == _currentCallUserId) {
      logger.debug('📞 [Mobile] 对方拒绝了通话，关闭呼叫界面');
      
      // 🔴 标记收到了拒绝信令，避免在 onCallNotConnected 的 default 分支发送消息
      _receivedRejectSignal = true;
      
      // 🔴 调用 TUICallEngine.hangup() 关闭呼叫界面
      try {
        logger.debug('📞 [Mobile] 尝试关闭 TUICallKit 呼叫界面...');
        TUICallEngine.instance.hangup();
        logger.debug('📞 [Mobile] TUICallKit 呼叫界面已关闭');
      } catch (e) {
        logger.debug('📞 [Mobile] 关闭 TUICallKit 呼叫界面失败（可能已经关闭）: $e');
      }
      
      // 🔴 触发错误回调，显示"对方拒绝了通话"
      onError?.call('对方拒绝了通话');
      
      // 更新状态
      _updateCallState(CallState.ended);
    } else {
      logger.debug('📞 [Mobile] 拒绝信令的发送者与当前通话目标不匹配，忽略');
      logger.debug('📞 [Mobile]   - fromUserId: $fromUserId');
      logger.debug('📞 [Mobile]   - _currentCallUserId: $_currentCallUserId');
    }
  }

  /// 设置 IM 信令监听（用于接收 PC 端的通话请求）
  void _setupIMSignalingListener() {
    final im = TencentImSDKPlugin.v2TIMManager;
    im.getSignalingManager().addSignalingListener(
      listener: V2TimSignalingListener(
        // 收到邀请（来自 PC 端的通话请求）
        onReceiveNewInvitation: (inviteID, inviter, groupID, inviteeList, data) {
          logger.debug('📞 [Mobile] 收到 IM 信令邀请: inviteID=$inviteID, inviter=$inviter, data=$data');
          _handleIMInvitation(inviteID, inviter, groupID, inviteeList, data);
        },
        // 邀请被接受
        onInviteeAccepted: (inviteID, invitee, data) {
          logger.debug('📞 [Mobile] IM 信令邀请被接受: inviteID=$inviteID, invitee=$invitee');
        },
        // 邀请被拒绝
        onInviteeRejected: (inviteID, invitee, data) {
          logger.debug('📞 [Mobile] IM 信令邀请被拒绝: inviteID=$inviteID, invitee=$invitee');
          logger.debug('📞 [Mobile] 当前状态: $_callState, 目标用户: $_currentCallUserId');
          
          // 🔴 当发起方收到拒绝通知时，关闭呼叫界面
          // 注意：不在这里更新状态，让 onCallNotConnected 来处理
          // 这样可以避免状态被提前重置，导致 onCallNotConnected 误判
          if (_callState == CallState.calling) {
            final inviteeIdInt = int.tryParse(invitee) ?? 0;
            logger.debug('📞 [Mobile] 对方拒绝了通话，inviteeId=$inviteeIdInt');
            
            // 🔴 标记收到了拒绝信令，避免在 onCallNotConnected 的 default 分支发送消息
            _receivedRejectSignal = true;
            
            // 🔴 调用 TUICallEngine.hangup() 关闭呼叫界面
            try {
              logger.debug('📞 [Mobile] 尝试关闭 TUICallKit 呼叫界面...');
              TUICallEngine.instance.hangup();
              logger.debug('📞 [Mobile] TUICallKit 呼叫界面已关闭');
            } catch (e) {
              logger.debug('📞 [Mobile] 关闭 TUICallKit 呼叫界面失败（可能已经关闭）: $e');
            }
            
            // 🔴 不在这里触发 onError 和更新状态，让 onCallNotConnected 来处理
            // 这样可以避免重复显示错误消息
          }
        },
        // 邀请被取消
        onInvitationCancelled: (inviteID, inviter, data) async {
          logger.debug('📞 [Mobile] IM 信令邀请被取消: inviteID=$inviteID, inviter=$inviter');
          logger.debug('📞 [Mobile] 当前 _callState: $_callState');
          
          // 🔴 修复：无论 _callState 是什么状态，都触发取消回调
          // 因为当 TUICallKit 原生层处理 av_call 信令时，我们的 _callState 可能仍然是 idle
          final inviterIdInt = int.tryParse(inviter) ?? 0;
          if (inviterIdInt > 0 && inviterIdInt != _myUserId) {
            logger.debug('📞 [Mobile] 接收方收到 IM 信令取消通知，触发 onCallCancelled 回调: inviterId=$inviterIdInt');
            onCallCancelled?.call(inviterIdInt, _callType, false);
          }
          
          // 🔴 修复：调用 TUICallEngine.hangup() 关闭 TUICallKit 的来电界面
          // 因为 TUICallKit 原生层会自动显示来电界面，我们需要主动关闭它
          try {
            logger.debug('📞 [Mobile] 尝试关闭 TUICallKit 来电界面...');
            await TUICallEngine.instance.hangup();
            logger.debug('📞 [Mobile] TUICallKit 来电界面已关闭');
          } catch (e) {
            logger.debug('📞 [Mobile] 关闭 TUICallKit 来电界面失败（可能已经关闭）: $e');
          }
          
          if (_callState == CallState.ringing) {
            onError?.call('对方取消了通话');
            _updateCallState(CallState.ended);
          }
        },
        // 邀请超时
        onInvitationTimeout: (inviteID, inviteeList) {
          logger.debug('📞 [Mobile] IM 信令邀请超时: inviteID=$inviteID');
        },
      ),
    );
    logger.debug('📞 [Mobile] IM 信令监听已设置');
  }

  /// 处理 IM 信令邀请（来自 PC 端的通话请求）
  String? _currentIMInviteId;
  int? _pcCallRoomId;  // PC 端通话的房间号
  DateTime? _lastCallEndTime;  // 上次通话结束时间
  
  void _handleIMInvitation(String inviteID, String inviter, String? groupID, List<String>? inviteeList, String? data) {
    logger.debug('📞 [Mobile] ========== _handleIMInvitation 被调用 ==========');
    logger.debug('📞 [Mobile] 当前状态: $_callState');
    logger.debug('📞 [Mobile] inviteID: $inviteID');
    logger.debug('📞 [Mobile] inviter: $inviter');
    logger.debug('📞 [Mobile] _currentIMInviteId: $_currentIMInviteId');
    logger.debug('📞 [Mobile] _pcCallRoomId: $_pcCallRoomId');
    logger.debug('📞 [Mobile] _lastCallEndTime: $_lastCallEndTime');
    
    // 检查是否是同一个邀请（避免重复处理）
    if (_currentIMInviteId == inviteID) {
      logger.debug('📞 [Mobile] 重复的邀请ID，忽略');
      return;
    }
    
    // 如果当前正在通话，忽略
    if (_callState != CallState.idle) {
      logger.debug('📞 [Mobile] 当前正在通话（状态: $_callState），拒绝 IM 信令邀请');
      // 发送忙线信号
      _rejectIMInvitation(inviteID, 'busy');
      return;
    }
    
    // 检查是否刚刚结束通话（防止状态竞争）
    if (_lastCallEndTime != null) {
      final timeSinceLastCall = DateTime.now().difference(_lastCallEndTime!).inMilliseconds;
      logger.debug('📞 [Mobile] 距离上次通话结束: ${timeSinceLastCall}ms');
      if (timeSinceLastCall < 500) {
        logger.debug('📞 [Mobile] 距离上次通话结束时间太短，延迟处理');
        // 延迟处理，等待状态完全重置
        Future.delayed(const Duration(milliseconds: 500), () {
          _handleIMInvitation(inviteID, inviter, groupID, inviteeList, data);
        });
        return;
      }
    }
    
    try {
      // 解析信令数据
      final signalData = data != null ? jsonDecode(data) : {};
      logger.debug('📞 [Mobile] 解析信令数据: $signalData');
      
      final businessID = signalData['businessID'];
      
      // 🔴 处理 av_call 信令
      // TUICallKit 原生层应该会自动处理，但如果没有触发 onCallReceived，
      // 说明原生层没有正确处理，我们需要手动处理
      if (businessID == 'av_call') {
        logger.debug('📞 [Mobile] 收到 av_call 信令');
        
        // 检查是否已经被 TUICallKit 原生层处理（通过 onCallReceived 回调）
        // 如果 _callState 已经是 ringing，说明原生层已经处理了
        if (_callState == CallState.ringing) {
          logger.debug('📞 [Mobile] av_call 信令已被 TUICallKit 原生层处理，跳过');
          return;
        }
        
        // 🔴 TUICallKit 原生层没有处理，我们手动处理
        // 这种情况可能发生在 PC 端发送的信令格式与 TUICallKit 期望的格式不完全一致时
        logger.debug('📞 [Mobile] TUICallKit 原生层未处理 av_call 信令，手动处理');
        
        final callTypeValue = signalData['call_type'];  // 1=语音, 2=视频
        final roomId = signalData['room_id'];
        final dataObj = signalData['data'];
        final callerName = dataObj?['inviter'] ?? inviter;
        
        logger.debug('📞 [Mobile] av_call 信令详情: callType=$callTypeValue, roomId=$roomId, inviter=$callerName');
        
        _currentIMInviteId = inviteID;
        
        // 设置通话状态
        final callerIdInt = int.tryParse(inviter) ?? 0;
        _currentCallUserId = callerIdInt;
        _currentCallUserIdStr = inviter;
        _callType = callTypeValue == 2 ? CallType.video : CallType.voice;
        
        // 保存房间号
        _pcCallRoomId = roomId is int ? roomId : int.tryParse(roomId.toString()) ?? 0;
        
        // 更新状态为 ringing
        _updateCallState(CallState.ringing);
        
        // 触发来电回调
        onIncomingCall?.call(callerIdInt, callerName.toString(), _callType);
        
        return;
      }
      
      if (businessID != 'youdu_call') {
        logger.debug('📞 [Mobile] 非 youdu_call 信令，忽略: businessID=$businessID');
        return;
      }
      
      // 🔴 以下是旧版 youdu_call 信令的处理（向后兼容）
      final callType = signalData['call_type'];  // 0=语音, 1=视频
      final roomId = signalData['room_id'];
      final callerName = signalData['caller_name'] ?? inviter;
      final callerAvatar = signalData['caller_avatar'] ?? '';
      
      logger.debug('📞 [Mobile] 收到旧版 PC 端通话请求 (youdu_call): callType=$callType, roomId=$roomId, callerName=$callerName');
      
      _currentIMInviteId = inviteID;
      
      // 设置通话状态
      final callerIdInt = int.tryParse(inviter) ?? 0;
      _currentCallUserId = callerIdInt;
      _currentCallUserIdStr = inviter;
      _callType = callType == 1 ? CallType.video : CallType.voice;
      
      // 使用 TUICallKit 的 joinInGroupCall 或直接进入房间
      // 由于 PC 端已经创建了 TRTC 房间，移动端需要加入同一个房间
      _joinPCCall(roomId, _callType == CallType.video ? TUICallMediaType.video : TUICallMediaType.audio, inviter, callerName);
      
    } catch (e) {
      logger.debug('📞 [Mobile] 解析 IM 信令数据失败: $e');
    }
  }

  /// 加入 PC 端发起的通话
  Future<void> _joinPCCall(dynamic roomId, TUICallMediaType mediaType, String callerId, String callerName) async {
    try {
      final roomIdInt = roomId is int ? roomId : int.tryParse(roomId.toString()) ?? 0;
      
      logger.debug('📞 [Mobile] 尝试加入 PC 端通话: roomId=$roomIdInt, mediaType=$mediaType');
      
      // 保存房间号，接听时使用
      _pcCallRoomId = roomIdInt;
      
      // 🔴 PC 端来电使用自定义信令（youdu_call），TUICallKit 内置 UI 无法自动处理
      // 需要先更新状态为 ringing，然后触发来电回调
      // mobile_home_page 会根据 callState == ringing 判断这是 PC 端来电，显示自定义弹窗
      _updateCallState(CallState.ringing);
      
      // 🔴 触发来电回调，mobile_home_page 会显示自定义来电弹窗
      onIncomingCall?.call(int.tryParse(callerId) ?? 0, callerName, _callType);
      
      // 注意：这里不自动接听，等用户点击接听按钮
      // 接听时会调用 acceptCall()，会处理 PC 端通话
      
    } catch (e) {
      logger.debug('📞 [Mobile] 加入 PC 端通话失败: $e');
      onError?.call('加入通话失败: $e');
    }
  }

  /// 拒绝 IM 信令邀请
  Future<void> _rejectIMInvitation(String inviteID, String reason) async {
    try {
      final im = TencentImSDKPlugin.v2TIMManager;
      await im.getSignalingManager().reject(
        inviteID: inviteID,
        data: jsonEncode({'reason': reason}),
      );
    } catch (e) {
      logger.debug('📞 [Mobile] 拒绝 IM 信令失败: $e');
    }
  }

  /// 接受 IM 信令邀请
  Future<void> _acceptIMInvitation() async {
    if (_currentIMInviteId == null) return;
    
    try {
      final im = TencentImSDKPlugin.v2TIMManager;
      await im.getSignalingManager().accept(
        inviteID: _currentIMInviteId!,
        data: jsonEncode({'accepted': true}),
      );
      logger.debug('📞 [Mobile] 已接受 IM 信令邀请');
    } catch (e) {
      logger.debug('📞 [Mobile] 接受 IM 信令失败: $e');
    }
  }

  bool _isGroupCall() {
    return _currentGroupId != null || 
           (_currentGroupCallUserIds != null && _currentGroupCallUserIds!.isNotEmpty);
  }

  void _updateCallState(CallState state) {
    _callState = state;
    onCallStateChanged?.call(state);
    
    if (state == CallState.ended) {
      _resetCallState();
    }
  }

  /// 强制重置通话状态（公共方法，用于外部调用）
  void forceResetCallState() {
    logger.debug('📞 [Mobile] forceResetCallState 被调用');
    _resetCallState();
  }

  /// 🔴 公共 getter：获取当前通话的 callId（用于群组通话重新加入）
  String? get currentCallId => _currentCallId;

  /// 重置通话状态
  /// [preserveCallId] 是否保留 _currentCallId（群组通话仍在继续时使用）
  void _resetCallState({bool preserveCallId = false}) {
    logger.debug('📞 [Mobile] ========== _resetCallState 被调用 ==========');
    logger.debug('📞 [Mobile] 重置前状态: $_callState');
    logger.debug('📞 [Mobile] 重置前 _currentIMInviteId: $_currentIMInviteId');
    logger.debug('📞 [Mobile] 重置前 _pcCallRoomId: $_pcCallRoomId');
    logger.debug('📞 [Mobile] 重置前 _currentCallId: $_currentCallId');
    logger.debug('📞 [Mobile] preserveCallId: $preserveCallId');
    
    _lastGroupId = _currentGroupId;
    _lastCallType = _callType;
    _lastCallUserId = _currentCallUserId;
    
    _callState = CallState.idle;
    _currentCallUserId = null;
    _currentCallUserIdStr = null;
    _currentGroupId = null;
    _callStartTime = null;
    // 🔴 根据参数决定是否清空 callId
    if (!preserveCallId) {
      _currentCallId = null;
      logger.debug('📞 [Mobile] 已清空 _currentCallId');
    } else {
      logger.debug('📞 [Mobile] 保留 _currentCallId: $_currentCallId');
    }
    _remoteUids.clear();
    _connectedMemberIds?.clear();
    _isEndingCall = false;
    _isLocalHangup = false;
    _receivedRejectSignal = false;  // 🔴 重置拒绝信令标志
    _isLocalReject = false;  // 🔴 重置本地拒绝标志
    _isCallMinimized = false;
    _currentIMInviteId = null;
    _pcCallRoomId = null;
    _lastCallEndTime = DateTime.now();  // 记录通话结束时间
    _isGroupCallInitiator = false;  // 🔴 重置群组通话发起者标记
    _isInGroupCall = false;  // 🔴 重置群组通话标志
    _usedTRTCSDKDirectly = false;  // 🔴 重置 TRTC SDK 直接进入房间标志
    _currentGroupCallRoomId = null;  // 🔴 重置群组通话房间号
    _currentGroupCallChannelName = null;  // 🔴 重置群组通话频道名称
    _currentGroupCallUserIds = null;  // 🔴 重置群组通话成员
    _currentGroupCallDisplayNames = null;  // 🔴 重置群组通话成员名称
    
    logger.debug('📞 [Mobile] 重置后状态: $_callState');
    logger.debug('📞 [Mobile] 重置后 _lastCallEndTime: $_lastCallEndTime');
  }

  /// 发起语音通话
  Future<void> startVoiceCall(int targetUserId, String targetDisplayName) async {
    await _startCall(targetUserId, targetDisplayName, CallType.voice);
  }

  /// 发起视频通话
  Future<void> startVideoCall(int targetUserId, String targetDisplayName) async {
    await _startCall(targetUserId, targetDisplayName, CallType.video);
  }

  /// 发起通话
  Future<void> _startCall(int targetUserId, String targetDisplayName, CallType callType) async {
    logger.debug('========== 📞 开始发起通话 ==========');
    logger.debug('📞 目标用户: $targetUserId ($targetDisplayName)');
    logger.debug('📞 通话类型: ${callType == CallType.voice ? '语音' : '视频'}');
    logger.debug('📞 使用的 SDKAppID: ${TencentConfig.sdkAppId}');
    logger.debug('📞 当前 _callState: $_callState');

    _isLocalHangup = false;

    if (targetUserId == _myUserId) {
      logger.debug('📞 不能给自己打电话');
      onError?.call('不能给自己打电话');
      return;
    }

    // 🔴 如果状态不是 idle，尝试强制重置
    if (_callState != CallState.idle) {
      logger.debug('📞 当前状态不是 idle，尝试强制重置');
      // 检查是否真的在通话中（通过 TUICallKit 状态）
      // 如果不是，则强制重置状态
      _resetCallState();
      logger.debug('📞 强制重置后状态: $_callState');
      
      if (_callState != CallState.idle) {
        onError?.call('当前正在通话');
        return;
      }
    }

    try {
      _currentCallUserId = targetUserId;
      _currentCallUserIdStr = targetUserId.toString();
      _callType = callType;
      _updateCallState(CallState.calling);

      final mediaType = callType == CallType.video 
          ? TUICallMediaType.video 
          : TUICallMediaType.audio;

      // 🔴 使用 TUICallKit.call() 显示内置 UI
      logger.debug('📞 调用 TUICallKit.instance.call()...');
      final params = TUICallParams();
      await TUICallKit.instance.call(
        _currentCallUserIdStr!,
        mediaType,
        params,
      );
      
      logger.debug('📞 ✅ 语音通话已发起（使用 TUICallKit 内置 UI）');
    } catch (e) {
      logger.debug('📞 ❌ 发起通话失败: $e');
      onError?.call('发起通话失败: $e');
      _resetCallState();
    }
  }
  /// 生成群组通话房间号
  /// 使用时间戳 + 发起者ID 生成唯一房间号
  int _generateGroupCallRoomId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final userId = _myUserId ?? 0;
    // 确保房间号在有效范围内 (1 ~ 2147483647)
    return ((timestamp % 1000000) * 1000 + (userId % 1000)) % 2147483647 + 1;
  }

  /// 发起群组通话
  /// 🔴 使用 TUICallKit 的 calls 接口发起群组通话
  /// 这样会显示 TUICallKit 内置的群组通话 UI（包含最小化按钮）
  Future<void> startGroupCall(
    List<int> userIds,
    List<String> displayNames,
    CallType callType, {
    int? groupId,
  }) async {
    logger.debug('========== 📞 开始发起群组通话（TUICallKit calls 接口）==========');
    logger.debug('📞 目标用户: $userIds');
    logger.debug('📞 通话类型: ${callType == CallType.voice ? '语音' : '视频'}');
    logger.debug('📞 群组ID: $groupId');

    _isLocalHangup = false;
    _isEndingCall = false;
    _receivedRejectSignal = false;
    _isLocalReject = false;

    if (_callState != CallState.idle) {
      onError?.call('当前正在通话');
      return;
    }

    try {
      _currentGroupCallUserIds = userIds;
      _currentGroupCallDisplayNames = displayNames;
      _currentGroupId = groupId;
      _callType = callType;
      _isInGroupCall = true; // 🔴 关键修复：设置群组通话标志
      
      logger.debug('📞 [startGroupCall] 已设置 _currentGroupId: $_currentGroupId');
      logger.debug('📞 [startGroupCall] 已设置 _callType: $_callType');
      logger.debug('📞 [startGroupCall] 已设置 _isInGroupCall: $_isInGroupCall');
      
      // 🔴 使用 TUICallKit 的 calls 接口发起多人通话
      // 这会自动显示 TUICallKit 内置的群组通话 UI
      final userIdStrList = userIds.map((id) => id.toString()).toList();
      final mediaType = callType == CallType.video 
          ? TUICallMediaType.video 
          : TUICallMediaType.audio;
      
      // 🔴 关键修复：传递 chatGroupId 和 roomId 参数
      // chatGroupId: 这样被叫方可以在 onCallReceived 中获取到 groupId
      // roomId: 使用 groupId 作为 roomId，这样用户可以使用 joinInGroupCall 重新加入通话
      final params = TUICallParams();
      if (groupId != null) {
        params.chatGroupId = groupId.toString();
        params.roomId = TUIRoomId.intRoomId(intRoomId: groupId);
        logger.debug('📞 [startGroupCall] 设置 TUICallParams.chatGroupId: ${params.chatGroupId}');
        logger.debug('📞 [startGroupCall] 设置 TUICallParams.roomId: $groupId');
      }
      
      logger.debug('📞 调用 TUICallKit.instance.calls: userIds=$userIdStrList, mediaType=$mediaType, chatGroupId=${params.chatGroupId}');
      
      final result = await TUICallKit.instance.calls(userIdStrList, mediaType, params);
      
      if (result.code.isNotEmpty) {
        logger.debug('📞 发起群组通话失败: ${result.message}');
        onError?.call('发起通话失败: ${result.message}');
        _resetCallState();
        return;
      }
      
      logger.debug('📞 ✅ TUICallKit.instance.calls 调用成功');
      
      // 🔴 调用服务器 API 发送"XX发起了群组语音通话"消息和"加入通话"按钮
      // 因为 TUICallKit 内置 UI 发起通话时不会经过服务器 API，所以需要单独发送消息
      if (groupId != null) {
        _sendGroupCallMessageToServer(groupId, callType);
      }
      
      // 🔴 同时通过 WebSocket 通知 PC 端（PC 端不使用 TUICallKit）
      // 生成一个房间号用于 PC 端加入
      _currentGroupCallRoomId = _generateGroupCallRoomId();
      await _notifyAllParticipantsGroupCall(userIds, displayNames, callType, groupId, _currentGroupCallRoomId!);
      
    } catch (e) {
      logger.debug('📞 发起群组通话失败: $e');
      onError?.call('发起群组通话失败: $e');
      _resetCallState();
    }
  }

  /// 🔴 调用服务器 API 发送群组通话发起消息
  /// 发送"XX发起了群组语音通话"消息和"加入通话"按钮到群组
  Future<void> _sendGroupCallMessageToServer(int groupId, CallType callType) async {
    try {
      final token = await Storage.getToken();
      if (token == null) {
        logger.debug('⚠️ [sendGroupCallMessage] token 为空，无法发送消息');
        return;
      }
      
      final callTypeStr = callType == CallType.video ? 'video' : 'voice';
      logger.debug('📞 [sendGroupCallMessage] 调用服务器 API 发送群组通话消息: groupId=$groupId, callType=$callTypeStr');
      
      final response = await ApiService.sendGroupCallMessage(
        token: token,
        groupId: groupId,
        callType: callTypeStr,
      );
      
      logger.debug('📞 [sendGroupCallMessage] 服务器响应: $response');
    } catch (e) {
      logger.debug('⚠️ [sendGroupCallMessage] 发送群组通话消息失败: $e');
      // 不抛出异常，因为这不是关键操作
    }
  }

  /// 通过 WebSocket 通知所有参与者群组通话
  /// 消息中包含 room_id，PC 端和移动端都可以使用这个 room_id 加入 TRTC 房间
  /// 🔴 注意：这个通知主要是给 PC 端的，移动端会通过 TUICallKit 的 IM 信令收到来电通知
  Future<void> _notifyAllParticipantsGroupCall(
    List<int> userIds, 
    List<String> displayNames, 
    CallType callType, 
    int? groupId,
    int roomId,
  ) async {
    try {
      // 获取当前用户昵称
      final callerName = await Storage.getFullName() ?? _myUserIdStr ?? '';
      
      // 构建成员列表（包含发起人自己）
      final members = <Map<String, dynamic>>[];
      
      // 🔴 首先添加发起人自己
      members.add({
        'user_id': _myUserId,
        'display_name': callerName,
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
      // 🔴 标记为 PC 端专用通知，移动端应该忽略（因为移动端会通过 TUICallKit IM 信令收到通知）
      for (final userId in userIds) {
        _wsService.sendWebRTCSignal({
          'type': 'incoming_group_call',
          'caller_id': _myUserId,
          'caller_name': callerName,
          'call_type': callType == CallType.video ? 'video' : 'voice',
          'group_id': groupId,
          'room_id': roomId,  // 🔴 关键：包含 TRTC 房间号
          'members': members,
          'to_user_id': userId,
          'from_user_id': _myUserId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'source': 'tuicallkit_mobile',
          'for_pc_only': true,  // 🔴 标记为 PC 端专用，移动端应该忽略
        });
        logger.debug('📞 已发送群组通话通知给用户 $userId (PC端专用), roomId=$roomId');
      }
      
      logger.debug('📞 ✅ 已通知所有参与者群组通话 (PC端专用): userIds=$userIds, roomId=$roomId');
    } catch (e) {
      logger.debug('⚠️ 发送群组通话通知失败: $e');
    }
  }

  /// 通话开始后，通知 PC 端房间信息
  /// 这样 PC 端可以加入同一个 TRTC 房间
  void _notifyPCCallStarted(String callId, TUICallMediaType callMediaType) {
    try {
      // 只有群组通话才需要通知 PC 端
      if (_currentGroupCallUserIds == null || _currentGroupCallUserIds!.isEmpty) {
        return;
      }
      
      logger.debug('📞 通话已开始，通知 PC 端可以加入: callId=$callId');
      
      // 向所有被叫用户发送通话开始通知
      for (final userId in _currentGroupCallUserIds!) {
        _wsService.sendWebRTCSignal({
          'type': 'group_call_started',
          'call_id': callId,
          'caller_id': _myUserId,
          'call_type': callMediaType == TUICallMediaType.video ? 'video' : 'voice',
          'group_id': _currentGroupId,
          'to_user_id': userId,
          'from_user_id': _myUserId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          // 🔴 PC 端收到此消息后，可以使用 joinInGroupCall 加入通话
          'source': 'tuicallkit_mobile',
        });
      }
      
      logger.debug('📞 已通知 PC 端通话已开始: callId=$callId');
    } catch (e) {
      logger.debug('⚠️ 通知 PC 端通话开始失败: $e');
    }
  }

  /// 发送群组通话结束信号给服务器
  /// 服务器收到后会将"加入通话"按钮消息转换为普通系统消息
  void _sendGroupCallEndedSignal(int groupId, CallType? callType) {
    try {
      logger.debug('📞 ========== _sendGroupCallEndedSignal 开始 ==========');
      logger.debug('📞 [_sendGroupCallEndedSignal] groupId: $groupId');
      logger.debug('📞 [_sendGroupCallEndedSignal] callType: $callType');
      logger.debug('📞 [_sendGroupCallEndedSignal] _myUserId: $_myUserId');
      
      final signal = {
        'type': 'group_call_ended',
        'group_id': groupId,
        'call_type': callType == CallType.video ? 'video' : 'voice',
        'to_user_id': _myUserId, // 发给自己，服务器会处理
        'from_user_id': _myUserId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'source': 'tuicallkit_mobile',
      };
      
      logger.debug('📞 [_sendGroupCallEndedSignal] 发送的信号: $signal');
      
      // 向服务器发送群组通话结束信号
      // 使用 to_user_id = 自己的ID，这样服务器会处理这个消息
      _wsService.sendWebRTCSignal(signal);
      
      logger.debug('📞 [_sendGroupCallEndedSignal] 信号已发送');
      logger.debug('📞 ========== _sendGroupCallEndedSignal 结束 ==========');
    } catch (e) {
      logger.debug('⚠️ [_sendGroupCallEndedSignal] 发送群组通话结束信号失败: $e');
    }
  }

  /// 🔴 使用 TUICallKit 内置 UI 加入群组通话
  /// 用于用户点击"加入语音通话"按钮时，使用 TUICallKit 的 joinInGroupCall 方法加入通话
  /// 这会自动显示 TUICallKit 内置的通话弹窗
  /// 
  /// @param callId 通话ID（从 onCallBegin 回调中获取，或从服务器获取）
  /// @param groupId 群组ID
  /// @param callType 通话类型
  Future<bool> joinGroupCallWithTUICallKit(String callId, int groupId, CallType callType) async {
    logger.debug('========== 📞 使用 TUICallKit 加入群组通话 ==========');
    logger.debug('📞 callId: $callId');
    logger.debug('📞 groupId: $groupId');
    logger.debug('📞 callType: ${callType == CallType.voice ? '语音' : '视频'}');

    if (groupId <= 0) {
      logger.debug('📞 groupId 无效，无法加入通话');
      onError?.call('无法加入通话：群组ID无效');
      return false;
    }

    try {
      _isLocalHangup = false;
      _isEndingCall = false;
      _receivedRejectSignal = false;
      _isLocalReject = false;
      _currentGroupId = groupId;
      _callType = callType;
      _isInGroupCall = true;
      _currentCallId = callId;

      final mediaType = callType == CallType.video 
          ? TUICallMediaType.video 
          : TUICallMediaType.audio;

      // 🔴 优先尝试使用 join(callId) 方法
      // 如果失败（call info not exist），则回退到 joinInGroupCall
      if (callId.isNotEmpty) {
        logger.debug('📞 尝试使用 TUICallKit.instance.join($callId)');
        try {
          await TUICallKit.instance.join(callId);
          logger.debug('📞 ✅ 已通过 TUICallKit.join 加入群组通话');
          _callStartTime = DateTime.now();
          _updateCallState(CallState.connected);
          return true;
        } catch (e) {
          logger.debug('📞 TUICallKit.join 失败: $e，尝试使用 joinInGroupCall');
        }
      }

      // 🔴 回退方案：使用 joinInGroupCall 方法
      // 使用 groupId 作为 roomId（与发起通话时保持一致）
      logger.debug('📞 使用 TUICallKit.instance.joinInGroupCall');
      logger.debug('📞 roomId: $groupId, groupId: $groupId, mediaType: $mediaType');
      
      // ignore: deprecated_member_use
      await TUICallKit.instance.joinInGroupCall(
        TUIRoomId.intRoomId(intRoomId: groupId),
        groupId.toString(),
        mediaType,
      );
      
      logger.debug('📞 ✅ 已通过 TUICallKit.joinInGroupCall 加入群组通话');
      _callStartTime = DateTime.now();
      _updateCallState(CallState.connected);
      
      return true;
    } catch (e) {
      logger.debug('📞 使用 TUICallKit 加入群组通话失败: $e');
      onError?.call('加入群组通话失败: $e');
      _resetCallState();
      return false;
    }
  }

  /// 加入已存在的群组通话
  /// 用于用户点击"加入语音通话"按钮时，直接进入已存在的通话房间
  /// 🔴 注意：这里使用 TRTC SDK 直接进入房间，而不是 TUICallKit 的 joinInGroupCall
  /// 因为 joinInGroupCall 需要 IM 群组 ID，而我们的场景是加入已存在的 TRTC 房间
  Future<void> joinGroupCall(
    List<int> userIds,
    List<String> displayNames,
    CallType callType, {
    int? groupId,
  }) async {
    logger.debug('========== 📞 加入已存在的群组通话 ==========');
    logger.debug('📞 目标用户: $userIds');
    logger.debug('📞 通话类型: ${callType == CallType.voice ? '语音' : '视频'}');
    logger.debug('📞 groupId: $groupId');

    _isLocalHangup = false;
    _isEndingCall = false;
    _receivedRejectSignal = false;
    _isLocalReject = false;

    if (groupId == null || groupId <= 0) {
      logger.debug('📞 groupId 无效，无法加入通话');
      onError?.call('无法加入通话：群组ID无效');
      return;
    }

    try {
      _currentGroupCallUserIds = userIds;
      _currentGroupCallDisplayNames = displayNames;
      _currentGroupId = groupId;
      _callType = callType;
      _currentGroupCallRoomId = groupId;  // 使用 groupId 作为 roomId
      
      final isVideo = callType == CallType.video;
      
      logger.debug('📞 使用 TRTC SDK 直接进入房间: roomId=$groupId, isVideo=$isVideo');
      
      // 直接使用 TRTC SDK 进入房间
      await _enterTRTCRoom(groupId, isVideo);
      
      logger.debug('📞 ✅ 已加入群组通话房间');
      _callStartTime = DateTime.now();
      _updateCallState(CallState.connected);
      
      // 通知其他参与者我已加入
      _notifyGroupCallAccepted();
      
    } catch (e) {
      logger.debug('📞 加入群组通话失败: $e');
      onError?.call('加入群组通话失败: $e');
      _resetCallState();
    }
  }


  /// 接听来电
  Future<void> acceptCall() async {
    // 🔴 修复：放宽状态检查，允许在 idle 或 ringing 状态下接听
    // 因为来电可能通过不同渠道（TUICallObserver、WebSocket、原生服务）到达
    // 状态可能还没有更新到 ringing
    if (_callState != CallState.ringing && _callState != CallState.idle) {
      logger.debug('📞 当前状态不允许接听: $_callState');
      return;
    }

    _isLocalHangup = false;

    try {
      logger.debug('📞 接听来电, 当前状态: $_callState');
      
      // 🔴 如果是群组通话（通过 WebSocket 收到的），使用 joinInGroupCall 加入房间
      if (_currentGroupCallRoomId != null && _currentGroupCallRoomId! > 0) {
        logger.debug('📞 [Mobile] 接听群组通话, roomId: $_currentGroupCallRoomId');
        await _acceptGroupCall();
        return;
      }
      
      // 如果是 PC 端发起的通话（通过 IM 信令），需要先接受信令再使用 TRTC SDK 进入房间
      if (_currentIMInviteId != null && _pcCallRoomId != null) {
        logger.debug('📞 [Mobile] 接听 PC 端发起的单人通话, roomId: $_pcCallRoomId');
        await _acceptIMInvitation();
        
        // 🔴 使用 TRTC SDK 直接进入房间（不使用 joinInGroupCall，因为那需要 groupId）
        await _enterTRTCRoom(_pcCallRoomId!, _callType == CallType.video);
        return;
      }
      
      // 正常的 TUICallKit 来电
      final result = await TUICallEngine.instance.accept();
      
      if (result.code.isNotEmpty) {
        logger.debug('📞 接听来电失败: ${result.message}');
        onError?.call('接听来电失败: ${result.message}');
        await endCall();
      } else {
        _updateCallState(CallState.connected);
        _callStartTime = DateTime.now();
        logger.debug('📞 已接听来电');
      }
    } catch (e) {
      logger.debug('📞 接听来电失败: $e');
      onError?.call('接听来电失败: $e');
      await endCall();
    }
  }

  /// 接听群组通话（直接使用 TRTC SDK 进入指定房间）
  Future<void> _acceptGroupCall() async {
    try {
      final roomId = _currentGroupCallRoomId!;
      final isVideo = _callType == CallType.video;
      
      logger.debug('📞 [Mobile] 使用 TRTC SDK 加入群组通话: roomId=$roomId, isVideo=$isVideo');
      
      // 直接使用 TRTC SDK 进入房间
      await _enterTRTCRoom(roomId, isVideo);
      
      logger.debug('📞 [Mobile] ✅ 已加入群组通话房间');
      _callStartTime = DateTime.now();
      _updateCallState(CallState.connected);
      
      // 通知其他参与者我已加入
      _notifyGroupCallAccepted();
      
    } catch (e) {
      logger.debug('📞 [Mobile] 加入群组通话异常: $e');
      onError?.call('加入群组通话失败: $e');
      _resetCallState();
    }
  }

  /// 通知其他参与者我已加入群组通话
  void _notifyGroupCallAccepted() {
    try {
      // 通知发起者和其他成员
      final allParticipants = <int>[];
      if (_currentCallUserId != null) {
        allParticipants.add(_currentCallUserId!);
      }
      if (_currentGroupCallUserIds != null) {
        allParticipants.addAll(_currentGroupCallUserIds!);
      }
      
      for (final userId in allParticipants) {
        if (userId != _myUserId) {
          _wsService.sendWebRTCSignal({
            'type': 'group_call_member_accepted',
            'user_id': _myUserId,
            'display_name': _myUserIdStr,
            'room_id': _currentGroupCallRoomId,
            'to_user_id': userId,
            'from_user_id': _myUserId,
          });
        }
      }
      logger.debug('📞 [Mobile] 已通知其他参与者我已加入群组通话');
    } catch (e) {
      logger.debug('⚠️ 通知群组通话加入失败: $e');
    }
  }

  /// TRTC 实例（用于接听 PC 端通话）
  TRTCCloud? _trtcCloud;
  TRTCCloudListener? _trtcListener;
  
  /// 使用 TRTC SDK 直接进入房间（用于接听 PC 端单人通话）
  Future<void> _enterTRTCRoom(int roomId, bool isVideo) async {
    try {
      logger.debug('📞 [Mobile] 使用 TRTC SDK 进入房间: roomId=$roomId, isVideo=$isVideo');
      
      // 🔴 标记使用了 TRTC SDK 直接进入房间
      _usedTRTCSDKDirectly = true;
      
      // 获取或创建 TRTC 实例
      _trtcCloud ??= await TRTCCloud.sharedInstance();
      
      // 设置 TRTC 监听器
      _setupTRTCListener();
      
      // 生成 UserSig
      final userSig = _genTestUserSig(_myUserIdStr!);
      
      // 设置进房参数
      final params = TRTCParams(
        sdkAppId: TencentConfig.sdkAppId,
        userId: _myUserIdStr!,
        userSig: userSig,
        roomId: roomId,
        role: TRTCRoleType.anchor,
      );
      
      // 设置场景
      final scene = isVideo ? TRTCAppScene.videoCall : TRTCAppScene.audioCall;
      
      logger.debug('📞 [Mobile] TRTC 进入房间: roomId=$roomId, userId=$_myUserIdStr, scene=$scene');
      
      // 进入房间
      _trtcCloud!.enterRoom(params, scene);
      
    } catch (e) {
      logger.debug('📞 [Mobile] TRTC 进入房间失败: $e');
      onError?.call('接听来电失败: $e');
      _currentIMInviteId = null;
      _pcCallRoomId = null;
      _usedTRTCSDKDirectly = false;  // 🔴 重置标志
      _updateCallState(CallState.ended);
    }
  }
  
  /// 设置 TRTC 监听器
  void _setupTRTCListener() {
    if (_trtcListener != null) return;
    
    _trtcListener = TRTCCloudListener(
      // 进入房间回调
      onEnterRoom: (result) {
        logger.debug('📞 [Mobile] TRTC 进入房间结果: $result');
        if (result > 0) {
          // 进房成功
          _currentIMInviteId = null;
          _pcCallRoomId = null;
          _callStartTime = DateTime.now();
          
          // 开启麦克风
          _trtcCloud?.startLocalAudio(TRTCAudioQuality.speech);
          
          logger.debug('📞 [Mobile] 已成功进入 TRTC 房间，耗时: ${result}ms');
          
          // 🔴 如果是群组通话发起者，触发 onGroupCallRoomEntered 回调
          // 这样调用方可以导航到通话页面
          if (_isGroupCallInitiator && _currentGroupCallRoomId != null) {
            logger.debug('📞 [Mobile] 群组通话发起者已进入房间，触发 onGroupCallRoomEntered 回调');
            _isGroupCallInitiator = false;  // 重置标记
            
            // 🔴 先更新状态为 connected，再触发回调
            // 这样 VoiceCallPage 打开时可以正确获取通话状态
            _updateCallState(CallState.connected);
            
            // 🔴 异步获取昵称并触发回调
            Future.microtask(() async {
              // 构建包含发起人自己的成员列表
              final allUserIds = <int>[_myUserId!, ...(_currentGroupCallUserIds ?? [])];
              final myDisplayName = await Storage.getFullName() ?? _myUserIdStr ?? '我';
              final allDisplayNames = <String>[myDisplayName, ...(_currentGroupCallDisplayNames ?? [])];
              
              logger.debug('📞 [Mobile] 群组通话成员列表（包含发起人）: userIds=$allUserIds, displayNames=$allDisplayNames');
              
              // 触发回调，通知调用方导航到通话页面
              onGroupCallRoomEntered?.call(
                _currentGroupCallRoomId!,
                allUserIds,
                allDisplayNames,
                _callType,
                _currentGroupId,
              );
            });
          } else {
            _updateCallState(CallState.connected);
          }
        } else {
          logger.debug('📞 [Mobile] TRTC 进入房间失败，错误码: $result');
          onError?.call('进入房间失败: $result');
          _currentIMInviteId = null;
          _pcCallRoomId = null;
          _isGroupCallInitiator = false;
          _updateCallState(CallState.ended);
        }
      },
      
      // 离开房间回调
      onExitRoom: (reason) {
        logger.debug('📞 [Mobile] TRTC 离开房间，原因: $reason');
        final duration = _callStartTime != null 
            ? DateTime.now().difference(_callStartTime!).inSeconds 
            : 0;
        // 🔴 修复：先触发状态变化为 ended，再触发 onCallEnded
        // 这样 CallPage 可以正确处理通话结束
        _updateCallState(CallState.ended);
        onCallEnded?.call(duration);
        _resetCallState();
      },
      
      // 远端用户进入房间
      onRemoteUserEnterRoom: (userId) {
        logger.debug('📞 [Mobile] TRTC 远端用户进入: $userId');
        final uid = int.tryParse(userId) ?? 0;
        _remoteUids.add(uid);
        onRemoteUserJoined?.call(uid);
      },
      
      // 远端用户离开房间
      onRemoteUserLeaveRoom: (userId, reason) {
        logger.debug('📞 [Mobile] TRTC 远端用户离开: $userId, 原因: $reason');
        final uid = int.tryParse(userId) ?? 0;
        _remoteUids.remove(uid);
        onRemoteUserLeft?.call(uid);
        
        // 如果所有远端用户都离开了，结束通话
        if (_remoteUids.isEmpty && _callState == CallState.connected) {
          logger.debug('📞 [Mobile] 所有远端用户已离开，结束通话');
          _exitTRTCRoom();
        }
      },
      
      // 远端用户视频可用
      onUserVideoAvailable: (userId, available) {
        logger.debug('📞 [Mobile] TRTC 用户视频可用: $userId, available=$available');
        final uid = int.tryParse(userId) ?? 0;
        if (available) {
          onRemoteVideoReady?.call(uid);
        }
        onRemoteVideoMuted?.call(uid, !available);
      },
      
      // 远端用户音频可用
      onUserAudioAvailable: (userId, available) {
        logger.debug('📞 [Mobile] TRTC 用户音频可用: $userId, available=$available');
      },
      
      // 错误回调
      onError: (errCode, errMsg) {
        logger.debug('📞 [Mobile] TRTC 错误: code=$errCode, msg=$errMsg');
        onError?.call('TRTC 错误: $errMsg');
      },
    );
    
    _trtcCloud?.registerListener(_trtcListener!);
    logger.debug('📞 [Mobile] TRTC 监听器已设置');
  }
  
  /// 退出 TRTC 房间
  void _exitTRTCRoom() {
    if (_trtcCloud != null) {
      _trtcCloud!.stopLocalAudio();
      _trtcCloud!.stopLocalPreview();
      _trtcCloud!.exitRoom();
    }
  }

  /// 拒绝来电
  Future<void> rejectCall() async {
    logger.debug('📞 [Mobile] ========== rejectCall 被调用 ==========');
    logger.debug('📞 [Mobile] 当前状态: $_callState');
    logger.debug('📞 [Mobile] _isEndingCall: $_isEndingCall');
    logger.debug('📞 [Mobile] _currentIMInviteId: $_currentIMInviteId');
    
    // 🔴 修复：放宽状态检查，允许在 idle 或 ringing 状态下拒绝
    if (_callState != CallState.ringing && _callState != CallState.idle) {
      logger.debug('📞 当前状态不允许拒绝: $_callState');
      return;
    }

    logger.debug('📞 拒绝来电, 当前状态: $_callState');
    
    // 🔴 标记接收方主动拒绝
    _isLocalReject = true;
    
    // 🔴 保存发起方用户ID，用于发送拒绝消息
    final callerUserId = _currentCallUserId;
    final currentCallType = _callType;

    try {
      // 如果是 PC 端发起的通话，拒绝 IM 信令
      if (_currentIMInviteId != null) {
        final inviteIdToReject = _currentIMInviteId!;
        _currentIMInviteId = null;
        _pcCallRoomId = null;
        await _rejectIMInvitation(inviteIdToReject, 'rejected');
        logger.debug('📞 [Mobile] 已拒绝 IM 信令邀请');
      }
      
      await TUICallEngine.instance.reject();
    } catch (e) {
      logger.debug('⚠️ 拒绝来电失败: $e');
    }

    // 🔴 触发 onCallRejectedByMe 回调，发送"已拒绝"消息给发起方
    if (callerUserId != null && callerUserId > 0) {
      logger.debug('📞 [Mobile] rejectCall 触发 onCallRejectedByMe 回调: callerUserId=$callerUserId');
      onCallRejectedByMe?.call(callerUserId, currentCallType);
    }

    // 🔴 直接重置状态，不依赖 endCall
    logger.debug('📞 [Mobile] 直接调用 _resetCallState');
    _resetCallState();
    onCallEnded?.call(0);
  }

  /// 结束通话
  Future<void> endCall({bool isLocalHangup = true}) async {
    logger.debug('📞 [Mobile] ========== endCall 被调用 ==========');
    logger.debug('📞 [Mobile] isLocalHangup: $isLocalHangup');
    logger.debug('📞 [Mobile] _isEndingCall: $_isEndingCall');
    logger.debug('📞 [Mobile] _callState: $_callState');
    logger.debug('📞 [Mobile] _isInGroupCall: $_isInGroupCall');
    logger.debug('📞 [Mobile] _remoteUids: $_remoteUids');
    logger.debug('📞 [Mobile] _trtcCloud: ${_trtcCloud != null ? "已初始化" : "null"}');
    
    // 🔴 简化逻辑：不判断 _callState，直接执行挂断
    // 防止重复调用
    if (_isEndingCall) {
      logger.debug('📞 正在结束通话，跳过重复调用');
      return;
    }

    _isEndingCall = true;
    _isLocalHangup = isLocalHangup;

    logger.debug('📞 结束通话, isLocalHangup: $isLocalHangup');
    logger.debug('📞 [Mobile] _usedTRTCSDKDirectly: $_usedTRTCSDKDirectly');

    // 计算通话时长
    int callDuration = 0;
    if (_callStartTime != null) {
      callDuration = DateTime.now().difference(_callStartTime!).inSeconds;
    }

    // 🔴 保存群组通话信息，因为后面可能会被重置
    final wasGroupCall = _isInGroupCall;
    final groupId = _currentGroupId ?? _lastGroupId;
    final currentCallType = _callType;
    final currentRoomId = _currentGroupCallRoomId;  // 🔴 保存房间号，用于生成 channel_name
    
    // 🔴 检查是否是最后一个已连接成员（群组通话时）
    // _remoteUids 包含当前房间内的其他用户
    final isLastMember = _remoteUids.isEmpty;
    logger.debug('📞 [Mobile] 是否是最后一个成员: $isLastMember (remoteUids=${_remoteUids.length})');
    logger.debug('📞 [Mobile] 保存的通话信息: wasGroupCall=$wasGroupCall, groupId=$groupId, roomId=$currentRoomId');

    try {
      // 🔴 如果使用了 TRTC SDK 直接进入房间，需要退出 TRTC 房间
      if (_usedTRTCSDKDirectly && _trtcCloud != null) {
        logger.debug('📞 [Mobile] 使用 TRTC SDK 退出房间');
        _exitTRTCRoom();
        _usedTRTCSDKDirectly = false;
      } else {
        // 🔴 正常的 TUICallKit 通话，使用 hangup
        logger.debug('📞 [Mobile] 使用 TUICallKit hangup');
        try {
          await TUICallEngine.instance.hangup();
        } catch (e) {
          logger.debug('⚠️ TUICallKit hangup 异常: $e');
        }
      }
      
      // 🔴 如果是群组通话，发送通话结束信号
      // 服务器会广播给所有成员，让他们移除"加入通话"按钮
      if (wasGroupCall && groupId != null && groupId > 0) {
        logger.debug('📞 [Mobile] 群组通话结束，发送结束信号: groupId=$groupId, callDuration=$callDuration, roomId=$currentRoomId');
        _sendGroupCallEndedSignalWithDuration(groupId, currentCallType, callDuration, currentRoomId);
      }
      
      // 🔴 触发回调并重置状态
      onCallEnded?.call(callDuration);
      _resetCallState();
      _isEndingCall = false;
      
    } catch (e) {
      logger.debug('⚠️ 挂断通话失败: $e');
      _usedTRTCSDKDirectly = false;
      onCallEnded?.call(callDuration);
      _resetCallState();
      _isEndingCall = false;
    }
  }
  
  /// 发送群组通话结束信号（带通话时长）
  void _sendGroupCallEndedSignalWithDuration(int groupId, CallType? callType, int callDuration, int? roomId) {
    try {
      // 🔴 生成 channel_name，格式与发起通话时一致
      final channelName = roomId != null ? 'tuicallkit_$roomId' : null;
      
      logger.debug('📞 发送群组通话结束信号(带时长): groupId=$groupId, callType=$callType, duration=$callDuration, channelName=$channelName');
      
      final signal = {
        'type': 'group_call_ended',
        'group_id': groupId,
        'call_type': callType == CallType.video ? 'video' : 'voice',
        'call_duration': callDuration,
        'to_user_id': _myUserId,
        'from_user_id': _myUserId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'source': 'tuicallkit_mobile',
      };
      
      // 🔴 如果有 channel_name，添加到信号中
      if (channelName != null) {
        signal['channel_name'] = channelName;
      }
      
      _wsService.sendWebRTCSignal(signal);
      
      logger.debug('📞 已发送群组通话结束信号(带时长)');
    } catch (e) {
      logger.debug('⚠️ 发送群组通话结束信号失败: $e');
    }
  }

  /// 群组通话中单个成员离开
  Future<Map<String, dynamic>> leaveGroupCallOnly() async {
    logger.debug('📞 ========== leaveGroupCallOnly 开始 ==========');
    logger.debug('📞 [leaveGroupCallOnly] _currentGroupId: $_currentGroupId');
    logger.debug('📞 [leaveGroupCallOnly] _lastGroupId: $_lastGroupId');
    logger.debug('📞 [leaveGroupCallOnly] _callType: $_callType');
    logger.debug('📞 [leaveGroupCallOnly] _remoteUids: $_remoteUids');
    logger.debug('📞 [leaveGroupCallOnly] _remoteUids.length: ${_remoteUids.length}');
    logger.debug('📞 [leaveGroupCallOnly] _currentGroupCallUserIds: $_currentGroupCallUserIds');
    logger.debug('📞 [leaveGroupCallOnly] _isInGroupCall: $_isInGroupCall');
    logger.debug('📞 [leaveGroupCallOnly] _callStartTime: $_callStartTime');
    logger.debug('📞 [leaveGroupCallOnly] _currentCallId: $_currentCallId');
    logger.debug('📞 [leaveGroupCallOnly] _myUserId: $_myUserId');

    int callDuration = 0;
    if (_callStartTime != null) {
      callDuration = DateTime.now().difference(_callStartTime!).inSeconds;
    }
    logger.debug('📞 [leaveGroupCallOnly] 计算的通话时长: $callDuration 秒');
    
    // 🔴 保存群组ID和通话类型，因为 hangup 后可能会被重置
    final groupId = _currentGroupId;
    final currentCallType = _callType;
    final currentCallId = _currentCallId; // 🔴 保存 callId
    
    logger.debug('📞 [leaveGroupCallOnly] 保存的 groupId: $groupId, callType: $currentCallType, callId: $currentCallId');

    try {
      logger.debug('📞 [leaveGroupCallOnly] 准备调用 TUICallEngine.instance.hangup()');
      await TUICallEngine.instance.hangup();
      logger.debug('📞 [leaveGroupCallOnly] TUICallEngine.instance.hangup() 调用成功');
    } catch (e) {
      logger.debug('⚠️ [leaveGroupCallOnly] 离开群组通话失败: $e');
    }

    // 🔴 修改：去掉之前通过 remoteUidsCountBeforeHangup 判断是否是最后一个成员的逻辑
    // 因为 TUICallKit 在群组通话只剩两个已连接成员时就会自动结束通话
    // hangup 后会触发 TUICallKit 的 onCallEnd 回调，由回调来处理结束逻辑
    // 这里不再需要判断是否显示"加入通话"按钮
    logger.debug('📞 [leaveGroupCallOnly] hangup 已调用，等待 TUICallKit onCallEnd 回调处理结束逻辑');
    
    // 🔴 关键修复：不要在这里调用 _updateCallState(CallState.ended)
    // 因为 _updateCallState(CallState.ended) 会调用 _resetCallState()，
    // 这会将 _isInGroupCall 重置为 false，导致 onCallEnd 回调中无法正确判断是否是群组通话
    // 让 TUICallKit 的 onCallEnd 回调来处理状态重置
    // _updateCallState(CallState.ended); // 🔴 注释掉，由 onCallEnd 回调处理

    logger.debug('📞 ========== leaveGroupCallOnly 结束 ==========');
    return {
      'callDuration': callDuration,
      'isCallEnded': true, // 🔴 始终返回 true，因为 TUICallKit 会自动处理通话结束
    };
  }

  /// 切换麦克风
  Future<void> toggleMicrophone(bool enable) async {
    try {
      if (enable) {
        await TUICallEngine.instance.openMicrophone();
      } else {
        await TUICallEngine.instance.closeMicrophone();
      }
      logger.debug('📞 麦克风已${enable ? '开启' : '关闭'}');
    } catch (e) {
      logger.debug('⚠️ 切换麦克风失败: $e');
    }
  }

  /// 切换摄像头
  Future<void> toggleCamera(bool enable) async {
    try {
      if (enable) {
        await TUICallEngine.instance.openCamera(TUICamera.front, null);
      } else {
        await TUICallEngine.instance.closeCamera();
      }
      logger.debug('📞 摄像头已${enable ? '开启' : '关闭'}');
    } catch (e) {
      logger.debug('⚠️ 切换摄像头失败: $e');
    }
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    try {
      // TUICallKit 会自动切换前后摄像头
      await TUICallEngine.instance.switchCamera(TUICamera.back);
      logger.debug('📞 摄像头已切换');
    } catch (e) {
      logger.debug('⚠️ 切换摄像头失败: $e');
    }
  }

  /// 切换扬声器
  Future<void> toggleSpeaker(bool enable) async {
    try {
      final device = enable 
          ? TUIAudioPlaybackDevice.speakerphone 
          : TUIAudioPlaybackDevice.earpiece;
      await TUICallEngine.instance.selectAudioPlaybackDevice(device);
      logger.debug('📞 扬声器已${enable ? '开启' : '关闭'}');
    } catch (e) {
      logger.debug('⚠️ 切换扬声器失败: $e');
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
    _isCallMinimized = isMinimized;
    _minimizedCallUserId = callUserId;
    _minimizedCallDisplayName = displayName;
    _minimizedCallType = callType;
    _minimizedIsGroupCall = isGroupCall;
    _minimizedGroupId = groupId;
  }

  /// 清除最小化状态
  void clearMinimizedState() {
    _isCallMinimized = false;
    _minimizedCallUserId = null;
    _minimizedCallDisplayName = null;
    _minimizedCallType = null;
    _minimizedIsGroupCall = false;
    _minimizedGroupId = null;
  }

  /// 登出
  Future<void> logout() async {
    try {
      await TUICallKit.instance.logout();
      _isLoggedIn = false;
      _lastLoginSdkAppId = null;
      _lastLoginUserId = null;
      _resetCallState();
      logger.debug('📞 TUICallKit 已登出');
    } catch (e) {
      logger.debug('⚠️ TUICallKit 登出失败: $e');
    }
  }
  
  /// 强制重新登录（用于配置变更后）
  Future<void> forceRelogin() async {
    logger.debug('📞 强制重新登录 TUICallKit');
    _isLoggedIn = false;
    _lastLoginSdkAppId = null;
    _lastLoginUserId = null;
    if (_myUserId != null) {
      await initialize(_myUserId!);
    }
  }

  /// 设置用户信息
  Future<void> setSelfInfo(String nickname, String avatar) async {
    try {
      await TUICallKit.instance.setSelfInfo(nickname, avatar);
      logger.debug('📞 用户信息已更新: $nickname');
      
      // 🔴 同时同步到腾讯 IM 服务器
      await _syncUserProfileToIM(nickname, avatar);
    } catch (e) {
      logger.debug('⚠️ 设置用户信息失败: $e');
    }
  }

  /// 🔴 同步用户资料到腾讯 IM 服务器
  /// 这样其他用户在通话时可以通过 getFriendsInfo 获取到正确的头像
  Future<void> _syncUserProfileToIM(String nickname, String avatar) async {
    try {
      logger.debug('📞 正在同步用户资料到腾讯 IM 服务器...');
      logger.debug('📞 昵称: $nickname, 头像: $avatar');
      
      final result = await TencentImSDKPlugin.v2TIMManager.setSelfInfo(
        userFullInfo: V2TimUserFullInfo(
          nickName: nickname,
          faceUrl: avatar,
        ),
      );
      
      if (result.code == 0) {
        logger.debug('📞 ✅ 用户资料已同步到腾讯 IM 服务器');
      } else {
        logger.debug('⚠️ 同步用户资料失败: ${result.desc}');
      }
    } catch (e) {
      logger.debug('⚠️ 同步用户资料到 IM 服务器失败: $e');
    }
  }

  /// 🔴 更新用户头像（当用户更新头像后调用）
  /// 同时更新 TUICallKit 和腾讯 IM 服务器
  Future<void> updateUserAvatar(String avatar) async {
    try {
      final nickname = await Storage.getFullName() ?? '';
      
      // 更新 TUICallKit
      await TUICallKit.instance.setSelfInfo(nickname, avatar);
      
      // 同步到腾讯 IM 服务器
      await _syncUserProfileToIM(nickname, avatar);
      
      logger.debug('📞 ✅ 用户头像已更新: $avatar');
    } catch (e) {
      logger.debug('⚠️ 更新用户头像失败: $e');
    }
  }

  /// 设置来电铃声
  Future<void> setCallingBell(String assetName) async {
    try {
      await TUICallKit.instance.setCallingBell(assetName);
      logger.debug('📞 来电铃声已设置: $assetName');
    } catch (e) {
      logger.debug('⚠️ 设置来电铃声失败: $e');
    }
  }

  /// 启用/禁用静音模式
  Future<void> enableMuteMode(bool enable) async {
    try {
      await TUICallKit.instance.enableMuteMode(enable);
      logger.debug('📞 静音模式已${enable ? '启用' : '禁用'}');
    } catch (e) {
      logger.debug('⚠️ 设置静音模式失败: $e');
    }
  }

  /// 启用/禁用悬浮窗
  Future<void> enableFloatWindow(bool enable) async {
    try {
      await TUICallKit.instance.enableFloatWindow(enable);
      logger.debug('📞 悬浮窗已${enable ? '启用' : '禁用'}');
    } catch (e) {
      logger.debug('⚠️ 设置悬浮窗失败: $e');
    }
  }

  /// 启用/禁用虚拟背景
  Future<void> enableVirtualBackground(bool enable) async {
    try {
      await TUICallKit.instance.enableVirtualBackground(enable);
      logger.debug('📞 虚拟背景已${enable ? '启用' : '禁用'}');
    } catch (e) {
      logger.debug('⚠️ 设置虚拟背景失败: $e');
    }
  }
  
  // 🔴 群组通话挂断事件回调
  ITUINotificationCallback? _groupCallHangupCallback;
  
  /// 设置群组通话挂断事件监听
  void _setupGroupCallHangupListener() {
    logger.debug('📞 [GroupCall] 注册群组通话挂断事件监听');
    
    _groupCallHangupCallback = (arg) {
      logger.debug('📞 [GroupCall] 收到挂断事件: $arg');
      
      if (arg is Map) {
        final isLastMember = arg['isLastMember'] as bool? ?? false;
        final connectedCount = arg['connectedCount'] as int? ?? 0;
        final shouldSendDurationMessage = arg['shouldSendDurationMessage'] as bool? ?? (connectedCount <= 1);
        
        logger.debug('📞 [GroupCall] isLastMember=$isLastMember, connectedCount=$connectedCount, shouldSendDurationMessage=$shouldSendDurationMessage');
        
        // 计算通话时长
        int callDuration = 0;
        if (_callStartTime != null) {
          callDuration = DateTime.now().difference(_callStartTime!).inSeconds;
        }
        
        // 保存群组信息（因为后面会被重置）
        final groupId = _currentGroupId ?? _lastGroupId;
        final currentCallType = _callType;
        
        logger.debug('📞 [GroupCall] groupId=$groupId, callType=$currentCallType, duration=$callDuration');
        
        // 🔴 只要 groupId 有效且 shouldSendDurationMessage 为 true，就触发回调
        // shouldSendDurationMessage 在 group_call_widget.dart 中设置为 connectedCount <= 1
        if (groupId != null && groupId > 0 && shouldSendDurationMessage) {
          // 触发回调，让外部处理（发送通话时长消息给所有群组成员）
          logger.debug('📞 [GroupCall] 触发 onGroupCallHangup 回调，发送通话时长消息给所有群组成员');
          onGroupCallHangup?.call(groupId, currentCallType, callDuration, isLastMember);
        } else {
          logger.debug('📞 [GroupCall] 不满足发送条件，跳过发送通话时长消息 (groupId=$groupId, shouldSendDurationMessage=$shouldSendDurationMessage)');
        }
      }
    };
    
    TUICore.instance.registerEvent('youdu_group_call_hangup', _groupCallHangupCallback);
  }
  
  /// 移除群组通话挂断事件监听
  void _removeGroupCallHangupListener() {
    if (_groupCallHangupCallback != null) {
      TUICore.instance.unregisterEvent('youdu_group_call_hangup', _groupCallHangupCallback);
      _groupCallHangupCallback = null;
    }
  }

  /// 同步群组通话成员状态
  /// 在接听群组通话后调用，从服务器获取当前已连接的成员列表
  Future<void> _syncGroupCallMemberStatus() async {
    // 🔴 支持通过 channelName 或 groupId 查询
    final hasChannelName = _currentGroupCallChannelName != null && _currentGroupCallChannelName!.isNotEmpty;
    final hasGroupId = _currentGroupId != null && _currentGroupId! > 0;
    
    if (!hasChannelName && !hasGroupId) {
      logger.debug('📞 [Mobile] 没有 channelName 和 groupId，无法同步成员状态');
      return;
    }

    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        logger.debug('📞 [Mobile] 没有 token，无法同步成员状态');
        return;
      }

      logger.debug('📞 [Mobile] 开始同步群组通话成员状态，channelName=$_currentGroupCallChannelName, groupId=$_currentGroupId');

      // 调用 API 获取已连接成员列表（优先使用 channelName，否则使用 groupId）
      final response = await ApiService.getGroupCallConnectedMembers(
        token: token,
        channelName: hasChannelName ? _currentGroupCallChannelName : null,
        groupId: hasGroupId ? _currentGroupId : null,
      );

      if (response['error'] != null) {
        logger.debug('📞 [Mobile] 同步成员状态失败: ${response['error']}');
        return;
      }

      final connectedMembers = response['connected_members'] as List<dynamic>? ?? [];
      final totalInvited = response['total_invited'] as int? ?? 0;
      final callStartTime = response['call_start_time'] as int? ?? 0;
      
      // 🔴 如果之前没有 channelName，从响应中获取
      if (!hasChannelName && response['channel_name'] != null) {
        _currentGroupCallChannelName = response['channel_name'] as String;
        logger.debug('📞 [Mobile] 从服务器获取到 channelName: $_currentGroupCallChannelName');
      }

      logger.debug('📞 [Mobile] 同步成员状态成功:');
      logger.debug('📞 [Mobile]   - 已连接成员数: ${connectedMembers.length}');
      logger.debug('📞 [Mobile]   - 总邀请人数: $totalInvited');
      logger.debug('📞 [Mobile]   - 通话开始时间: $callStartTime');

      // 更新本地已连接成员集合
      _connectedMemberIds ??= {};
      for (final member in connectedMembers) {
        final memberId = member['user_id'] as int? ?? 0;
        if (memberId > 0 && memberId != _myUserId) {
          _connectedMemberIds!.add(memberId);
          
          // 触发成员状态变化回调
          final displayName = member['display_name'] as String? ?? '';
          onGroupCallMemberStatusChanged?.call(memberId, 'accepted', displayName);
          logger.debug('📞 [Mobile] 更新成员 $memberId 状态为已连接');
        }
      }

      logger.debug('📞 [Mobile] 成员状态同步完成，已连接成员: $_connectedMemberIds');
    } catch (e) {
      logger.debug('📞 [Mobile] 同步成员状态异常: $e');
    }
  }
}
