import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../services/api_service.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
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
          _buildEmailItem(), // 使用专门的邮箱组件
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

  // 邮箱信息项（带绑定/更换按钮）
  Widget _buildEmailItem() {
    final hasEmail = _currentEmail != null && _currentEmail!.isNotEmpty;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              '邮箱',
              style: TextStyle(
                fontSize: 15,
                color: Color(0xFF666666),
              ),
            ),
          ),
          Expanded(
            child: Text(
              hasEmail ? _currentEmail! : '未设置',
              style: TextStyle(
                fontSize: 15,
                color: hasEmail
                    ? const Color(0xFF333333)
                    : const Color(0xFFCCCCCC),
              ),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _showBindEmailDialog(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                hasEmail ? '更换邮箱' : '绑定邮箱',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 显示绑定邮箱弹窗
  void _showBindEmailDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _BindEmailDialog(
        token: widget.token,
        currentEmail: _currentEmail,
        onSuccess: (newEmail) {
          setState(() {
            _currentEmail = newEmail;
          });
          // 同时更新本地存储
          Storage.setEmail(newEmail);
          // 通知外部更新
          widget.onUpdate?.call();
        },
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

/// 绑定邮箱弹窗组件
class _BindEmailDialog extends StatefulWidget {
  final String token;
  final String? currentEmail;
  final Function(String) onSuccess;

  const _BindEmailDialog({
    required this.token,
    this.currentEmail,
    required this.onSuccess,
  });

  @override
  State<_BindEmailDialog> createState() => _BindEmailDialogState();
}

class _BindEmailDialogState extends State<_BindEmailDialog> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  
  bool _isLoading = false;
  bool _isSendingCode = false;
  int _countdown = 0;
  Timer? _countdownTimer;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // 验证邮箱格式
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return emailRegex.hasMatch(email);
  }

  // 发送验证码
  Future<void> _sendVerificationCode() async {
    final email = _emailController.text.trim();
    
    // 验证邮箱格式
    if (email.isEmpty) {
      setState(() {
        _errorMessage = '请输入邮箱地址';
      });
      return;
    }
    
    if (!_isValidEmail(email)) {
      setState(() {
        _errorMessage = '请输入正确的邮箱格式';
      });
      return;
    }

    setState(() {
      _isSendingCode = true;
      _errorMessage = null;
    });

    try {
      // 先检查邮箱是否可用
      final checkResponse = await ApiService.checkEmailAvailability(
        token: widget.token,
        email: email,
      );
      
      if (checkResponse['code'] != 0) {
        setState(() {
          _errorMessage = checkResponse['message'] ?? '该邮箱已被其他用户绑定';
          _isSendingCode = false;
        });
        return;
      }
      
      // 发送验证码
      final response = await ApiService.sendEmailBindCode(
        token: widget.token,
        email: email,
      );

      if (response['code'] == 0) {
        // 开始倒计时
        setState(() {
          _countdown = 120;
          _isSendingCode = false;
        });
        _startCountdown();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('验证码已发送，请查收邮件'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = response['message'] ?? '发送验证码失败';
          _isSendingCode = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '发送验证码失败，请稍后重试';
        _isSendingCode = false;
      });
    }
  }

  // 开始倒计时
  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        setState(() {
          _countdown--;
        });
      } else {
        timer.cancel();
      }
    });
  }

  // 绑定邮箱
  Future<void> _bindEmail() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _errorMessage = '请输入邮箱地址';
      });
      return;
    }

    if (!_isValidEmail(email)) {
      setState(() {
        _errorMessage = '请输入正确的邮箱格式';
      });
      return;
    }

    if (code.isEmpty) {
      setState(() {
        _errorMessage = '请输入验证码';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await ApiService.bindEmail(
        token: widget.token,
        email: email,
        code: code,
      );

      if (response['code'] == 0) {
        if (mounted) {
          Navigator.pop(context);
          widget.onSuccess(email);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.currentEmail != null ? '邮箱更换成功' : '邮箱绑定成功'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = response['message'] ?? '绑定失败';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '绑定失败，请稍后重试';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasEmail = widget.currentEmail != null && widget.currentEmail!.isNotEmpty;
    
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  hasEmail ? '更换邮箱' : '绑定邮箱',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF333333),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, color: Color(0xFF999999)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // 邮箱输入框
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: '请输入邮箱地址',
                hintStyle: const TextStyle(color: Color(0xFFCCCCCC)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() {
                    _errorMessage = null;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            
            // 验证码输入框和发送按钮
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      hintText: '请输入验证码',
                      hintStyle: const TextStyle(color: Color(0xFFCCCCCC)),
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() {
                          _errorMessage = null;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: (_countdown > 0 || _isSendingCode) ? null : _sendVerificationCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      disabledBackgroundColor: const Color(0xFFCCCCCC),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    child: _isSendingCode
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Text(
                            _countdown > 0 ? '${_countdown}s' : '获取验证码',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            
            // 错误提示
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.red,
                ),
              ),
            ],
            
            const SizedBox(height: 20),
            
            // 确定按钮
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _bindEmail,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90E2),
                  disabledBackgroundColor: const Color(0xFFCCCCCC),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        '确定',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
