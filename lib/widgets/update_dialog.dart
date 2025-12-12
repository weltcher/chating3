import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/update_info.dart';
import '../services/update_service.dart';
import '../utils/app_localizations.dart';

/// 升级提示对话框（带下载进度）
class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final VoidCallback? onUpdateComplete;

  const UpdateDialog({
    Key? key,
    required this.updateInfo,
    this.onUpdateComplete,
  }) : super(key: key);

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();

  /// 显示更新对话框
  static Future<void> show(
    BuildContext context,
    UpdateInfo updateInfo, {
    VoidCallback? onUpdateComplete,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false, // 禁止点击外部关闭
      builder: (context) => UpdateDialog(
        updateInfo: updateInfo,
        onUpdateComplete: onUpdateComplete,
      ),
    );
  }
}

class _UpdateDialogState extends State<UpdateDialog> {
  final UpdateService _updateService = UpdateService();
  
  bool _isDownloading = false;
  bool _isInstalling = false;
  bool _downloadComplete = false;
  double _progress = 0.0;
  String? _downloadedFilePath;
  String? _errorMessage;
  
  // 节流控制
  Timer? _progressTimer;
  double _pendingProgress = 0.0;

  @override
  void initState() {
    super.initState();
    // 自动开始下载
    _startDownload();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  void _startDownload() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _errorMessage = null;
    });

    // 启动定时器，每500ms更新一次进度（节流）
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted && _pendingProgress != _progress) {
        setState(() {
          _progress = _pendingProgress;
        });
      }
    });

    try {
      final filePath = await _updateService.downloadUpdate(
        widget.updateInfo,
        (received, total) {
          if (total > 0) {
            // 只更新待处理的进度值，不直接更新UI
            _pendingProgress = received / total;
          }
        },
      );

      _progressTimer?.cancel();

      if (filePath == null) {
        throw Exception('下载失败');
      }

      // 校验文件
      final isValid = await _updateService.verifyFile(filePath, widget.updateInfo.md5);
      if (!isValid) {
        await File(filePath).delete();
        throw Exception('文件校验失败');
      }

      _downloadedFilePath = filePath;
      
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadComplete = true;
          _progress = 1.0;
        });
      }
    } catch (e) {
      _progressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final updateInfo = widget.updateInfo;

    return WillPopScope(
      onWillPop: () async => false, // 禁止返回键关闭
      child: AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.blue),
            const SizedBox(width: 8),
            Text(localizations.translate('new_version_available')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildVersionInfo(localizations, updateInfo),
              const SizedBox(height: 16),
              _buildReleaseNotes(localizations, updateInfo),
              const SizedBox(height: 16),
              _buildDownloadProgress(localizations),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                _buildErrorMessage(),
              ],
            ],
          ),
        ),
        actions: _buildActions(localizations),
      ),
    );
  }

  Widget _buildVersionInfo(AppLocalizations localizations, UpdateInfo updateInfo) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                localizations.translate('version_number'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(updateInfo.version),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                localizations.translate('file_size'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(updateInfo.formattedFileSize),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                localizations.translate('release_date'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '${updateInfo.releaseDate.year}-${updateInfo.releaseDate.month.toString().padLeft(2, '0')}-${updateInfo.releaseDate.day.toString().padLeft(2, '0')}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReleaseNotes(AppLocalizations localizations, UpdateInfo updateInfo) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          localizations.translate('update_content'),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            updateInfo.releaseNotes,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadProgress(AppLocalizations localizations) {
    final percent = (_progress * 100).toStringAsFixed(1);
    final downloadedMB = (widget.updateInfo.fileSize * _progress / 1024 / 1024).toStringAsFixed(2);
    final totalMB = (widget.updateInfo.fileSize / 1024 / 1024).toStringAsFixed(2);
    
    String statusText;
    if (_isDownloading) {
      statusText = '${localizations.translate('downloading')} $percent% ($downloadedMB MB / $totalMB MB)';
    } else if (_downloadComplete) {
      statusText = localizations.translate('download_complete');
    } else if (_errorMessage != null) {
      statusText = localizations.translate('download_failed');
    } else {
      statusText = localizations.translate('preparing');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          statusText,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _errorMessage != null ? Colors.red : null,
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _progress,
          backgroundColor: Colors.grey.shade200,
          valueColor: AlwaysStoppedAnimation<Color>(
            _errorMessage != null ? Colors.red : Colors.blue,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions(AppLocalizations localizations) {
    // 下载中：不显示任何按钮
    if (_isDownloading) {
      return [];
    }

    // 安装中
    if (_isInstalling) {
      return [
        TextButton(
          onPressed: null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(localizations.translate('installing')),
            ],
          ),
        ),
      ];
    }

    // 下载失败：显示重试按钮
    if (_errorMessage != null) {
      return [
        TextButton(
          onPressed: _startDownload,
          child: Text(localizations.translate('retry')),
        ),
      ];
    }

    // 下载完成：显示立即更新和稍后按钮
    if (_downloadComplete) {
      return [
        if (!widget.updateInfo.forceUpdate)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(localizations.translate('later')),
          ),
        ElevatedButton(
          onPressed: _installUpdate,
          child: Text(localizations.translate('update_now')),
        ),
      ];
    }

    return [];
  }

  Future<void> _installUpdate() async {
    if (_downloadedFilePath == null) return;

    setState(() => _isInstalling = true);

    try {
      // 保存版本信息到数据库
      await UpdateService.saveVersionToDatabase(widget.updateInfo);

      bool success = false;
      
      if (Platform.isAndroid || Platform.isIOS) {
        success = await _updateService.installUpdate(_downloadedFilePath!);
        if (success) {
          widget.onUpdateComplete?.call();
          if (mounted) {
            Navigator.of(context).pop();
          }
        }
      } else {
        // PC端启动升级器
        success = await _updateService.startUpdater(_downloadedFilePath!);
        if (success) {
          widget.onUpdateComplete?.call();
          exit(0);
        }
      }

      if (!success) {
        setState(() {
          _isInstalling = false;
          _errorMessage = '安装失败';
        });
      }
    } catch (e) {
      setState(() {
        _isInstalling = false;
        _errorMessage = '安装失败: $e';
      });
    }
  }
}
