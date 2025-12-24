import 'package:flutter/material.dart';
import 'package:youdu/services/api_service.dart';

/// 修改密码对话框
class ChangePasswordDialog extends StatefulWidget {
  final String token; // 添加token参数，避免从Storage读取被其他窗口覆盖的token

  const ChangePasswordDialog({
    super.key,
    required this.token, // token必须传入
  });

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();

  /// 显示修改密码对话框
  static void show(BuildContext context, {required String token}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ChangePasswordDialog(token: token),
    );
  }
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _obscureOldPassword = true;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // 验证输入
  bool _validateInputs() {
    final oldPassword = _oldPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (oldPassword.isEmpty) {
      _showError('请输入旧密码');
      return false;
    }

    if (newPassword.isEmpty) {
      _showError('请输入新密码');
      return false;
    }

    if (newPassword.length < 4 || newPassword.length > 16) {
      _showError('新密码需要4-16位');
      return false;
    }

    if (confirmPassword.isEmpty) {
      _showError('请再次输入新密码');
      return false;
    }

    if (newPassword != confirmPassword) {
      _showError('两次输入的密码不一致');
      return false;
    }

    if (oldPassword == newPassword) {
      _showError('新密码不能与旧密码相同');
      return false;
    }

    return true;
  }

  // 提交修改密码请求
  Future<void> _handleSubmit() async {
    if (!_validateInputs()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // 使用widget中的token，避免从Storage读取被其他窗口覆盖的token
      final token = widget.token;
      if (token.isEmpty) {
        _showError('请先登录');
        return;
      }

      final response = await ApiService.changePassword(
        token: token,
        oldPassword: _oldPasswordController.text,
        newPassword: _newPasswordController.text,
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      if (response['code'] == 0) {
        if (mounted) {
          // 显示成功消息
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('密码修改成功'),
              backgroundColor: Colors.green,
            ),
          );
          // 关闭对话框
          Navigator.pop(context);
        }
      } else {
        _showError(response['message'] ?? '修改密码失败');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _showError('修改密码失败: $e');
    }
  }

  // 显示错误提示
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Container(
        width: 450,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题和关闭按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '修改密码',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF333333),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 说明文字
            const Text(
              '新密码需要4-16位',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 24),
            // 旧密码输入框
            _buildPasswordField(
              label: '旧密码：',
              controller: _oldPasswordController,
              hintText: '请输入旧密码',
              obscureText: _obscureOldPassword,
              onToggleVisibility: () {
                setState(() {
                  _obscureOldPassword = !_obscureOldPassword;
                });
              },
            ),
            const SizedBox(height: 20),
            // 新密码输入框
            _buildPasswordField(
              label: '新密码：',
              controller: _newPasswordController,
              hintText: '请输入新密码',
              obscureText: _obscureNewPassword,
              onToggleVisibility: () {
                setState(() {
                  _obscureNewPassword = !_obscureNewPassword;
                });
              },
            ),
            const SizedBox(height: 20),
            // 确认新密码输入框
            _buildPasswordField(
              label: '确认新密码：',
              controller: _confirmPasswordController,
              hintText: '请再次输入新密码',
              obscureText: _obscureConfirmPassword,
              onToggleVisibility: () {
                setState(() {
                  _obscureConfirmPassword = !_obscureConfirmPassword;
                });
              },
            ),
            const SizedBox(height: 32),
            // 按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 取消按钮
                SizedBox(
                  width: 100,
                  height: 36,
                  child: OutlinedButton(
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFDDDDDD)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(fontSize: 14, color: Color(0xFF666666)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 确定按钮
                SizedBox(
                  width: 100,
                  height: 36,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleSubmit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE5E5E5),
                      disabledForegroundColor: const Color(0xFF999999),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text('确定', style: TextStyle(fontSize: 14)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 构建密码输入框
  Widget _buildPasswordField({
    required String label,
    required TextEditingController controller,
    required String hintText,
    required bool obscureText,
    required VoidCallback onToggleVisibility,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标签
        Row(
          children: [
            const Text(
              '*',
              style: TextStyle(fontSize: 14, color: Color(0xFFFF4D4F)),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 输入框
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFDDDDDD)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            textAlignVertical: TextAlignVertical.center,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: const TextStyle(
                color: Color(0xFFCCCCCC),
                fontSize: 14,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  obscureText ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                  color: const Color(0xFF999999),
                ),
                onPressed: onToggleVisibility,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
