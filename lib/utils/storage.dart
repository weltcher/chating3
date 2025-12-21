import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/contact_model.dart';
import '../models/online_notification_model.dart';
import '../utils/logger.dart';

/// 本地存储工具类
class Storage {
  // 🔴 进程ID，用于多实例隔离存储
  static final String _processId = pid.toString();

  // 安全存储实例（用于存储敏感信息）
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // 🔴 为关键的认证信息添加进程ID前缀，避免多实例冲突
  static String get _tokenKey => '${_processId}_auth_token';
  static String get _userIdKey => '${_processId}_user_id';
  static String get _usernameKey => '${_processId}_username';
  static String get _fullNameKey => '${_processId}_full_name';
  // 🔴 用户相关数据也需要进程ID前缀，避免多实例用户数据混淆
  static String get _onlineNotificationsKey =>
      '${_processId}_online_notifications';
  static String get _fileStoragePathKey => '${_processId}_file_storage_path';
  static String get _messageStoragePathKey =>
      '${_processId}_message_storage_path';
  static String get _autoDownloadEnabledKey =>
      '${_processId}_auto_download_enabled';
  static String get _autoDownloadSizeMBKey =>
      '${_processId}_auto_download_size_mb';
  // 🔴 置顶和删除会话配置，使用用户ID作为前缀（而不是进程ID）
  // 这些方法需要传入用户ID，因为每个用户的配置是独立的
  static String _getPinnedChatsKey(int userId) => 'user_${userId}_pinned_chats';
  static String _getDeletedChatsKey(int userId) =>
      'user_${userId}_deleted_chats';
  static String _getPendingContactsKey(int userId) =>
      'user_${userId}_pending_contacts';

  // 🔴 最近一次登录的用户ID（不使用进程ID前缀，因为这是全局的，所有进程共享）
  static const String _lastLoggedInUserIdKey = 'last_logged_in_user_id';

  // 全局配置（不需要进程ID前缀，所有实例共享）
  static const String _idleStatusEnabledKey = 'idle_status_enabled';
  static const String _idleMinutesKey = 'idle_minutes';
  static const String _appLanguageKey = 'app_language';
  static const String _windowZoomKey = 'window_zoom';
  static const String _newMessageSoundEnabledKey = 'new_message_sound_enabled';
  static const String _newMessagePopupEnabledKey = 'new_message_popup_enabled';
  static const String _lastDatabaseRepairTimeKey = 'last_database_repair_time';

  // 🔴 登录凭证相关，使用用户ID作为前缀（而不是进程ID）
  // 这些方法需要传入用户ID，因为每个用户的配置是独立的
  static String _getRememberPasswordKey(int userId) =>
      'user_${userId}_remember_password';
  static String _getAutoLoginKey(int userId) => 'user_${userId}_auto_login';
  static String _getSavedAccountKey(int userId) =>
      'user_${userId}_saved_account';
  static String _getSavedPasswordKey(int userId) =>
      'user_${userId}_saved_password';
  static String _getLastPageRouteKey(int userId) =>
      'user_${userId}_last_page_route';

