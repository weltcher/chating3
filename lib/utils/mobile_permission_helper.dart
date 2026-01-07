import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/logger.dart';

/// 移动端权限助手
class MobilePermissionHelper {
  /// 请求相机权限
  static Future<bool> requestCameraPermission(BuildContext context) async {
    logger.debug('📷 [权限] 开始请求相机权限...');
    
    // 先检查当前状态
    final currentStatus = await Permission.camera.status;
    logger.debug('📷 [权限] 当前相机权限状态: $currentStatus');
    
    if (currentStatus.isGranted) {
      logger.debug('📷 [权限] 相机权限已授予');
      return true;
    }
    
    // 请求权限（会弹出系统授权弹窗）
    final status = await Permission.camera.request();
    logger.debug('📷 [权限] 请求后相机权限状态: $status');

    if (status.isGranted) {
      logger.debug('📷 [权限] 相机权限授予成功');
      return true;
    }

    // 权限被拒绝，显示引导对话框
    if (status.isDenied) {
      logger.debug('📷 [权限] 相机权限被拒绝（可再次请求）');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要相机权限',
          message: '视频通话需要使用相机，请允许访问相机权限。',
          canRetry: true,
          onRetry: () async {
            // 再次请求权限
            final retryStatus = await Permission.camera.request();
            return retryStatus.isGranted;
          },
        );
      }
    } else if (status.isPermanentlyDenied) {
      logger.debug('📷 [权限] 相机权限被永久拒绝，需要去设置中开启');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要相机权限',
          message: '相机权限已被禁用，请在系统设置中手动开启相机权限，以便进行视频通话。',
          canRetry: false,
        );
      }
    }

    return false;
  }

  /// 请求麦克风权限
  static Future<bool> requestMicrophonePermission(BuildContext context) async {
    logger.debug('🎤 [权限] 开始请求麦克风权限...');
    
    // 先检查当前状态
    final currentStatus = await Permission.microphone.status;
    logger.debug('🎤 [权限] 当前麦克风权限状态: $currentStatus');
    
    if (currentStatus.isGranted) {
      logger.debug('🎤 [权限] 麦克风权限已授予');
      return true;
    }
    
    // 请求权限
    final status = await Permission.microphone.request();
    logger.debug('🎤 [权限] 请求后麦克风权限状态: $status');

    if (status.isGranted) {
      logger.debug('🎤 [权限] 麦克风权限授予成功');
      return true;
    }

    // 权限被拒绝
    if (status.isDenied) {
      logger.debug('🎤 [权限] 麦克风权限被拒绝（可再次请求）');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要麦克风权限',
          message: '语音/视频通话需要使用麦克风，请允许访问麦克风权限。',
          canRetry: true,
          onRetry: () async {
            final retryStatus = await Permission.microphone.request();
            return retryStatus.isGranted;
          },
        );
      }
    } else if (status.isPermanentlyDenied) {
      logger.debug('🎤 [权限] 麦克风权限被永久拒绝，需要去设置中开启');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要麦克风权限',
          message: '麦克风权限已被禁用，请在系统设置中手动开启麦克风权限，以便进行语音通话。',
          canRetry: false,
        );
      }
    }

    return false;
  }

  /// 请求存储权限
  static Future<bool> requestStoragePermission(BuildContext context) async {
    logger.debug('📁 [权限] 开始请求存储权限...');
    
    // 检查是否已经有权限
    if (await Permission.storage.isGranted ||
        await Permission.photos.isGranted) {
      logger.debug('📁 [权限] 存储权限已授予');
      return true;
    }

    // 尝试请求照片权限（适用于iOS和Android 13+）
    PermissionStatus status = await Permission.photos.request();
    logger.debug('📁 [权限] 照片权限状态: $status');

    // 如果照片权限被拒绝，尝试请求存储权限（适用于Android 12及以下）
    if (!status.isGranted) {
      status = await Permission.storage.request();
      logger.debug('📁 [权限] 存储权限状态: $status');
    }

    if (status.isGranted) {
      logger.debug('📁 [权限] 存储权限授予成功');
      return true;
    }

    if (status.isDenied) {
      logger.debug('📁 [权限] 存储权限被拒绝（可再次请求）');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要存储权限',
          message: '发送和保存文件需要存储权限，请允许访问存储。',
          canRetry: true,
          onRetry: () async {
            final retryStatus = await Permission.storage.request();
            return retryStatus.isGranted;
          },
        );
      }
    } else if (status.isPermanentlyDenied) {
      logger.debug('📁 [权限] 存储权限被永久拒绝');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要存储权限',
          message: '存储权限已被禁用，请在系统设置中手动开启存储权限，以便发送和保存文件。',
          canRetry: false,
        );
      }
    }

    return false;
  }

  /// 请求通知权限
  static Future<bool> requestNotificationPermission(
    BuildContext context,
  ) async {
    logger.debug('🔔 [权限] 开始请求通知权限...');
    
    final currentStatus = await Permission.notification.status;
    logger.debug('🔔 [权限] 当前通知权限状态: $currentStatus');
    
    if (currentStatus.isGranted) {
      logger.debug('🔔 [权限] 通知权限已授予');
      return true;
    }
    
    final status = await Permission.notification.request();
    logger.debug('🔔 [权限] 请求后通知权限状态: $status');

    if (status.isGranted) {
      logger.debug('🔔 [权限] 通知权限授予成功');
      return true;
    }

    if (status.isDenied) {
      logger.debug('🔔 [权限] 通知权限被拒绝（可再次请求）');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要通知权限',
          message: '接收新消息提醒需要通知权限，请允许发送通知。',
          canRetry: true,
          onRetry: () async {
            final retryStatus = await Permission.notification.request();
            return retryStatus.isGranted;
          },
        );
      }
    } else if (status.isPermanentlyDenied) {
      logger.debug('🔔 [权限] 通知权限被永久拒绝');
      if (context.mounted) {
        await _showPermissionDialog(
          context,
          title: '需要通知权限',
          message: '通知权限已被禁用，请在系统设置中手动开启通知权限，以便接收新消息提醒。',
          canRetry: false,
        );
      }
    }

    return false;
  }

  /// 请求所有必要权限
  static Future<Map<String, bool>> requestAllPermissions(
    BuildContext context,
  ) async {
    final results = <String, bool>{};

    // 请求通知权限
    results['notification'] = await requestNotificationPermission(context);

    // 其他权限根据需要请求

    logger.debug('权限请求结果: $results');
    return results;
  }

  /// 检查权限状态
  static Future<Map<Permission, PermissionStatus>> checkPermissions() async {
    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.notification,
      Permission.photos,
    ];

    final statuses = <Permission, PermissionStatus>{};
    for (final permission in permissions) {
      statuses[permission] = await permission.status;
    }

    return statuses;
  }

  /// 显示权限对话框
  static Future<bool> _showPermissionDialog(
    BuildContext context, {
    required String title,
    required String message,
    bool canRetry = false,
    Future<bool> Function()? onRetry,
  }) async {
    bool granted = false;
    
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            if (canRetry && onRetry != null)
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  granted = await onRetry();
                },
                child: const Text('重试'),
              ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
    
    return granted;
  }

  /// 处理键盘高度变化
  static double getKeyboardHeight(BuildContext context) {
    return MediaQuery.of(context).viewInsets.bottom;
  }

  /// 获取安全区域padding
  static EdgeInsets getSafeAreaPadding(BuildContext context) {
    return MediaQuery.of(context).padding;
  }
}
