import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/local_database_service.dart';
import '../services/websocket_service.dart';
import '../services/update_checker.dart';
import '../services/notification_service.dart';
import '../services/jpush_service.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';
import '../utils/app_localizations.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/mobile_customer_service_dialog.dart';
import 'mobile_profile_view_page.dart';
import 'mobile_profile_edit_page.dart';
import 'mobile_favorites_page.dart';
import 'mobile_settings_page.dart';
import 'mobile_chat_page.dart';
import 'mobile_contacts_page.dart';
import 'mobile_home_page.dart';
import 'my_qr_code_page.dart';
import 'login_page.dart';
import 'account_switch_page.dart';

/// 移动端"我的"页面
class MobileProfilePage extends StatefulWidget {
  final String userDisplayName;
  final String username;
  final String userId;
  final String? userAvatar;
  final String? fullName;
  final String? gender;
  final String? phone;
  final String? email;
  final String? department;
  final String? position;
  final String? region;
  final String? workSignature;
  final String? inviteCode; // 邀请码
  final String userStatus;
  final String? token;
  final VoidCallback onUserInfoUpdate;
  final VoidCallback? onChatListNeedRefresh; // 通知主页面刷新聊天列表

  const MobileProfilePage({
    super.key,
    required this.userDisplayName,
    required this.username,
    required this.userId,
    this.userAvatar,
    this.fullName,
    this.gender,
    this.phone,
    this.email,
    this.department,
    this.position,
    this.region,
    this.workSignature,
    this.inviteCode, // 邀请码
    required this.userStatus,
    this.token,
    required this.onUserInfoUpdate,
    this.onChatListNeedRefresh,
  });

  @override
  State<MobileProfilePage> createState() => _MobileProfilePageState();
}

class _MobileProfilePageState extends State<MobileProfilePage> {
  late String _workSignature;
  late String _userStatus;

  @override
  void initState() {
    super.initState();
    _workSignature = widget.workSignature ?? '';
    _userStatus = widget.userStatus;
  }

