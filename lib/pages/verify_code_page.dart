import 'package:flutter/material.dart';
import 'reset_password_page.dart';
import 'package:youdu/services/api_service.dart';
import '../utils/logger.dart';

class VerifyCodePage extends StatefulWidget {
  final String contact;

  const VerifyCodePage({super.key, required this.contact});

  @override
  State<VerifyCodePage> createState() => _VerifyCodePageState();
}

class _VerifyCodePageState extends State<VerifyCodePage> {
  final TextEditingController _verifyCodeController = TextEditingController();
  bool _hasInput = false;

  // 验证码倒计时相关
  int _countdown = 60;
  bool _isCountingDown = true; // 初始时已经发送过一次验证码

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
    _verifyCodeController.addListener(_onInputChanged);
    // 进入页面时已经发送过一次验证码，启动倒计时
    _startCountdown();
  }

  void _onInputChanged() {
    setState(() {
      _hasInput = _verifyCodeController.text.trim().isNotEmpty;
    });
  }

  // 重新发送验证码
  Future<void> _resendVerifyCode() async {
    logger.debug('=== 重新发送验证码 ===');
    // 如果正在倒计时，不处理
    if (_isCountingDown) {
      logger.debug('倒计时中，忽略点击');
      return;
    }

    logger.debug('账号: ${widget.contact}');

    try {
      logger.debug('调用API重新发送验证码...');
      final result = await ApiService.sendVerifyCode(
        account: widget.contact,
        type: 'reset', // 忘记密码类型
      );

      logger.debug('API返回结果: $result');

      if (result['code'] == 0) {
        _showSuccess('验证码已重新发送');
        // 开发环境下服务器会返回验证码
        if (result['data'] != null && result['data']['code'] != null) {
          logger.debug('✅ 验证码: ${result['data']['code']}');
        }

        // 启动倒计时
        logger.debug('启动倒计时...');
        _startCountdown();
      } else {
        logger.debug('❌ 发送失败: ${result['message']}');
        _showError(result['message'] ?? '发送失败');
      }
    } catch (e) {
      logger.debug('❌ 重新发送验证码异常: $e');
      _showError('发送验证码失败: $e');
    }
  }

  // 启动倒计时
  void _startCountdown() {
    setState(() {
      _countdown = 120;
      _isCountingDown = true;
    });

    // 开始倒计时
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;

      setState(() {
        _countdown--;
      });

      if (_countdown <= 0) {
        setState(() {
          _isCountingDown = false;
        });
        return false;
      }
      return true;
    });
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
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _verifyCodeController.removeListener(_onInputChanged);
    _verifyCodeController.dispose();
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
              child: _buildVerifyCodeForm(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVerifyCodeForm() {
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
            Text(
              '验证码已发送至 ${widget.contact}',
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF666666),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            // 验证码输入框
            _buildVerifyCodeField(),
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

  Widget _buildVerifyCodeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('验证码', style: _labelStyle),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: TextField(
                  controller: _verifyCodeController,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    hintText: '请输入验证码',
                    hintStyle: TextStyle(
                      color: Color(0xFFCCCCCC),
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _isCountingDown ? null : _resendVerifyCode,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                minimumSize: const Size(0, 42),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                disabledForegroundColor: const Color(0xFF999999),
              ),
              child: Text(
                _isCountingDown ? '$_countdown秒后重试' : '重新获取',
                style: TextStyle(
                  fontSize: 14,
                  color: _isCountingDown
                      ? const Color(0xFF999999)
                      : const Color(0xFF4A90E2),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNextButton() {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: ElevatedButton(
        onPressed: _hasInput
            ? () {
                // 进入重置密码页面
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => ResetPasswordPage(
                      contact: widget.contact,
                      verifyCode: _verifyCodeController.text.trim(),
                    ),
                  ),
                );
              }
            : null,
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
