import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youdu/services/api_service.dart';
import 'edit_profile_dialog.dart';

/// 个人基本信息弹窗（简化版-只展示不编辑）
class UserInfoDialog extends StatefulWidget {
  final String username;
  final String userId;
  final String status;
  final String token; // 添加token参数，避免从Storage读取被其他窗口覆盖的token
  final String? fullName;
  final String? gender;
  final String? workSignature;
  final String? phone;
  final String? landline;
  final String? shortNumber;
  final String? email;
  final String? department;
  final String? position;
  final String? region;
  final String? inviteCode; // 用户邀请码
  final VoidCallback? onEdit;
  final bool showEditButton; // 是否显示编辑按钮

  const UserInfoDialog({
    super.key,
    required this.username,
    required this.userId,
    required this.status,
    required this.token, // token必须传入
    this.fullName,
    this.gender,
    this.workSignature,
    this.phone,
    this.landline,
    this.shortNumber,
    this.email,
    this.department,
    this.position,
    this.region,
    this.inviteCode, // 用户邀请码
    this.onEdit,
    this.showEditButton = false, // 默认不显示编辑按钮（用于查看别人资料）
  });

  @override
  State<UserInfoDialog> createState() => _UserInfoDialogState();

  /// 显示个人信息弹窗
  static void show(
    BuildContext context, {
    required String username,
    required String userId,
    required String status,
    required String token, // token必须传入
    String? fullName,
    String? gender,
    String? workSignature,
    String? phone,
    String? landline,
    String? shortNumber,
    String? email,
    String? department,
    String? position,
    String? region,
    String? inviteCode, // 用户邀请码
    VoidCallback? onEdit,
    bool showEditButton = false, // 是否显示编辑按钮（默认不显示，用于查看别人资料）
  }) {
    showDialog(
      context: context,
      builder: (context) => UserInfoDialog(
        username: username,
        userId: userId,
        status: status,
        token: token, // 传递token
        fullName: fullName,
        gender: gender,
        workSignature: workSignature,
        phone: phone,
        landline: landline,
        shortNumber: shortNumber,
        email: email,
        department: department,
        position: position,
        region: region,
        inviteCode: inviteCode, // 传递邀请码
        onEdit: onEdit,
        showEditButton: showEditButton,
      ),
    );
  }
}

class _UserInfoDialogState extends State<UserInfoDialog> {
  @override
  Widget build(BuildContext context) {
    // 获取屏幕宽度
    final screenWidth = MediaQuery.of(context).size.width;
    // PC端使用500px，移动端使用屏幕宽度的90%（最大500px）
    final dialogWidth = screenWidth > 600 ? 500.0 : screenWidth * 0.9;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: dialogWidth,
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 头部：头像、用户名、状态
                _buildHeader(),
                const SizedBox(height: 32),
                // 个人信息列表
                _buildInfoList(),
                // 编辑资料按钮（根据参数决定是否显示）
                if (widget.showEditButton) ...[
                  const SizedBox(height: 32),
                  _buildEditButton(context),
                ],
              ],
            ),
          ),
          // 右上角关闭按钮
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, size: 24, color: Color(0xFF999999)),
              onPressed: () => Navigator.of(context).pop(),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              tooltip: '关闭',
            ),
          ),
        ],
      ),
    );
  }

  // 头部信息
  Widget _buildHeader() {
    // 获取屏幕宽度，判断是否为移动端
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth <= 600;

    return Row(
      children: [
        // 头像
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: const Color(0xFF4A90E2),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.username.length >= 2
                ? widget.username.substring(0, 2)
                : widget.username,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 16),
        // 用户信息
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      () {
                        final displayName = widget.fullName ?? widget.username;
                        return displayName.length > 9
                            ? '${displayName.substring(0, 9)}...'
                            : displayName;
                      }(),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                  // 移动端不显示小人头像
                  if (!isMobile) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.person,
                      size: 18,
                      color: Color(0xFF4A90E2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _getStatusText(widget.status),
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 信息列表（只显示签名、部门、职位、地区）
  Widget _buildInfoList() {
    return Column(
      children: [
        _buildInfoItem('签名：', widget.workSignature),
        _buildInfoItem('部门：', widget.department),
        _buildInfoItem('职位：', widget.position),
        _buildInfoItem('地区：', widget.region),
        // 邀请码项（带复制按钮）
        _buildInviteCodeItem(),
      ],
    );
  }

  // 邀请码信息项（带复制按钮）
  Widget _buildInviteCodeItem() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '邀请码：',
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Text(
                  widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                      ? widget.inviteCode!
                      : '- 未填写 -',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                        ? FontWeight.bold // 邀请码使用粗体
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
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      child: const Icon(
                        Icons.copy,
                        size: 16,
                        color: Color(0xFF4A90E2),
                      ),
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

  // 单个信息项
  Widget _buildInfoItem(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
            child: Text(
              value != null && value.isNotEmpty ? value : '- 未填写 -',
              style: TextStyle(
                fontSize: 14,
                color: value != null && value.isNotEmpty
                    ? const Color(0xFF333333)
                    : const Color(0xFFCCCCCC),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 编辑资料按钮
  Widget _buildEditButton(BuildContext context) {
    return Center(
      child: OutlinedButton.icon(
        onPressed: () async {
          // 打开编辑个人资料弹窗
          EditProfileDialog.show(
            context,
            username: widget.username,
            userId: widget.userId,
            token: widget.token, // 传递token
            fullName: widget.fullName,
            gender: widget.gender,
            phone: widget.phone,
            landline: widget.landline,
            shortNumber: widget.shortNumber,
            email: widget.email,
            department: widget.department,
            position: widget.position,
            region: widget.region,
            inviteCode: widget.inviteCode, // 传递邀请码
            onSave: (data) async {
              // 调用API保存数据
              await _saveProfileData(context, data);
            },
          );
        },
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('编辑资料', style: TextStyle(fontSize: 14)),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF4A90E2),
          side: const BorderSide(color: Color(0xFF4A90E2)),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
    );
  }

  // 保存个人资料数据
  Future<void> _saveProfileData(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    try {
      // 检查是否只包含头像更新（头像已在上传时保存）
      final isAvatarOnly = data.length == 1 && data.containsKey('avatar');

      if (isAvatarOnly) {
        // 如果只是头像更新，直接刷新数据，不重复保存，不关闭弹窗
        widget.onEdit?.call();
        return;
      }

      // 使用widget中的token，避免从Storage读取被其他窗口覆盖的token
      final token = widget.token;
      if (token.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先登录')));
        }
        return;
      }

      // 显示加载中
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      // 调用API更新个人信息
      final response = await ApiService.updateUserProfile(
        token: token,
        fullName: data['full_name'],
        gender: data['gender'],
        phone: data['phone'],
        landline: data['landline'],
        shortNumber: data['short_number'],
        department: data['department'],
        position: data['position'],
        region: data['region'],
      );

      // 关闭加载提示
      if (context.mounted) Navigator.pop(context);

      if (response['code'] == 0) {
        // 关闭个人信息弹窗
        if (context.mounted) Navigator.pop(context);

        // 显示成功提示
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('个人信息更新成功')));
        }

        // 调用回调刷新数据
        widget.onEdit?.call();
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '更新失败')),
          );
        }
      }
    } catch (e) {
      // 关闭加载提示
      if (context.mounted) Navigator.pop(context);

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    }
  }

  // 获取状态文本
  String _getStatusText(String status) {
    switch (status) {
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
}
