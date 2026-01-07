import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/logger.dart';

/// 移动端文件存储权限助手
/// 仅用于移动端（Android/iOS），不涉及PC端
class MobileStoragePermissionHelper {
  /// 检查并请求文件存储权限（移动端专用）
  /// 适用场景：
  /// 1. 选择图片、视频、文件时
  /// 2. 保存图片、视频、文件时
  ///
  /// [context] - BuildContext用于显示权限对话框
  /// [forSaving] - true表示是保存操作，false表示是选择操作（用于显示不同的提示信息）
  /// 返回 true 表示有权限，false表示没有权限
  static Future<bool> checkAndRequestStoragePermission(
    BuildContext context, {
    bool forSaving = false,
  }) async {
    // 只处理移动端
    if (!Platform.isAndroid && !Platform.isIOS) {
      logger.debug('非移动端平台，跳过权限检查');
      return true;
    }

    try {
      // Android 和 iOS 的权限处理
      PermissionStatus status;

      if (Platform.isAndroid) {
        // Android 13+ (API 33+) 使用新的媒体权限
        // Android 12及以下使用存储权限

        // 先检查照片权限（适用于 Android 13+）
        status = await Permission.photos.status;

        if (status.isGranted) {
          logger.debug('照片权限已授予');
          return true;
        }

        // 检查视频权限（适用于 Android 13+）
        final videoStatus = await Permission.videos.status;
        if (videoStatus.isGranted) {
          logger.debug('视频权限已授予');
          return true;
        }

        // 检查存储权限（适用于 Android 12及以下）
        status = await Permission.storage.status;

        if (status.isGranted) {
          logger.debug('存储权限已授予');
          return true;
        }

        // 权限未授予，需要请求权限
        logger.debug('存储权限未授予，开始请求权限');
        return await _requestAndroidStoragePermission(
          context,
          forSaving: forSaving,
        );
      } else if (Platform.isIOS) {
        // iOS 使用照片权限
        status = await Permission.photos.status;

        if (status.isGranted) {
          logger.debug('iOS照片权限已授予');
          return true;
        }

        // 权限未授予，需要请求权限
        logger.debug('iOS照片权限未授予，开始请求权限');
        return await _requestIOSStoragePermission(
          context,
          forSaving: forSaving,
        );
      }

      return false;
    } catch (e) {
      logger.error('检查存储权限时出错', error: e);
      return false;
    }
  }

  /// 请求 Android 存储权限（私有方法）
  static Future<bool> _requestAndroidStoragePermission(
    BuildContext context, {
    required bool forSaving,
  }) async {
    try {
      // 尝试请求照片权限（适用于 Android 13+）
      PermissionStatus photosStatus = await Permission.photos.request();

      if (photosStatus.isGranted) {
        logger.debug('照片权限已授予');
        return true;
      }

      // 尝试请求视频权限（适用于 Android 13+）
      PermissionStatus videoStatus = await Permission.videos.request();

      if (videoStatus.isGranted) {
        logger.debug('视频权限已授予');
        return true;
      }

      // 尝试请求存储权限（适用于 Android 12及以下）
      PermissionStatus storageStatus = await Permission.storage.request();

      if (storageStatus.isGranted) {
        logger.debug('存储权限已授予');
        return true;
      }

      // 检查是否被永久拒绝
      bool isPermanentlyDenied =
          photosStatus.isPermanentlyDenied ||
          videoStatus.isPermanentlyDenied ||
          storageStatus.isPermanentlyDenied;

      if (isPermanentlyDenied) {
        // 显示对话框引导用户去设置
        if (context.mounted) {
          await _showPermissionDialog(context, forSaving: forSaving);
        }
        return false;
      }

      // 权限被拒绝但不是永久拒绝，显示对话框让用户选择重试或去设置
      if (context.mounted) {
        final shouldRetry = await _showPermissionDeniedDialog(context, forSaving: forSaving);
        if (shouldRetry) {
          // 用户选择重试，再次请求权限
          return await _requestAndroidStoragePermission(context, forSaving: forSaving);
        }
      }

      return false;
    } catch (e) {
      logger.error('请求Android存储权限时出错', error: e);
      return false;
    }
  }

  /// 请求 iOS 存储权限（私有方法）
  static Future<bool> _requestIOSStoragePermission(
    BuildContext context, {
    required bool forSaving,
  }) async {
    try {
      // iOS 请求照片权限
      PermissionStatus status = await Permission.photos.request();

      if (status.isGranted) {
        logger.debug('iOS照片权限已授予');
        return true;
      }

      // 检查是否被永久拒绝
      if (status.isPermanentlyDenied) {
        // 显示对话框引导用户去设置
        if (context.mounted) {
          await _showPermissionDialog(context, forSaving: forSaving);
        }
        return false;
      }

      // 权限被拒绝但不是永久拒绝，显示对话框让用户选择重试或去设置
      if (context.mounted) {
        final shouldRetry = await _showPermissionDeniedDialog(context, forSaving: forSaving);
        if (shouldRetry) {
          // 用户选择重试，再次请求权限
          return await _requestIOSStoragePermission(context, forSaving: forSaving);
        }
      }

      return false;
    } catch (e) {
      logger.error('请求iOS存储权限时出错', error: e);
      return false;
    }
  }

  /// 显示权限对话框，引导用户去设置
  static Future<void> _showPermissionDialog(
    BuildContext context, {
    required bool forSaving,
  }) async {
    final action = forSaving ? '保存' : '选择';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('需要文件访问权限'),
          content: Text(
            '应用需要访问您的文件和存储空间以${action}图片、视频和文件。\n\n'
            '请在设置中允许文件访问和存储权限。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                // 打开应用设置页面
                await openAppSettings();
              },
              child: const Text(
                '去设置',
                style: TextStyle(
                  color: Color(0xFF4A90E2),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 显示权限被拒绝的提示（SnackBar）
  static void _showPermissionDeniedSnackBar(
    BuildContext context, {
    required bool forSaving,
  }) {
    final action = forSaving ? '保存' : '选择';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('需要文件访问权限才能$action文件'),
        backgroundColor: Colors.orange,
        action: SnackBarAction(
          label: '去设置',
          textColor: Colors.white,
          onPressed: () async {
            await openAppSettings();
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 显示权限被拒绝的对话框（非永久拒绝时使用）
  /// 返回 true 表示用户选择重试，false 表示用户取消或去设置
  static Future<bool> _showPermissionDeniedDialog(
    BuildContext context, {
    required bool forSaving,
  }) async {
    final action = forSaving ? '保存' : '选择';
    bool shouldRetry = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('需要文件访问权限'),
          content: Text(
            '${action}图片、视频和文件需要文件访问权限。\n\n'
            '请点击"重试"并在弹出的系统对话框中选择"允许"。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                shouldRetry = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text(
                '重试',
                style: TextStyle(
                  color: Color(0xFF4A90E2),
                  fontWeight: FontWeight.bold,
                ),
              ),
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

    return shouldRetry;
  }
}
