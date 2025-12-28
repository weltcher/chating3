import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'mobile_chat_page.dart';

/// 添加个人页面（扫码后跳转）
class AddFriendFromQRPage extends StatefulWidget {
  final String userId; // 从二维码解析出的用户ID
  final String? username; // 从二维码解析出的用户名

  const AddFriendFromQRPage({
    super.key,
    required this.userId,
    this.username,
  });

  @override
  State<AddFriendFromQRPage> createState() => _AddFriendFromQRPageState();
}

class _AddFriendFromQRPageState extends State<AddFriendFromQRPage> {
  bool _isLoading = true;
  bool _isAdding = false;
  Map<String, dynamic>? _userInfo;
  bool _isFriend = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  // 加载用户信息
  Future<void> _loadUserInfo() async {
    try {
      final token = await Storage.getToken();
      if (token == null) {
        setState(() {
          _errorMessage = '未登录';
          _isLoading = false;
        });
        return;
      }

      // 检查用户ID是否为空
      if (widget.userId.isEmpty) {
        setState(() {
          _errorMessage = '无效的二维码';
          _isLoading = false;
        });
        return;
      }

      // 根据用户ID查询用户信息
      final userIdInt = int.tryParse(widget.userId);
      if (userIdInt == null) {
        setState(() {
          _errorMessage = '无效的用户ID';
          _isLoading = false;
        });
        return;
      }

      final response = await ApiService.getUserByID(
        token: token,
        userId: userIdInt,
      );

      if (response['code'] == 0 && response['data'] != null) {
        // 用户信息在 data.user 中
        final userData = response['data']['user'] ?? response['data'];

        // 检查是否已经是好友
        final contactsResponse = await ApiService.getContacts(token: token);
        bool isFriend = false;
        if (contactsResponse['code'] == 0 &&
            contactsResponse['data'] != null) {
          final contacts = contactsResponse['data']['contacts'] as List;
          isFriend = contacts.any((contact) =>
              contact['friend_id'] == userData['id'] &&
              contact['approval_status'] == 'approved');
        }

        setState(() {
          _userInfo = userData;
          _isFriend = isFriend;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = response['message'] ?? '用户不存在';
          _isLoading = false;
        });
      }
    } catch (e) {
      logger.error('加载用户信息失败: $e');
      setState(() {
        _errorMessage = '加载失败: $e';
        _isLoading = false;
      });
    }
  }

  // 添加好友
  Future<void> _addFriend() async {
    if (_isAdding || _userInfo == null) return;

    setState(() {
      _isAdding = true;
    });

    try {
      final token = await Storage.getToken();
      if (token == null) {
        _showError('未登录');
        return;
      }

      final response = await ApiService.addContact(
        token: token,
        friendUsername: _userInfo!['username'],
      );

      if (response['code'] == 0) {
        _showSuccess('好友申请已发送');
        // 延迟返回
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          Navigator.pop(context);
        }
      } else {
        _showError(response['message'] ?? '添加失败');
      }
    } catch (e) {
      logger.error('添加好友失败: $e');
      _showError('添加失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isAdding = false;
        });
      }
    }
  }

  // 发送消息
  Future<void> _sendMessage() async {
    if (_userInfo == null) return;

    final token = await Storage.getToken();
    final currentUserId = await Storage.getUserId();

    if (token == null || currentUserId == null) {
      _showError('未登录');
      return;
    }

    // 跳转到聊天页面
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => MobileChatPage(
            userId: _userInfo!['id'],
            displayName: _userInfo!['full_name'] ?? _userInfo!['username'],
            avatar: _userInfo!['avatar'],
          ),
        ),
      );
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 64,
                        color: Color(0xFF999999),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ],
                  ),
                )
              : _buildUserInfo(),
    );
  }

  Widget _buildUserInfo() {
    if (_userInfo == null) return const SizedBox();

    final username = _userInfo!['username']?.toString() ?? '';
    final fullName = _userInfo!['full_name']?.toString() ?? username;
    final gender = _userInfo!['gender']?.toString();
    final region = _userInfo!['region']?.toString();
    final avatar = _userInfo!['avatar']?.toString();

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // 头像
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: avatar != null && avatar.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            avatar,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return _buildDefaultAvatar(fullName);
                            },
                          ),
                        )
                      : _buildDefaultAvatar(fullName),
                ),
                const SizedBox(height: 16),
                // 昵称
                Text(
                  fullName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 40),
                // 信息列表
                _buildInfoItem('性别', _convertGender(gender)),
                _buildInfoItem('用户名', username),
                if (region != null && region.isNotEmpty)
                  _buildInfoItem('地区', region),
              ],
            ),
          ),
        ),
        // 底部按钮
        Container(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _isAdding
                  ? null
                  : (_isFriend ? _sendMessage : _addFriend),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isAdding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _isFriend ? '发消息' : '加为好友',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoItem(String label, String? value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF666666),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value != null && value.isNotEmpty ? value : '未设置',
              style: TextStyle(
                fontSize: 15,
                color: value != null && value.isNotEmpty
                    ? const Color(0xFF333333)
                    : const Color(0xFFCCCCCC),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar(String name) {
    return Center(
      child: Text(
        name.length >= 2 ? name.substring(name.length - 2) : name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 32,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  String _convertGender(String? gender) {
    switch (gender?.toLowerCase()) {
      case 'male':
        return '男';
      case 'female':
        return '女';
      default:
        return '未设置';
    }
  }
}
