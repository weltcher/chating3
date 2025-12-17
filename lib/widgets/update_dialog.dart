import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/update_info.dart';
import '../services/update_service.dart';
import '../utils/app_localizations.dart';

// 全局标志：更新对话框是否正在显示
bool _isUpdateDialogShowing = false;

// Getter 函数：获取更新对话框状态
bool isUpdateDialogShowing() => _isUpdateDialogShowing;

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
    _isUpdateDialogShowing = true;
    return showDialog(
      context: context,
      barrierDismissible: false, // 禁止点击外部关闭
      builder: (context) => UpdateDialog(
        updateInfo: updateInfo,
        onUpdateComplete: onUpdateComplete,
      ),
    ).whenComplete(() {
      _isUpdateDialogShowing = false;
    });
  }
}

class _UpdateDialogState extends State<UpdateDialog> {
  final UpdateService _updateService = UpdateService();
  
  bool _isDownloading = false;
  bool _isInstalling = false;
  bool _downloadComplete = false;
  bool _usedCachedFile = false; // 是否使用了已下载的文件
  double _progress = 0.0;
  String? _downloadedFilePath;
  String? _errorMessage;
  
  // 节流控制
  Timer? _progressTimer;
  double _pendingProgress = 0.0;
  
  // 下载速度计算
  int _lastReceivedBytes = 0;
  DateTime? _lastSpeedTime;
  double _downloadSpeed = 0.0; // bytes per second

  @override
  void initState() {
    super.initState();
    // 不自动下载，等待用户点击"立即更新"
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  /// 用户点击"立即更新"后开始下载并安装
  void _startDownloadAndInstall() {
    // iOS 平台：直接打开浏览器访问下载链接
    if (Platform.isIOS) {
      _openDownloadUrlInBrowser();
      return;
    }
    _startDownload(autoInstall: true);
  }

  /// iOS 平台：打开系统浏览器访问下载链接
  Future<void> _openDownloadUrlInBrowser() async {
    final downloadUrl = widget.updateInfo.downloadUrl;
    if (downloadUrl.isEmpty) {
      setState(() {
        _errorMessage = '下载链接为空';
      });
      return;
    }

    try {
      final uri = Uri.parse(downloadUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        // 关闭对话框
        if (mounted) {
          Navigator.of(context).pop();
        }
      } else {
        setState(() {
          _errorMessage = '无法打开下载链接';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '打开下载链接失败: $e';
      });
    }
  }

  void _startDownload({bool autoInstall = false}) async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _errorMessage = null;
      _usedCachedFile = false;
    });

    // 启动定时器，每500ms更新一次进度（节流）
    _lastSpeedTime = DateTime.now();
    _lastReceivedBytes = 0;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted && _pendingProgress != _progress) {
        setState(() {
          _progress = _pendingProgress;
        });
      }
    });

    try {
      // 记录开始时间，用于判断是否使用了缓存文件
      final startTime = DateTime.now();
      
      final filePath = await _updateService.downloadUpdate(
        widget.updateInfo,
        (received, total) {
          if (total > 0) {
            // 只更新待处理的进度值，不直接更新UI
            _pendingProgress = received / total;
            
            // 计算下载速度
            final now = DateTime.now();
            if (_lastSpeedTime != null) {
              final elapsed = now.difference(_lastSpeedTime!).inMilliseconds;
              if (elapsed >= 500) {
                final bytesDownloaded = received - _lastReceivedBytes;
                _downloadSpeed = bytesDownloaded / (elapsed / 1000);
                _lastReceivedBytes = received;
                _lastSpeedTime = now;
              }
            }
          }
        },
        useChunkDownload: true,
        concurrency: 8,
      );

      _progressTimer?.cancel();

      if (filePath == null) {
        throw Exception('下载失败：未知错误');
      }

      // 如果下载很快完成（小于1秒），可能是使用了缓存文件
      final duration = DateTime.now().difference(startTime);
      if (duration.inMilliseconds < 1000 && _progress >= 1.0) {
        _usedCachedFile = true;
      }

      _downloadedFilePath = filePath;
      
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadComplete = true;
          _progress = 1.0;
        });
        
        // 下载完成后自动进入安装
        if (autoInstall) {
          _installUpdate();
        }
      }
    } catch (e) {
      _progressTimer?.cancel();
      if (mounted) {
        // 提取更友好的错误信息
        String errorMsg = e.toString();
        if (errorMsg.startsWith('Exception: ')) {
          errorMsg = errorMsg.substring('Exception: '.length);
        }
        setState(() {
          _isDownloading = false;
          _errorMessage = errorMsg;
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

  /// 格式化下载速度
  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
  }

  Widget _buildDownloadProgress(AppLocalizations localizations) {
    // 未开始下载时不显示进度条
    if (!_isDownloading && !_downloadComplete && _errorMessage == null) {
      return const SizedBox.shrink();
    }
    
    final percent = (_progress * 100).toStringAsFixed(1);
    final downloadedMB = (widget.updateInfo.fileSize * _progress / 1024 / 1024).toStringAsFixed(2);
    final totalMB = (widget.updateInfo.fileSize / 1024 / 1024).toStringAsFixed(2);
    
    String statusText;
    String? speedText;
    
    if (_isDownloading) {
      if (_usedCachedFile && _progress >= 1.0) {
        statusText = '使用已下载的文件';
      } else {
        statusText = '${localizations.translate('downloading')} $percent% ($downloadedMB MB / $totalMB MB)';
        if (_downloadSpeed > 0) {
          speedText = _formatSpeed(_downloadSpeed);
        }
      }
    } else if (_downloadComplete) {
      if (_usedCachedFile) {
        statusText = '使用已下载的文件';
      } else {
        statusText = localizations.translate('download_complete');
      }
    } else if (_errorMessage != null) {
      statusText = localizations.translate('download_failed');
    } else {
      statusText = localizations.translate('preparing');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                statusText,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _errorMessage != null ? Colors.red : null,
                ),
              ),
            ),
            if (speedText != null)
              Text(
                speedText,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
          ],
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

    // 下载失败：显示取消按钮
    if (_errorMessage != null) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.translate('cancel')),
        ),
      ];
    }

    // 下载完成：自动进入安装，不显示按钮
    if (_downloadComplete) {
      return [];
    }

    // 未开始下载：显示立即更新和稍后按钮
    return [
      if (!widget.updateInfo.forceUpdate)
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.translate('later')),
        ),
      ElevatedButton(
        onPressed: _startDownloadAndInstall,
        child: Text(localizations.translate('update_now')),
      ),
    ];
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