  @override
  void didUpdateWidget(MobileProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.workSignature != oldWidget.workSignature) {
      setState(() {
        _workSignature = widget.workSignature ?? '';
      });
    }
    if (widget.userStatus != oldWidget.userStatus) {
      setState(() {
        _userStatus = widget.userStatus;
      });
    }
  }

  // 显示我的二维码
  void _showMyQRCode() {
    // 检查邀请码是否存在
    if (widget.inviteCode == null || widget.inviteCode!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('邀请码未生成，请联系管理员'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MyQRCodePage(
          fullName: widget.fullName ?? widget.username,
          avatar: widget.userAvatar,
          region: widget.region,
          inviteCode: widget.inviteCode!,
          username: widget.username,
        ),
      ),
    );
  }

  void _showProfileEdit() async {
    try {
      final token = widget.token;
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('获取用户信息失败')));
        }
        return;
      }

      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MobileProfileViewPage(
              username: widget.username,
              userId: widget.userId,
              token: token,
              fullName: widget.fullName,
              gender: widget.gender,
              phone: widget.phone,
              email: widget.email,
              department: widget.department,
              position: widget.position,
              region: widget.region,
              avatar: widget.userAvatar,
              inviteCode: widget.inviteCode, // 传递邀请码
              onUpdate: () {
                // 保存成功后重新加载用户信息
                widget.onUserInfoUpdate();
              },
            ),
          ),
        );
      }
    } catch (e) {
      logger.error('打开个人资料失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('打开个人资料失败')));
      }
    }
  }

  // 切换账号 - 跳转到账号切换页面
  void _handleSwitchAccount() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountSwitchPage(currentToken: widget.token),
      ),
    );
  }

  // 打开文件传输助手
  void _openFileAssistant() async {
    try {
      final userId = await Storage.getUserId();
      if (userId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('获取用户信息失败')),
          );
        }
        return;
      }

      // 检查文件传输助手是否已存在于最近联系人列表中
      await _ensureFileAssistantInRecentContacts(userId);

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MobileChatPage(
              userId: userId, // 文件传输助手使用自己的ID
              displayName: '文件传输助手',
              isGroup: false,
              isFileAssistant: true, // 标记为文件传输助手
              avatar: null,
            ),
          ),
        );
      }
    } catch (e) {
      logger.error('打开文件传输助手失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打开文件传输助手失败')),
        );
      }
    }
  }

  // 确保文件传输助手存在于最近联系人列表中
  Future<void> _ensureFileAssistantInRecentContacts(int userId) async {
    try {
      // 🔴 步骤1：检查文件传输助手是否被标记为已删除，如果是则恢复它
      final contactKey = Storage.generateContactKey(
        isGroup: false,
        id: userId,
      );
      final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
      if (isDeleted) {
        logger.debug('🔄 文件传输助手已被删除，现在恢复: $contactKey');
        await Storage.removeDeletedChatForCurrentUser(contactKey);
        logger.debug('✅ 文件传输助手已恢复，会话将重新显示在最近联系人列表中');
      }
      
      final localDb = LocalDatabaseService();
      
      // 🔴 步骤2：检查是否已有文件传输助手消息
      final existingMessages = await localDb.getFileAssistantMessages(userId: userId, limit: 1);
      
      if (existingMessages.isEmpty) {
        // 如果没有消息记录，创建一个占位消息
        final now = DateTime.now();
        final placeholderMessage = {
          'user_id': userId,
          'content': '欢迎使用文件传输助手',
          'message_type': 'text',
          'sender_id': userId,
          'receiver_id': userId,
          'sender_name': await Storage.getUsername() ?? '',
          'receiver_name': '文件传输助手',
          'sender_avatar': await Storage.getAvatar() ?? '',
          'receiver_avatar': '',
          'created_at': now.toIso8601String(),
          'is_read': true,
          'status': 'normal', // 添加status字段，确保不会被过滤
        };
        
        await localDb.insertFileAssistantMessage(placeholderMessage);
        logger.debug('✅ 已创建文件传输助手占位消息，将出现在最近联系人列表中');
        
        // 🔴 通知主页面刷新聊天列表
        widget.onChatListNeedRefresh?.call();
        logger.debug('🔄 已通知主页面刷新聊天列表');
      } else {
        logger.debug('✅ 文件传输助手已存在消息记录');
      }
    } catch (e) {
      logger.error('确保文件传输助手在最近联系人列表中失败: $e');
      // 即使失败也不影响打开文件传输助手
    }
  }

  // 登出 - 清理用户数据并跳转到登录页面
  void _handleLogout() async {
    try {
      // 先设置用户状态为离线
      final token = widget.token;
      if (token != null) {
        try {
          await ApiService.updateStatus(token: token, status: 'offline');
          logger.debug('✅ 用户状态已设置为离线');
        } catch (e) {
          logger.debug('⚠️ 设置离线状态失败: $e');
          // 即使设置状态失败也继续登出流程
        }
      }

      // 🔴 断开WebSocket连接（非常重要！避免残留连接）
      logger.debug('🔌 开始断开WebSocket连接...');
      await WebSocketService().disconnect(sendOfflineStatus: false);
      logger.debug('✅ WebSocket连接已断开');
      
      // 🔴 删除极光推送别名（停止接收推送）
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await JPushService.instance.deleteAlias();
          logger.debug('📱 [JPush] 删除别名成功');
        } catch (e) {
          logger.error('📱 [JPush] 删除别名失败: $e');
        }
      }

      // 清除登录信息（token、userId、username）
      // 先获取当前用户ID，用于清除该用户的保存密码
      final currentUserId = await Storage.getUserId();
      await Storage.clearLoginInfo();

      // 移动端：清除保存的账号密码，这样下次打开应用会进入登录页面
      if (currentUserId != null) {
        await Storage.clearSavedCredentials(currentUserId);
        logger.debug('✅ 已清除保存的账号密码');
      }

      // 重置升级检查器
      UpdateChecker().reset();
      logger.debug('🔄 已重置升级检查器');

      // 🔴 清除所有本地缓存
      logger.info('🗑️ 登出，开始清除所有本地缓存...');
      MobileChatPage.clearAllCache();
      MobileContactsPage.clearAllCache();
      MobileHomePage.clearAllCache();
      
      // 🔴 清除Flutter图片缓存（避免切换账号后显示旧头像）
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      logger.info('🖼️ Flutter图片缓存已清除');
      
      logger.info('✅ 所有本地缓存已清除');

      // 跳转到登录页面
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginPage(clearCredentials: true)),
          (route) => false,
        );
      }
    } catch (e) {
      logger.error('登出失败: $e');
    }
  }

  // 显示编辑工作签名对话框
  void _showEditWorkSignatureDialog() {
    final controller = TextEditingController(text: _workSignature);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑工作签名'),
        content: TextField(
          controller: controller,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '请输入工作签名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final newSignature = controller.text.trim();
              Navigator.pop(dialogContext);
              await _updateWorkSignature(newSignature);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 更新工作签名
  Future<void> _updateWorkSignature(String newSignature) async {
    try {
      final token = widget.token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      // 显示加载
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      // 调用API
      final response = await ApiService.updateWorkSignature(
        token: token,
        workSignature: newSignature,
      );

      // 关闭加载
      if (mounted) Navigator.pop(context);

      if (response['code'] == 0) {
        // 更新本地状态
        setState(() {
          _workSignature = newSignature;
        });

        // 触发父组件更新
        widget.onUserInfoUpdate();

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('工作签名更新成功')));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '更新失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // 关闭加载
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    }
  }

  // 显示状态选择对话框
  void _showStatusSelectionDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Container(
          width: 200,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStatusOption(
                dialogContext,
                'online',
                '在线',
                const Color(0xFF52C41A),
              ),
              _buildStatusOption(
                dialogContext,
                'busy',
                '忙碌',
                const Color(0xFFFF4D4F),
              ),
              _buildStatusOption(
                dialogContext,
                'away',
                '离开',
                const Color(0xFFFAAD14),
              ),
              _buildStatusOption(
                dialogContext,
                'offline',
                '离线',
                const Color(0xFFBFBFBF),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建状态选项
  Widget _buildStatusOption(
    BuildContext dialogContext,
    String statusValue,
    String statusLabel,
    Color statusColor,
  ) {
    final isSelected = _userStatus == statusValue;

    return InkWell(
      onTap: () {
        Navigator.pop(dialogContext);
        _updateStatus(statusValue);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                statusLabel,
                style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              ),
            ),
            if (isSelected)
              const Icon(Icons.check, size: 18, color: Color(0xFF52C41A)),
          ],
        ),
      ),
    );
  }

  // 更新状态
  Future<void> _updateStatus(String newStatus) async {
    if (newStatus == _userStatus) return;

    try {
      final token = widget.token;
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      // 显示加载
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      // 调用API
      final response = await ApiService.updateStatus(
        token: token,
        status: newStatus,
      );

      // 关闭加载
      if (mounted) Navigator.pop(context);

      if (response['code'] == 0) {
        // 更新本地状态
        setState(() {
          _userStatus = newStatus;
        });

        // 触发父组件更新
        widget.onUserInfoUpdate();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('状态已更新: ${_getStatusText(newStatus)}')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '更新状态失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // 关闭加载
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新状态失败: $e')));
      }
    }
  }

  // 获取状态文本
  String _getStatusText(String statusValue) {
    switch (statusValue) {
      case 'online':
        return '在线';
      case 'busy':
        return '忙碌';
      case 'away':
        return '离开';
      case 'offline':
        return '离线';
      default:
        return '在线';
    }
  }

  // 获取状态颜色
  Color _getStatusColor(String statusValue) {
    switch (statusValue) {
      case 'online':
        return const Color(0xFF52C41A); // 绿色
      case 'busy':
        return const Color(0xFFFF4D4F); // 红色
      case 'away':
        return const Color(0xFFFAAD14); // 橙色
      case 'offline':
        return const Color(0xFFBFBFBF); // 灰色
      default:
        return const Color(0xFF52C41A);
    }
  }

  // 辅助方法：截断显示名称，超过9个字符添加省略号
  String _truncateDisplayName(String name) {
    if (name.length > 9) {
      return '${name.substring(0, 9)}...';
    }
    return name;
  }

  // 构建显示名称
  String _buildDisplayName() {
    final displayName = widget.userDisplayName.trim();
    final username = widget.username.trim();

    // 如果显示名称为空，使用 "Unknown"
    if (displayName.isEmpty) {
      return 'Unknown($username)';
    }

    // 如果显示名称和用户名相同，只显示一个，并截断
    if (displayName == username) {
      return _truncateDisplayName(displayName);
    }

    // 否则显示 "显示名称(用户名)" 格式，对显示名称进行截断
    return '${_truncateDisplayName(displayName)}($username)';
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Container(
      color: const Color(0xFFEEF1F6),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            // 用户信息大卡片（包含用户信息和编辑签名）
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // 用户信息区域
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        // 左侧信息
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 公司/组织名称（可选）
                              if (widget.department != null &&
                                  widget.department!.isNotEmpty)
                                Text(
                                  widget.department!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              if (widget.department != null &&
                                  widget.department!.isNotEmpty)
                                const SizedBox(height: 8),
                              // 用户显示名称和用户名
                              Text(
                                _buildDisplayName(),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 6),
                              // 登录状态
                              Text(
                                '已登录',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        // 右侧头像
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A90E2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child:
                              widget.userAvatar != null &&
                                  widget.userAvatar!.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    widget.userAvatar!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      // 🔴 优先使用昵称（fullName），如果为空则使用用户名
                                      final displayText = (widget.fullName != null && widget.fullName!.isNotEmpty)
                                          ? widget.fullName!
                                          : widget.username;
                                      return Center(
                                        child: Text(
                                          displayText.isNotEmpty
                                              ? (displayText.length >= 2 
                                                  ? displayText.substring(displayText.length - 2) 
                                                  : displayText)
                                              : 'U',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 28,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                )
                              : Center(
                                  child: Text(
                                    // 🔴 优先使用昵称（fullName），如果为空则使用用户名
                                    () {
                                      final displayText = (widget.fullName != null && widget.fullName!.isNotEmpty)
                                          ? widget.fullName!
                                          : widget.username;
                                      return displayText.isNotEmpty
                                          ? (displayText.length >= 2 
                                              ? displayText.substring(displayText.length - 2) 
                                              : displayText)
                                          : 'U';
                                    }(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 28,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  // 分隔线
                  Divider(height: 1, color: Colors.grey[200]),
                  // 编辑签名区域
                  InkWell(
                    onTap: _showEditWorkSignatureDialog,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.edit_outlined,
                            color: Colors.grey[600],
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _workSignature.isNotEmpty
                                  ? _workSignature
                                  : '点击此处编辑签名',
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: _workSignature.isNotEmpty
                                    ? Colors.black87
                                    : Colors.grey[600],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 菜单列表 - 第一组
            Container(
              color: Colors.white,
              child: Column(
                children: [
                  _buildMenuItem(
                    icon: Icons.person,
                    title: i18n.translate('view_profile'),
                    onTap: _showProfileEdit,
                  ),
                  _buildMenuItem(
                    icon: Icons.qr_code,
                    title: i18n.translate('my_qr_code'),
                    onTap: _showMyQRCode,
                  ),
                  _buildMenuItem(
                    icon: Icons.folder_outlined,
                    iconColor: const Color(0xFF52C41A),
                    title: i18n.translate('file_transfer_assistant'),
                    onTap: _openFileAssistant,
                  ),
                  _buildMenuItem(
                    icon: Icons.access_time,
                    title: i18n.translate('status'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _getStatusColor(_userStatus),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _getStatusText(_userStatus),
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: Colors.grey,
                        ),
                      ],
                    ),
                    onTap: _showStatusSelectionDialog,
                  ),
                  _buildMenuItem(
                    icon: Icons.star_outline,
                    title: i18n.translate('favorites'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const MobileFavoritesPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 菜单列表 - 第二组
            Container(
              color: Colors.white,
              child: Column(
                children: [
                  _buildMenuItem(
                    icon: Icons.settings,
                    title: i18n.translate('settings'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const MobileSettingsPage(),
                        ),
                      );
                    },
                  ),
                  // 🔴 通知设置入口（仅Android显示）
                  if (Platform.isAndroid)
                    _buildMenuItem(
                      icon: Icons.notifications_active_outlined,
                      title: '通知设置',
                      onTap: () async {
                        await NotificationService.instance.openNotificationSettings();
                      },
                    ),
                  _buildMenuItem(
                    icon: Icons.headset_mic_outlined,
                    title: i18n.translate('customer_service'),
                    onTap: () {
                      MobileCustomerServiceDialog.show(context);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.lock_outline,
                    title: i18n.translate('change_password'),
                    onTap: () {
                      if (widget.token != null) {
                        ChangePasswordDialog.show(
                          context,
                          token: widget.token!,
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 切换账号按钮
            Container(
              color: Colors.white,
              child: _buildMenuItem(
                icon: Icons.swap_horiz,
                title: i18n.translate('switch_account'),
                iconColor: const Color(0xFF4A90E2),
                onTap: _handleSwitchAccount,
              ),
            ),
            const SizedBox(height: 8),
            // 登出按钮（退出应用）
            Container(
              color: Colors.white,
              child: _buildMenuItem(
                icon: Icons.logout,
                title: i18n.translate('logout'),
                iconColor: Colors.red,
                onTap: _handleLogout,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? titleColor,
    Color iconColor = const Color(0xFF4A90E2),
    Widget? trailing,
    bool isLast = false,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: Colors.grey[300]!, width: 1)),
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(title, style: TextStyle(color: titleColor)),
        subtitle: subtitle != null ? Text(subtitle) : null,
        trailing:
            trailing ??
            const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
        onTap: onTap,
      ),
    );
  }
}
