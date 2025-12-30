import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/logger.dart';

final _logger = Logger();

/// iOS CallKit 服务
/// 用于在 iOS 后台显示系统级来电界面
class CallKitService {
  static final CallKitService _instance = CallKitService._internal();
  factory CallKitService() => _instance;
  CallKitService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.example.youdu/callkit');

  // 回调函数
  Function(Map<String, dynamic> callInfo)? onCallAccepted;
  Function(Map<String, dynamic> callInfo)? onCallRejected;
  Function(Map<String, dynamic> callInfo)? onCallEnded;  // 🔴 新增：通话结束回调
  Function()? onAudioSessionActivated;
  Function()? onAudioSessionDeactivated;

  bool _isInitialized = false;

  /// 初始化 CallKit 服务
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!Platform.isIOS) return;

    _channel.setMethodCallHandler(_handleMethodCall);
    _isInitialized = true;
    _logger.debug('📞 [CallKitService] Flutter 服务已初始化');
  }

  /// 处理来自 iOS 的方法调用
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    _logger.debug('╔═══════════════════════════════════════════════════════════════╗');
    _logger.debug('║ 📞 [CallKitService] 收到 iOS 回调: ${call.method.padRight(25)} ║');
    _logger.debug('╚═══════════════════════════════════════════════════════════════╝');
    _logger.debug('📞 [CallKitService] 回调参数: ${call.arguments}');

    switch (call.method) {
      case 'onCallAccepted':
        final callInfo = Map<String, dynamic>.from(call.arguments as Map);
        _logger.debug('📞 [CallKitService] 解析后的 callInfo: $callInfo');
        _logger.debug('📞 [CallKitService] onCallAccepted 回调是否已设置: ${onCallAccepted != null}');
        if (onCallAccepted != null) {
          _logger.debug('📞 [CallKitService] 调用 onCallAccepted 回调...');
          onCallAccepted?.call(callInfo);
          _logger.debug('📞 [CallKitService] onCallAccepted 回调已调用');
        } else {
          _logger.debug('📞 [CallKitService] ⚠️ onCallAccepted 回调未设置！');
        }
        break;

      case 'onCallRejected':
        final callInfo = Map<String, dynamic>.from(call.arguments as Map);
        _logger.debug('📞 [CallKitService] 解析后的 callInfo: $callInfo');
        _logger.debug('📞 [CallKitService] onCallRejected 回调是否已设置: ${onCallRejected != null}');
        if (onCallRejected != null) {
          _logger.debug('📞 [CallKitService] 调用 onCallRejected 回调...');
          onCallRejected?.call(callInfo);
          _logger.debug('📞 [CallKitService] onCallRejected 回调已调用');
        } else {
          _logger.debug('📞 [CallKitService] ⚠️ onCallRejected 回调未设置！');
        }
        break;

      case 'onCallEnded':
        // 🔴 新增：处理通话结束（用户通过 CallKit 挂断已接听的通话）
        final callInfo = Map<String, dynamic>.from(call.arguments as Map);
        _logger.debug('📞 [CallKitService] 解析后的 callInfo: $callInfo');
        _logger.debug('📞 [CallKitService] onCallEnded 回调是否已设置: ${onCallEnded != null}');
        if (onCallEnded != null) {
          _logger.debug('📞 [CallKitService] 调用 onCallEnded 回调...');
          onCallEnded?.call(callInfo);
          _logger.debug('📞 [CallKitService] onCallEnded 回调已调用');
        } else {
          _logger.debug('📞 [CallKitService] ⚠️ onCallEnded 回调未设置！');
        }
        break;

      case 'onAudioSessionActivated':
        _logger.debug('📞 [CallKitService] 音频会话已激活');
        _logger.debug('📞 [CallKitService] onAudioSessionActivated 回调是否已设置: ${onAudioSessionActivated != null}');
        onAudioSessionActivated?.call();
        break;

      case 'onAudioSessionDeactivated':
        _logger.debug('📞 [CallKitService] 音频会话已停用');
        _logger.debug('📞 [CallKitService] onAudioSessionDeactivated 回调是否已设置: ${onAudioSessionDeactivated != null}');
        onAudioSessionDeactivated?.call();
        break;

      default:
        _logger.debug('📞 [CallKitService] ⚠️ 未知方法: ${call.method}');
    }
    
    _logger.debug('📞 [CallKitService] _handleMethodCall 处理完成');
  }

  /// 显示来电界面（通过 WebSocket 触发）
  Future<bool> reportIncomingCall({
    required int callerId,
    required String callerName,
    required String callType,
    required String channelName,
    required String token,
    bool isGroupCall = false,
    int? groupId,
    List<Map<String, dynamic>>? members,
  }) async {
    if (!Platform.isIOS) return false;

    try {
      _logger.debug('📞 [CallKit] 显示来电界面');
      _logger.debug('   - 来电者: $callerName (ID: $callerId)');
      _logger.debug('   - 类型: $callType');
      _logger.debug('   - 频道: $channelName');

      await _channel.invokeMethod('reportIncomingCall', {
        'caller_id': callerId,
        'caller_name': callerName,
        'call_type': callType,
        'channel_name': channelName,
        'token': token,
        'is_group_call': isGroupCall,
        'group_id': groupId,
        'members': members,
      });

      _logger.debug('📞 [CallKit] ✅ 来电界面已显示');
      return true;
    } catch (e) {
      _logger.error('📞 [CallKit] ❌ 显示来电界面失败: $e');
      return false;
    }
  }

  /// 结束当前通话
  Future<bool> endCall() async {
    if (!Platform.isIOS) return false;

    try {
      await _channel.invokeMethod('endCall');
      _logger.debug('📞 [CallKit] ✅ 通话已结束');
      return true;
    } catch (e) {
      _logger.error('📞 [CallKit] ❌ 结束通话失败: $e');
      return false;
    }
  }

  /// 报告通话已连接
  Future<bool> reportCallConnected() async {
    if (!Platform.isIOS) return false;

    try {
      await _channel.invokeMethod('reportCallConnected');
      _logger.debug('📞 [CallKit] ✅ 已报告通话连接');
      return true;
    } catch (e) {
      _logger.error('📞 [CallKit] ❌ 报告通话连接失败: $e');
      return false;
    }
  }

  /// 报告通话结束
  Future<bool> reportCallEnded({int reason = 2}) async {
    if (!Platform.isIOS) return false;

    try {
      await _channel.invokeMethod('reportCallEnded', {'reason': reason});
      _logger.debug('📞 [CallKit] ✅ 已报告通话结束');
      return true;
    } catch (e) {
      _logger.error('📞 [CallKit] ❌ 报告通话结束失败: $e');
      return false;
    }
  }
}
