import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../utils/logger.dart';

/// 分片下载配置
class ChunkDownloadConfig {
  /// 并行下载线程数（默认8）
  final int concurrency;
  
  /// 每个分片大小（默认2MB）
  final int chunkSize;
  
  /// 单个分片最大重试次数
  final int maxRetries;
  
  /// 连接超时时间
  final Duration connectTimeout;
  
  /// 读取超时时间
  final Duration readTimeout;

  const ChunkDownloadConfig({
    this.concurrency = 8,
    this.chunkSize = 2 * 1024 * 1024, // 2MB
    this.maxRetries = 3,
    this.connectTimeout = const Duration(seconds: 30),
    this.readTimeout = const Duration(seconds: 30), // 单个分片读取超时30秒
  });
}

/// 分片信息
class ChunkInfo {
  final int index;
  final int start;
  final int end;
  int downloaded;
  bool completed;
  int retryCount;

  ChunkInfo({
    required this.index,
    required this.start,
    required this.end,
    this.downloaded = 0,
    this.completed = false,
    this.retryCount = 0,
  });

  int get size => end - start + 1;
}

/// 下载进度信息
class DownloadProgress {
  final int totalBytes;
  final int downloadedBytes;
  final int activeChunks;
  final double speed; // bytes per second
  final Duration? estimatedTime;

  DownloadProgress({
    required this.totalBytes,
    required this.downloadedBytes,
    required this.activeChunks,
    required this.speed,
    this.estimatedTime,
  });

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';
  
  String get speedText {
    if (speed < 1024) return '${speed.toStringAsFixed(0)} B/s';
    if (speed < 1024 * 1024) return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    return '${(speed / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
}


/// 分片下载服务
/// 支持多线程并行下载，断点续传，自动重试
class ChunkDownloadService {
  static final ChunkDownloadService _instance = ChunkDownloadService._internal();
  factory ChunkDownloadService() => _instance;
  ChunkDownloadService._internal();

  final ChunkDownloadConfig _config = const ChunkDownloadConfig();
  
  bool _isCancelled = false;
  final List<ChunkInfo> _chunks = [];
  int _totalBytes = 0;
  int _downloadedBytes = 0;
  DateTime? _startTime;
  int _lastBytes = 0;
  DateTime? _lastSpeedCheck;

  /// 检查服务器是否支持 Range 请求
  Future<bool> supportsRangeRequest(String url) async {
    try {
      final response = await http.head(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );
      
      final acceptRanges = response.headers['accept-ranges'];
      final contentLength = response.headers['content-length'];
      
      logger.debug('🔍 [分片下载] Accept-Ranges: $acceptRanges');
      logger.debug('🔍 [分片下载] Content-Length: $contentLength');
      
      return acceptRanges == 'bytes' && contentLength != null;
    } catch (e) {
      logger.warning('⚠️ [分片下载] 检查Range支持失败: $e');
      return false;
    }
  }

  /// 获取文件大小
  Future<int?> getFileSize(String url) async {
    try {
      final response = await http.head(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );
      
      final contentLength = response.headers['content-length'];
      if (contentLength != null) {
        return int.tryParse(contentLength);
      }
      return null;
    } catch (e) {
      logger.error('❌ [分片下载] 获取文件大小失败: $e');
      return null;
    }
  }

