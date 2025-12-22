import 'package:flutter/material.dart';
import 'verify_code_page.dart';
import 'package:youdu/services/api_service.dart';
import '../utils/logger.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final TextEditingController _contactController = TextEditingController();
  bool _hasInput = false;
  String? _errorMessage;

  // 统一的标签样式
  static const TextStyle _labelStyle = TextStyle(
    fontSize: 14,
    color: Color(0xFF333333),
    fontWeight: FontWeight.w500,
    height: 1.0,
    letterSpacing: 0,
  );

  // 验证邮箱格式
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    return emailRegex.hasMatch(email);
  }

  // 验证输入格式
  bool _validateContact() {
    final contact = _contactController.text.trim();
    if (contact.isEmpty) {
      setState(() {
        _errorMessage = '请输入邮箱';
      });
      return false;
    }

    if (_isValidEmail(contact)) {
      setState(() {
        _errorMessage = null;
      });
      return true;
    } else {
      setState(() {
        _errorMessage = '请输入正确的邮箱格式';
      });
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _contactController.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    setState(() {
      _hasInput = _contactController.text.trim().isNotEmpty;
    });
  }

  // 处理下一步
  Future<void> _handleNext() async {
    logger.debug('=== 忘记密码-发送验证码 ===');
    // 验证格式
    if (!_validateContact()) {
      logger.debug('格式验证失败');
      return;
    }

    final contact = _contactController.text.trim();
    logger.debug('联系方式: $contact');

    try {
      // 发送验证码
      logger.debug('调用API发送验证码...');
      final result = await ApiService.sendVerifyCode(
        account: contact,
        type: 'reset', // 忘记密码类型
      );

      logger.debug('API返回结果: $result');

      if (result['code'] == 0) {
        // 发送成功，进入验证码页面
        _showSuccess('验证码已发送');

        // 开发环境下服务器会返回验证码
        if (result['data'] != null && result['data']['code'] != null) {
          logger.debug('✅ 验证码: ${result['data']['code']}');
        }

        // 延迟一下再跳转，让用户看到成功提示
        await Future.delayed(const Duration(milliseconds: 500));

        logger.debug('跳转到验证码页面...');
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => VerifyCodePage(contact: contact),
            ),
          );
        }
      } else {
        logger.debug('❌ 发送失败: ${result['message']}');
        _showError(result['message'] ?? '发送失败');
      }
    } catch (e) {
      logger.debug('❌ 发送验证码异常: $e');
      _showError('发送验证码失败: $e');
    }
  }

  // 显示错误提示
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // 显示成功提示
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  void dispose() {
    _contactController.removeListener(_onInputChanged);
    _contactController.dispose();
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
              child: _buildForgotPasswordForm(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForgotPasswordForm() {
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
              '找回密码',
              style: TextStyle(
                fontSize: 24,
                color: Color(0xFF333333),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            // 说明文字
            const Text(
              '请填写你在企业内绑定的邮箱，以便接收验证码',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF666666),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            // 邮箱输入框
            _buildInputField(),
            const SizedBox(height: 60),
            // 下一步按钮
            _buildNextButton(),
            const SizedBox(height: 16),
            // 返回按钮
            _buildBackButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('邮箱', style: _labelStyle),
        const SizedBox(height: 8),
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: _contactController,
            textAlignVertical: TextAlignVertical.center,
            onChanged: (value) {
              // 清除错误提示
              if (_errorMessage != null) {
                setState(() {
                  _errorMessage = null;
                });
              }
            },
            decoration: const InputDecoration(
              hintText: '请输入邮箱',
              hintStyle: TextStyle(color: Color(0xFFCCCCCC), fontSize: 14),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
            ),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            style: const TextStyle(fontSize: 12, color: Color(0xFFFF0000)),
          ),
        ],
      ],
    );
  }

  Widget _buildNextButton() {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: ElevatedButton(
        onPressed: _hasInput ? _handleNext : null,
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
          '下一步',
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
