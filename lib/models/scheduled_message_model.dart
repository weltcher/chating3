/// 定时消息模型

/// 定时消息类型
enum ScheduledMessageType {
  private, // 私聊
  group,   // 群聊
}

/// 发送类型
enum ScheduledMessageSendType {
  once,  // 单次
  daily, // 每日
}

/// 任务状态
enum ScheduledMessageStatus {
  pending, // 待发送
  sent,    // 已发送
  deleted, // 已删除
}

/// 定时消息模型
class ScheduledMessageModel {
  final int id;
  final int senderId;
  final int receiverId;
  final ScheduledMessageType messageType;
  final String title;
  final String sendTime; // HH:MM格式
  final ScheduledMessageSendType sendType;
  final String content;
  final ScheduledMessageStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScheduledMessageModel({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.messageType,
    required this.title,
    required this.sendTime,
    required this.sendType,
    required this.content,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ScheduledMessageModel.fromJson(Map<String, dynamic> json) {
    return ScheduledMessageModel(
      id: json['id'] as int,
      senderId: json['sender_id'] as int,
      receiverId: json['receiver_id'] as int,
      messageType: _parseMessageType(json['message_type'] as String),
      title: json['title'] as String,
      sendTime: json['send_time'] as String,
      sendType: _parseSendType(json['send_type'] as String),
      content: json['content'] as String,
      status: _parseStatus(json['status'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'message_type': messageType.name,
      'title': title,
      'send_time': sendTime,
      'send_type': sendType.name,
      'content': content,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  static ScheduledMessageType _parseMessageType(String type) {
    switch (type) {
      case 'private':
        return ScheduledMessageType.private;
      case 'group':
        return ScheduledMessageType.group;
      default:
        return ScheduledMessageType.private;
    }
  }

  static ScheduledMessageSendType _parseSendType(String type) {
    switch (type) {
      case 'once':
        return ScheduledMessageSendType.once;
      case 'daily':
        return ScheduledMessageSendType.daily;
      default:
        return ScheduledMessageSendType.once;
    }
  }

  static ScheduledMessageStatus _parseStatus(String status) {
    switch (status) {
      case 'pending':
        return ScheduledMessageStatus.pending;
      case 'sent':
        return ScheduledMessageStatus.sent;
      case 'deleted':
        return ScheduledMessageStatus.deleted;
      default:
        return ScheduledMessageStatus.pending;
    }
  }

  ScheduledMessageModel copyWith({
    int? id,
    int? senderId,
    int? receiverId,
    ScheduledMessageType? messageType,
    String? title,
    String? sendTime,
    ScheduledMessageSendType? sendType,
    String? content,
    ScheduledMessageStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScheduledMessageModel(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      messageType: messageType ?? this.messageType,
      title: title ?? this.title,
      sendTime: sendTime ?? this.sendTime,
      sendType: sendType ?? this.sendType,
      content: content ?? this.content,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