  /// 分片并行下载
  /// [url] 下载地址
  /// [savePath] 保存路径
  /// [onProgress] 进度回调
  /// [expectedMd5] 期望的MD5值（可选，用于校验）
  Future<String?> download({
    required String url,
    required String savePath,
    Function(DownloadProgress)? onProgress,
    String? expectedMd5,
    ChunkDownloadConfig? config,
  }) async {
    final cfg = config ?? _config;
    _isCancelled = false;
    _chunks.clear();
    _downloadedBytes = 0;
    _startTime = DateTime.now();
    _lastSpeedCheck = _startTime;
    _lastBytes = 0;

    try {
      logger.info('📥 [分片下载] 开始下载: $url');
      logger.info('📁 [分片下载] 保存路径: $savePath');
      
      // 1. 检查是否支持分片下载
      final supportsRange = await supportsRangeRequest(url);
      if (!supportsRange) {
        logger.warning('⚠️ [分片下载] 服务器不支持Range请求，回退到普通下载');
        return await _fallbackDownload(url, savePath, onProgress);
      }

      // 2. 获取文件大小
      final fileSize = await getFileSize(url);
      if (fileSize == null || fileSize <= 0) {
        logger.warning('⚠️ [分片下载] 无法获取文件大小，回退到普通下载');
        return await _fallbackDownload(url, savePath, onProgress);
      }
      
      _totalBytes = fileSize;
      logger.info('📊 [分片下载] 文件大小: ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)} MB');

      // 3. 创建分片
      _createChunks(cfg.chunkSize);
      logger.info('🔢 [分片下载] 分片数量: ${_chunks.length}, 并发数: ${cfg.concurrency}');

      // 4. 创建临时目录和分片文件
      final tempDir = Directory('${savePath}_chunks');
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      // 5. 并行下载所有分片
      final completer = Completer<bool>();
      int activeDownloads = 0;
      int nextChunkIndex = 0;
      final errors = <String>[];

      void startNextChunk() async {
        if (_isCancelled || completer.isCompleted) return;
        
        while (activeDownloads < cfg.concurrency && nextChunkIndex < _chunks.length) {
          final chunk = _chunks[nextChunkIndex];
          nextChunkIndex++;
          activeDownloads++;
          
          _downloadChunk(
            url: url,
            chunk: chunk,
            tempDir: tempDir.path,
            config: cfg,
            onProgress: (bytes) {
              _downloadedBytes += bytes;
              _notifyProgress(onProgress, activeDownloads);
            },
          ).then((success) {
            activeDownloads--;
            if (!success && !_isCancelled) {
              errors.add('分片 ${chunk.index} 下载失败');
            }
            
            if (_isCancelled) {
              if (!completer.isCompleted) completer.complete(false);
              return;
            }
            
            // 检查是否所有分片都完成
            if (_chunks.every((c) => c.completed)) {
              if (!completer.isCompleted) completer.complete(true);
            } else if (activeDownloads == 0 && nextChunkIndex >= _chunks.length) {
              // 所有任务都结束但有分片未完成
              if (!completer.isCompleted) completer.complete(false);
            } else {
              startNextChunk();
            }
          });
        }
      }

      // 启动初始下载任务
      startNextChunk();

      // 等待所有分片完成，整体超时5分钟
      const overallTimeout = Duration(minutes: 5);
      logger.debug('⏱️ [分片下载] 整体超时时间: 5分钟');
      
      final success = await completer.future.timeout(
        overallTimeout,
        onTimeout: () {
          logger.error('❌ [分片下载] 整体下载超时');
          _isCancelled = true;
          return false;
        },
      );
      
      if (!success) {
        logger.error('❌ [分片下载] 下载失败: ${errors.join(", ")}');
        await _cleanup(tempDir);
        return null;
      }

      // 6. 合并分片
      logger.info('🔗 [分片下载] 开始合并分片...');
      final mergeSuccess = await _mergeChunks(tempDir.path, savePath);
      if (!mergeSuccess) {
        logger.error('❌ [分片下载] 合并分片失败');
        await _cleanup(tempDir);
        return null;
      }

      // 7. 清理临时文件
      await _cleanup(tempDir);

      // 8. 校验MD5（如果提供）
      if (expectedMd5 != null && expectedMd5.isNotEmpty) {
        logger.info('🔐 [分片下载] 校验文件MD5...');
        final file = File(savePath);
        final bytes = await file.readAsBytes();
        final digest = md5.convert(bytes);
        final fileMd5 = digest.toString();
        
        if (fileMd5.toLowerCase() != expectedMd5.toLowerCase()) {
          logger.error('❌ [分片下载] MD5校验失败');
          logger.error('   期望: $expectedMd5');
          logger.error('   实际: $fileMd5');
          await file.delete();
          return null;
        }
        logger.info('✅ [分片下载] MD5校验通过');
      }

      final duration = DateTime.now().difference(_startTime!);
      final avgSpeed = _totalBytes / duration.inSeconds;
      logger.info('✅ [分片下载] 下载完成！');
      logger.info('   耗时: ${duration.inSeconds}秒');
      logger.info('   平均速度: ${(avgSpeed / 1024 / 1024).toStringAsFixed(2)} MB/s');

      return savePath;
    } catch (e) {
      logger.error('❌ [分片下载] 下载异常: $e');
      return null;
    }
  }

  /// 取消下载
  void cancel() {
    _isCancelled = true;
    logger.info('🛑 [分片下载] 下载已取消');
  }

  /// 创建分片
  void _createChunks(int chunkSize) {
    _chunks.clear();
    int start = 0;
    int index = 0;
    
    while (start < _totalBytes) {
      final end = min(start + chunkSize - 1, _totalBytes - 1);
      _chunks.add(ChunkInfo(
        index: index,
        start: start,
        end: end,
      ));
      start = end + 1;
      index++;
    }
  }

