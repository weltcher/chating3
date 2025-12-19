import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../utils/logger.dart';
import 'mobile_profile_edit_page.dart';

/// 移动端个人资料查看页面（只读）
class MobileProfileViewPage extends StatefulWidget {
  final String username;
  final String userId;
  final String token;
  final String? fullName;
  final String? gender;
  final String? phone;
  final String? email;
  final String? department;
  final String? position;
  final String? region;
  final String? avatar;
  final String? inviteCode; // 邀请码
  final VoidCallback? onUpdate;

  const MobileProfileViewPage({
    super.key,
    required this.username,
    required this.userId,
    required this.token,
    this.fullName,
    this.gender,
    this.phone,
    this.email,
    this.department,
    this.position,
    this.region,
    this.avatar,
    this.inviteCode,
    this.onUpdate,
  });

  @override
  State<MobileProfileViewPage> createState() => _MobileProfileViewPageState();
}

class _MobileProfileViewPageState extends State<MobileProfileViewPage> {
  String? _currentAvatar;
  String? _currentFullName;
  String? _currentGender;
  String? _currentPhone;
  String? _currentEmail;
  String? _currentDepartment;
  String? _currentPosition;
  String? _currentRegion;

  @override
  void initState() {
    super.initState();
    _currentAvatar = widget.avatar;
    _currentFullName = widget.fullName;
    _currentGender = widget.gender;
    _currentPhone = widget.phone;
    _currentEmail = widget.email;
    _currentDepartment = widget.department;
    _currentPosition = widget.position;
    _currentRegion = widget.region;
  }

  // 转换性别：英文 -> 中文
  String _convertGenderToChinese(String? englishGender) {
    switch (englishGender?.toLowerCase()) {
      case 'male':
        return '男';
      case 'female':
        return '女';
      default:
        return '未设置';
    }
  }

  // 打开编辑页面
  Future<void> _openEditPage() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MobileProfileEditPage(
          username: widget.username,
          userId: widget.userId,
          token: widget.token,
          fullName: _currentFullName,
          gender: _currentGender,
          phone: _currentPhone,
          email: _currentEmail,
          department: _currentDepartment,
          position: _currentPosition,
          region: _currentRegion,
          avatar: _currentAvatar,
          onSave: (updatedData) async {
            // 保存成功后刷新数据
            await _refreshUserInfo();
          },
        ),
      ),
    );

    // 如果编辑页面返回了数据，也刷新
    if (result == true) {
      await _refreshUserInfo();
    }
  }

  // 刷新用户信息
  Future<void> _refreshUserInfo() async {
    try {
      final response = await ApiService.getUserProfile(token: widget.token);
      if (response['code'] == 0 && response['data'] != null) {
        final userData = response['data']['user'];
        if (mounted) {
          setState(() {
            _currentAvatar = userData['avatar'];
            _currentFullName = userData['full_name'];
            _currentGender = userData['gender'];
            _currentPhone = userData['phone'];
            _currentEmail = userData['email'];
            _currentDepartment = userData['department'];
            _currentPosition = userData['position'];
            _currentRegion = userData['region'];
          });
          // 通知外部更新
          widget.onUpdate?.call();
        }
      }
    } catch (e) {
      logger.error('刷新用户信息失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _currentFullName ?? widget.username;
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90E2),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          '个人资料',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _openEditPage,
            child: const Text(
              '编辑',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 头像区域
            _buildAvatarSection(displayName),
            const SizedBox(height: 20),
            // 信息列表
            _buildInfoList(),
          ],
        ),
      ),
    );
  }

  // 头像区域
  Widget _buildAvatarSection(String displayName) {
    // 截断显示名称，超过9个字符显示省略号
    final truncatedName = displayName.length > 9 
        ? '${displayName.substring(0, 9)}...' 
        : displayName;
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 30),
      color: Colors.white,
      child: Center(
        child: Column(
          children: [
            // 头像
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(40),
              ),
              child: _currentAvatar != null && _currentAvatar!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: Image.network(
                        _currentAvatar!,
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildDefaultAvatar(displayName);
                        },
                      ),
                    )
                  : _buildDefaultAvatar(displayName),
            ),
            const SizedBox(height: 12),
            // 姓名（超过9个字符显示省略号）
            Text(
              truncatedName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: Color(0xFF333333),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 默认头像
  Widget _buildDefaultAvatar(String displayName) {
    return Center(
      child: Text(
        displayName.length >= 2
            ? displayName.substring(displayName.length - 2)
            : displayName,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // 信息列表
  Widget _buildInfoList() {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          _buildInfoItem('账号', widget.username),
          _buildInfoItem('性别', _convertGenderToChinese(_currentGender)),
          _buildInfoItem('手机', _currentPhone),
          _buildInfoItem('邮箱', _currentEmail),
          _buildInfoItem('部门', _currentDepartment),
          _buildInfoItem('职位', _currentPosition),
          _buildInfoItem('地区', _currentRegion),
          _buildInviteCodeItem(),
        ],
      ),
    );
  }

  // 单个信息项
  Widget _buildInfoItem(String label, String? value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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

  // 邀请码信息项（带复制按钮）
  Widget _buildInviteCodeItem() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text(
              '邀请码',
              style: TextStyle(
                fontSize: 15,
                color: Color(0xFF666666),
              ),
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                      ? widget.inviteCode!
                      : '未设置',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight:
                        widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                            ? FontWeight.bold
                            : FontWeight.normal,
                    color: widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                        ? const Color(0xFF333333)
                        : const Color(0xFFCCCCCC),
                  ),
                ),
                if (widget.inviteCode != null && widget.inviteCode!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: widget.inviteCode!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('邀请码已复制到剪贴板'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: const Icon(
                      Icons.copy,
                      size: 18,
                      color: Color(0xFF4A90E2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
