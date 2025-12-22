import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/logger.dart';

class ResetPasswordPage extends StatefulWidget {
  final String contact;
  final String verifyCode;

  const ResetPasswordPage({
    super.key,
    required this.contact,
    required this.verifyCode,
  });

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _canConfirm = false;
  String? _errorMessage;

  // 统一的标签样式
  static const TextStyle _labelStyle = TextStyle(
    fontSize: 14,
    color: Color(0xFF333333),
    fontWeight: FontWeight.w500,
    height: 1.0,
    letterSpacing: 0,
  );

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_checkCanConfirm);
    _confirmPasswordController.addListener(_checkCanConfirm);
  }

  void _checkCanConfirm() {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    setState(() {
      // 检查两次密码是否一致
      if (password.isNotEmpty && confirmPassword.isNotEmpty) {
        if (password == confirmPassword) {
          _canConfirm = true;
          _errorMessage = null;
        } else {
          _canConfirm = false;
          _errorMessage = '两次密码输入不一致';
        }
      } else {
        _canConfirm = false;
        if (password.isNotEmpty && confirmPassword.isNotEmpty) {
          _errorMessage = null;
        }
      }
    });
  }

  // 处理重置密码
  Future<void> _handleResetPassword() async {
    logger.debug('=== 重置密码 ===');
    logger.debug('联系方式: ${widget.contact}');
    logger.debug('验证码: ${widget.verifyCode}');

    try {
      final result = await ApiService.forgotPassword(
        account: widget.contact,
        code: widget.verifyCode,
        newPassword: _passwordController.text,
      );

      logger.debug('重置密码响应: $result');

      if (result['code'] == 0) {
        // 重置成功，显示提示并返回登录页
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('密码重置成功'),
              content: const Text('请使用新密码登录'),
              actions: [
                TextButton(
                  onPressed: () {
                    // 返回到登录页（关闭所有页面）
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        }
      } else {
        // 重置失败，显示错误信息
        if (mounted) {
          setState(() {
            _errorMessage = result['message'] ?? '密码重置失败，请重试';
          });
        }
      }
    } catch (e) {
      logger.error('重置密码异常: $e');
      if (mounted) {
        setState(() {
          _errorMessage = '网络错误，请检查网络连接';
        });
      }
    }
  }

  @override
  void dispose() {
    _passwordController.removeListener(_checkCanConfirm);
    _confirmPasswordController.removeListener(_checkCanConfirm);
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/登录/背景图.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: _buildResetPasswordForm(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResetPasswordForm() {
    return Container(
      width: 400,
      constraints: const BoxConstraints(maxWidth: 400),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            const Text(
              '重置密码',
              style: TextStyle(
                fontSize: 24,
                color: Color(0xFF333333),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            // 说明文字
            const Text(
              '请设置新密码',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF666666),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            // 新密码输入框
            _buildPasswordField(),
            const SizedBox(height: 20),
            // 确认密码输入框
            _buildConfirmPasswordField(),
            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF0000)),
              ),
            ],
            const SizedBox(height: 40),
            // 确认按钮
            _buildConfirmButton(),
            const SizedBox(height: 16),
            // 返回按钮
            _buildBackButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('新密码', style: _labelStyle),
        const SizedBox(height: 8),
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: '请输入新密码',
              hintStyle: const TextStyle(
                color: Color(0xFFCCCCCC),
                fontSize: 14,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  color: const Color(0xFF999999),
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('确认密码', style: _labelStyle),
        const SizedBox(height: 8),
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirmPassword,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: '请再次输入新密码',
              hintStyle: const TextStyle(
                color: Color(0xFFCCCCCC),
                fontSize: 14,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirmPassword
                      ? Icons.visibility_off
                      : Icons.visibility,
                  color: const Color(0xFF999999),
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscureConfirmPassword = !_obscureConfirmPassword;
                  });
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmButton() {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: ElevatedButton(
        onPressed: _canConfirm ? _handleResetPassword : null,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFFE5E5E5);
            }
            return const Color(0xFF4A90E2);
          }),
          foregroundColor: WidgetStateProperty.all(const Color(0xFFFFFFFF)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
          elevation: WidgetStateProperty.all(0),
        ),
        child: const Text(
          '确认',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: OutlinedButton(
        onPressed: () {
          Navigator.of(context).pop();
        },
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFFDDDDDD), width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          backgroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
        ),
        child: const Text(
          '返回',
          style: TextStyle(
            fontSize: 15,
            color: Color(0xFF333333),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