  /// 保存登录token（使用加密存储）
  static Future<void> saveToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  /// 获取登录token（从加密存储读取）
  static Future<String?> getToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  /// 保存用户ID
  static Future<void> saveUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_userIdKey, userId);
  }

  /// 获取用户ID
  static Future<int?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_userIdKey);
  }

  /// 保存用户名
  static Future<void> saveUsername(String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, username);
  }

  /// 获取用户名
  static Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  /// 保存用户昵称
  static Future<void> saveFullName(String fullName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fullNameKey, fullName);
  }

  /// 获取用户昵称
  static Future<String?> getFullName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_fullNameKey);
  }

  /// 保存用户邮箱
  static Future<void> setEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_processId}_email', email);
  }

  /// 获取用户邮箱
  static Future<String?> getEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_processId}_email');
  }

  /// 获取用户头像
  static Future<String?> getAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_processId}_avatar');
  }

  /// 保存用户头像
  static Future<void> saveAvatar(String avatar) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_processId}_avatar', avatar);
  }

  /// 保存登录信息
  static Future<void> saveLoginInfo({
    required String token,
    required int userId,
    required String username,
    String? fullName,
    String? avatar,
  }) async {
    await saveToken(token);
    await saveUserId(userId);
    await saveUsername(username);
    if (fullName != null && fullName.isNotEmpty) {
      await saveFullName(fullName);
    }
    if (avatar != null && avatar.isNotEmpty) {
      await saveAvatar(avatar);
    }
    // 保存最近一次登录的用户ID
    await saveLastLoggedInUserId(userId);
    
    // 🔴 添加到已登录账号列表（用于多账号切换）
    await addLoggedInAccount(
      userId: userId,
      username: username,
      fullName: fullName,
      avatar: avatar,
    );
  }

  /// 保存最近一次登录的用户ID
  static Future<void> saveLastLoggedInUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastLoggedInUserIdKey, userId);
    logger.debug('💾 保存最近一次登录的用户ID: $userId, key=$_lastLoggedInUserIdKey');
  }

  /// 获取最近一次登录的用户ID
  static Future<int?> getLastLoggedInUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt(_lastLoggedInUserIdKey);
    logger.debug('📖 读取最近一次登录的用户ID: $userId, key=$_lastLoggedInUserIdKey');
    return userId;
  }

  /// 清除所有登录信息
  static Future<void> clearLoginInfo() async {
    final prefs = await SharedPreferences.getInstance();
    // 从加密存储中删除 token
    await _secureStorage.delete(key: _tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_fullNameKey);
  }

  /// 检查是否已登录
  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// 保存上线提醒列表
  static Future<void> saveOnlineNotifications(
    List<OnlineNotificationModel> notifications,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = notifications.map((n) => n.toJson()).toList();
    await prefs.setString(_onlineNotificationsKey, jsonEncode(jsonList));
  }

  /// 获取上线提醒列表
  static Future<List<OnlineNotificationModel>> getOnlineNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_onlineNotificationsKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList
          .map((json) => OnlineNotificationModel.fromJson(json))
          .toList();
    } catch (e) {
      logger.debug('解析上线提醒失败: $e');
      return [];
    }
  }

  /// 添加一条上线提醒
  static Future<void> addOnlineNotification(
    OnlineNotificationModel notification,
  ) async {
    final notifications = await getOnlineNotifications();

    // 检查是否已存在该用户的通知，如果存在则更新时间
    final index = notifications.indexWhere(
      (n) => n.userId == notification.userId,
    );
    if (index != -1) {
      notifications[index] = notification;
    } else {
      notifications.insert(0, notification);
    }

    // 只保留最近50条
    if (notifications.length > 50) {
      notifications.removeRange(50, notifications.length);
    }

    await saveOnlineNotifications(notifications);
  }

  /// 清空上线提醒
  static Future<void> clearOnlineNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_onlineNotificationsKey);
  }

  /// 删除指定用户的上线提醒
  static Future<void> removeOnlineNotification(int userId) async {
    final notifications = await getOnlineNotifications();

    // 移除指定用户的通知
    notifications.removeWhere((n) => n.userId == userId);

    // 保存更新后的列表
    await saveOnlineNotifications(notifications);
  }

  /// 保存文件存储路径
  static Future<void> saveFileStoragePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fileStoragePathKey, path);
  }

  /// 获取文件存储路径
  static Future<String?> getFileStoragePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_fileStoragePathKey);
  }

  /// 保存消息存储路径
  static Future<void> saveMessageStoragePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_messageStoragePathKey, path);
  }

  /// 获取消息存储路径
  static Future<String?> getMessageStoragePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_messageStoragePathKey);
  }

  /// 保存自动下载开关状态
  static Future<void> saveAutoDownloadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoDownloadEnabledKey, enabled);
  }

  /// 获取自动下载开关状态
  static Future<bool> getAutoDownloadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoDownloadEnabledKey) ?? false;
  }

  /// 保存自动下载文件大小限制（MB）
  static Future<void> saveAutoDownloadSizeMB(int sizeMB) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoDownloadSizeMBKey, sizeMB);
  }

  /// 获取自动下载文件大小限制（MB）
  static Future<int> getAutoDownloadSizeMB() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_autoDownloadSizeMBKey) ?? 30; // 默认30MB
  }

  /// 保存闲置状态开关
  static Future<void> saveIdleStatusEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_idleStatusEnabledKey, enabled);
  }

  /// 获取闲置状态开关
  static Future<bool> getIdleStatusEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_idleStatusEnabledKey) ?? false;
  }

  /// 保存闲置时间（分钟）
  static Future<void> saveIdleMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_idleMinutesKey, minutes);
  }

  /// 获取闲置时间（分钟）
  static Future<int> getIdleMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_idleMinutesKey) ?? 5; // 默认5分钟
  }

  /// 保存语言设置
  static Future<void> saveLanguage(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLanguageKey, languageCode);
  }

  /// 获取语言设置
  static Future<String> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_appLanguageKey) ?? 'zh_CN'; // 默认简体中文
  }

  /// 保存窗口缩放比例
  static Future<void> saveWindowZoom(double zoomFactor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_windowZoomKey, zoomFactor);
  }

  /// 获取窗口缩放比例
  static Future<double> getWindowZoom() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_windowZoomKey) ?? 0.75; // 默认75%
  }

  /// 保存新消息提示音开关
  static Future<void> saveNewMessageSoundEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_newMessageSoundEnabledKey, enabled);
  }

  /// 获取新消息提示音开关
  static Future<bool> getNewMessageSoundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_newMessageSoundEnabledKey) ?? false; // 默认关闭
  }

  /// 保存新消息弹窗显示开关
  static Future<void> saveNewMessagePopupEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_newMessagePopupEnabledKey, enabled);
  }

  /// 获取新消息弹窗显示开关
  static Future<bool> getNewMessagePopupEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_newMessagePopupEnabledKey) ?? true; // 默认开启
  }

  // ============ 聊天偏好设置（置顶、删除，按用户ID隔离） ============

  /// 获取置顶的会话列表（需要用户ID）
  /// 返回格式: {"user_123": timestamp, "group_456": timestamp}
  static Future<Map<String, int>> getPinnedChats(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getPinnedChatsKey(userId);
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return {};
    }
    try {
      final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
      // 转换为 Map<String, int>
      return jsonMap.map((key, value) => MapEntry(key, value as int));
    } catch (e) {
      logger.debug('解析置顶会话配置失败: $e');
      return {};
    }
  }

  /// 保存置顶的会话列表（需要用户ID）
  static Future<void> _savePinnedChats(
    int userId,
    Map<String, int> pinnedChats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getPinnedChatsKey(userId);
    await prefs.setString(key, jsonEncode(pinnedChats));
  }

  /// 添加置顶会话（需要用户ID）
  /// contactKey格式: "user_123" 或 "group_456"
  static Future<void> addPinnedChat(int userId, String contactKey) async {
    final pinnedChats = await getPinnedChats(userId);
    // 使用当前时间戳作为置顶时间
    pinnedChats[contactKey] = DateTime.now().millisecondsSinceEpoch;
    await _savePinnedChats(userId, pinnedChats);
  }

  /// 移除置顶会话（需要用户ID）
  static Future<void> removePinnedChat(int userId, String contactKey) async {
    final pinnedChats = await getPinnedChats(userId);
    pinnedChats.remove(contactKey);
    await _savePinnedChats(userId, pinnedChats);
  }

  /// 检查会话是否置顶（需要用户ID）
  static Future<bool> isChatPinned(int userId, String contactKey) async {
    final pinnedChats = await getPinnedChats(userId);
    return pinnedChats.containsKey(contactKey);
  }

  /// 获取置顶时间戳（需要用户ID）
  static Future<int?> getPinnedTimestamp(int userId, String contactKey) async {
    final pinnedChats = await getPinnedChats(userId);
    return pinnedChats[contactKey];
  }

  /// 获取删除的会话列表（需要用户ID）
  /// 返回格式: ["user_123", "group_456"]
  static Future<Set<String>> getDeletedChats(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDeletedChatsKey(userId);
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return {};
    }
    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList.map((e) => e as String).toSet();
    } catch (e) {
      logger.debug('解析删除会话配置失败: $e');
      return {};
    }
  }

  /// 保存删除的会话列表（需要用户ID）
  static Future<void> _saveDeletedChats(
    int userId,
    Set<String> deletedChats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDeletedChatsKey(userId);
    await prefs.setString(key, jsonEncode(deletedChats.toList()));
  }

  /// 添加删除的会话（需要用户ID）
  /// contactKey格式: "user_123" 或 "group_456"
  static Future<void> addDeletedChat(int userId, String contactKey) async {
    final deletedChats = await getDeletedChats(userId);
    deletedChats.add(contactKey);
    await _saveDeletedChats(userId, deletedChats);
    // 删除时同时取消置顶
    await removePinnedChat(userId, contactKey);
  }

  /// 移除删除标记（恢复会话，需要用户ID）
  static Future<void> removeDeletedChat(int userId, String contactKey) async {
    final deletedChats = await getDeletedChats(userId);
    deletedChats.remove(contactKey);
    await _saveDeletedChats(userId, deletedChats);
  }

  /// 检查会话是否已删除（需要用户ID）
  static Future<bool> isChatDeleted(int userId, String contactKey) async {
    final deletedChats = await getDeletedChats(userId);
    return deletedChats.contains(contactKey);
  }

  /// 清空所有聊天偏好设置（需要用户ID）
  static Future<void> clearChatPreferences(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_getPinnedChatsKey(userId));
    await prefs.remove(_getDeletedChatsKey(userId));
  }

  /// 获取当前登录用户的置顶会话列表
  static Future<Map<String, int>> getPinnedChatsForCurrentUser() async {
    final userId = await getUserId();
    if (userId == null) return {};
    return await getPinnedChats(userId);
  }

  /// 获取当前登录用户的删除会话列表
  static Future<Set<String>> getDeletedChatsForCurrentUser() async {
    final userId = await getUserId();
    if (userId == null) return {};
    return await getDeletedChats(userId);
  }

  /// 为当前登录用户添加置顶会话
  static Future<void> addPinnedChatForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return;
    await addPinnedChat(userId, contactKey);
  }

  /// 为当前登录用户移除置顶会话
  static Future<void> removePinnedChatForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return;
    await removePinnedChat(userId, contactKey);
  }

  /// 检查当前登录用户的会话是否置顶
  static Future<bool> isChatPinnedForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return false;
    return await isChatPinned(userId, contactKey);
  }

  /// 为当前登录用户添加删除的会话
  static Future<void> addDeletedChatForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return;
    await addDeletedChat(userId, contactKey);
  }

  /// 为当前登录用户移除删除标记（恢复会话）
  static Future<void> removeDeletedChatForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return;
    await removeDeletedChat(userId, contactKey);
  }

  /// 检查当前登录用户的会话是否已删除
  static Future<bool> isChatDeletedForCurrentUser(String contactKey) async {
    final userId = await getUserId();
    if (userId == null) return false;
    return await isChatDeleted(userId, contactKey);
  }

  /// 生成联系人Key（用于置顶和删除标识）
  /// 对于用户: "user_123"
  /// 对于群组: "group_456"
  static String generateContactKey({required bool isGroup, required int id}) {
    return isGroup ? 'group_$id' : 'user_$id';
  }

  // ============ 消息免打扰配置（按用户ID和联系人隔离） ============

  /// 获取消息免打扰Key
  static String _getDoNotDisturbKey(int userId, String contactKey) =>
      'user_${userId}_do_not_disturb_$contactKey';

  /// 获取消息免打扰状态
  static Future<bool> getDoNotDisturb(int userId, String contactKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDoNotDisturbKey(userId, contactKey);
    return prefs.getBool(key) ?? false;
  }

  /// 保存消息免打扰状态
  static Future<void> saveDoNotDisturb(
    int userId,
    String contactKey,
    bool doNotDisturb,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDoNotDisturbKey(userId, contactKey);
    await prefs.setBool(key, doNotDisturb);
    logger.debug('💾 保存消息免打扰状态: $doNotDisturb - key: $key');
  }

  /// 清除消息免打扰状态
  static Future<void> clearDoNotDisturb(int userId, String contactKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDoNotDisturbKey(userId, contactKey);
    await prefs.remove(key);
  }

  // ============ 待审核联系人缓存（按用户ID隔离） ============

  static Future<Set<int>> getPendingContacts(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getPendingContactsKey(userId);
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return {};
    }
    try {
      final List<dynamic> data = jsonDecode(jsonString);
      return data
          .map((value) {
            if (value is int) return value;
            return int.tryParse(value.toString()) ?? -1;
          })
          .where((id) => id > 0)
          .toSet();
    } catch (e) {
      logger.debug('解析待审核联系人失败: $e');
      return {};
    }
  }

  static Future<void> _savePendingContacts(
    int userId,
    Set<int> contacts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getPendingContactsKey(userId);
    if (contacts.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(contacts.toList()));
    }
  }

  static Future<void> addPendingContact(int userId, int contactId) async {
    if (userId <= 0 || contactId <= 0) return;
    final contacts = await getPendingContacts(userId);
    if (contacts.add(contactId)) {
      await _savePendingContacts(userId, contacts);
    }
  }

  static Future<void> removePendingContact(int userId, int contactId) async {
    if (userId <= 0 || contactId <= 0) return;
    final contacts = await getPendingContacts(userId);
    if (contacts.remove(contactId)) {
      await _savePendingContacts(userId, contacts);
    }
  }

  static Future<void> syncPendingContacts(
    int userId,
    Iterable<int> contactIds,
  ) async {
    if (userId <= 0) return;
    final normalized = contactIds.where((id) => id > 0).toSet();
    await _savePendingContacts(userId, normalized);
  }

  static Future<Set<int>> getPendingContactsForCurrentUser() async {
    final userId = await getUserId();
    if (userId == null) {
      return {};
    }
    return await getPendingContacts(userId);
  }

  static Future<void> addPendingContactForCurrentUser(int contactId) async {
    final userId = await getUserId();
    if (userId == null) return;
    await addPendingContact(userId, contactId);
  }

  static Future<void> removePendingContactForCurrentUser(int contactId) async {
    final userId = await getUserId();
    if (userId == null) return;
    await removePendingContact(userId, contactId);
  }

  static Future<void> syncPendingContactsForCurrentUser(
    Iterable<int> contactIds,
  ) async {
    final userId = await getUserId();
    if (userId == null) return;
    await syncPendingContacts(userId, contactIds);
  }

  static Future<void> syncPendingContactsFromModels(
    List<ContactModel> contacts, {
    int? currentUserId,
  }) async {
    final userId = currentUserId ?? await getUserId();
    if (userId == null) return;
    final pendingIds = contacts
        .where((c) => c.isPending && c.userId != userId)
        .map((c) => c.friendId)
        .toSet();
    await syncPendingContacts(userId, pendingIds);
  }

  // ============ 登录记住密码和自动登录（按用户ID隔离） ============

  /// 保存记住密码状态（需要用户ID）
  static Future<void> saveRememberPassword(int userId, bool remember) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getRememberPasswordKey(userId);
    await prefs.setBool(key, remember);
    logger.debug('💾 保存记住密码状态: userId=$userId, remember=$remember, key=$key');
  }

  /// 获取记住密码状态（需要用户ID）
  static Future<bool> getRememberPassword(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getRememberPasswordKey(userId);
    final value = prefs.getBool(key) ?? false;
    logger.debug('📖 读取记住密码状态: userId=$userId, value=$value, key=$key');
    return value;
  }

  /// 保存自动登录状态（需要用户ID）
  static Future<void> saveAutoLogin(int userId, bool autoLogin) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getAutoLoginKey(userId);
    await prefs.setBool(key, autoLogin);
    logger.debug('💾 保存自动登录状态: userId=$userId, autoLogin=$autoLogin, key=$key');
  }

  /// 获取自动登录状态（需要用户ID）
  static Future<bool> getAutoLogin(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getAutoLoginKey(userId);
    final value = prefs.getBool(key) ?? false;
    logger.debug('📖 读取自动登录状态: userId=$userId, value=$value, key=$key');
    return value;
  }

  /// 保存账号（使用加密存储，需要用户ID）
  static Future<void> saveSavedAccount(int userId, String account) async {
    await _secureStorage.write(
      key: _getSavedAccountKey(userId),
      value: account,
    );
  }

  /// 获取保存的账号（从加密存储读取，需要用户ID）
  static Future<String?> getSavedAccount(int userId) async {
    return await _secureStorage.read(key: _getSavedAccountKey(userId));
  }

  /// 保存密码（使用加密存储，需要用户ID）
  static Future<void> saveSavedPassword(int userId, String password) async {
    await _secureStorage.write(
      key: _getSavedPasswordKey(userId),
      value: password,
    );
  }

  /// 获取保存的密码（从加密存储读取，需要用户ID）
  static Future<String?> getSavedPassword(int userId) async {
    return await _secureStorage.read(key: _getSavedPasswordKey(userId));
  }

  /// 清除保存的账号密码信息（需要用户ID）
  static Future<void> clearSavedCredentials(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_getRememberPasswordKey(userId));
    await prefs.remove(_getAutoLoginKey(userId));
    // 从安全存储中删除敏感信息
    await _secureStorage.delete(key: _getSavedAccountKey(userId));
    await _secureStorage.delete(key: _getSavedPasswordKey(userId));
  }

  /// 获取最近一次登录用户的记住密码状态
  static Future<bool> getRememberPasswordForLastUser() async {
    final lastUserId = await getLastLoggedInUserId();
    if (lastUserId == null) {
      logger.debug('⚠️ 没有最近一次登录的用户ID，返回false');
      return false;
    }
    return await getRememberPassword(lastUserId);
  }

  /// 获取最近一次登录用户的自动登录状态
  static Future<bool> getAutoLoginForLastUser() async {
    final lastUserId = await getLastLoggedInUserId();
    if (lastUserId == null) {
      logger.debug('⚠️ 没有最近一次登录的用户ID，返回false');
      return false;
    }
    return await getAutoLogin(lastUserId);
  }

  /// 获取最近一次登录用户的保存账号
  static Future<String?> getSavedAccountForLastUser() async {
    final lastUserId = await getLastLoggedInUserId();
    if (lastUserId == null) return null;
    return await getSavedAccount(lastUserId);
  }

  /// 获取最近一次登录用户的保存密码
  static Future<String?> getSavedPasswordForLastUser() async {
    final lastUserId = await getLastLoggedInUserId();
    if (lastUserId == null) return null;
    return await getSavedPassword(lastUserId);
  }

  // ============ 通话设备配置（麦克风、扬声器、摄像头） ============

  /// 获取语音通话设备配置key（按用户ID隔离）
  static Future<String> _getVoiceDeviceConfigKey() async {
    final userId = await getUserId();
    return '${_processId}_voice_device_config_${userId ?? 0}';
  }

  /// 获取视频通话设备配置key（按用户ID隔离）
  static Future<String> _getVideoDeviceConfigKey() async {
    final userId = await getUserId();
    return '${_processId}_video_device_config_${userId ?? 0}';
  }

  /// 保存语音通话设备配置
  /// config 格式: {
  ///   "microphoneDeviceId": "xxx",
  ///   "microphoneVolume": 100.0,
  ///   "speakerDeviceId": "xxx",
  ///   "speakerVolume": 100.0,
  /// }
  static Future<void> saveVoiceCallDeviceConfig(
    Map<String, dynamic> config,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _getVoiceDeviceConfigKey();
    await prefs.setString(key, jsonEncode(config));
    logger.debug('💾 保存语音通话设备配置: $config');
  }

  /// 获取语音通话设备配置
  static Future<Map<String, dynamic>?> getVoiceCallDeviceConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _getVoiceDeviceConfigKey();
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      logger.debug('⚠️ 解析语音通话设备配置失败: $e');
      return null;
    }
  }

  /// 保存视频通话设备配置
  /// config 格式: {
  ///   "microphoneDeviceId": "xxx",
  ///   "microphoneVolume": 100.0,
  ///   "speakerDeviceId": "xxx",
  ///   "speakerVolume": 100.0,
  ///   "cameraDeviceId": "xxx",
  /// }
  static Future<void> saveVideoCallDeviceConfig(
    Map<String, dynamic> config,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _getVideoDeviceConfigKey();
    await prefs.setString(key, jsonEncode(config));
    logger.debug('💾 保存视频通话设备配置: $config');
  }

  /// 获取视频通话设备配置
  static Future<Map<String, dynamic>?> getVideoCallDeviceConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _getVideoDeviceConfigKey();
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      logger.debug('⚠️ 解析视频通话设备配置失败: $e');
      return null;
    }
  }

  /// 清除通话设备配置
  static Future<void> clearCallDeviceConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final voiceKey = await _getVoiceDeviceConfigKey();
    final videoKey = await _getVideoDeviceConfigKey();
    await prefs.remove(voiceKey);
    await prefs.remove(videoKey);
  }

  // ============ 最后访问页面路径（用于自动登录后恢复页面） ============

  /// 保存最后访问的页面路径（需要用户ID）
  static Future<void> saveLastPageRoute(int userId, String route) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getLastPageRouteKey(userId);
    await prefs.setString(key, route);
    logger.debug('💾 保存最后页面路径: userId=$userId, route=$route');
  }

  /// 获取最后访问的页面路径（需要用户ID）
  static Future<String?> getLastPageRoute(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getLastPageRouteKey(userId);
    final route = prefs.getString(key);
    logger.debug('📖 读取最后页面路径: userId=$userId, route=$route');
    return route;
  }

  /// 获取当前用户最后访问的页面路径
  static Future<String?> getLastPageRouteForCurrentUser() async {
    final userId = await getUserId();
    if (userId == null) return null;
    return await getLastPageRoute(userId);
  }

  /// 清除最后访问的页面路径（需要用户ID）
  static Future<void> clearLastPageRoute(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getLastPageRouteKey(userId);
    await prefs.remove(key);
    logger.debug('🗑️ 清除最后页面路径: userId=$userId');
  }

  // ============ 数据库修复相关 ============

  /// 保存最后一次数据库修复时间
  static Future<void> saveLastDatabaseRepairTime(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastDatabaseRepairTimeKey, timestamp);
    logger.debug('💾 保存数据库修复时间: $timestamp');
  }

  /// 获取最后一次数据库修复时间
  static Future<int?> getLastDatabaseRepairTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastDatabaseRepairTimeKey);
    logger.debug('📖 读取数据库修复时间: $timestamp');
    return timestamp;
  }

  /// 清除数据库修复时间（用于重置修复状态）
  static Future<void> clearLastDatabaseRepairTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastDatabaseRepairTimeKey);
    logger.debug('🗑️ 清除数据库修复时间');
  }

  // ============ 首次同步完成标记（按用户ID隔离） ============
  
  static String _getFirstSyncCompletedKey(int userId) => 'user_${userId}_first_sync_completed';
  
  /// 保存首次同步完成状态
  static Future<void> saveFirstSyncCompleted(bool completed) async {
    final userId = await getUserId();
    if (userId == null) return;
    
    final prefs = await SharedPreferences.getInstance();
    final key = _getFirstSyncCompletedKey(userId);
    await prefs.setBool(key, completed);
    logger.debug('💾 保存首次同步完成状态: $completed (userId: $userId)');
  }
  
  /// 获取首次同步完成状态
  static Future<bool> getFirstSyncCompleted() async {
    final userId = await getUserId();
    if (userId == null) return false;
    
    final prefs = await SharedPreferences.getInstance();
    final key = _getFirstSyncCompletedKey(userId);
    final completed = prefs.getBool(key) ?? false;
    logger.debug('📖 读取首次同步完成状态: $completed (userId: $userId)');
    return completed;
  }
  
  /// 清除首次同步完成状态（用于重新同步）
  static Future<void> clearFirstSyncCompleted() async {
    final userId = await getUserId();
    if (userId == null) return;
    
    final prefs = await SharedPreferences.getInstance();
    final key = _getFirstSyncCompletedKey(userId);
    await prefs.remove(key);
    logger.debug('🗑️ 清除首次同步完成状态 (userId: $userId)');
  }

  /// 保存布尔值
  static Future<void> setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// 获取布尔值
  static Future<bool?> getBool(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key);
  }

  // ============ 多账号管理（已登录账号列表） ============

  static const String _loggedInAccountsKey = 'logged_in_accounts';

  /// 已登录账号信息模型
  static Map<String, dynamic> _createAccountInfo({
    required int userId,
    required String username,
    String? fullName,
    String? avatar,
  }) {
    return {
      'userId': userId,
      'username': username,
      'fullName': fullName,
      'avatar': avatar,
      'lastLoginTime': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 添加或更新已登录账号
  static Future<void> addLoggedInAccount({
    required int userId,
    required String username,
    String? fullName,
    String? avatar,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_loggedInAccountsKey);
    
    List<Map<String, dynamic>> accounts = [];
    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        accounts = jsonList.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (e) {
        logger.debug('解析已登录账号列表失败: $e');
      }
    }

    // 检查是否已存在该账号
    final existingIndex = accounts.indexWhere((a) => a['userId'] == userId);
    final accountInfo = _createAccountInfo(
      userId: userId,
      username: username,
      fullName: fullName,
      avatar: avatar,
    );

    if (existingIndex != -1) {
      // 更新已存在的账号信息
      accounts[existingIndex] = accountInfo;
    } else {
      // 添加新账号
      accounts.insert(0, accountInfo);
    }

    // 最多保存10个账号
    if (accounts.length > 10) {
      accounts = accounts.sublist(0, 10);
    }

    await prefs.setString(_loggedInAccountsKey, jsonEncode(accounts));
    logger.debug('💾 已添加/更新登录账号: userId=$userId, username=$username');
  }

  /// 获取已登录账号列表
  static Future<List<LoggedInAccountInfo>> getLoggedInAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_loggedInAccountsKey);
    
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList.map((json) => LoggedInAccountInfo.fromJson(Map<String, dynamic>.from(json))).toList();
    } catch (e) {
      logger.debug('解析已登录账号列表失败: $e');
      return [];
    }
  }

  /// 移除已登录账号
  static Future<void> removeLoggedInAccount(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_loggedInAccountsKey);
    
    if (jsonString == null || jsonString.isEmpty) {
      return;
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      final accounts = jsonList.map((e) => Map<String, dynamic>.from(e)).toList();
      accounts.removeWhere((a) => a['userId'] == userId);
      await prefs.setString(_loggedInAccountsKey, jsonEncode(accounts));
      logger.debug('🗑️ 已移除登录账号: userId=$userId');
    } catch (e) {
      logger.debug('移除已登录账号失败: $e');
    }
  }

  /// 清空所有已登录账号
  static Future<void> clearAllLoggedInAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_loggedInAccountsKey);
    logger.debug('🗑️ 已清空所有登录账号');
  }
}

/// 已登录账号信息
class LoggedInAccountInfo {
  final int userId;
  final String username;
  final String? fullName;
  final String? avatar;
  final int? lastLoginTime;

  LoggedInAccountInfo({
    required this.userId,
    required this.username,
    this.fullName,
    this.avatar,
    this.lastLoginTime,
  });

  factory LoggedInAccountInfo.fromJson(Map<String, dynamic> json) {
    return LoggedInAccountInfo(
      userId: json['userId'] as int,
      username: json['username'] as String,
      fullName: json['fullName'] as String?,
      avatar: json['avatar'] as String?,
      lastLoginTime: json['lastLoginTime'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'fullName': fullName,
    'avatar': avatar,
    'lastLoginTime': lastLoginTime,
  };
}
