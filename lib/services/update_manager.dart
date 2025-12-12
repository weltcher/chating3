import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/update_info.dart';
import '../utils/logger.dart';
import 'update_service.dart';

/// 升级管理器
class UpdateManager extends ChangeNotifier {
  static final UpdateManager _instance = UpdateManager._internal();
  factory UpdateManager() => _instance;
  UpdateManager._internal();

  final UpdateService _updateService = UpdateService();

  UpdateInfo? _updateInfo;
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _downloadedFilePath;
  String? _errorMessage;

  UpdateInfo? get updateInfo => _updateInfo;
  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadedFilePath => _downloadedFilePath;
  String? get errorMessage => _errorMessage;
  bool get hasUpdate => _updateInfo != null;

  /// 检查更新
  Future<bool> checkForUpdate({bool silent = false}) async {
    if (_isChecking) {
      logger.debug('⏭️ [UpdateManager] 正在检查中，跳过重复请求');
      return false;
    }

    logger.info('🔍 [UpdateManager] 开始检查更新...');
    _isChecking = true;
    _errorMessage = null;
    // 不通知UI

    try {
      final updateInfo = await _updateService.checkUpdate();
      _updateInfo = updateInfo;
      _isChecking = false;
      // 不通知UI

      if (updateInfo != null) {
        logger.info('✅ [UpdateManager] 发现新版本: ${updateInfo.version}');
        if (!silent) {
          // 自动开始下载
          await downloadUpdate();
        }
      } else {
        logger.info('ℹ️ [UpdateManager] 当前已是最新版本');
      }

      return updateInfo != null;
    } catch (e) {
      _errorMessage = '检查更新失败: $e';
      logger.error('❌ [UpdateManager] 检查更新失败: $e');
      _isChecking = false;
      // 不通知UI
      return false;
    }
  }

  /// 下载更新（后台静默下载，完全不影响UI）
  Future<bool> downloadUpdate() async {
    if (_updateInfo == null) {
      logger.warning('⚠️ [UpdateManager] 无更新信息，无法下载');
      return false;
    }
    
    if (_isDownloading) {
      logger.debug('⏭️ [UpdateManager] 正在下载中，跳过重复请求');
      return false;
    }

    _isDownloading = true;
    _downloadProgress = 0.0;
    _errorMessage = null;

    try {
      final filePath = await _updateService.downloadUpdate(
        _updateInfo!,
        null, // 不传递进度回调，完全静默
      );

      if (filePath == null) {
        throw Exception('下载失败');
      }

      // 校验文件
      final isValid = await _updateService.verifyFile(filePath, _updateInfo!.md5);
      if (!isValid) {
        await File(filePath).delete();
        throw Exception('文件校验失败');
      }

      _downloadedFilePath = filePath;
      _isDownloading = false;
      return true;
    } catch (e) {
      _errorMessage = '下载失败: $e';
      _isDownloading = false;
      return false;
    }
  }

  /// 安装更新
  Future<bool> installUpdate() async {
    if (_downloadedFilePath == null) {
      logger.warning('⚠️ [UpdateManager] 无下载文件，无法安装');
      return false;
    }

    if (_updateInfo == null) {
      logger.warning('⚠️ [UpdateManager] 无更新信息，无法安装');
      return false;
    }

    logger.info('📦 [UpdateManager] 开始安装更新...');
    try {
      bool success = false;
      
      if (Platform.isAndroid || Platform.isIOS) {
        // 移动端直接安装
        logger.info('📱 [UpdateManager] 移动端安装模式');
        success = await _updateService.installUpdate(_downloadedFilePath!);
        
        // 移动端安装成功后保存版本信息
        // 注意：移动端安装后会启动系统安装器，应用会被替换
        // 所以这里先保存版本信息，新版本启动后会读取到
        if (success) {
          await UpdateService.saveVersionToDatabase(_updateInfo!);
        }
      } else {
        // PC端启动升级器
        logger.info('💻 [UpdateManager] PC端升级模式');
        
        // PC端在启动升级器前保存版本信息
        // 因为升级器会替换文件并重启应用
        await UpdateService.saveVersionToDatabase(_updateInfo!);
        
        success = await _updateService.startUpdater(_downloadedFilePath!);
      }
      
      return success;
    } catch (e) {
      _errorMessage = '安装失败: $e';
      logger.error('❌ [UpdateManager] 安装失败: $e');
      // 不通知UI
      return false;
    }
  }

  /// 取消下载
  void cancelDownload() {
    if (_downloadedFilePath != null) {
      File(_downloadedFilePath!).delete().catchError((_) {});
      _downloadedFilePath = null;
    }
    _isDownloading = false;
    _downloadProgress = 0.0;
    // 不通知UI
  }

  /// 清除更新信息
  void clearUpdate() {
    _updateInfo = null;
    _downloadedFilePath = null;
    _downloadProgress = 0.0;
    _errorMessage = null;
    // 不通知UI
  }

  /// 重置状态
  void reset() {
    cancelDownload();
    clearUpdate();
  }
}
