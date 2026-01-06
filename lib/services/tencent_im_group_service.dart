import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:tencent_cloud_chat_sdk/tencent_im_sdk_plugin.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_full_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member.dart';
import '../config/tencent_config.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';

/// 腾讯云IM群组同步服务
/// 用于在创建群组时同步群组信息和成员关系到腾讯云
class TencentIMGroupService {
  // 单例模式
  static final TencentIMGroupService _instance = TencentIMGroupService._internal();
  factory TencentIMGroupService() => _instance;
  TencentIMGroupService._internal();

  // 腾讯云 IM SDK
  final _im = TencentImSDKPlugin.v2TIMManager;
  
  // 是否已初始化
  bool _isInitialized = false;
  bool _isLoggedIn = false;
  
  // 当前用户ID
  int? _currentUserId;
  String? _currentUserIdStr;

  bool get isInitialized => _isInitialized;
  bool get isLoggedIn => _isLoggedIn;

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

  /// 初始化并登录腾讯云IM
  Future<bool> initialize(int currentUserId) async {
    try {
      logger.debug('========== 📱 腾讯云IM群组服务初始化开始 ==========');
      logger.debug('📱 用户ID: $currentUserId');

      _currentUserId = currentUserId;
      _currentUserIdStr = currentUserId.toString();

      // 如果已经初始化且登录，直接返回
      if (_isInitialized && _isLoggedIn) {
        logger.debug('📱 腾讯云IM已初始化并登录，跳过');
        return true;
      }

      // 初始化 IM SDK
      final initResult = await _im.initSDK(
        sdkAppID: TencentConfig.sdkAppId,
        loglevel: LogLevelEnum.V2TIM_LOG_INFO,
        listener: null,
      );
      
      if (initResult.code != 0) {
        logger.error('📱 IM SDK 初始化失败: ${initResult.desc}');
        return false;
      }
      
      _isInitialized = true;
      logger.debug('📱 IM SDK 初始化成功');

      // 生成 UserSig
      final userSig = _genTestUserSig(_currentUserIdStr!);
      
      // 登录 IM
      final loginResult = await _im.login(
        userID: _currentUserIdStr!,
        userSig: userSig,
      );
      
      if (loginResult.code != 0) {
        logger.error('📱 IM 登录失败: ${loginResult.desc}');
        return false;
      }
      
      _isLoggedIn = true;
      logger.debug('📱 IM 登录成功');
      logger.debug('========== 腾讯云IM群组服务初始化完成 ==========');
      
      return true;
    } catch (e) {
      logger.error('📱 腾讯云IM群组服务初始化失败: $e');
      return false;
    }
  }

  /// 确保已登录
  Future<bool> _ensureLoggedIn() async {
    if (_isLoggedIn) return true;
    
    final userId = await Storage.getUserId();
    if (userId == null) {
      logger.error('📱 无法获取当前用户ID');
      return false;
    }
    
    return await initialize(userId);
  }


