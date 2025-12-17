/// 消息位置缓存服务
/// 
/// 用于缓存消息的位置信息，支持通过 server_id 快速定位消息
/// 主要用于引用消息跳转功能
class MessagePositionCache {
  // 单例模式
  static final MessagePositionCache _instance = MessagePositionCache._internal();
  factory MessagePositionCache() => _instance;
  MessagePositionCache._internal();

  /// 消息位置缓存
  /// key: 会话唯一标识 (格式: "user_123" 或 "group_456" 或 "file_assistant_123")
  /// value: Map of serverId to MessagePosition
  final Map<String, Map<int, MessagePosition>> _positionCache = {};

  /// 缓存消息位置
  /// 
  /// [sessionKey] 会话唯一标识
  /// [serverId] 服务器消息ID
  /// [localId] 本地消息ID
  /// [index] 消息在列表中的索引
  void cachePosition({
    required String sessionKey,
    required int? serverId,
    required int localId,
    required int index,
  }) {
    if (serverId == null) return;
    
    _positionCache.putIfAbsent(sessionKey, () => {});
    _positionCache[sessionKey]![serverId] = MessagePosition(
      serverId: serverId,
      localId: localId,
      index: index,
    );
  }

  /// 批量缓存消息位置
  /// 
  /// [sessionKey] 会话唯一标识
  /// [messages] 消息列表，每个元素包含 serverId, localId
  void cachePositions({
    required String sessionKey,
    required List<MessagePositionData> messages,
  }) {
    _positionCache[sessionKey] = {};
    
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.serverId != null) {
        _positionCache[sessionKey]![msg.serverId!] = MessagePosition(
          serverId: msg.serverId!,
          localId: msg.localId,
          index: i,
        );
      }
    }
  }

  /// 通过 serverId 获取消息位置
  /// 
  /// [sessionKey] 会话唯一标识
  /// [serverId] 服务器消息ID
  /// 
  /// 返回消息位置信息，如果未找到返回 null
  MessagePosition? getPosition({
    required String sessionKey,
    required int serverId,
  }) {
    return _positionCache[sessionKey]?[serverId];
  }

  /// 通过 serverId 获取本地消息ID
  /// 
  /// [sessionKey] 会话唯一标识
  /// [serverId] 服务器消息ID
  /// 
  /// 返回本地消息ID，如果未找到返回 null
  int? getLocalId({
    required String sessionKey,
    required int serverId,
  }) {
    return _positionCache[sessionKey]?[serverId]?.localId;
  }

  /// 通过 serverId 获取消息索引
  /// 
  /// [sessionKey] 会话唯一标识
  /// [serverId] 服务器消息ID
  /// 
  /// 返回消息索引，如果未找到返回 -1
  int getIndex({
    required String sessionKey,
    required int serverId,
  }) {
    return _positionCache[sessionKey]?[serverId]?.index ?? -1;
  }

  /// 清除指定会话的缓存
  void clearSession(String sessionKey) {
    _positionCache.remove(sessionKey);
  }

  /// 清除所有缓存
  void clearAll() {
    _positionCache.clear();
  }

  /// 更新消息位置（当消息列表发生变化时调用）
  /// 
  /// [sessionKey] 会话唯一标识
  /// [serverId] 服务器消息ID
  /// [newIndex] 新的索引位置
  void updateIndex({
    required String sessionKey,
    required int serverId,
    required int newIndex,
  }) {
    final position = _positionCache[sessionKey]?[serverId];
    if (position != null) {
      _positionCache[sessionKey]![serverId] = MessagePosition(
        serverId: position.serverId,
        localId: position.localId,
        index: newIndex,
      );
    }
  }

  /// 生成会话唯一标识
  /// 
  /// [isGroup] 是否是群组
  /// [id] 用户ID或群组ID
  /// [isFileAssistant] 是否是文件助手
  /// [currentUserId] 当前用户ID（文件助手需要）
  static String generateSessionKey({
    required bool isGroup,
    required int id,
    bool isFileAssistant = false,
    int? currentUserId,
  }) {
    if (isFileAssistant) {
      return 'file_assistant_${currentUserId ?? id}';
    } else if (isGroup) {
      return 'group_$id';
    } else {
      return 'user_$id';
    }
  }
}

/// 消息位置信息
class MessagePosition {
  final int serverId;
  final int localId;
  final int index;

  MessagePosition({
    required this.serverId,
    required this.localId,
    required this.index,
  });

  @override
  String toString() {
    return 'MessagePosition(serverId: $serverId, localId: $localId, index: $index)';
  }
}

/// 消息位置数据（用于批量缓存）
class MessagePositionData {
  final int? serverId;
  final int localId;

  MessagePositionData({
    required this.serverId,
    required this.localId,
  });
}
