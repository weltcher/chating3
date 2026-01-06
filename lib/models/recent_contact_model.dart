/// 最近联系人模型（支持用户、群组和文件助手）
class RecentContactModel {
  final String type; // 类型：user、group 或 file_assistant
  final int userId; // 用户ID或群组ID（文件助手为0）
  final String username;
  final String fullName;
  final String? avatar; // 用户头像URL
  final String lastMessageTime;
  final String lastMessage;
  final String? lastMessageStatus; // 🔴 新增：最后一条消息的状态（recalled表示已撤回）
  final int unreadCount; // 未读消息数量
  final String status; // 用户状态：online, busy, away, offline
  final int? groupId; // 群组ID（仅当type为group时有值）
  final String? groupName; // 群组名称（仅当type为group时有值）
  final String? remark; // 用户对群组的备注（仅当type为group时有值）
  final bool doNotDisturb; // 消息免打扰（一对一单聊和群组均有效）
  final bool hasMentionedMe; // 群组中是否有人@我（仅群组消息有效）

  RecentContactModel({
    this.type = 'user', // 默认为用户类型
    required this.userId,
    required this.username,
    required this.fullName,
    this.avatar,
    required this.lastMessageTime,
    required this.lastMessage,
    this.lastMessageStatus, // 🔴 新增
    this.unreadCount = 0, // 默认为0
    this.status = 'offline', // 默认为离线
    this.groupId,
    this.groupName,
    this.remark,
    this.doNotDisturb = false, // 默认不免打扰
    this.hasMentionedMe = false, // 默认没有被@
  });

  /// 创建群组类型的最近联系人
  factory RecentContactModel.group({
    required int groupId,
    required String groupName,
    String? avatar, // 添加群组头像参数
    String lastMessage = '创建了群组',
    String? lastMessageTime,
    String? remark, // 添加备注参数
    bool doNotDisturb = false, // 添加消息免打扰参数
  }) {
    // 如果没有提供头像或头像为空，使用默认群组头像
    final finalAvatar = (avatar != null && avatar.isNotEmpty) 
        ? avatar 
        : null; // 保持为null，让UI层显示默认样式
        
    return RecentContactModel(
      type: 'group',
      userId: groupId, // 使用groupId作为userId
      username: groupName,
      fullName: groupName,
      avatar: finalAvatar, // 传递处理后的群组头像
      lastMessageTime: lastMessageTime ?? DateTime.now().toIso8601String(),
      lastMessage: lastMessage,
      unreadCount: 0,
      status: 'online',
      groupId: groupId,
      groupName: groupName,
      remark: remark, // 传递备注
      doNotDisturb: doNotDisturb, // 传递消息免打扰
      hasMentionedMe: false,
    );
  }

  /// 创建文件助手类型的最近联系人
  factory RecentContactModel.fileAssistant({
    String lastMessage = '暂无消息',
    String? lastMessageTime,
  }) {
    return RecentContactModel(
      type: 'file_assistant',
      userId: 0, // 文件助手使用特殊ID 0
      username: 'fileassistant',
      fullName: '文件传输助手',
      lastMessageTime: lastMessageTime ?? DateTime.now().toIso8601String(),
      lastMessage: lastMessage,
      unreadCount: 0,
      status: 'online',
    );
  }

  /// 从 JSON 创建模型
  factory RecentContactModel.fromJson(Map<String, dynamic> json) {
    // 安全获取必需字段，提供默认值
    final userId = json['user_id'] is int 
        ? json['user_id'] as int 
        : int.tryParse(json['user_id']?.toString() ?? '') ?? 0;
    
    final username = json['username']?.toString() ?? 'Unknown';
    
    final lastMessageTime = json['last_message_time']?.toString() ?? 
        DateTime.now().toIso8601String();
    
    final lastMessage = json['last_message']?.toString() ?? '';
    
    return RecentContactModel(
      type: json['type'] as String? ?? 'user',
      userId: userId,
      username: username,
      fullName: json['full_name']?.toString() ?? username,
      avatar: json['avatar']?.toString(),
      lastMessageTime: lastMessageTime,
      lastMessage: lastMessage,
      lastMessageStatus: json['last_message_status']?.toString(), // 🔴 新增
      unreadCount: json['unread_count'] is int 
          ? json['unread_count'] as int 
          : int.tryParse(json['unread_count']?.toString() ?? '') ?? 0,
      status: json['status'] as String? ?? 'offline',
      groupId: json['group_id'] is int ? json['group_id'] as int : null,
      groupName: json['group_name']?.toString(),
      remark: json['remark']?.toString(),
      doNotDisturb: json['do_not_disturb'] == true || 
          json['do_not_disturb']?.toString() == 'true',
      hasMentionedMe: json['has_mentioned_me'] == true || 
          json['has_mentioned_me']?.toString() == 'true',
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'user_id': userId,
      'username': username,
      'full_name': fullName,
      if (avatar != null) 'avatar': avatar,
      'last_message_time': lastMessageTime,
      'last_message': lastMessage,
      if (lastMessageStatus != null) 'last_message_status': lastMessageStatus, // 🔴 新增
      'unread_count': unreadCount,
      'status': status,
      if (groupId != null) 'group_id': groupId,
      if (groupName != null) 'group_name': groupName,
      if (remark != null) 'remark': remark,
      'do_not_disturb': doNotDisturb,
      'has_mentioned_me': hasMentionedMe,
    };
  }

  /// 创建一个新的实例，可以修改某些字段
  RecentContactModel copyWith({
    String? type,
    int? userId,
    String? username,
    String? fullName,
    String? avatar,
    String? lastMessageTime,
    String? lastMessage,
    String? lastMessageStatus, // 🔴 新增
    int? unreadCount,
    String? status,
    int? groupId,
    String? groupName,
    String? remark,
    bool? doNotDisturb,
    bool? hasMentionedMe,
  }) {
    return RecentContactModel(
      type: type ?? this.type,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      avatar: avatar ?? this.avatar,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageStatus: lastMessageStatus ?? this.lastMessageStatus, // 🔴 新增
      unreadCount: unreadCount ?? this.unreadCount,
      status: status ?? this.status,
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      remark: remark ?? this.remark,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      hasMentionedMe: hasMentionedMe ?? this.hasMentionedMe,
    );
  }

  /// 是否为群组
  bool get isGroup => type == 'group';

  /// 是否为文件助手
  bool get isFileAssistant => type == 'file_assistant';

  /// 获取显示名称
  /// - 对于文件助手：始终显示"文件传输助手"
  /// - 对于群组：优先使用 remark（备注），如果为空则使用 groupName 或 fullName
  /// - 对于用户：优先使用 fullName，如果为空则使用 username
  String get displayName {
    if (isFileAssistant) {
      return '文件传输助手';
    } else if (isGroup) {
      // 群组：优先备注 -> 群组名称 -> fullName
      if (remark != null && remark!.isNotEmpty) {
        return remark!;
      }
      if (groupName != null && groupName!.isNotEmpty) {
        return groupName!;
      }
      return fullName.isNotEmpty ? fullName : '未知群组';
    } else {
      // 用户：优先备注 -> fullName -> username
      if (remark != null && remark!.isNotEmpty) {
        return remark!;
      }
      return fullName.isNotEmpty ? fullName : username;
    }
  }

  /// 获取头像文本（取名字的最后两个字符）
  String get avatarText {
    final name = displayName;
    if (name.length >= 2) {
      return name.substring(name.length - 2);
    }
    return name;
  }
}
