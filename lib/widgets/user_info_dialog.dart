import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youdu/services/api_service.dart';
import 'edit_profile_dialog.dart';
import '../utils/logger.dart';

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
  final String? avatar;
  final String? inviteCode; // 用户邀请码
  final VoidCallback? onEdit;

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
    this.avatar,
    this.inviteCode, // 用户邀请码
    this.onEdit,
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
    String? avatar,
    String? inviteCode, // 用户邀请码
    VoidCallback? onEdit,
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
        avatar: avatar,
        inviteCode: inviteCode, // 传递邀请码
        onEdit: onEdit,
      ),
    );
  }
}

class _UserInfoDialogState extends State<UserInfoDialog> {
  String? _currentAvatar; // 当前头像URL

  @override
  void initState() {
    super.initState();
    _currentAvatar = widget.avatar; // 初始化时使用传入的头像
  }

  @override
  void didUpdateWidget(UserInfoDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果头像参数更新了，同步更新状态
    if (oldWidget.avatar != widget.avatar) {
      _currentAvatar = widget.avatar;
    }
  }

  // 辅助方法：截断显示名称，超过9个字符添加省略号
  String _truncateDisplayName(String name) {
    if (name.length > 9) {
      return '${name.substring(0, 9)}...';
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Container(
        width: 480,
        height: 600, // 设置固定高度，确保对话框不会无限扩展
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：头像、用户名、状态
            _buildHeader(),
            const SizedBox(height: 32),
            // 个人信息列表 - 添加滚动功能
            Flexible(
              child: SingleChildScrollView(
                child: _buildInfoList(),
              ),
            ),
            const SizedBox(height: 32),
            // 编辑资料按钮
            _buildEditButton(context),
          ],
        ),
      ),
    );
  }

  // 头部信息
  Widget _buildHeader() {
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
          child: _currentAvatar != null && _currentAvatar!.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _currentAvatar!,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return _buildDefaultAvatar();
                    },
                  ),
                )
              : _buildDefaultAvatar(),
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
                      _truncateDisplayName(widget.fullName ?? widget.username),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF333333),
                      ),
                      overflow: TextOverflow.visible,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.person, size: 18, color: Color(0xFF4A90E2)),
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

  // 信息列表
  Widget _buildInfoList() {
    return Column(
      children: [
        _buildSignatureItem('签名', widget.workSignature),
        _buildInfoItem('性别', _getGenderText(widget.gender)),
        _buildInfoItem('手机', widget.phone),
        _buildInfoItem('座机', widget.landline),
        _buildInfoItem('短号', widget.shortNumber),
        _buildInfoItem('邮箱', widget.email),
        _buildInfoItem('部门', widget.department),
        _buildInfoItem('职位', widget.position),
        _buildInfoItem('地区', widget.region),
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
              '邀请码',
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Text(
                  widget.inviteCode != null && widget.inviteCode!.isNotEmpty
                      ? widget.inviteCode!
                      : '- 未填-',
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

  // 签名信息项（完整显示所有内容）
  Widget _buildSignatureItem(String label, String? value) {
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
              value != null && value.isNotEmpty ? value : '- 未填-',
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
              value != null && value.isNotEmpty ? value : '- 未填-',
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
            avatar: _currentAvatar ?? widget.avatar, // 使用当前头像状态
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
      logger.debug('📝 开始保存用户资料到服务器...');
      logger.debug('   接收到的数据: $data');
      logger.debug('   头像字段: ${data['avatar']}');

      // 检查是否只包含头像更新（头像已在上传时保存）
      final isAvatarOnly = data.length == 1 && data.containsKey('avatar');

      if (isAvatarOnly) {
        // 如果只是头像更新，直接更新本地头像并刷新数据，不重复保存，不关闭弹窗
        final newAvatar = data['avatar'] as String?;
        logger.debug('🎭 [头像更新] 检测到仅头像更新，新头像URL: $newAvatar');

        // 更新本地头像状态
        setState(() {
          _currentAvatar = newAvatar;
        });
        logger.debug('🎭 [头像更新] 已更新本地头像状态');

        logger.debug('🎭 [头像更新] 准备调用 onEdit 回调');
        logger.debug(
          '🎭 [头像更新] 调用 onEdit 前 context.mounted: ${context.mounted}',
        );

        try {
          widget.onEdit?.call();
          logger.debug('🎭 [头像更新] onEdit 回调调用完成');
        } catch (e, stackTrace) {
          logger.debug('❌ [头像更新] onEdit 回调调用异常: $e');
          logger.debug('❌ [头像更新] 异常堆栈: $stackTrace');
        }

        logger.debug(
          '🎭 [头像更新] 调用 onEdit 后 context.mounted: ${context.mounted}',
        );
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

      // 显示加载提示
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      // 调用API更新个人信息
      logger.debug('🌐 调用API更新个人信息...');
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
        avatar: data['avatar'],
      );

      logger.debug('📦 API响应: $response');

      // 关闭加载提示
      if (context.mounted) Navigator.pop(context);

      if (response['code'] == 0) {
        logger.debug('个人信息更新成功');
        logger.debug('   返回的用户信息: ${response['data']}');

        // 更新本地头像状态（如果头像有更新）
        if (data['avatar'] != null) {
          final newAvatar = data['avatar'] as String?;
          if (mounted) {
            setState(() {
              _currentAvatar = newAvatar;
            });
            logger.debug('🎭 [头像更新] UserInfoDialog 头像已更新: $newAvatar');
          }
        }

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
        logger.debug('更新失败: ${response['message']}');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '更新失败')),
          );
        }
      }
    } catch (e) {
      logger.debug('保存异常: $e');
      // 关闭加载提示
      if (context.mounted) Navigator.pop(context);

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    }
  }

  // 默认头像
  Widget _buildDefaultAvatar() {
    return Text(
      widget.username.length >= 2
          ? widget.username.substring(0, 2)
          : widget.username,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w500,
      ),
    );
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

  // 获取性别文本
  String _getGenderText(String? gender) {
    switch (gender) {
      case 'male':
        return '男';
      case 'female':
        return '女';
      case 'other':
        return '其他';
      default:
        return '- 未填-';
    }
  }
}
