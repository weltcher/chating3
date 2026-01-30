import 'dart:io';
import 'package:flutter/material.dart';
import '../models/update_info.dart';
import '../widgets/update_dialog.dart';
import '../utils/logger.dart';
import 'update_manager.dart';

/// 升级检查器 - 用于在登录后自动检查更新
class UpdateChecker {
  static final UpdateChecker _instance = UpdateChecker._internal();
  factory UpdateChecker() => _instance;
  UpdateChecker._internal();

  final UpdateManager _updateManager = UpdateManager();
  bool _hasChecked = false;

  /// 登录后检查更新
  /// 在登录成功后调用此方法，会异步检查更新并在有新版本时弹窗提示
  /// Android端：登录时立即检测，不延迟
  /// 其他平台：延迟2秒后检查
  Future<void> checkAfterLogin(BuildContext context) async {
    logger.info('🔄 [升级检查] checkAfterLogin 被调用, _hasChecked=$_hasChecked');
    // 避免重复检查
    if (_hasChecked) {
      logger.info('⏭️ [升级检查] 已检查过，跳过');
      return;
    }
    _hasChecked = true;
    logger.info('🔄 [升级检查] 设置 _hasChecked=true，开始异步检查');

    // 异步检查更新，不阻塞主流程
    _checkUpdateAsync(context);
  }

  /// 异步检查更新（完全不阻塞主线程）
  void _checkUpdateAsync(BuildContext context) {
    // 使用 Future 完全异步执行，不阻塞主线程
    Future(() async {
      try {
        logger.info('🔄 [升级检查] 开始检查更新...');
        
        // 🤖 Android端：登录时立即检测版本，不延迟
        // 其他平台：延迟2秒后检查，让用户先看到主界面
        if (!Platform.isAndroid) {
          await Future.delayed(const Duration(seconds: 2));
        }

        // 检查更新
        final hasUpdate = await _updateManager.checkForUpdate(silent: true);

        if (hasUpdate && _updateManager.updateInfo != null) {
          final updateInfo = _updateManager.updateInfo!;
          logger.info('✅ [升级检查] 发现新版本: ${updateInfo.version}');
          
          // 弹窗展示版本信息，等待用户点击"立即更新"后才下载
          if (context.mounted) {
            logger.info('💬 [升级检查] 弹窗展示版本信息');
            _showUpdateDialog(context, updateInfo);
          }
        } else {
          logger.info('ℹ️ [升级检查] 当前已是最新版本');
        }
      } catch (e) {
        logger.error('❌ [升级检查] 检查更新失败: $e');
      }
    });
  }

  /// 显示更新对话框
  /// Android端：自动开始下载安装
  /// 其他平台：显示版本信息，等待用户点击
  void _showUpdateDialog(BuildContext context, UpdateInfo updateInfo) {
    if (!context.mounted) return;

    // 🤖 Android端：自动开始下载安装
    final autoStart = Platform.isAndroid;
    
    logger.info('💬 [升级检查] 显示更新对话框 (autoStartDownload=$autoStart)');
    UpdateDialog.show(
      context,
      updateInfo,
      autoStartDownload: autoStart,
      onUpdateComplete: () {
        logger.info('✅ [升级检查] 用户确认更新');
      },
    );
  }

  /// 手动检查更新（设置页面使用）
  Future<bool> manualCheck(BuildContext context) async {
    try {
      logger.info('🔍 [手动检查] 用户手动检查更新');
      final hasUpdate = await _updateManager.checkForUpdate(silent: true);

      if (hasUpdate && _updateManager.updateInfo != null) {
        logger.info('✅ [手动检查] 发现新版本: ${_updateManager.updateInfo!.version}');
        // 弹窗展示版本信息，等待用户点击"立即更新"后才下载
        if (context.mounted) {
          _showUpdateDialog(context, _updateManager.updateInfo!);
          return true;
        }
      } else {
        logger.info('ℹ️ [手动检查] 当前已是最新版本');
      }
      return false;
    } catch (e) {
      logger.error('❌ [手动检查] 检查更新失败: $e');
      return false;
    }
  }

  /// 重置检查状态（用于切换账号后重新检查）
  void reset() {
    _hasChecked = false;
    _updateManager.reset();
  }
}
