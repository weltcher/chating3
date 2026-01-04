/// 通话页面的实际实现选择器
/// 此文件根据平台自动选择使用 TUICallKit 实现还是桌面端实现
/// 
/// - 移动端 (Android/iOS): 使用 call_page.dart (TUICallKit)
/// - 桌面端 (Windows/macOS/Linux): 使用 desktop_call_page.dart (TRTC SDK)
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/agora_service.dart' show CallType;

// 🔴 条件导入：桌面端不导入 TUICallKit，避免 SDK 自动初始化
import 'call_page.dart' if (dart.library.io) 'call_page.dart' as call_page;
import 'desktop_call_page.dart';

/// 判断是否为桌面平台
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// 通话页面 - 根据平台自动选择实现
/// 
/// 移动端使用 TUICallKit 的 CallPage
/// 桌面端使用 TRTC SDK 的 DesktopCallPage
class VoiceCallPage extends StatelessWidget {
  final int targetUserId;
  final String targetDisplayName;
  final bool isIncoming;
  final CallType callType;
  final String? targetAvatar;
  final List<int>? groupCallUserIds;
  final List<String>? groupCallDisplayNames;
  final List<String?>? groupCallAvatarUrls;
  final int? currentUserId;
  final int? groupId;
  final bool isJoiningExistingCall;
  final String? memberRole;

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
  Widget build(BuildContext context) {
    // 🔴 桌面端直接使用 DesktopCallPage，不经过 CallPage
    // 这样可以避免导入 TUICallKit，防止 SDK 自动初始化
    if (_isDesktopPlatform) {
      // 🔴 重要：桌面端来电时，home_page.dart 已经调用了 acceptCall()
      // 所以这里传递 isIncoming=false，让 DesktopCallPage 直接显示通话中界面
      // 而不是再显示来电界面让用户再次点击接听
      return DesktopCallPage(
        targetUserId: targetUserId,
        targetDisplayName: targetDisplayName,
        targetAvatar: targetAvatar,
        isIncoming: false,  // 🔴 桌面端来电已在 home_page 中接听，这里不再显示来电界面
        isVideoCall: callType == CallType.video,
      );
    }
    
    // 移动端使用 TUICallKit 的 CallPage
    return call_page.CallPage(
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
