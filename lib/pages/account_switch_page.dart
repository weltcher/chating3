import 'package:flutter/material.dart';
import '../utils/storage.dart';
import '../utils/logger.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/update_checker.dart';
import 'login_page.dart';
import 'mobile_chat_page.dart';
import 'mobile_contacts_page.dart';
import 'mobile_home_page.dart';

/// 已登录账号信息模型（扩展自 LoggedInAccountInfo，添加 isCurrent 属性）
class LoggedInAccount {
  final int userId;
  final String username;
  final String? fullName;
  final String? avatar;
  final bool isCurrent;

  LoggedInAccount({
    required this.userId,
    required this.username,
    this.fullName,
    this.avatar,
    this.isCurrent = false,
  });

  /// 显示名称（优先使用昵称）
  String get displayName => (fullName != null && fullName!.isNotEmpty) ? fullName! : username;

  /// 从 LoggedInAccountInfo 创建
  factory LoggedInAccount.fromAccountInfo(LoggedInAccountInfo info, {bool isCurrent = false}) {
    return LoggedInAccount(
      userId: info.userId,
      username: info.username,
      fullName: info.fullName,
      avatar: info.avatar,
      isCurrent: isCurrent,
    );
  }
}

/// 账号切换页面
class AccountSwitchPage extends StatefulWidget {
  final String? currentToken;
  
  const AccountSwitchPage({super.key, this.currentToken});

  @override
  State<AccountSwitchPage> createState() => _AccountSwitchPageState();
}