  /// 下载单个分片
  Future<bool> _downloadChunk({
    required String url,
    required ChunkInfo chunk,
    required String tempDir,
    required ChunkDownloadConfig config,
    required Function(int) onProgress,
  }) async {
    final chunkFile = File(path.join(tempDir, 'chunk_${chunk.index}'));
    
    for (int retry = 0; retry <= config.maxRetries; retry++) {
      if (_isCancelled) return false;
      
      try {
        final request = http.Request('GET', Uri.parse(url));
        request.headers['Range'] = 'bytes=${chunk.start}-${chunk.end}';
        
        final response = await request.send().timeout(config.connectTimeout);
        
        if (response.statusCode != 206 && response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final sink = chunkFile.openWrite();
        int chunkDownloaded = 0;
        DateTime lastDataTime = DateTime.now();
        
        // 使用带超时的流读取
        await for (var data in response.stream.timeout(
          config.readTimeout,
          onTimeout: (sink) {
            // 检查是否长时间没有收到数据
            final elapsed = DateTime.now().difference(lastDataTime);
            if (elapsed > config.readTimeout) {
              logger.warning('⚠️ [分片下载] 分片 ${chunk.index} 读取超时');
              sink.close();
            }
          },
        )) {
          if (_isCancelled) {
            await sink.close();
            return false;
          }
          sink.add(data);
          chunkDownloaded += data.length;
          lastDataTime = DateTime.now();
          onProgress(data.length);
        }
        
        await sink.close();
        chunk.completed = true;
        chunk.downloaded = chunkDownloaded;
        
        return true;
      } catch (e) {
        chunk.retryCount++;
        logger.warning('⚠️ [分片下载] 分片 ${chunk.index} 第 ${retry + 1} 次尝试失败: $e');
        
        // 删除可能不完整的分片文件
        if (await chunkFile.exists()) {
          try {
            await chunkFile.delete();
          } catch (_) {}
        }
        
        if (retry < config.maxRetries) {
          await Future.delayed(Duration(seconds: pow(2, retry).toInt()));
        }
      }
    }
    
    return false;
  }

  /// 合并分片
  Future<bool> _mergeChunks(String tempDir, String savePath) async {
    try {
      final outputFile = File(savePath);
      final sink = outputFile.openWrite();
      
      for (int i = 0; i < _chunks.length; i++) {
        final chunkFile = File(path.join(tempDir, 'chunk_$i'));
        if (!await chunkFile.exists()) {
          logger.error('❌ [分片下载] 分片文件不存在: chunk_$i');
          await sink.close();
          return false;
        }
        
        final bytes = await chunkFile.readAsBytes();
        sink.add(bytes);
      }
      
      await sink.close();
      logger.info('✅ [分片下载] 分片合并完成');
      return true;
    } catch (e) {
      logger.error('❌ [分片下载] 合并分片异常: $e');
      return false;
    }
  }

  /// 清理临时文件
  Future<void> _cleanup(Directory tempDir) async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        logger.debug('🧹 [分片下载] 临时文件已清理');
      }
    } catch (e) {
      logger.warning('⚠️ [分片下载] 清理临时文件失败: $e');
    }
  }

  /// 通知进度
  void _notifyProgress(Function(DownloadProgress)? onProgress, int activeChunks) {
    if (onProgress == null) return;
    
    final now = DateTime.now();
    double speed = 0;
    
    if (_lastSpeedCheck != null) {
      final elapsed = now.difference(_lastSpeedCheck!).inMilliseconds;
      if (elapsed > 500) { // 每500ms计算一次速度
        speed = (_downloadedBytes - _lastBytes) / (elapsed / 1000);
        _lastBytes = _downloadedBytes;
        _lastSpeedCheck = now;
      }
    }
    
    Duration? estimatedTime;
    if (speed > 0) {
      final remaining = _totalBytes - _downloadedBytes;
      estimatedTime = Duration(seconds: (remaining / speed).round());
    }
    
    onProgress(DownloadProgress(
      totalBytes: _totalBytes,
      downloadedBytes: _downloadedBytes,
      activeChunks: activeChunks,
      speed: speed,
      estimatedTime: estimatedTime,
    ));
  }

  /// 回退到普通下载（当服务器不支持Range时）
  Future<String?> _fallbackDownload(
    String url,
    String savePath,
    Function(DownloadProgress)? onProgress,
  ) async {
    try {
      logger.info('📥 [普通下载] 开始下载...');
      
      final request = http.Request('GET', Uri.parse(url));
      final response = await request.send();
      
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      
      _totalBytes = response.contentLength ?? 0;
      _downloadedBytes = 0;
      
      final file = File(savePath);
      final sink = file.openWrite();
      
      await for (var chunk in response.stream) {
        if (_isCancelled) {
          await sink.close();
          await file.delete();
          return null;
        }
        sink.add(chunk);
        _downloadedBytes += chunk.length;
        _notifyProgress(onProgress, 1);
      }
      
      await sink.close();
      logger.info('✅ [普通下载] 下载完成');
      return savePath;
    } catch (e) {
      logger.error('❌ [普通下载] 下载失败: $e');
      return null;
    }
  }
}
