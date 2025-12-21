import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:http/http.dart' as http;
import 'package:youdu/config/api_config.dart';
import '../utils/logger.dart';
import '../utils/storage.dart';
import 'message_service.dart';
import 'favorite_service.dart';
import 'file_assistant_service.dart';
import 'oss_multipart_service.dart';

/// API 服务- 统一处理所有HTTP 请求
class ApiService {
  /// 统一的响应处理
  static Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode == 200) {
      try {
        final data = json.decode(utf8.decode(response.bodyBytes));
        return data;
      } catch (e) {
        logger.debug('❌ [API响应] JSON解析失败: $e');
        throw ApiException(
          statusCode: response.statusCode,
          message: 'JSON解析失败: $e',
        );
      }
    } else {
      // 尝试解析错误响应体
      String errorMessage = '请求失败: ${response.statusCode}';
      try {
        final errorData = json.decode(utf8.decode(response.bodyBytes));
        if (errorData['message'] != null) {
          errorMessage = errorData['message'];
        }
        logger.debug('❌ [API响应] 服务器错误: $errorMessage');
      } catch (e) {
        logger.debug('❌ [API响应] 无法解析错误响应: $e');
      }
      
      throw ApiException(
        statusCode: response.statusCode,
        message: errorMessage,
      );
    }
  }

  /// POST 请求
  static Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data, {
    String? token,
  }) async {
    try {
      final url = ApiConfig.getApiUrl(path);
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: json.encode(data),
      );
      return _handleResponse(response);
    } catch (e) {
      logger.debug('❌ [POST请求] 网络请求异常: $e');
      
      // 检测致命网络错误
      if (_isFatalNetworkError(e)) {
        logger.debug('🚫 [POST请求] 检测到致命网络错误，终止请求');
        throw ApiException(
          message: '网络连接已断开，请检查服务器状态',
          isFatal: true,
        );
      }
      
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// GET 请求
  static Future<Map<String, dynamic>> get(String path, {String? token}) async {
    try {
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http.get(
        Uri.parse(ApiConfig.getApiUrl(path)),
        headers: headers,
      );
      return _handleResponse(response);
    } catch (e) {
      // 检测致命网络错误
      if (_isFatalNetworkError(e)) {
        logger.debug('🚫 [GET请求] 检测到致命网络错误，终止请求');
        throw ApiException(
          message: '网络连接已断开，请检查服务器状态',
          isFatal: true,
        );
      }
      
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// PUT 请求
  static Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> data, {
    String? token,
  }) async {
    try {
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http.put(
        Uri.parse(ApiConfig.getApiUrl(path)),
        headers: headers,
        body: json.encode(data),
      );
      return _handleResponse(response);
    } catch (e) {
      // 检测致命网络错误
      if (_isFatalNetworkError(e)) {
        logger.debug('🚫 [PUT请求] 检测到致命网络错误，终止请求');
        throw ApiException(
          message: '网络连接已断开，请检查服务器状态',
          isFatal: true,
        );
      }
      
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 检测是否为致命网络错误（不应重试）
  static bool _isFatalNetworkError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    
    // 检测 errno 10057 - 套接字未连接
    if (errorStr.contains('errno = 10057') || 
        errorStr.contains('errno: 10057') ||
        errorStr.contains('由于套接字没有连接')) {
      return true;
    }
    
    // 其他致命网络错误码
    // errno 10054 - 远程主机强迫关闭了一个现有的连接
    // errno 10061 - 目标计算机积极拒绝
    if (errorStr.contains('errno = 10054') ||
        errorStr.contains('errno = 10061')) {
      return true;
    }
    
    return false;
  }

  // ============ 认证相关 API ============

  /// 用户注册
  ///
  /// 请求参数:
  /// - username: 用户名(必填, 3-50字符)
  /// - fullName: 昵称 (必填)
  /// - password: 密码 (必填, 6-50字符)
  /// - confirmPassword: 确认密码 (必填)
  /// - inviteCode: 邀请码 (可选)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { user: {...}, token: "..." }
  static Future<Map<String, dynamic>> register({
    required String username,
    required String fullName,
    required String password,
    required String confirmPassword,
    String? inviteCode,
  }) async {
    final data = {
      'username': username,
      'full_name': fullName,
      'password': password,
      'confirm_password': confirmPassword,
    };

    if (inviteCode != null && inviteCode.isNotEmpty) {
      data['invite_code'] = inviteCode;
    }

    return await post(ApiConfig.authRegister, data);
  }

  /// 账号密码登录
  ///
  /// 请求参数:
  /// - username: 用户名(必填)
  /// - password: 密码 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { user: {...}, token: "..." }
  static Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    return await post(ApiConfig.authLogin, {
      'username': username,
      'password': password,
    });
  }

  /// 发送验证码
  ///
  /// 请求参数:
  /// - account: 账号 (用户名, 手机号, 邮箱)
  /// - type: 类型 ('login', 'register', 'reset')
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { code: "123456", expires_at: "..." }
  static Future<Map<String, dynamic>> sendVerifyCode({
    required String account,
    required String type, // 'login', 'register', 'reset'
  }) async {
    return await post(ApiConfig.authVerifyCodeSend, {
      'account': account,
      'type': type,
    });
  }

  /// 验证码登录
  ///
  /// 请求参数:
  /// - account: 账号 (用户名, 手机号, 邮箱)
  /// - code: 验证码
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { user: {...}, token: "..." }
  static Future<Map<String, dynamic>> verifyCodeLogin({
    required String account,
    required String code,
  }) async {
    return await post(ApiConfig.authVerifyCodeLogin, {
      'account': account,
      'code': code,
    });
  }

  /// 忘记密码（重置密码）
  ///
  /// 请求参数:
  /// - account: 账号 (用户名, 手机号, 邮箱)
  /// - code: 验证码
  /// - new_password: 新密码(6-50字符)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> forgotPassword({
    required String account,
    required String code,
    required String newPassword,
  }) async {
    return await post(ApiConfig.authForgotPassword, {
      'account': account,
      'code': code,
      'new_password': newPassword,
    });
  }

  // ============ 配置相关 API ============

  /// 获取服务器配置
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { server_name: {...}, server_url: {...}, ... }
  static Future<Map<String, dynamic>> getServerConfig() async {
    return await get(ApiConfig.configServer);
  }

  /// 健康检查
  ///
  /// 返回:
  /// - status: "ok"
  static Future<Map<String, dynamic>> healthCheck() async {
    return await get(ApiConfig.health);
  }

  // ============ 用户信息相关 API ============

  /// 获取当前登录用户的个人信息
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { user: {...} }
  static Future<Map<String, dynamic>> getUserProfile({
    required String token,
  }) async {
    return await get(ApiConfig.userProfile, token: token);
  }

  /// 根据用户ID获取用户信息
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - userId: 用户ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { id, username, full_name, status, ... }
  static Future<Map<String, dynamic>> getUserByID({
    required String token,
    required int userId,
  }) async {
    return await get('${ApiConfig.user}/$userId', token: token);
  }

  /// 获取用户信息（简化版本，兼容性方法）
  ///
  /// 请求参数:
  /// - userId: 用户ID (必填)
  /// - token: 登录凭证 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { id, username, full_name, avatar, status, ... }
  static Future<Map<String, dynamic>> getUserInfo(int userId, {required String token}) async {
    return await getUserByID(token: token, userId: userId);
  }

  /// 根据邀请码获取用户信息
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - inviteCode: 邀请码 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { id, username, full_name, avatar, gender, region, ... }
  static Future<Map<String, dynamic>> getUserByInviteCode({
    required String token,
    required String inviteCode,
  }) async {
    return await get('/api/user/invite-code/$inviteCode', token: token);
  }

  /// 更新个人信息
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - fullName: 姓名 (可选)
  /// - gender: 性别 (可选, male/female/other)
  /// - phone: 手机 (可选)
  /// - landline: 座机 (可选)
  /// - shortNumber: 短号 (可选)
  /// - email: 邮箱 (可选)
  /// - department: 部门 (可选)
  /// - position: 职位 (可选)
  /// - avatar: 头像URL (可选)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { user: {...} }
  static Future<Map<String, dynamic>> updateUserProfile({
    required String token,
    String? fullName,
    String? gender,
    String? phone,
    String? landline,
    String? shortNumber,
    String? department,
    String? position,
    String? region,
    String? avatar,
  }) async {
    final data = <String, dynamic>{};

    if (fullName != null) data['full_name'] = fullName;
    if (gender != null) data['gender'] = gender;
    if (phone != null) data['phone'] = phone;
    if (landline != null) data['landline'] = landline;
    if (shortNumber != null) data['short_number'] = shortNumber;
    if (department != null) data['department'] = department;
    if (position != null) data['position'] = position;
    if (region != null) data['region'] = region;
    if (avatar != null) data['avatar'] = avatar;

    return await put(ApiConfig.userProfile, data, token: token);
  }

  /// 更新工作签名
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - workSignature: 工作签名 (必填, 最多100字符)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateWorkSignature({
    required String token,
    required String workSignature,
  }) async {
    return await put(ApiConfig.userWorkSignature, {
      'work_signature': workSignature,
    }, token: token);
  }

  /// 更新状态
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - status: 状态(必填, online/busy/away/offline)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateStatus({
    required String token,
    required String status,
  }) async {
    return await put(ApiConfig.userStatus, {'status': status}, token: token);
  }

  /// 修改密码
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - oldPassword: 旧密码(必填)
  /// - newPassword: 新密码(必填, 4-16字符)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> changePassword({
    required String token,
    required String oldPassword,
    required String newPassword,
  }) async {
    return await post(ApiConfig.userChangePassword, {
      'old_password': oldPassword,
      'new_password': newPassword,
    }, token: token);
  }

  /// 批量获取用户在线状态
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - userIds: 用户ID列表 (必填, 最多100个)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { statuses: { userId: "online|offline", ... } }
  static Future<Map<String, dynamic>> batchGetOnlineStatus({
    required String token,
    required List<int> userIds,
  }) async {
    if (userIds.isEmpty) {
      logger.debug('⚠️ [API] 用户ID列表为空');
      return {
        'code': -1,
        'message': '用户ID列表不能为空',
        'data': null,
      };
    }

    if (userIds.length > 100) {
      logger.debug('⚠️ [API] 用户ID列表过长: ${userIds.length}');
      return {
        'code': -1,
        'message': '一次最多查询100个用户的在线状态',
        'data': null,
      };
    }

    try {
      final response = await post('/api/user/batch-online-status', {
        'user_ids': userIds,
      }, token: token);
      
      return response;
    } catch (e) {
      logger.debug('❌ [API] 批量查询在线状态失败: $e');
      rethrow;
    }
  }

  /// 检查邮箱是否已被其他用户绑定
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - email: 邮箱地址 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { available: true/false, message: "..." }
  static Future<Map<String, dynamic>> checkEmailAvailability({
    required String token,
    required String email,
  }) async {
    try {
      final response = await post(ApiConfig.userCheckEmail, {
        'email': email,
      }, token: token);
      
      return response;
    } catch (e) {
      logger.debug('❌ [API] 检查邮箱可用性失败: $e');
      rethrow;
    }
  }

  /// 发送邮箱验证码（用于绑定/更换邮箱）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - email: 邮箱地址 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> sendEmailBindCode({
    required String token,
    required String email,
  }) async {
    try {
      final response = await post(ApiConfig.userSendEmailCode, {
        'email': email,
      }, token: token);
      
      return response;
    } catch (e) {
      logger.debug('❌ [API] 发送邮箱验证码失败: $e');
      rethrow;
    }
  }

  /// 绑定/更换邮箱
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - email: 邮箱地址 (必填)
  /// - code: 验证码 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> bindEmail({
    required String token,
    required String email,
    required String code,
  }) async {
    try {
      final response = await post(ApiConfig.userBindEmail, {
        'email': email,
        'code': code,
      }, token: token);
      
      return response;
    } catch (e) {
      logger.debug('❌ [API] 绑定邮箱失败: $e');
      rethrow;
    }
  }

  // ============ 文件上传相关 API ============

  /// 上传图片到阿里云OSS
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - filePath: 文件路径 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { url: "...", file_name: "...", size: 0 }
  static Future<Map<String, dynamic>> uploadImage({
    required String token,
    required String filePath,
  }) async {
    try {
      final headers = <String, String>{};
      headers['Authorization'] = 'Bearer $token';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.getApiUrl(ApiConfig.uploadImage)),
      );

      request.headers.addAll(headers);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 上传图片到阿里云OSS（带进度回调）- 仅供移动端使用
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - filePath: 文件路径 (必填)
  /// - onProgress: 进度回调，值为0.0-1.0
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { url: "...", file_name: "...", size: 0 }
  static Future<Map<String, dynamic>> uploadImageWithProgress({
    required String token,
    required String filePath,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final headers = <String, String>{};
      headers['Authorization'] = 'Bearer $token';

      final file = File(filePath);
      final fileSize = await file.length();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.getApiUrl(ApiConfig.uploadImage)),
      );

      request.headers.addAll(headers);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      // 发送请求
      final streamedResponse = await request.send();

      // 收集响应数据
      final List<int> bytes = [];
      int bytesReceived = 0;

      await for (final chunk in streamedResponse.stream) {
        bytes.addAll(chunk);
        bytesReceived += chunk.length;

        // 简单的进度估算（实际进度需要服务器支持）
        if (onProgress != null && fileSize > 0) {
          // 假设上传占70%，响应占30%
          final progress = (bytesReceived / fileSize) * 0.7;
          onProgress(progress.clamp(0.0, 0.7));
        }
      }

      // 标记上传完成，处理响应
      onProgress?.call(0.9);

      // 创建响应对象
      final response = http.Response.bytes(
        bytes,
        streamedResponse.statusCode,
        headers: streamedResponse.headers,
        request: streamedResponse.request,
      );

      // 完成
      onProgress?.call(1.0);

      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 上传文件到阿里云OSS（带进度回调）- 仅供移动端使用
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - filePath: 文件路径 (必填)
  /// - onProgress: 进度回调，值为0.0-1.0
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { url: "...", file_name: "...", size: 0 }
  static Future<Map<String, dynamic>> uploadFileWithProgress({
    required String token,
    required String filePath,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final headers = <String, String>{};
      headers['Authorization'] = 'Bearer $token';

      final file = File(filePath);
      final fileSize = await file.length();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.getApiUrl(ApiConfig.uploadFile)),
      );

      request.headers.addAll(headers);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      // 发送请求
      final streamedResponse = await request.send();

      // 收集响应数据
      final List<int> bytes = [];
      int bytesReceived = 0;

      await for (final chunk in streamedResponse.stream) {
        bytes.addAll(chunk);
        bytesReceived += chunk.length;

        // 简单的进度估算（实际进度需要服务器支持）
        if (onProgress != null && fileSize > 0) {
          // 假设上传占70%，响应占30%
          final progress = (bytesReceived / fileSize) * 0.7;
          onProgress(progress.clamp(0.0, 0.7));
        }
      }

      // 标记上传完成，处理响应
      onProgress?.call(0.9);

      // 创建响应对象
      final response = http.Response.bytes(
        bytes,
        streamedResponse.statusCode,
        headers: streamedResponse.headers,
        request: streamedResponse.request,
      );

      // 完成
      onProgress?.call(1.0);

      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 上传通用文件到阿里云OSS
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - filePath: 文件路径 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { url: "...", file_name: "...", size: 0 }
  static Future<Map<String, dynamic>> uploadFile({
    required String token,
    required String filePath,
  }) async {
    try {
      final headers = <String, String>{};
      headers['Authorization'] = 'Bearer $token';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.getApiUrl(ApiConfig.uploadFile)),
      );

      request.headers.addAll(headers);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 上传头像到阿里云OSS（使用OSS直传）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - filePath: 文件路径 (必填)
  /// - onProgress: 进度回调 (已上传字节数, 总字节数)，可选
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { url: "...", file_name: "...", size: 0 }
  /// 
  /// 说明:
  /// - 现在使用OSS直传，不再走后端中转，速度更快
  /// - 分片大小：5MB，并发数：8
  static Future<Map<String, dynamic>> uploadAvatar({
    required String token,
    required String filePath,
    Function(int uploaded, int total)? onProgress,
  }) async {
    // 使用OSS直传服务
    try {
      final result = await OSSMultipartService.uploadFile(
        token: token,
        filePath: filePath,
        fileType: 'image', // 头像属于图片类型
        onProgress: onProgress,
      );

      return {
        'code': 0,
        'message': '头像上传成功',
        'data': {
          'url': result['url'],
          'file_name': result['file_name'],
          'size': 0, // OSS直传不返回文件大小，保持兼容性
        },
      };
    } catch (e) {
      throw ApiException(message: '头像上传失败: $e');
    }
  }

  // ============ 消息相关 API ============
  // 注意：消息现在存储在本地SQLite数据库中，不再从服务器获取

  /// 获取最新20个联系人列表（从本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { contacts: [...] }
  ///   每个联系人包含: user_id, username, full_name, last_message_time, last_message
  static Future<Map<String, dynamic>> getRecentContacts({
    required String token,
  }) async {
    logger.debug('📱 从本地数据库获取最近联系人');
    final messageService = MessageService();
    final result = await messageService.getRecentContacts();
    logger.debug('📱 本地数据库返回: $result');
    return result;
  }

  /// 获取与指定用户的消息历史记录（从本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - userId: 对方用户ID (必填)
  /// - page: 页码 (可选, 默认1)
  /// - pageSize: 每页数量 (可选, 默认50)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { messages: [...], page: 1, page_size: 50, total: 0 }
  static Future<Map<String, dynamic>> getMessageHistory({
    required String token,
    required int userId,
    int page = 1,
    int pageSize = 50,
  }) async {
    logger.debug('📱 从本地数据库获取消息历史 - userId: $userId');
    final messageService = MessageService();
    return await messageService.getMessageHistory(
      userId: userId,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 获取私聊消息（从本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - contactId: 联系人ID (必填)
  /// - page: 页码 (可选, 默认1)
  /// - pageSize: 每页数量 (可选, 默认50)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { messages: [...], page: 1, page_size: 50, total: 0 }
  static Future<Map<String, dynamic>> getMessages({
    required String token,
    required int contactId,
    int page = 1,
    int pageSize = 50,
  }) async {
    final messageService = MessageService();
    return await messageService.getMessageHistory(
      userId: contactId,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 标记与某个用户的所有未读消息为已读（本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - senderID: 消息发送者ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { message: "标记成功", rows_affected: 5 }
  static Future<Map<String, dynamic>> markMessagesAsRead({
    required String token,
    required int senderID,
  }) async {
    logger.debug('📱 标记消息为已读（本地数据库） - senderId: $senderID');
    final messageService = MessageService();
    try {
      await messageService.markMessagesAsRead(senderID);
      return {
        'code': 0,
        'message': '标记成功',
        'data': {'message': '标记成功'},
      };
    } catch (e) {
      return {'code': -1, 'message': '标记失败: $e', 'data': null};
    }
  }

  /// 标记群组的所有未读消息为已读（本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - groupID: 群组ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { message: "标记成功", rows_affected: 5 }
  static Future<Map<String, dynamic>> markGroupMessagesAsRead({
    required String token,
    required int groupID,
  }) async {
    logger.debug('📱 标记群聊消息为已读（本地数据库） - groupId: $groupID');
    final messageService = MessageService();
    try {
      await messageService.markGroupMessagesAsRead(groupID);
      return {
        'code': 0,
        'message': '标记成功',
        'data': {'message': '标记成功'},
      };
    } catch (e) {
      return {'code': -1, 'message': '标记失败: $e', 'data': null};
    }
  }

  // ============ 联系人相关 API ============

  /// 添加联系人
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - friendUsername: 好友用户名(必填)
  ///
  /// 返回:
  /// - code: 200 表示成功
  /// - message: 响应消息
  /// - data: { relation: {...}, friend: {...} }
  static Future<Map<String, dynamic>> addContact({
    required String token,
    required String friendUsername,
  }) async {
    logger.debug('🔄 开始添加联系人: $friendUsername');
    logger.debug('📡 API URL: ${ApiConfig.getApiUrl(ApiConfig.contacts)}');
    
    try {
      final result = await post(ApiConfig.contacts, {
        'friend_username': friendUsername,
      }, token: token);
      
      logger.debug('✅ 添加联系人API调用成功: $result');
      return result;
    } catch (e) {
      logger.debug('❌ 添加联系人API调用失败: $e');
      rethrow;
    }
  }

  /// 获取联系人列表
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  ///
  /// 返回:
  /// - code: 200 表示成功
  /// - data: { contacts: [...], total: 0 }
  static Future<Map<String, dynamic>> getContacts({
    required String token,
  }) async {
    return await get(ApiConfig.contacts, token: token);
  }

  /// 获取待审核的联系人申请
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { requests: [...], total: 0 }
  static Future<Map<String, dynamic>> getPendingContactRequests({
    required String token,
  }) async {
    return await get('${ApiConfig.contacts}/requests', token: token);
  }

  /// 删除联系人
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - friendUsername: 好友用户名(必填)
  ///
  /// 返回:
  /// - code: 200 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> deleteContact({
    required String token,
    required String friendUsername,
  }) async {
    try {
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      headers['Authorization'] = 'Bearer $token';

      final response = await http.delete(
        Uri.parse('${ApiConfig.getApiUrl(ApiConfig.contacts)}/$friendUsername'),
        headers: headers,
      );
      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 搜索联系人
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - keyword: 搜索关键字(必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { contacts: [...], total: 0 }
  ///   每个联系人包含: username, full_name, last_message_time, last_message
  static Future<Map<String, dynamic>> searchContacts({
    required String token,
    required String keyword,
  }) async {
    try {
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      headers['Authorization'] = 'Bearer $token';

      final uri = Uri.parse(ApiConfig.getApiUrl(ApiConfig.contacts)).replace(
        path: '/api/contacts/search',
        queryParameters: {'keyword': keyword},
      );

      final response = await http.get(uri, headers: headers);
      return _handleResponse(response);
    } catch (e) {
      throw ApiException(message: '网络请求失败: $e');
    }
  }

  /// 更新联系人审核状态
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - relationId: 关系ID (必填)
  /// - approvalStatus: 审核状态 (必填: 'approved' 或 'rejected')
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateContactApprovalStatus({
    required String token,
    required int relationId,
    required String approvalStatus,
  }) async {
    return await put('/api/contacts/$relationId/approval', {
      'approval_status': approvalStatus,
    }, token: token);
  }

  /// 拉黑联系人
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - friendId: 好友ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> blockContact({
    required String token,
    required int friendId,
  }) async {
    return await post('/api/contacts/$friendId/block', {}, token: token);
  }

  /// 恢复联系人（取消拉黑）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - friendId: 好友ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> unblockContact({
    required String token,
    required int friendId,
  }) async {
    return await post('/api/contacts/$friendId/unblock', {}, token: token);
  }

  /// 删除联系人（软删除）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - friendId: 好友ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> deleteContactById({
    required String token,
    required int friendId,
  }) async {
    return await post('/api/contacts/$friendId/delete', {}, token: token);
  }

  /// 创建收藏（本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - messageId: 本地消息ID (必填，用于本地存储)
  /// - serverMessageId: 服务器消息ID (可选，用于同步到服务器)
  /// - content: 消息内容 (必填)
  /// - messageType: 消息类型 (必填)
  /// - senderId: 发送者ID (必填)
  /// - senderName: 发送者姓名 (必填)
  /// - fileName: 文件名 (可选)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: "已保存到收藏"
  /// - data: 收藏对象
  static Future<Map<String, dynamic>> createFavorite({
    required String token,
    required int messageId,
    int? serverMessageId,
    required String content,
    required String messageType,
    required int senderId,
    required String senderName,
    String? fileName,
  }) async {
    logger.debug('📱 添加收藏（本地数据库）- messageId: $messageId, serverMessageId: $serverMessageId');
    final favoriteService = FavoriteService();
    try {
      final id = await favoriteService.addFavorite(
        messageId: messageId,
        serverMessageId: serverMessageId,
        content: content,
        messageType: messageType,
        fileName: fileName,
        senderId: senderId,
        senderName: senderName,
      );
      return {
        'code': 0,
        'message': '已保存到收藏',
        'data': {'id': id},
      };
    } catch (e) {
      return {'code': -1, 'message': '添加收藏失败: $e', 'data': null};
    }
  }

  /// 批量创建收藏（本地数据库）
  /// 注意：此方法需要逐个添加，不支持合并为一条
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - messages: 消息列表 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: "已将N条消息保存到收藏"
  static Future<Map<String, dynamic>> createBatchFavorite({
    required String token,
    required List<Map<String, dynamic>> messages,
  }) async {
    logger.debug('📱 批量添加收藏（本地数据库）');
    final favoriteService = FavoriteService();
    try {
      int successCount = 0;
      for (var msg in messages) {
        try {
          await favoriteService.addFavorite(
            messageId: msg['message_id'] as int?,
            content: msg['content'] as String,
            messageType: msg['message_type'] as String,
            fileName: msg['file_name'] as String?,
            senderId: msg['sender_id'] as int,
            senderName: msg['sender_name'] as String,
          );
          successCount++;
        } catch (e) {
          logger.debug('添加收藏失败: $e');
        }
      }
      return {
        'code': 0,
        'message': '已将${successCount}条消息保存到收藏',
        'data': {'count': successCount},
      };
    } catch (e) {
      return {'code': -1, 'message': '批量添加收藏失败: $e', 'data': null};
    }
  }

  /// 获取收藏列表（本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - page: 页码 (可选，默认1)
  /// - pageSize: 每页数量 (可选，默认20)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: {
  ///     favorites: 收藏列表,
  ///     total: 总数,
  ///     page: 当前页码,
  ///     page_size: 每页数量,
  ///   }
  static Future<Map<String, dynamic>> getFavorites({
    required String token,
    int page = 1,
    int pageSize = 20,
  }) async {
    logger.debug('📱 从本地数据库获取收藏列表 - page: $page, pageSize: $pageSize');
    final favoriteService = FavoriteService();
    try {
      final favorites = await favoriteService.getFavorites(
        page: page,
        pageSize: pageSize,
      );
      logger.debug('📱 FavoriteService返回 ${favorites.length} 条收藏');
      
      final favoritesJson = favorites.map((f) => f.toJson()).toList();
      logger.debug('📱 转换为JSON后: ${favoritesJson.length} 条');
      
      return {
        'code': 0,
        'message': '获取成功',
        'data': {
          'favorites': favoritesJson,
          'total': favorites.length,
          'page': page,
          'page_size': pageSize,
        },
      };
    } catch (e) {
      logger.debug('❌ 获取收藏列表失败: $e');
      return {'code': -1, 'message': '获取收藏列表失败: $e', 'data': null};
    }
  }

  /// 删除收藏（本地数据库）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - favoriteId: 收藏ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: "删除成功"
  static Future<Map<String, dynamic>> deleteFavorite({
    required String token,
    required int favoriteId,
  }) async {
    logger.debug('📱 删除收藏（本地数据库）: ID=$favoriteId');
    final favoriteService = FavoriteService();
    try {
      final success = await favoriteService.deleteFavorite(favoriteId);
      if (success) {
        return {'code': 0, 'message': '删除成功', 'data': null};
      } else {
        return {'code': -1, 'message': '删除失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '删除失败: $e', 'data': null};
    }
  }

  /// 撤回消息(1分钟内) - 本地数据库操作
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - messageId: 消息ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: "消息已撤回"
  static Future<Map<String, dynamic>> recallMessage({
    required String token,
    required int messageId,
  }) async {
    logger.debug('📱 撤回消息（本地数据库） - messageId: $messageId');
    final messageService = MessageService();
    try {
      await messageService.recallMessage(messageId);
      return {'code': 0, 'message': '消息已撤回', 'data': null};
    } catch (e) {
      return {'code': -1, 'message': '撤回失败: $e', 'data': null};
    }
  }

  /// 删除消息（仅自己不可见） - 本地数据库操作
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - messageId: 消息ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: "消息已删除"
  static Future<Map<String, dynamic>> deleteMessage({
    required String token,
    required int messageId,
  }) async {
    logger.debug('📱 删除消息（本地数据库） - messageId: $messageId');
    final messageService = MessageService();
    try {
      // 获取当前用户ID
      final userId = await Storage.getUserId();
      if (userId == null) {
        return {'code': -1, 'message': '未登录', 'data': null};
      }

      await messageService.deleteMessage(messageId, userId);
      return {'code': 0, 'message': '消息已删除', 'data': null};
    } catch (e) {
      return {'code': -1, 'message': '删除失败: $e', 'data': null};
    }
  }

  /// 批量删除消息（本地数据库）
  static Future<Map<String, dynamic>> batchDeleteMessages({
    required String token,
    required List<int> messageIds,
  }) async {
    logger.debug('📱 批量删除消息（本地数据库） - count: ${messageIds.length}');
    final messageService = MessageService();
    try {
      // 获取当前用户ID
      final userId = await Storage.getUserId();
      if (userId == null) {
        return {'code': -1, 'message': '未登录', 'data': null};
      }

      // 批量删除
      for (final messageId in messageIds) {
        await messageService.deleteMessage(messageId, userId);
      }

      return {'code': 0, 'message': '批量删除成功', 'data': null};
    } catch (e) {
      return {'code': -1, 'message': '批量删除失败: $e', 'data': null};
    }
  }

  // ============ 群组相关 API ============

  /// 创建群组
  ///
  /// 请求参数:
  /// - name: 群组名称 (必填)
  /// - announcement: 群主公告 (可选)
  /// - avatar: 群头像URL (可选)
  /// - member_ids: 成员ID列表 (必填)
  /// - nickname: 我在本群的昵称(可选)
  /// - remark: 备注 (可选)
  /// - doNotDisturb: 消息免打扰 (可选)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { group: {...} }
  static Future<Map<String, dynamic>> createGroup({
    required String token,
    required String name,
    String? announcement,
    String? avatar,
    required List<int> memberIds,
    String? nickname,
    String? remark,
    bool? doNotDisturb,
  }) async {
    return await post('/api/groups', {
      'name': name,
      if (announcement != null && announcement.isNotEmpty)
        'announcement': announcement,
      if (avatar != null && avatar.isNotEmpty) 'avatar': avatar,
      'member_ids': memberIds,
      if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
      if (remark != null && remark.isNotEmpty) 'remark': remark,
      if (doNotDisturb != null) 'do_not_disturb': doNotDisturb,
    }, token: token);
  }

  /// 获取用户的所有群组
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { groups: [...] }
  static Future<Map<String, dynamic>> getUserGroups({
    required String token,
  }) async {
    return await get('/api/groups', token: token);
  }

  /// 获取群组详情
  ///
  /// 参数:
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { group: {...}, members: [...], member_role: "..." }
  static Future<Map<String, dynamic>> getGroupDetail({
    required String token,
    required int groupId,
  }) async {
    return await get('/api/groups/$groupId', token: token);
  }

  /// 发送群组消息
  ///
  /// 请求参数:
  /// - group_id: 群组ID
  /// - content: 消息内容
  /// - message_type: 消息类型 (text/image/file)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { message: {...} }
  static Future<Map<String, dynamic>> sendGroupMessage({
    required String token,
    required int groupId,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
  }) async {
    return await post('/api/groups/messages', {
      'group_id': groupId,
      'content': content,
      'message_type': messageType,
      if (fileName != null && fileName.isNotEmpty) 'file_name': fileName,
      if (quotedMessageId != null) 'quoted_message_id': quotedMessageId,
      if (quotedMessageContent != null)
        'quoted_message_content': quotedMessageContent,
    }, token: token);
  }

  /// 获取群组消息列表（从本地数据库）
  ///
  /// 参数:
  /// - token: 登录凭证 (必填)
  /// - groupId: 群组ID
  /// - page: 页码 (可选, 默认1)
  /// - pageSize: 每页数量 (可选, 默认100)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { messages: [...] }
  static Future<Map<String, dynamic>> getGroupMessages({
    required String token,
    required int groupId,
    int page = 1,
    int pageSize = 100,
  }) async {
    logger.debug('📱 从本地数据库获取群聊消息 - groupId: $groupId');
    final messageService = MessageService();
    return await messageService.getGroupMessages(
      groupId: groupId,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 更新群组信息
  ///
  /// 请求参数:
  /// - groupId: 群组ID (必填)
  /// - name: 群组名称 (可选，仅群主可修改)
  /// - announcement: 群公告(可选，仅群主可修改)
  /// - nickname: 用户在群组中的昵称(可选)
  /// - remark: 用户对群组的备注 (可选)
  /// - doNotDisturb: 消息免打扰 (可选)
  /// - addMembers: 要添加的成员ID列表 (可选，仅群主可操作)
  /// - removeMembers: 要移除的成员ID列表 (可选，仅群主可操作)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { group: {...} }
  static Future<Map<String, dynamic>> updateGroup({
    required String token,
    required int groupId,
    String? name,
    String? announcement,
    String? avatar,
    String? nickname,
    String? remark,
    bool? doNotDisturb,
    List<int>? addMembers,
    List<int>? removeMembers,
  }) async {
    final data = <String, dynamic>{};
    if (name != null && name.isNotEmpty) data['name'] = name;
    if (announcement != null) data['announcement'] = announcement;
    if (avatar != null && avatar.isNotEmpty) data['avatar'] = avatar;
    if (nickname != null) data['nickname'] = nickname.isEmpty ? null : nickname;
    if (remark != null) data['remark'] = remark.isEmpty ? null : remark;
    if (doNotDisturb != null) data['do_not_disturb'] = doNotDisturb;
    if (addMembers != null && addMembers.isNotEmpty) {
      data['add_members'] = addMembers;
    }
    if (removeMembers != null && removeMembers.isNotEmpty) {
      data['remove_members'] = removeMembers;
    }

    return await put('/api/groups/$groupId', data, token: token);
  }

  /// 禁言群组成员
  ///
  /// 参数:
  /// - groupId: 群组ID
  /// - userId: 要禁言的用户ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> muteGroupMember({
    required String token,
    required int groupId,
    required int userId,
  }) async {
    return await post('/api/groups/$groupId/mute', {
      'user_id': userId,
    }, token: token);
  }

  /// 解除群组成员禁言
  ///
  /// 参数:
  /// - groupId: 群组ID
  /// - userId: 要解除禁言的用户ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> unmuteGroupMember({
    required String token,
    required int groupId,
    required int userId,
  }) async {
    return await post('/api/groups/$groupId/unmute', {
      'user_id': userId,
    }, token: token);
  }

  /// 转让群主权限
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  /// - newOwnerId: 新群主的用户ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> transferGroupOwnership({
    required String token,
    required int groupId,
    required int newOwnerId,
  }) async {
    return await post('/api/groups/$groupId/transfer', {
      'new_owner_id': newOwnerId,
    }, token: token);
  }

  /// 设置群管理员
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  /// - adminIds: 管理员用户ID列表（最多5个）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> setGroupAdmins({
    required String token,
    required int groupId,
    required List<int> adminIds,
  }) async {
    return await post('/api/groups/$groupId/admins', {
      'admin_ids': adminIds,
    }, token: token);
  }

  /// 删除群组（解散群组）
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> deleteGroup({
    required String token,
    required int groupId,
  }) async {
    return await http
        .delete(
          Uri.parse(ApiConfig.getApiUrl('/api/groups/$groupId')),
          headers: {
            'Content-Type': 'application/json; charset=UTF-8',
            'Authorization': 'Bearer $token',
          },
        )
        .then((response) => _handleResponse(response));
  }

  /// 加入群组
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> joinGroup({
    required String token,
    required int groupId,
  }) async {
    return await post('/api/groups/$groupId/join', {}, token: token);
  }

  /// 退出群组
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> leaveGroup({
    required String token,
    required int groupId,
  }) async {
    return await post('/api/groups/$groupId/leave', {}, token: token);
  }

  /// 更新群组全体禁言状态
  ///
  /// 参数:
  /// - token: 用户认证令牌
  /// - groupId: 群组ID
  /// - allMuted: 是否开启全体禁言
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateGroupAllMuted({
    required String token,
    required int groupId,
    required bool allMuted,
  }) async {
    return await post('/api/groups/$groupId/all-muted', {
      'all_muted': allMuted,
    }, token: token);
  }

  /// 更新群组邀请确认状态
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  /// - inviteConfirmation: 是否开启邀请确认
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateGroupInviteConfirmation({
    required String token,
    required int groupId,
    required bool inviteConfirmation,
  }) async {
    return await post('/api/groups/$groupId/invite-confirmation', {
      'invite_confirmation': inviteConfirmation,
    }, token: token);
  }

  /// 更新群组"仅管理员可修改群名称"状态
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  /// - adminOnlyEditName: 是否仅管理员可修改群名称
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateGroupAdminOnlyEditName({
    required String token,
    required int groupId,
    required bool adminOnlyEditName,
  }) async {
    return await post('/api/groups/$groupId/admin-only-edit-name', {
      'admin_only_edit_name': adminOnlyEditName,
    }, token: token);
  }

  /// 更新群组"群成员查看权限"状态
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  /// - memberViewPermission: 群成员查看权限（true表示普通成员可以查看其他成员信息，false表示不可以）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> updateGroupMemberViewPermission({
    required String token,
    required int groupId,
    required bool memberViewPermission,
  }) async {
    return await post('/api/groups/$groupId/member-view-permission', {
      'member_view_permission': memberViewPermission,
    }, token: token);
  }

  /// 通过群成员审核
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  /// - userId: 待审核的用户ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> approveGroupMember({
    required String token,
    required int groupId,
    required int userId,
  }) async {
    return await post('/api/groups/$groupId/approve-member', {
      'user_id': userId,
    }, token: token);
  }

  /// 拒绝群成员审核
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  /// - userId: 待审核的用户ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> rejectGroupMember({
    required String token,
    required int groupId,
    required int userId,
  }) async {
    return await post('/api/groups/$groupId/reject-member', {
      'user_id': userId,
    }, token: token);
  }

  // ============ 常用联系人相关 API（本地数据库） ============

  /// 添加常用联系人（本地数据库）
  ///
  /// 请求参数:
  /// - contactId: 联系人ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> addFavoriteContact({
    required String token,
    required int contactId,
  }) async {
    logger.debug('📱 添加常用联系人（本地数据库）: ContactID=$contactId');
    final favoriteService = FavoriteService();
    try {
      final success = await favoriteService.addFavoriteContact(contactId);
      if (success) {
        return {'code': 0, 'message': '添加成功', 'data': null};
      } else {
        return {'code': -1, 'message': '添加失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '添加失败: $e', 'data': null};
    }
  }

  /// 移除常用联系人（本地数据库）
  ///
  /// 参数:
  /// - contactId: 联系人ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> removeFavoriteContact({
    required String token,
    required int contactId,
  }) async {
    logger.debug('📱 移除常用联系人（本地数据库）: ContactID=$contactId');
    final favoriteService = FavoriteService();
    try {
      final success = await favoriteService.removeFavoriteContact(contactId);
      if (success) {
        return {'code': 0, 'message': '移除成功', 'data': null};
      } else {
        return {'code': -1, 'message': '移除失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '移除失败: $e', 'data': null};
    }
  }

  /// 获取常用联系人列表（本地数据库）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: [{contact_id, user_id, username, full_name, avatar, status}...]
  static Future<Map<String, dynamic>> getFavoriteContacts({
    required String token,
  }) async {
    logger.debug('📱 从本地数据库获取常用联系人列表');
    final favoriteService = FavoriteService();
    try {
      final contacts = await favoriteService.getFavoriteContactsWithDetails();
      return {
        'code': 0,
        'message': '获取成功',
        'data': contacts,
      };
    } catch (e) {
      return {'code': -1, 'message': '获取失败: $e', 'data': null};
    }
  }

  /// 检查是否为常用联系人（本地数据库）
  ///
  /// 参数:
  /// - contactId: 联系人ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { is_favorite: true/false }
  static Future<Map<String, dynamic>> checkFavoriteContact({
    required String token,
    required int contactId,
  }) async {
    logger.debug('📱 检查常用联系人（本地数据库）: ContactID=$contactId');
    final favoriteService = FavoriteService();
    try {
      final isFavorite = await favoriteService.isFavoriteContact(contactId);
      return {
        'code': 0,
        'message': '检查成功',
        'data': {'is_favorite': isFavorite},
      };
    } catch (e) {
      return {'code': -1, 'message': '检查失败: $e', 'data': null};
    }
  }

  // ============ 常用群组相关 API（本地数据库） ============

  /// 添加常用群组（本地数据库）
  ///
  /// 请求参数:
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> addFavoriteGroup({
    required String token,
    required int groupId,
  }) async {
    logger.debug('📱 添加常用群组（本地数据库）: GroupID=$groupId');
    final favoriteService = FavoriteService();
    try {
      final success = await favoriteService.addFavoriteGroup(groupId);
      if (success) {
        return {'code': 0, 'message': '添加成功', 'data': null};
      } else {
        return {'code': -1, 'message': '添加失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '添加失败: $e', 'data': null};
    }
  }

  /// 移除常用群组（本地数据库）
  ///
  /// 参数:
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> removeFavoriteGroup({
    required String token,
    required int groupId,
  }) async {
    logger.debug('📱 移除常用群组（本地数据库）: GroupID=$groupId');
    final favoriteService = FavoriteService();
    try {
      final success = await favoriteService.removeFavoriteGroup(groupId);
      if (success) {
        return {'code': 0, 'message': '移除成功', 'data': null};
      } else {
        return {'code': -1, 'message': '移除失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '移除失败: $e', 'data': null};
    }
  }

  /// 获取常用群组ID列表（本地数据库）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: [group_id...]
  static Future<Map<String, dynamic>> getFavoriteGroups({
    required String token,
  }) async {
    logger.debug('📱 从本地数据库获取常用群组列表');
    final favoriteService = FavoriteService();
    try {
      final groupIds = await favoriteService.getFavoriteGroupIds();
      return {
        'code': 0,
        'message': '获取成功',
        'data': groupIds,
      };
    } catch (e) {
      return {'code': -1, 'message': '获取失败: $e', 'data': null};
    }
  }

  /// 检查是否为常用群组（本地数据库）
  ///
  /// 参数:
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { is_favorite: true/false }
  static Future<Map<String, dynamic>> checkFavoriteGroup({
    required String token,
    required int groupId,
  }) async {
    logger.debug('📱 检查常用群组（本地数据库）: GroupID=$groupId');
    final favoriteService = FavoriteService();
    try {
      final isFavorite = await favoriteService.isFavoriteGroup(groupId);
      return {
        'code': 0,
        'message': '检查成功',
        'data': {'is_favorite': isFavorite},
      };
    } catch (e) {
      return {'code': -1, 'message': '检查失败: $e', 'data': null};
    }
  }

  // ============ 文件传输助手相关 API（本地数据库） ============

  /// 获取文件助手消息列表（本地数据库）
  ///
  /// 参数:
  /// - page: 页码（默认1）
  /// - pageSize: 每页数量（默认50）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { messages: [...], total: 0, page: 1, pageSize: 50 }
  static Future<Map<String, dynamic>> getFileAssistantMessages({
    required String token,
    int page = 1,
    int pageSize = 50,
  }) async {
    logger.debug('📱 从本地数据库获取文件助手消息');
    final fileAssistantService = FileAssistantService();
    return await fileAssistantService.getMessagesApiFormat(
      page: page,
      pageSize: pageSize,
    );
  }

  /// 发送文件助手消息（本地数据库）
  ///
  /// 参数:
  /// - content: 消息内容
  /// - messageType: 消息类型（text, image, file, quoted）
  /// - fileName: 文件名（可选）
  /// - quotedMessageId: 被引用的消息ID（可选）
  /// - quotedMessageContent: 被引用的消息内容（可选）
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { id, user_id, content, created_at, ... }
  static Future<Map<String, dynamic>> sendFileAssistantMessage({
    required String token,
    required String content,
    String messageType = 'text',
    String? fileName,
    int? quotedMessageId,
    String? quotedMessageContent,
  }) async {
    logger.debug('📱 发送文件助手消息（本地数据库）');
    final fileAssistantService = FileAssistantService();
    try {
      final userId = await Storage.getUserId();
      if (userId == null) {
        return {'code': -1, 'message': '用户未登录', 'data': null};
      }
      
      final id = await fileAssistantService.saveMessage(
        content: content,
        messageType: messageType,
        fileName: fileName,
        quotedMessageId: quotedMessageId,
        quotedMessageContent: quotedMessageContent,
      );
      
      return {
        'code': 0,
        'message': '发送成功',
        'data': {
          'id': id,
          'user_id': userId,
          'content': content,
          'message_type': messageType,
          'created_at': DateTime.now().toIso8601String(),
          if (fileName != null) 'file_name': fileName,
          if (quotedMessageId != null) 'quoted_message_id': quotedMessageId,
          if (quotedMessageContent != null) 'quoted_message_content': quotedMessageContent,
        },
      };
    } catch (e) {
      return {'code': -1, 'message': '发送失败: $e', 'data': null};
    }
  }

  /// 删除文件助手消息（本地数据库）
  ///
  /// 参数:
  /// - messageId: 消息ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  static Future<Map<String, dynamic>> deleteFileAssistantMessage({
    required String token,
    required int messageId,
  }) async {
    logger.debug('📱 删除文件助手消息（本地数据库）: ID=$messageId');
    final fileAssistantService = FileAssistantService();
    try {
      final success = await fileAssistantService.deleteMessage(messageId);
      if (success) {
        return {'code': 0, 'message': '删除成功', 'data': null};
      } else {
        return {'code': -1, 'message': '删除失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '删除失败: $e', 'data': null};
    }
  }

  /// 撤回文件助手消息（本地数据库）
  ///
  /// 参数:
  /// - messageId: 消息ID
  ///
  /// 返回:
  /// - code: 0 表示成功
  static Future<Map<String, dynamic>> recallFileAssistantMessage({
    required String token,
    required int messageId,
  }) async {
    logger.debug('📱 撤回文件助手消息（本地数据库）: ID=$messageId');
    final fileAssistantService = FileAssistantService();
    try {
      final success = await fileAssistantService.recallMessage(messageId);
      if (success) {
        return {'code': 0, 'message': '撤回成功', 'data': null};
      } else {
        return {'code': -1, 'message': '撤回失败', 'data': null};
      }
    } catch (e) {
      return {'code': -1, 'message': '撤回失败: $e', 'data': null};
    }
  }

  // ============ 语音/视频通话相关 API ============

  /// 发起通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - calleeId: 被叫方用户ID
  /// - callType: 通话类型 ('voice' 或 'video')
  ///
  /// 返回:
  /// - channel_name: 频道名称
  /// - token: Agora Token
  /// - caller_uid: 主叫方 UID
  /// - callee_uid: 被叫方 UID
  /// - call_type: 通话类型
  static Future<Map<String, dynamic>> initiateCall({
    required String token,
    required int calleeId,
    required String callType,
  }) async {
    return await post('/api/call/initiate', {
      'callee_id': calleeId,
      'call_type': callType,
    }, token: token);
  }

  /// 发起群组语音/视频通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - calleeIds: 被叫方用户ID列表
  /// - callType: 通话类型 ('voice' 或 'video')
  ///
  /// 返回:
  /// - channel_name: 频道名称
  /// - token: Agora Token
  /// - caller_uid: 主叫方 UID
  /// - callee_uids: 被叫方 UID 映射
  /// - call_type: 通话类型
  /// - members: 所有成员信息列表
  static Future<Map<String, dynamic>> initiateGroupCall({
    required String token,
    required List<int> calleeIds,
    required String callType,
    int? groupId, // 添加群组ID参数（可选）
  }) async {
    final Map<String, dynamic> requestBody = {
      'callee_ids': calleeIds,
      'call_type': callType,
    };
    
    // 🔍 调试日志：显示接收到的groupId参数
    print('🔍 [ApiService.initiateGroupCall] 接收到的groupId: $groupId');
    
    // 如果提供了群组ID，添加到请求体中
    if (groupId != null) {
      requestBody['group_id'] = groupId;
      print('🔍 [ApiService.initiateGroupCall] 已添加group_id到请求体: $groupId');
    } else {
      print('🔍 [ApiService.initiateGroupCall] groupId为null，不添加到请求体');
    }
    
    // 🔍 调试日志：显示最终的请求体
    print('🔍 [ApiService.initiateGroupCall] 最终请求体: $requestBody');
    
    return await post('/api/call/initiate_group', requestBody, token: token);
  }

  /// 接听群组通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 频道名称
  ///
  /// 返回:
  /// - message: 响应消息
  static Future<Map<String, dynamic>> acceptGroupCall({
    required String token,
    required String channelName,
  }) async {
    return await post('/api/call/accept_group', {
      'channel_name': channelName,
    }, token: token);
  }

  /// 拒绝通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 频道名称
  /// - callerId: 主叫方用户ID
  ///
  /// 返回:
  /// - message: 响应消息
  static Future<Map<String, dynamic>> rejectCall({
    required String token,
    required String channelName,
    required int callerId,
  }) async {
    return await post('/api/call/reject', {
      'channel_name': channelName,
      'caller_id': callerId,
    }, token: token);
  }

  /// 邀请成员加入现有群组通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 现有通话的频道名称
  /// - calleeIds: 被邀请的成员ID列表
  /// - callType: 通话类型
  ///
  /// 返回:
  /// - message: 响应消息
  static Future<Map<String, dynamic>> inviteToGroupCall({
    required String token,
    required String channelName,
    required List<int> calleeIds,
    required String callType,
  }) async {
    return await post('/api/call/invite_to_group', {
      'channel_name': channelName,
      'callee_ids': calleeIds,
      'call_type': callType,
    }, token: token);
  }

  /// 结束通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 频道名称
  /// - peerId: 对方用户ID
  ///
  /// 返回:
  /// - message: 响应消息
  static Future<Map<String, dynamic>> endCall({
    required String token,
    required String channelName,
    required int peerId,
  }) async {
    return await post('/api/call/end', {
      'channel_name': channelName,
      'peer_id': peerId,
    }, token: token);
  }

  /// 刷新频道Token
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 频道名称
  ///
  /// 返回:
  /// - token: 新的 Agora Token
  /// - uid: 用户 UID
  static Future<Map<String, dynamic>> refreshChannelToken({
    required String token,
    required String channelName,
  }) async {
    return await post('/api/call/token', {
      'channel_name': channelName,
    }, token: token);
  }

  /// 离开群组通话
  ///
  /// 参数:
  /// - token: 用户token
  /// - channelName: 频道名称
  ///
  /// 返回:
  /// - message: 响应消息
  static Future<Map<String, dynamic>> leaveGroupCall({
    required String token,
    required String channelName,
    int? groupId,
    String? callType,
  }) async {
    final body = {
      'channel_name': channelName,
      if (groupId != null) 'group_id': groupId,
      if (callType != null) 'call_type': callType,
    };
    return await post('/api/call/leave_group', body, token: token);
  }

  /// 获取群组详细信息
  ///
  /// 参数:
  /// - token: 用户token
  /// - groupId: 群组ID
  ///
  /// 返回:
  /// - 群组详细信息，包含成员列表
  static Future<Map<String, dynamic>> getGroupInfo({
    required String token,
    required int groupId,
  }) async {
    return await get('/api/groups/$groupId', token: token);
  }

  // ============ 设备注册相关 API ============

  /// AES加密密钥（与服务器端保持一致）
  static const _deviceEncryptionKey = 'uDrAPQyLzXB3G1';

  /// 加密设备数据
  /// 使用 AES-256-CBC 算法加密，密钥使用 SHA-256 哈希后的值
  static String _encryptDeviceData(Map<String, dynamic> data) {
    try {
      // 1. 将数据序列化为JSON字符串
      final jsonString = json.encode(data);

      // 2. 生成32字节密钥（AES-256需要32字节）
      // 使用SHA-256对原始密钥进行哈希
      final keyBytes = sha256.convert(utf8.encode(_deviceEncryptionKey)).bytes;
      final key = encrypt.Key.fromBase64(base64.encode(keyBytes));

      // 3. 生成随机IV（16字节）
      final iv = encrypt.IV.fromSecureRandom(16);

      // 4. 创建AES加密器（CBC模式）
      final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));

      // 5. 加密数据
      final encrypted = encrypter.encrypt(jsonString, iv: iv);

      // 6. 将IV和密文合并，然后Base64编码
      // IV在前，密文在后
      final combined = iv.bytes + encrypted.bytes;

      return base64.encode(combined);
    } catch (e) {
      logger.debug('❌ 加密设备数据失败: $e');
      rethrow;
    }
  }

  /// 注册设备信息（首次启动时使用，支持AES-256加密）
  ///
  /// 参数：
  /// - uuid: 数据库密钥UUID
  /// - platform: 平台类型（android, ios, windows, macos, linux）
  /// - systemInfo: 系统详细信息
  /// - installedAt: 安装时间
  ///
  /// 返回：
  /// - code: 状态码
  /// - message: 响应消息
  static Future<Map<String, dynamic>> registerDevice({
    required String uuid,
    required String platform,
    required Map<String, dynamic> systemInfo,
    required DateTime installedAt,
  }) async {
    try {
      // 1. 准备原始数据
      final deviceData = {
        'uuid': uuid,
        'platform': platform,
        'system_info': systemInfo,
        'installed_at': installedAt.toIso8601String(),
      };

      logger.debug('🔒 正在加密设备注册数据...');

      // 2. 加密数据
      final encryptedData = _encryptDeviceData(deviceData);

      logger.debug('✅ 设备数据加密成功，数据长度: ${encryptedData.length}');

      // 3. 发送加密后的数据
      return await post('/api/device/register', {
        'encrypted_data': encryptedData,
      });
    } catch (e) {
      logger.debug('❌ 设备注册加密失败: $e');
      rethrow;
    }
  }

  // ============ 服务器收藏同步 API ============

  /// 在服务器上创建收藏
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - messageId: 消息ID (可选，群组消息可能没有)
  /// - content: 消息内容 (必填)
  /// - messageType: 消息类型 (必填)
  /// - fileName: 文件名 (可选)
  /// - senderId: 发送者ID (必填)
  /// - senderName: 发送者姓名 (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  /// - data: { id, user_id, content, ... }
  static Future<Map<String, dynamic>> createFavoriteOnServer({
    required String token,
    int? messageId,
    required String content,
    required String messageType,
    String? fileName,
    required int senderId,
    required String senderName,
  }) async {
    try {
      // 如果有messageId，使用原有的基于消息ID的API
      if (messageId != null) {
        return await post(ApiConfig.favorites, {
          'message_id': messageId,
        }, token: token);
      }
      
      // 如果没有messageId（如群组消息），使用直接创建的方式
      // 注意：服务器端的CreateFavorite需要message_id，所以群组消息需要特殊处理
      // 这里我们使用批量创建API的单条模式
      return await post('${ApiConfig.favorites}/direct', {
        'content': content,
        'message_type': messageType,
        'file_name': fileName,
        'sender_id': senderId,
        'sender_name': senderName,
      }, token: token);
    } catch (e) {
      logger.debug('❌ 服务器创建收藏失败: $e');
      return {'code': -1, 'message': '服务器创建收藏失败: $e', 'data': null};
    }
  }

  /// 从服务器获取收藏列表
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - page: 页码 (可选，默认1)
  /// - pageSize: 每页数量 (可选，默认100)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { favorites: [...], total: 0, page: 1, page_size: 100 }
  static Future<Map<String, dynamic>> getFavoritesFromServer({
    required String token,
    int page = 1,
    int pageSize = 100,
  }) async {
    try {
      return await get(
        '${ApiConfig.favorites}?page=$page&page_size=$pageSize',
        token: token,
      );
    } catch (e) {
      logger.debug('❌ 从服务器获取收藏列表失败: $e');
      return {'code': -1, 'message': '获取服务器收藏列表失败: $e', 'data': null};
    }
  }

  /// 从服务器删除收藏
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - favoriteId: 服务器端收藏ID (必填)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - message: 响应消息
  static Future<Map<String, dynamic>> deleteFavoriteOnServer({
    required String token,
    required int favoriteId,
  }) async {
    try {
      final headers = {'Content-Type': 'application/json; charset=UTF-8'};
      headers['Authorization'] = 'Bearer $token';

      final response = await http.delete(
        Uri.parse(ApiConfig.getApiUrl('${ApiConfig.favorites}/$favoriteId')),
        headers: headers,
      );
      return _handleResponse(response);
    } catch (e) {
      logger.debug('❌ 从服务器删除收藏失败: $e');
      return {'code': -1, 'message': '服务器删除收藏失败: $e', 'data': null};
    }
  }

  // ============ 历史消息同步 API ============

  /// 从服务器获取与指定联系人的消息历史（用于首次安装同步）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - contactId: 联系人ID (必填)
  /// - page: 页码 (可选，默认1)
  /// - pageSize: 每页数量 (可选，默认100)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { messages: [...], total: 0, page: 1, page_size: 100 }
  static Future<Map<String, dynamic>> getMessageHistoryFromServer({
    required String token,
    required int contactId,
    int page = 1,
    int pageSize = 100,
  }) async {
    try {
      logger.debug('📥 [API] 从服务器获取与联系人 $contactId 的消息历史 - page: $page, pageSize: $pageSize');
      return await get(
        '${ApiConfig.messagesHistory}/$contactId?page=$page&page_size=$pageSize',
        token: token,
      );
    } catch (e) {
      logger.debug('❌ [API] 从服务器获取消息历史失败: $e');
      return {'code': -1, 'message': '获取消息历史失败: $e', 'data': null};
    }
  }

  /// 从服务器获取群聊历史消息（用于首次安装同步）
  ///
  /// 请求参数:
  /// - token: 登录凭证 (必填)
  /// - groupId: 群组ID (必填)
  /// - page: 页码 (可选，默认1)
  /// - pageSize: 每页数量 (可选，默认100)
  ///
  /// 返回:
  /// - code: 0 表示成功
  /// - data: { messages: [...], total: 0, page: 1, page_size: 100 }
  static Future<Map<String, dynamic>> getGroupMessagesFromServer({
    required String token,
    required int groupId,
    int page = 1,
    int pageSize = 100,
  }) async {
    try {
      logger.debug('📥 [API] 从服务器获取群组 $groupId 历史消息 - page: $page, pageSize: $pageSize');
      return await get(
        '${ApiConfig.groups}/$groupId/messages?page=$page&page_size=$pageSize',
        token: token,
      );
    } catch (e) {
      logger.debug('❌ [API] 从服务器获取群聊历史消息失败: $e');
      return {'code': -1, 'message': '获取群聊历史消息失败: $e', 'data': null};
    }
  }
}

/// API 异常类

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  final bool isFatal; // 是否为致命错误（不应重试）

  ApiException({
    this.statusCode, 
    required this.message,
    this.isFatal = false,
  });

  @override
  String toString() {
    if (statusCode != null) {
      return 'ApiException($statusCode): $message';
    }
    return 'ApiException: $message';
  }
}