class _AccountSwitchPageState extends State<AccountSwitchPage> {
  List<LoggedInAccount> _accounts = [];
  bool _isLoading = true;
  bool _isManageMode = false; // 管理模式（可删除账号）

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  /// 加载已登录的账号列表
  Future<void> _loadAccounts() async {
    try {
      final currentUserId = await Storage.getUserId();
      final accounts = await Storage.getLoggedInAccounts();
      
      setState(() {
        _accounts = accounts.map((account) {
          return LoggedInAccount.fromAccountInfo(
            account,
            isCurrent: account.userId == currentUserId,
          );
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      logger.error('加载账号列表失败: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// 切换到指定账号
  Future<void> _switchToAccount(LoggedInAccount account) async {
    if (account.isCurrent) {
      // 已经是当前账号，直接返回
      Navigator.pop(context);
      return;
    }

    // 显示加载
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 1. 先将当前账号设置为离线
      if (widget.currentToken != null) {
        try {
          await ApiService.updateStatus(token: widget.currentToken!, status: 'offline');
          logger.debug('✅ 当前账号状态已设置为离线');
        } catch (e) {
          logger.debug('⚠️ 设置离线状态失败: $e');
        }
      }

      // 2. 断开WebSocket连接
      logger.debug('🔌 开始断开WebSocket连接...');
      await WebSocketService().disconnect(sendOfflineStatus: false);
      logger.debug('✅ WebSocket连接已断开');

      // 3. 获取目标账号的保存密码
      final savedAccount = await Storage.getSavedAccount(account.userId);
      final savedPassword = await Storage.getSavedPassword(account.userId);

      if (savedAccount == null || savedPassword == null || savedPassword.isEmpty) {
        // 没有保存的密码，跳转到登录页面
        if (mounted) Navigator.pop(context); // 关闭加载
        _showError('账号凭证已过期，请重新登录');
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => LoginPage(
              clearCredentials: false,
              prefillAccount: savedAccount ?? account.username,
            )),
            (route) => false,
          );
        }
        return;
      }

      // 4. 尝试自动登录
      final result = await ApiService.login(
        username: savedAccount,
        password: savedPassword,
      );

      if (result['code'] == 0) {
        // 登录成功
        final token = result['data']['token'];
        final user = result['data']['user'];

        // 保存token和用户信息
        await Storage.saveLoginInfo(
          token: token,
          userId: user['id'],
          username: user['username'],
          fullName: user['full_name'],
          avatar: user['avatar'],
        );

        // 重新初始化日志系统
        await logger.init(userId: user['id'].toString());
        logger.info('📝 日志系统已重新初始化，用户ID: ${user['id']}');

        // 清除所有本地缓存
        logger.info('🗑️ 切换账号成功，开始清除所有本地缓存...');
        MobileChatPage.clearAllCache();
        MobileContactsPage.clearAllCache();
        MobileHomePage.clearAllCache();
        logger.info('✅ 所有本地缓存已清除');

        if (mounted) Navigator.pop(context); // 关闭加载

        // 跳转到主页
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
        }
      } else {
        if (mounted) Navigator.pop(context); // 关闭加载
        _showError(result['message'] ?? '登录失败，请重新登录');
        
        // 登录失败，跳转到登录页面
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => LoginPage(
              clearCredentials: false,
              prefillAccount: savedAccount,
            )),
            (route) => false,
          );
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // 关闭加载
      logger.error('切换账号失败: $e');
      _showError('切换账号失败: $e');
    }
  }

  /// 添加新账号
  void _addNewAccount() async {
    try {
      // 先将当前账号设置为离线
      if (widget.currentToken != null) {
        try {
          await ApiService.updateStatus(token: widget.currentToken!, status: 'offline');
          logger.debug('✅ 当前账号状态已设置为离线');
        } catch (e) {
          logger.debug('⚠️ 设置离线状态失败: $e');
        }
      }

      // 断开WebSocket连接
      logger.debug('🔌 开始断开WebSocket连接...');
      await WebSocketService().disconnect(sendOfflineStatus: false);
      logger.debug('✅ WebSocket连接已断开');

      // 清除当前登录信息（但保留已登录账号列表）
      await Storage.clearLoginInfo();

      // 重置升级检查器
      UpdateChecker().reset();

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginPage(clearCredentials: true)),
          (route) => false,
        );
      }
    } catch (e) {
      logger.error('添加账号失败: $e');
      _showError('添加账号失败: $e');
    }
  }

  /// 删除账号（从已登录列表中移除）
  Future<void> _removeAccount(LoggedInAccount account) async {
    if (account.isCurrent) {
      _showError('无法删除当前登录的账号');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要从列表中移除账号 "${account.displayName}" 吗？\n\n移除后需要重新登录才能使用该账号。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await Storage.removeLoggedInAccount(account.userId);
      await Storage.clearSavedCredentials(account.userId);
      await _loadAccounts();
      _showSuccess('账号已移除');
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leadingWidth: 80,
        leading: Center(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(60, 40),
            ),
            child: const Text('关闭', style: TextStyle(color: Color(0xFF333333), fontSize: 16)),
          ),
        ),
        title: const Icon(Icons.chat_bubble, color: Color(0xFF4A90E2), size: 28),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _isManageMode = !_isManageMode;
              });
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(60, 40),
            ),
            child: Text(
              _isManageMode ? '完成' : '管理',
              style: const TextStyle(color: Color(0xFF333333), fontSize: 16),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const SizedBox(height: 40),
                // 标题
                const Text(
                  '轻触头像以切换账号',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 32),
                // 账号列表
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _accounts.length + 1, // +1 for "添加账号"
                    itemBuilder: (context, index) {
                      if (index < _accounts.length) {
                        return _buildAccountItem(_accounts[index]);
                      } else {
                        return _buildAddAccountItem();
                      }
                    },
                  ),
                ),
              ],
            ),
    );
  }

  /// 构建账号列表项
  Widget _buildAccountItem(LoggedInAccount account) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: _buildAvatar(account),
        title: Text(
          account.displayName,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Color(0xFF333333),
          ),
        ),
        subtitle: Text(
          account.username,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF999999),
          ),
        ),
        trailing: _isManageMode
            ? (account.isCurrent
                ? const Text('当前使用', style: TextStyle(color: Color(0xFF4A90E2), fontSize: 14))
                : IconButton(
                    icon: const Icon(Icons.remove_circle, color: Colors.red),
                    onPressed: () => _removeAccount(account),
                  ))
            : (account.isCurrent
                ? const Text('当前使用', style: TextStyle(color: Color(0xFF4A90E2), fontSize: 14))
                : null),
        onTap: _isManageMode ? null : () => _switchToAccount(account),
      ),
    );
  }

  /// 构建头像
  Widget _buildAvatar(LoggedInAccount account) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: const Color(0xFF4A90E2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: account.avatar != null && account.avatar!.isNotEmpty
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                account.avatar!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return _buildAvatarText(account);
                },
              ),
            )
          : _buildAvatarText(account),
    );
  }

  /// 构建头像文字
  Widget _buildAvatarText(LoggedInAccount account) {
    final displayText = account.displayName;
    final text = displayText.isNotEmpty
        ? (displayText.length >= 2 ? displayText.substring(displayText.length - 2) : displayText)
        : 'U';
    return Center(
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 20,
        ),
      ),
    );
  }

  /// 构建"添加账号"项
  Widget _buildAddAccountItem() {
    if (_isManageMode) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: const Icon(Icons.add, color: Color(0xFF999999), size: 28),
        ),
        title: const Text(
          '添加账号',
          style: TextStyle(
            fontSize: 16,
            color: Color(0xFF333333),
          ),
        ),
        onTap: _addNewAccount,
      ),
    );
  }
}
