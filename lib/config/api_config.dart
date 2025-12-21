import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// API 配置类
class ApiConfig {
  // 默认服务器配置
  // 🔥 自动根据debug/release模式和平台切换服务器地址和协议
  // Debug模式:
  //   - macOS: 使用 192.168.1.20 (HTTP 8180/8181)
  //   - Windows: 使用 192.168.1.6 (HTTP 8180/8181)
  // Release模式: 使用生产服务器 www.xn--wxtp0q.com (HTTPS 8180/8181)
  static String get defaultHost {
    if (!kDebugMode) {
      return 'www.xn--wxtp0q.com';
    }
    // Debug 模式下根据平台选择不同的本地服务器
    // 注意：在 macOS 上编译 iOS 应用时，Platform.isMacOS 为 false，Platform.isIOS 为 true
    if (Platform.isMacOS || Platform.isIOS) {
      return '192.168.1.20';
    } else {
      // Windows、Android 和其他平台
      return '192.168.1.6';
    }
  }
  
  // 端口配置：统一使用 8080/8081
  static const String defaultPort = '8180';
  static const String defaultWSPort = '8181';
  
  // HTTPS 配置：仅生产环境启用HTTPS，开发环境使用HTTP
  static final bool useHttps = !kDebugMode;

  // 当前服务器配置（可以被用户修改）
  static String _currentHost = defaultHost;
  static String _currentPort = defaultPort;
  static String _currentWSPort = defaultWSPort;

  /// 获取当前主机地址
  static String get host => _currentHost;

  /// 获取当前端口
  static String get port => _currentPort;

  /// 获取当前WebSocket端口
  static String get wsPort => _currentWSPort;

  /// 获取协议前缀（http 或 https）
  static String get protocol => useHttps ? 'https' : 'http';

  /// 获取 WebSocket 协议前缀（ws 或 wss）
  static String get wsProtocol => useHttps ? 'wss' : 'ws';

  /// 获取完整的 base URL
  static String get baseUrl => '$protocol://$_currentHost:$_currentPort';

  /// 获取完整的 WebSocket URL
  /// 注意：必须使用 ws:// 或 wss:// 协议，不能使用 http:// 或 https://
  static String get wsBaseUrl {
    final wsProto = useHttps ? 'wss' : 'ws';
    return '$wsProto://$_currentHost:$_currentWSPort';
  }

  /// 设置服务器地址
  static void setServer(String host, String port, {String? wsPort}) {
    _currentHost = host;
    _currentPort = port;
    if (wsPort != null) {
      _currentWSPort = wsPort;
    }
  }

  /// 重置为默认服务器
  static void resetToDefault() {
    _currentHost = defaultHost;
    _currentPort = defaultPort;
    _currentWSPort = defaultWSPort;
  }

  // API 接口路径
  static const String authRegister = '/api/auth/register';
  static const String authLogin = '/api/auth/login';
  static const String authVerifyCodeSend = '/api/auth/verify-code/send';
  static const String authVerifyCodeLogin = '/api/auth/verify-code/login';
  static const String authForgotPassword = '/api/auth/forgot-password';
  static const String configServer = '/api/config/server';
  static const String user = '/api/user';
  static const String userProfile = '/api/user/profile';
  static const String userWorkSignature = '/api/user/work-signature';
  static const String userStatus = '/api/user/status';
  static const String userChangePassword = '/api/user/change-password';
  static const String userCheckEmail = '/api/user/check-email';
  static const String userSendEmailCode = '/api/user/send-email-code';
  static const String userBindEmail = '/api/user/bind-email';
  static const String uploadImage = '/api/upload/image';
  static const String uploadFile = '/api/upload/file';
  static const String uploadAvatar = '/api/upload/avatar';
  static const String uploadVideoChunk = '/api/upload/video/chunk';
  
  // OSS分片直传API
  static const String ossInitiateMultipart = '/api/oss/initiate_multipart';
  static const String ossSignPart = '/api/oss/sign_part';
  static const String ossCompleteMultipart = '/api/oss/complete_multipart';
  static const String ossGetOpusUploadUrl = '/api/oss/get_opus_upload_url';
  static const String contacts = '/api/contacts';
  static const String messages = '/api/messages';
  static const String messagesRecentContacts = '/api/messages/recent-contacts';
  static const String messagesHistory = '/api/messages/history';
  static const String favorites = '/api/favorites';
  static const String groups = '/api/groups';
  static const String health = '/health';

  /// 获取完整的 API URL
  static String getApiUrl(String path) {
    return '$baseUrl$path';
  }

  /// 注册接口
  static String get registerUrl => getApiUrl(authRegister);

  /// 登录接口
  static String get loginUrl => getApiUrl(authLogin);

  /// 发送验证码接口
  static String get sendVerifyCodeUrl => getApiUrl(authVerifyCodeSend);

  /// 验证码登录接口
  static String get verifyCodeLoginUrl => getApiUrl(authVerifyCodeLogin);

  /// 忘记密码接口
  static String get forgotPasswordUrl => getApiUrl(authForgotPassword);

  /// 获取服务器配置接口
  static String get serverConfigUrl => getApiUrl(configServer);

  /// 健康检查接口
  static String get healthUrl => getApiUrl(health);

  // 默认头像配置
  /// 默认群组头像URL
  static const String defaultGroupAvatar = 'assets/images/default_group_avatar.png';
  
  /// 默认用户头像URL  
  static const String defaultUserAvatar = 'assets/images/default_user_avatar.png';
}