  /// 创建腾讯云IM群组并同步成员
  /// 
  /// 参数:
  /// - groupId: 本地群组ID（用作腾讯云群组ID）
  /// - groupName: 群组名称
  /// - ownerId: 群主用户ID
  /// - memberIds: 群成员用户ID列表（不包含群主）
  /// - groupAvatar: 群组头像URL（可选）
  /// - notification: 群公告（可选）
  /// 
  /// 返回:
  /// - 成功返回腾讯云群组ID，失败返回null
  Future<String?> createGroupWithMembers({
    required int groupId,
    required String groupName,
    required int ownerId,
    required List<int> memberIds,
    String? groupAvatar,
    String? notification,
  }) async {
    try {
      logger.debug('========== 📱 创建腾讯云IM群组 ==========');
      logger.debug('📱 本地群组ID: $groupId');
      logger.debug('📱 群组名称: $groupName');
      logger.debug('📱 群主ID: $ownerId');
      logger.debug('📱 成员IDs: $memberIds');
      logger.debug('📱 群头像: $groupAvatar');
      logger.debug('📱 群公告: $notification');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法创建群组');
        return null;
      }

      // 使用本地群组ID作为腾讯云群组ID（确保唯一性）
      final imGroupId = 'group_$groupId';
      
      // 构建成员列表（不包含群主，群主会自动成为群成员）
      final memberInfoList = memberIds
          .where((id) => id != ownerId) // 排除群主
          .map((id) => V2TimGroupMember(
                userID: id.toString(),
                role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_MEMBER,
              ))
          .toList();

      logger.debug('📱 准备添加的成员数量: ${memberInfoList.length}');

      // 创建群组
      // 使用 Work 类型（工作群），成员需要被邀请才能加入
      final createResult = await _im.getGroupManager().createGroup(
        groupID: imGroupId,
        groupType: 'Work', // Work=工作群, Public=公开群, Meeting=会议群, AVChatRoom=直播群
        groupName: groupName,
        faceUrl: groupAvatar,
        notification: notification,
        addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_FORBID, // 禁止申请加入
        memberList: memberInfoList,
      );

      if (createResult.code != 0) {
        logger.error('📱 创建腾讯云IM群组失败: ${createResult.desc}');
        
        // 如果群组已存在，尝试同步成员
        if (createResult.code == 10021) {
          logger.debug('📱 群组已存在，尝试同步成员');
          await syncGroupMembers(groupId: groupId, memberIds: memberIds);
          return imGroupId;
        }
        
        return null;
      }

      final createdGroupId = createResult.data;
      logger.debug('📱 ✅ 腾讯云IM群组创建成功: $createdGroupId');
      logger.debug('📱 ✅ 已同步 ${memberInfoList.length} 个成员到腾讯云');
      logger.debug('========== 腾讯云IM群组创建完成 ==========');

      return createdGroupId;
    } catch (e) {
      logger.error('📱 创建腾讯云IM群组异常: $e');
      return null;
    }
  }

  /// 同步群组成员到腾讯云
  /// 
  /// 用于在群组已存在的情况下，同步成员列表
  Future<bool> syncGroupMembers({
    required int groupId,
    required List<int> memberIds,
  }) async {
    try {
      logger.debug('========== 📱 同步群组成员到腾讯云 ==========');
      logger.debug('📱 群组ID: $groupId');
      logger.debug('📱 成员IDs: $memberIds');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法同步成员');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      // 获取当前群组成员列表
      final existingMembersResult = await _im.getGroupManager().getGroupMemberList(
        groupID: imGroupId,
        filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
        nextSeq: '0',
      );

      Set<String> existingMemberIds = {};
      if (existingMembersResult.code == 0 && existingMembersResult.data != null) {
        existingMemberIds = existingMembersResult.data!.memberInfoList
            ?.map((m) => m?.userID ?? '')
            .where((id) => id.isNotEmpty)
            .toSet() ?? {};
      }

      logger.debug('📱 现有成员: $existingMemberIds');

      // 找出需要添加的成员
      final membersToAdd = memberIds
          .map((id) => id.toString())
          .where((id) => !existingMemberIds.contains(id))
          .toList();

      logger.debug('📱 需要添加的成员: $membersToAdd');

      if (membersToAdd.isEmpty) {
        logger.debug('📱 没有需要添加的成员');
        return true;
      }

      // 邀请成员加入群组
      final inviteResult = await _im.getGroupManager().inviteUserToGroup(
        groupID: imGroupId,
        userList: membersToAdd,
      );

      if (inviteResult.code != 0) {
        logger.error('📱 邀请成员加入群组失败: ${inviteResult.desc}');
        return false;
      }

      logger.debug('📱 ✅ 成功邀请 ${membersToAdd.length} 个成员加入群组');
      logger.debug('========== 群组成员同步完成 ==========');

      return true;
    } catch (e) {
      logger.error('📱 同步群组成员异常: $e');
      return false;
    }
  }

  /// 添加单个成员到群组
  Future<bool> addMemberToGroup({
    required int groupId,
    required int memberId,
  }) async {
    try {
      logger.debug('📱 添加成员到群组: groupId=$groupId, memberId=$memberId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法添加成员');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      final result = await _im.getGroupManager().inviteUserToGroup(
        groupID: imGroupId,
        userList: [memberId.toString()],
      );

      if (result.code != 0) {
        logger.error('📱 添加成员失败: ${result.desc}');
        return false;
      }

      logger.debug('📱 ✅ 成员添加成功');
      return true;
    } catch (e) {
      logger.error('📱 添加成员异常: $e');
      return false;
    }
  }

  /// 从群组移除成员
  Future<bool> removeMemberFromGroup({
    required int groupId,
    required int memberId,
  }) async {
    try {
      logger.debug('📱 从群组移除成员: groupId=$groupId, memberId=$memberId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法移除成员');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      final result = await _im.getGroupManager().kickGroupMember(
        groupID: imGroupId,
        memberList: [memberId.toString()],
      );

      if (result.code != 0) {
        logger.error('📱 移除成员失败: ${result.desc}');
        return false;
      }

      logger.debug('📱 ✅ 成员移除成功');
      return true;
    } catch (e) {
      logger.error('📱 移除成员异常: $e');
      return false;
    }
  }

  /// 更新群组信息
  Future<bool> updateGroupInfo({
    required int groupId,
    String? groupName,
    String? groupAvatar,
    String? notification,
  }) async {
    try {
      logger.debug('📱 更新群组信息: groupId=$groupId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法更新群组');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      final groupInfo = V2TimGroupInfo(
        groupID: imGroupId,
        groupType: 'Work',
        groupName: groupName,
        faceUrl: groupAvatar,
        notification: notification,
      );

      final result = await _im.getGroupManager().setGroupInfo(info: groupInfo);

      if (result.code != 0) {
        logger.error('📱 更新群组信息失败: ${result.desc}');
        return false;
      }

      logger.debug('📱 ✅ 群组信息更新成功');
      return true;
    } catch (e) {
      logger.error('📱 更新群组信息异常: $e');
      return false;
    }
  }

  /// 解散群组
  Future<bool> dismissGroup({required int groupId}) async {
    try {
      logger.debug('📱 解散群组: groupId=$groupId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法解散群组');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      final result = await _im.dismissGroup(groupID: imGroupId);

      if (result.code != 0) {
        logger.error('📱 解散群组失败: ${result.desc}');
        return false;
      }

      logger.debug('📱 ✅ 群组解散成功');
      return true;
    } catch (e) {
      logger.error('📱 解散群组异常: $e');
      return false;
    }
  }

  /// 退出群组
  Future<bool> quitGroup({required int groupId}) async {
    try {
      logger.debug('📱 退出群组: groupId=$groupId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法退出群组');
        return false;
      }

      final imGroupId = 'group_$groupId';
      
      final result = await _im.quitGroup(groupID: imGroupId);

      if (result.code != 0) {
        logger.error('📱 退出群组失败: ${result.desc}');
        return false;
      }

      logger.debug('📱 ✅ 退出群组成功');
      return true;
    } catch (e) {
      logger.error('📱 退出群组异常: $e');
      return false;
    }
  }

  /// 获取群组成员列表
  Future<List<V2TimGroupMemberFullInfo>?> getGroupMembers({
    required int groupId,
  }) async {
    try {
      logger.debug('📱 获取群组成员: groupId=$groupId');

      // 确保已登录
      if (!await _ensureLoggedIn()) {
        logger.error('📱 腾讯云IM未登录，无法获取成员');
        return null;
      }

      final imGroupId = 'group_$groupId';
      
      final result = await _im.getGroupManager().getGroupMemberList(
        groupID: imGroupId,
        filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
        nextSeq: '0',
      );

      if (result.code != 0) {
        logger.error('📱 获取群组成员失败: ${result.desc}');
        return null;
      }

      final members = result.data?.memberInfoList
          ?.where((m) => m != null)
          .cast<V2TimGroupMemberFullInfo>()
          .toList();

      logger.debug('📱 ✅ 获取到 ${members?.length ?? 0} 个成员');
      return members;
    } catch (e) {
      logger.error('📱 获取群组成员异常: $e');
      return null;
    }
  }
}
