import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/update_info.dart';
import '../config/api_config.dart';
import '../config/app_version_config.dart';
import '../utils/logger.dart';
import 'local_database_service.dart';
import 'chunk_download_service.dart';
import 'version_persistence_service.dart';

/// 升级服务
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  /// 获取当前版本信息（用于 UI 展示）
  /// iOS端：仅从 pubspec.yaml 获取版本，禁止从其他文件和数据库中获取
  /// 其他平台：优先级：持久化文件 > 本地数据库 > 包信息
  /// PC端升级会删除应用目录，所以需要从持久化文件读取
  static Future<Map<String, String>> getCurrentVersion() async {
    try {
      final platform = Platform.operatingSystem;
      
      // 🍎 iOS端：直接使用全局版本字段，禁止从其他文件和数据库中获取，不存在优先级
      if (Platform.isIOS) {
        final versionInfo = AppVersionConfig.getIOSVersion();
        if (versionInfo != null) {
          logger.info('🍎 [版本信息] iOS 从全局版本字段获取: ${versionInfo['version']} (代码: ${versionInfo['versionCode']})');
          return versionInfo;
        } else {
          logger.error('❌ [版本信息] iOS 全局版本字段获取失败');
          // iOS读取失败时返回默认值，不尝试从其他来源获取
          return {
            'version': '1.0.0',
            'versionCode': '1',
          };
        }
      }
      
      final persistenceService = VersionPersistenceService();
      
      // 1. 优先从持久化文件获取（PC端升级后不会丢失）
      final persistedVersion = await persistenceService.getVersion(platform);
      if (persistedVersion != null) {
        String version = persistedVersion['version'] as String;
        String versionCode = persistedVersion['version_code'] as String? ?? version;
        
        logger.info('📱 [版本信息] 从持久化文件获取: $version (代码: $versionCode)');
        return {
          'version': version,
          'versionCode': versionCode,
        };
      }

      // 2. 从本地数据库获取版本信息
      final dbService = LocalDatabaseService();
      final storedVersion = await dbService.getStoredVersion(platform);

      if (storedVersion != null) {
        String version = storedVersion['version'] as String;
        String versionCode = storedVersion['version_code'] as String? ?? version;

        // 修复旧版本格式问题：如果 version 包含错误格式（如 1.0.41765520149）
        if (version.contains(RegExp(r'\d+\.\d+\.\d+\d{10}'))) {
          final match = RegExp(r'^(\d+\.\d+\.\d+)(\d{10})$').firstMatch(version);
          if (match != null) {
            version = match.group(1)!; // 1.0.4
            versionCode = match.group(2)!; // 1765520149
            logger.debug('🔧 [版本信息] 修复数据库中的版本格式: ${storedVersion['version']} -> $version + $versionCode');

            // 更新数据库中的版本信息
            await dbService.saveVersion(
              version: version,
              versionCode: versionCode,
              fileSize: storedVersion['file_size'] as int? ?? 0,
              releaseNotes: storedVersion['release_notes'] as String?,
              releaseDate: storedVersion['release_date'] as String?,
              platform: platform,
            );
          }
        }

        logger.debug('📱 [版本信息] 从数据库获取: $version (代码: $versionCode)');
        return {
          'version': version,
          'versionCode': versionCode,
        };
      }

      // 3. 数据库没有记录，从包信息获取
      final packageInfo = await PackageInfo.fromPlatform();
      String version = packageInfo.version;
      String buildNumber = packageInfo.buildNumber;

      // 修复旧版本格式问题
      if (version.contains(RegExp(r'\d+\.\d+\.\d+\d{10}'))) {
        final match = RegExp(r'^(\d+\.\d+\.\d+)(\d{10})$').firstMatch(version);
        if (match != null) {
          version = match.group(1)!;
          buildNumber = match.group(2)!;
          logger.debug('🔧 [版本信息] 修复包信息中的版本格式: ${packageInfo.version} -> $version + $buildNumber');
        }
      }

      logger.debug('📱 [版本信息] 从包信息获取: $version (代码: $buildNumber)');
      return {
        'version': version,
        'versionCode': buildNumber,
      };
    } catch (e) {
      logger.error('❌ [版本信息] 获取失败: $e');
      return {
        'version': '1.0.0',
        'versionCode': '1',
      };
    }
  }

  /// 获取用于检查更新的版本信息
  /// iOS端：仅从 pubspec.yaml 获取版本，禁止从其他文件和数据库中获取，不存在优先级
  /// 其他平台：使用 getCurrentVersion() 的逻辑
  static Future<Map<String, String>> getVersionForUpdateCheck() async {
    try {
      // 🍎 iOS端：直接使用全局版本字段，禁止从其他文件和数据库中获取，不存在优先级
      if (Platform.isIOS) {
        final versionInfo = AppVersionConfig.getIOSVersion();
        if (versionInfo != null) {
          logger.info('🍎 [版本检查] iOS 从全局版本字段获取: ${versionInfo['version']} (代码: ${versionInfo['versionCode']})');
          return versionInfo;
        } else {
          logger.error('❌ [版本检查] iOS 全局版本字段获取失败');
          // iOS禁止从其他来源获取，返回默认值
          return {
            'version': '1.0.0',
            'versionCode': '1',
          };
        }
      }

      // 🤖 Android 等：从 pubspec.yaml 获取，失败则 PackageInfo
      if (Platform.isAndroid) {
        String version;
        String buildNumber;
        try {
          final pubspec = await rootBundle.loadString('pubspec.yaml');
          final match = RegExp(r'^\s*version\s*:\s*([^\s]+)\s*$', multiLine: true).firstMatch(pubspec);
          if (match == null) throw StateError('pubspec.yaml 中未找到 version 字段');
          final raw = match.group(1)!.trim();
          final parts = raw.split('+');
          if (parts.isEmpty || parts[0].isEmpty) {
            throw FormatException('pubspec.yaml version 格式不符合 x.y.z+build: $raw');
          }
          version = parts[0].replaceAll('v', '');
          buildNumber = parts.length > 1 && parts[1].isNotEmpty
              ? parts[1]
              : (await PackageInfo.fromPlatform()).buildNumber;
          logger.info('📱 [版本检查] 从 pubspec.yaml 获取: $version (代码: $buildNumber)');
        } catch (e) {
          final packageInfo = await PackageInfo.fromPlatform();
          version = packageInfo.version;
          buildNumber = packageInfo.buildNumber;
          if (version.contains(RegExp(r'\d+\.\d+\.\d+\d{10}'))) {
            final m = RegExp(r'^(\d+\.\d+\.\d+)(\d{10})$').firstMatch(version);
            if (m != null) {
              version = m.group(1)!;
              buildNumber = m.group(2)!;
            }
          }
          logger.warning('📱 [版本检查] 读取 pubspec.yaml 失败，回退到 PackageInfo: $version (代码: $buildNumber)');
        }
        return {'version': version, 'versionCode': buildNumber};
      }

      // 🖥️ 其他平台：使用原有逻辑
      return await getCurrentVersion();
    } catch (e) {
      logger.error('❌ [版本检查] 获取版本失败: $e');
      return {
        'version': '1.0.0',
        'versionCode': '1',
      };
    }
  }

  /// 保存版本信息到本地数据库和持久化文件（升级成功后调用）
  static Future<void> saveVersionToDatabase(UpdateInfo updateInfo) async {
    try {
      final platform = Platform.operatingSystem;
      final dbService = LocalDatabaseService();
      final persistenceService = VersionPersistenceService();
      
      // 1. 保存到持久化文件（PC端升级后不会丢失）
      await persistenceService.saveVersion(
        version: updateInfo.version,
        versionCode: updateInfo.versionCode,
        platform: platform,
        fileSize: updateInfo.fileSize,
        releaseNotes: updateInfo.releaseNotes,
        releaseDate: updateInfo.releaseDate.toIso8601String(),
      );
      
      // 2. 保存到本地数据库
      await dbService.saveVersion(
        version: updateInfo.version,
        versionCode: updateInfo.versionCode,
        fileSize: updateInfo.fileSize,
        releaseNotes: updateInfo.releaseNotes,
        releaseDate: updateInfo.releaseDate.toIso8601String(),
        platform: platform,
      );

      logger.info('✅ [版本保存] 版本信息已保存: ${updateInfo.version}');
    } catch (e) {
      logger.error('❌ [版本保存] 保存失败: $e');
    }
  }

  /// 检查更新
  /// iOS端：从 pubspec.yaml 获取版本，调用服务端接口，直接根据 has_update 判断是否有新版本
  Future<UpdateInfo?> checkUpdate() async {
    try {
      final versionInfo = await getVersionForUpdateCheck();
      logger.info('📱 [检查更新] 当前版本: ${versionInfo['version']} (代码: ${versionInfo['versionCode']})');
      
      final queryParams = {
        'platform': Platform.operatingSystem,
        'current_version': versionInfo['version']!,
        'version_code': versionInfo['versionCode']!,
      };
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/version/check')
          .replace(queryParameters: queryParams);
      
      logger.info('🔍 [检查更新] 请求URL: $uri');
      
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      logger.info('📡 [检查更新] 响应状态码: ${response.statusCode}');
      logger.info('📦 [检查更新] 响应内容: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        logger.info('📦 [检查更新] 解析数据: has_update=${data['has_update']}, update_info=${data['update_info'] != null}');
        
        if (data['has_update'] == true && data['update_info'] != null) {
          final updateInfo = UpdateInfo.fromJson(data['update_info']);
          logger.info('✅ [检查更新] 发现新版本: ${updateInfo.version}');
          return updateInfo;
        } else {
          logger.info('ℹ️ [检查更新] 无可用更新 (has_update=${data['has_update']})');
        }
      } else {
        logger.warning('⚠️ [检查更新] 服务器返回错误: ${response.statusCode}');
      }
      return null;
    } catch (e) {
      logger.error('❌ [检查更新] 失败: $e');
      return null;
    }
  }

  /// 分片下载服务实例
  final ChunkDownloadService _chunkDownloadService = ChunkDownloadService();


  /// 下载更新包（支持分片并行下载）
  /// [useChunkDownload] 是否使用分片下载，默认true
  /// [concurrency] 并行下载线程数，默认8
  Future<String?> downloadUpdate(
    UpdateInfo updateInfo,
    Function(int received, int total)? onProgress, {
    bool useChunkDownload = true,
    int concurrency = 8,
  }) async {
    try {
      logger.info('📥 [下载更新] 开始下载: ${updateInfo.downloadUrl}');
      
      final dir = await _getDownloadDirectory();
      logger.debug('📁 [下载更新] 下载目录: ${dir.path}');
      
      final fileName = _getUpdateFileName(updateInfo.downloadUrl);
      final filePath = path.join(dir.path, fileName);
      final file = File(filePath);
      
      logger.debug('📦 [下载更新] 文件路径: $filePath');

      // 如果文件已存在且大小匹配，直接返回
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize == updateInfo.fileSize || updateInfo.fileSize == 0) {
          logger.info('📦 [下载更新] 发现已下载的文件');
          logger.info('✅ [下载更新] 使用已下载的文件，跳过下载 (${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB)');
          onProgress?.call(updateInfo.fileSize, updateInfo.fileSize);
          return filePath;
        } else {
          // 文件大小不匹配，删除重新下载
          logger.warning('⚠️ [下载更新] 文件大小不匹配，重新下载');
          await file.delete();
        }
      }

      // 判断是否使用分片下载
      // 条件：启用分片下载 && 文件大于5MB
      final shouldUseChunk = useChunkDownload && updateInfo.fileSize > 5 * 1024 * 1024;
      
      if (shouldUseChunk) {
        logger.info('🚀 [下载更新] 使用分片并行下载 ($concurrency线程)');
        return await _chunkDownload(updateInfo, filePath, onProgress, concurrency);
      } else {
        logger.info('🌐 [下载更新] 使用普通下载');
        return await _normalDownload(updateInfo, filePath, onProgress);
      }
    } catch (e) {
      logger.error('❌ [下载更新] 下载失败: $e');
      rethrow;
    }
  }

  /// 分片并行下载
  Future<String?> _chunkDownload(
    UpdateInfo updateInfo,
    String filePath,
    Function(int received, int total)? onProgress,
    int concurrency,
  ) async {
    final config = ChunkDownloadConfig(
      concurrency: concurrency,
      chunkSize: 2 * 1024 * 1024, // 2MB per chunk
      maxRetries: 5, // 单个分片重试5次
      downloadRetries: 3, // 整体下载失败重试3次
      connectTimeout: const Duration(seconds: 60), // 弱网环境延长超时
      readTimeout: const Duration(seconds: 60), // 弱网环境延长超时
      enableResume: true, // 启用断点续传
    );

    final result = await _chunkDownloadService.download(
      url: updateInfo.downloadUrl,
      savePath: filePath,
      config: config,
      expectedMd5: updateInfo.md5.isNotEmpty ? updateInfo.md5 : null,
      onProgress: (progress) {
        onProgress?.call(progress.downloadedBytes, progress.totalBytes);
      },
    );

    return result;
  }

  /// 普通单线程下载
  Future<String?> _normalDownload(
    UpdateInfo updateInfo,
    String filePath,
    Function(int received, int total)? onProgress,
  ) async {
    logger.info('🌐 [下载更新] 开始HTTP请求...');
    final request = http.Request('GET', Uri.parse(updateInfo.downloadUrl));
    final response = await request.send();

    if (response.statusCode != 200) {
      logger.error('❌ [下载更新] HTTP错误: ${response.statusCode}');
      throw Exception('服务器返回错误: HTTP ${response.statusCode}');
    }

    final contentLength = response.contentLength ?? updateInfo.fileSize;
    logger.info('📊 [下载更新] 文件大小: ${(contentLength / 1024 / 1024).toStringAsFixed(2)} MB');
    
    int received = 0;
    final file = File(filePath);
    final sink = file.openWrite();
    
    await for (var chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, contentLength);
    }
    await sink.close();
    
    logger.info('✅ [下载更新] 下载完成: $filePath');
    return filePath;
  }

  /// 取消下载
  void cancelDownload() {
    _chunkDownloadService.cancel();
    logger.info('🛑 [下载更新] 下载已取消');
  }

  /// 获取下载目录
  Future<Directory> _getDownloadDirectory() async {
    if (Platform.isAndroid) {
      // Android使用外部存储的Download目录
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        final downloadDir = Directory(path.join(dir.path, 'Download'));
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }
        return downloadDir;
      }
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // PC端：使用应用目录上一级的tmp目录
      final currentExePath = Platform.resolvedExecutable;
      final appDir = path.dirname(currentExePath);
      final parentDir = path.dirname(appDir);
      final tmpDir = Directory(path.join(parentDir, 'tmp'));
      if (!await tmpDir.exists()) {
        await tmpDir.create(recursive: true);
      }
      return tmpDir;
    }
    // 其他平台使用临时目录
    return await getTemporaryDirectory();
  }

  /// 校验文件完整性
  Future<bool> verifyFile(String filePath, String expectedMd5) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        logger.error('❌ [文件校验] 文件不存在: $filePath');
        return false;
      }

      // 如果没有提供MD5，跳过校验
      if (expectedMd5.isEmpty) {
        logger.warning('⚠️ [文件校验] 未提供MD5，跳过校验');
        return true;
      }

      logger.info('🔐 [文件校验] 开始计算文件MD5...');
      final fileSize = await file.length();
      logger.debug('📦 [文件校验] 文件大小: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB');
      
      final bytes = await file.readAsBytes();
      final digest = md5.convert(bytes);
      final fileMd5 = digest.toString();

      logger.info('🔐 [文件校验] 期望MD5: ${expectedMd5.toLowerCase()}');
      logger.info('🔐 [文件校验] 实际MD5: ${fileMd5.toLowerCase()}');
      
      final isValid = fileMd5.toLowerCase() == expectedMd5.toLowerCase();
      if (isValid) {
        logger.info('✅ [文件校验] MD5校验通过');
      } else {
        logger.error('❌ [文件校验] MD5校验失败');
      }
      
      return isValid;
    } catch (e) {
      logger.error('❌ [文件校验] 校验过程出错: $e');
      return false;
    }
  }

  /// 获取更新文件名
  /// 直接从下载URL中提取完整文件名（包含版本号）
  String _getUpdateFileName(String downloadUrl) {
    // 从URL中提取完整文件名
    try {
      final uri = Uri.parse(downloadUrl);
      final urlPath = uri.path;
      final urlFileName = path.basename(urlPath);
      
      // 如果URL包含有效的文件名，直接使用
      if (urlFileName.isNotEmpty && urlFileName.contains('.')) {
        logger.debug('📦 [文件名] 从URL提取: $urlFileName');
        return urlFileName;
      }
    } catch (e) {
      logger.warning('⚠️ [文件名] 从URL提取失败: $e');
    }

    // 如果无法从URL提取，使用默认文件名
    logger.debug('📦 [文件名] 使用默认文件名');
    if (Platform.isWindows) {
      return 'youdu_update.exe';
    } else if (Platform.isMacOS) {
      return 'youdu_update.dmg';
    } else if (Platform.isLinux) {
      return 'youdu_update.AppImage';
    } else if (Platform.isAndroid) {
      return 'youdu_update.apk';
    } else if (Platform.isIOS) {
      return 'youdu_update.ipa';
    }
    return 'youdu_update';
  }

  /// 安装更新（移动端）
  Future<bool> installUpdate(String filePath) async {
    try {
      logger.info('📦 [安装更新] 开始安装: $filePath');
      
      if (Platform.isAndroid) {
        return await _installAndroidApk(filePath);
      } else if (Platform.isIOS) {
        logger.info('ℹ️ [安装更新] iOS 更新需要通过 App Store');
        return false;
      }
      return false;
    } catch (e) {
      logger.error('❌ [安装更新] 失败: $e');
      return false;
    }
  }

  /// Android APK 安装
  Future<bool> _installAndroidApk(String filePath) async {
    try {
      logger.info('📱 [Android安装] 检查安装权限...');
      
      // 检查并请求安装未知应用权限（Android 8.0+）
      if (await Permission.requestInstallPackages.isDenied) {
        logger.info('⚠️ [Android安装] 请求安装未知应用权限...');
        final status = await Permission.requestInstallPackages.request();
        if (status.isDenied) {
          logger.error('❌ [Android安装] 用户拒绝了安装未知应用权限');
          return false;
        }
        logger.info('✅ [Android安装] 权限已授予');
      }

      logger.info('🚀 [Android安装] 调用系统安装器...');
      // 使用 open_filex 打开APK文件，调用系统安装器
      final result = await OpenFilex.open(
        filePath,
        type: 'application/vnd.android.package-archive',
      );

      logger.info('📋 [Android安装] 结果: ${result.type}, ${result.message}');
      
      return result.type == ResultType.done;
    } catch (e) {
      logger.error('❌ [Android安装] 失败: $e');
      return false;
    }
  }


  /// 启动升级器（PC端）
  Future<bool> startUpdater(String updateFilePath) async {
    try {
      logger.info('💻 [PC升级] 启动升级器: $updateFilePath');
      
      if (Platform.isWindows) {
        return await _startWindowsUpdater(updateFilePath);
      } else if (Platform.isMacOS) {
        return await _startMacUpdater(updateFilePath);
      } else if (Platform.isLinux) {
        return await _startLinuxUpdater(updateFilePath);
      }
      return false;
    } catch (e) {
      logger.error('❌ [PC升级] 启动升级器失败: $e');
      return false;
    }
  }

  /// 启动带下载功能的升级器
  /// 在 shell 脚本中下载、校验、安装，显示下载进度
  Future<bool> startUpdaterWithDownload(UpdateInfo updateInfo) async {
    try {
      logger.info('💻 [升级] 启动带下载功能的升级器');
      
      if (Platform.isWindows) {
        return await _startWindowsUpdaterWithDownload(updateInfo);
      } else if (Platform.isMacOS) {
        return await _startMacUpdaterWithDownload(updateInfo);
      } else if (Platform.isLinux) {
        return await _startLinuxUpdaterWithDownload(updateInfo);
      } else if (Platform.isAndroid) {
        return await _startAndroidUpdaterWithDownload(updateInfo);
      }
      return false;
    } catch (e) {
      logger.error('❌ [升级] 启动升级器失败: $e');
      return false;
    }
  }

  /// Windows 带下载功能的升级器
  Future<bool> _startWindowsUpdaterWithDownload(UpdateInfo updateInfo) async {
    try {
      final currentExePath = Platform.resolvedExecutable;
      final appDir = path.dirname(currentExePath);
      final parentDir = path.dirname(appDir);
      final appName = path.basenameWithoutExtension(currentExePath);
      
      // tmp目录在应用目录的上一级
      final tmpDir = path.join(parentDir, 'tmp');
      
      // 确保tmp目录存在
      final tmpDirObj = Directory(tmpDir);
      if (!await tmpDirObj.exists()) {
        await tmpDirObj.create(recursive: true);
      }
      
      // 从URL获取文件扩展名
      final downloadUrl = updateInfo.downloadUrl;
      final urlFileName = path.basename(Uri.parse(downloadUrl).path);
      final fileExtension = path.extension(urlFileName).toLowerCase();
      final zipFile = path.join(tmpDir, 'youdu_update$fileExtension');
      
      logger.info('🪟 [Windows升级] 当前应用: $currentExePath');
      logger.info('📁 [Windows升级] 应用目录: $appDir');
      logger.info('📁 [Windows升级] 临时目录: $tmpDir');
      logger.info('🔗 [Windows升级] 下载地址: $downloadUrl');
      logger.info('📦 [Windows升级] 保存路径: $zipFile');
      
      // 将路径中的反斜杠转换为双反斜杠（用于批处理脚本）
      final zipFileEsc = zipFile.replaceAll('\\', '\\\\');
      final tmpDirEsc = tmpDir.replaceAll('\\', '\\\\');
      final appDirEsc = appDir.replaceAll('\\', '\\\\');
      final currentExePathEsc = currentExePath.replaceAll('\\', '\\\\');
      
      final scriptContent = '''
@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
echo ========================================
echo           Youdu Update Script
echo ========================================
echo.

set "DOWNLOAD_URL=$downloadUrl"
set "ZIP_FILE=$zipFileEsc"
set "TMP_DIR=$tmpDirEsc"
set "APP_DIR=$appDirEsc"
set "APP_NAME=$appName"
set "APP_EXE=$currentExePathEsc"
set "EXPECTED_MD5=${updateInfo.md5}"

echo [1/7] Downloading update package...
echo URL: !DOWNLOAD_URL!
echo Saving to: !ZIP_FILE!
echo.
powershell -Command "& { \$ProgressPreference = 'Continue'; Invoke-WebRequest -Uri '!DOWNLOAD_URL!' -OutFile '!ZIP_FILE!' -UseBasicParsing }"
if !ERRORLEVEL! NEQ 0 (
    echo ERROR: Failed to download update package!
    pause
    exit /b 1
)
echo Download completed!
echo.

echo [2/7] Verifying file integrity...
for %%A in ("!ZIP_FILE!") do set "FILE_SIZE=%%~zA"
echo File size: !FILE_SIZE! bytes
if "!EXPECTED_MD5!" NEQ "" (
    for /f "skip=1 tokens=* delims=" %%# in ('certutil -hashfile "!ZIP_FILE!" MD5') do (
        if not defined FILE_MD5 set "FILE_MD5=%%#"
    )
    set "FILE_MD5=!FILE_MD5: =!"
    echo Expected MD5: !EXPECTED_MD5!
    echo Actual MD5: !FILE_MD5!
    if /I not "!FILE_MD5!"=="!EXPECTED_MD5!" (
        echo ERROR: MD5 verification failed!
        del "!ZIP_FILE!" >nul 2>&1
        pause
        exit /b 1
    )
    echo MD5 verification passed!
) else (
    echo Skipping MD5 verification...
)
echo.

echo [3/7] Closing application...
taskkill /F /IM !APP_NAME!.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [4/7] Extracting update package...
powershell -Command "Expand-Archive -Path '!ZIP_FILE!' -DestinationPath '!TMP_DIR!' -Force"
if !ERRORLEVEL! NEQ 0 (
    echo ERROR: Failed to extract update package!
    pause
    exit /b 1
)

echo [5/7] Finding extracted version directory...
for /d %%D in ("!TMP_DIR!\\*") do (
    set "VERSION_DIR=%%D"
)
echo Found version directory: !VERSION_DIR!

echo [6/7] Replacing application files...
echo Deleting old files in !APP_DIR!...
del /Q "!APP_DIR!\\*.*" >nul 2>&1
for /d %%D in ("!APP_DIR!\\*") do (
    if /I not "%%~nxD"=="tmp" rmdir /S /Q "%%D" >nul 2>&1
)

echo Copying new files from !VERSION_DIR!...
xcopy /E /Y /I "!VERSION_DIR!\\*" "!APP_DIR!\\" >nul
if !ERRORLEVEL! NEQ 0 (
    echo ERROR: Failed to copy new files!
    pause
    exit /b 1
)

echo [7/7] Starting new version...
start /b cmd /c start "" "!APP_EXE!"

echo.
echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
rmdir /S /Q "!VERSION_DIR!" >nul 2>&1
del "!ZIP_FILE!" >nul 2>&1

echo ========================================
echo      Update completed successfully!
echo ========================================
timeout /t 1 /nobreak >nul
endlocal
exit
''';
      
      // 创建升级器脚本
      final updaterScript = path.join(tmpDir, 'updater.bat');
      await File(updaterScript).writeAsString(scriptContent);
      logger.info('📝 [Windows升级] 升级脚本已创建: $updaterScript');
      
      // 启动升级器脚本
      logger.info('🚀 [Windows升级] 启动升级脚本...');
      await Process.start(
        'cmd',
        ['/c', 'start', 'cmd', '/c', updaterScript],
        mode: ProcessStartMode.detached,
      );
      
      logger.info('✅ [Windows升级] 升级器已启动，应用即将退出');
      return true;
    } catch (e) {
      logger.error('❌ [Windows升级] 失败: $e');
      return false;
    }
  }

  /// macOS 带下载功能的升级器
  Future<bool> _startMacUpdaterWithDownload(UpdateInfo updateInfo) async {
    // TODO: 实现 macOS 带下载功能的升级器
    logger.warning('⚠️ [macOS升级] 暂未实现带下载功能的升级器');
    return false;
  }

  /// Linux 带下载功能的升级器
  Future<bool> _startLinuxUpdaterWithDownload(UpdateInfo updateInfo) async {
    // TODO: 实现 Linux 带下载功能的升级器
    logger.warning('⚠️ [Linux升级] 暂未实现带下载功能的升级器');
    return false;
  }

  /// Android 带下载功能的升级器
  Future<bool> _startAndroidUpdaterWithDownload(UpdateInfo updateInfo) async {
    try {
      logger.info('📱 [Android升级] 开始下载APK...');
      
      // 下载APK
      final filePath = await downloadUpdate(updateInfo, (received, total) {
        final percent = (received / total * 100).toInt();
        logger.debug('📥 [Android下载] 进度: $percent%');
      });
      
      if (filePath == null) {
        logger.error('❌ [Android升级] 下载失败');
        return false;
      }
      
      // 校验文件
      final isValid = await verifyFile(filePath, updateInfo.md5);
      if (!isValid) {
        logger.error('❌ [Android升级] 文件校验失败');
        await File(filePath).delete();
        return false;
      }
      
      // 安装APK
      return await _installAndroidApk(filePath);
    } catch (e) {
      logger.error('❌ [Android升级] 失败: $e');
      return false;
    }
  }

  /// Windows 升级器
  /// 升级流程：
  /// 1. 在应用目录上一级的tmp目录中解压ZIP
  /// 2. 杀死当前应用
  /// 3. 删除应用目录所有文件
  /// 4. 复制解压后的文件到应用目录
  /// 5. 启动新版本
  Future<bool> _startWindowsUpdater(String updateFilePath) async {
    try {
      final currentExePath = Platform.resolvedExecutable;
      final appDir = path.dirname(currentExePath);
      final parentDir = path.dirname(appDir);
      final appName = path.basenameWithoutExtension(currentExePath);
      final fileExtension = path.extension(updateFilePath).toLowerCase();
      
      // tmp目录在应用目录的上一级
      final tmpDir = path.join(parentDir, 'tmp');
      
      logger.info('🪟 [Windows升级] 当前应用: $currentExePath');
      logger.info('📁 [Windows升级] 应用目录: $appDir');
      logger.info('📁 [Windows升级] 临时目录: $tmpDir');
      logger.info('📦 [Windows升级] 更新包类型: $fileExtension');
      
      String scriptContent;
      
      // 将路径中的反斜杠转换为双反斜杠（用于批处理脚本）
      final updateFilePathEsc = updateFilePath.replaceAll('\\', '\\\\');
      final tmpDirEsc = tmpDir.replaceAll('\\', '\\\\');
      final appDirEsc = appDir.replaceAll('\\', '\\\\');
      final currentExePathEsc = currentExePath.replaceAll('\\', '\\\\');
      
      if (fileExtension == '.zip') {
        // ZIP包：解压到tmp目录，然后替换应用目录
        // ZIP解压后会得到一个以版本号命名的目录
        scriptContent = '''
@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
echo ========================================
echo           Youdu Update Script
echo ========================================
echo.

set "ZIP_FILE=$updateFilePathEsc"
set "TMP_DIR=$tmpDirEsc"
set "APP_DIR=$appDirEsc"
set "APP_NAME=$appName"
set "APP_EXE=$currentExePathEsc"

echo [1/6] Preparing update...
timeout /t 2 /nobreak >nul

echo [2/6] Closing application...
taskkill /F /IM !APP_NAME!.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [3/6] Extracting update package to tmp directory...
powershell -Command "Expand-Archive -Path '!ZIP_FILE!' -DestinationPath '!TMP_DIR!' -Force"
if !ERRORLEVEL! NEQ 0 (
    echo ERROR: Failed to extract update package!
    pause
    exit /b 1
)

echo [4/6] Finding extracted version directory...
for /d %%D in ("!TMP_DIR!\\*") do (
    set "VERSION_DIR=%%D"
)
echo Found version directory: !VERSION_DIR!

echo [5/6] Replacing application files...
echo Deleting old files in !APP_DIR!...
del /Q "!APP_DIR!\\*.*" >nul 2>&1
for /d %%D in ("!APP_DIR!\\*") do (
    if /I not "%%~nxD"=="tmp" rmdir /S /Q "%%D" >nul 2>&1
)

echo Copying new files from !VERSION_DIR!...
xcopy /E /Y /I "!VERSION_DIR!\\*" "!APP_DIR!\\" >nul
if !ERRORLEVEL! NEQ 0 (
    echo ERROR: Failed to copy new files!
    pause
    exit /b 1
)

echo [6/6] Starting new version...
start /b cmd /c start "" "!APP_EXE!"

echo.
echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
rmdir /S /Q "!VERSION_DIR!" >nul 2>&1
del "!ZIP_FILE!" >nul 2>&1

echo ========================================
echo      Update completed successfully!
echo ========================================
timeout /t 1 /nobreak >nul
endlocal
exit
''';
      } else if (fileExtension == '.7z') {
        // 7z包：不再支持，提示用户使用ZIP格式
        logger.error('❌ [Windows升级] 不再支持7z格式，请使用ZIP格式');
        return false;
      } else if (fileExtension == '.exe') {
        // EXE安装包：直接运行安装程序
        scriptContent = '''
@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
echo ========================================
echo           Youdu Update Script (EXE)
echo ========================================
echo.

set "UPDATE_FILE=$updateFilePathEsc"
set "APP_DIR=$appDirEsc"
set "APP_NAME=$appName"
set "APP_EXE=$currentExePathEsc"

echo [1/4] Preparing update...
timeout /t 2 /nobreak >nul

echo [2/4] Closing application...
taskkill /F /IM !APP_NAME!.exe >nul 2>&1
timeout /t 1 /nobreak >nul

echo [3/4] Installing update...
start /wait "" "!UPDATE_FILE!" /S /D="!APP_DIR!"

echo [4/4] Starting new version...
start /b cmd /c start "" "!APP_EXE!"

echo.
echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
del "!UPDATE_FILE!" >nul 2>&1

echo ========================================
echo      Update completed successfully!
echo ========================================
timeout /t 1 /nobreak >nul
endlocal
exit
''';
      } else {
        logger.error('❌ [Windows升级] 不支持的文件格式: $fileExtension');
        return false;
      }
      
      // 创建升级器脚本到tmp目录（避免被删除）
      final updaterScript = path.join(tmpDir, 'updater.bat');
      await File(updaterScript).writeAsString(scriptContent);
      logger.info('📝 [Windows升级] 升级脚本已创建: $updaterScript');
      
      // 启动升级器脚本
      logger.info('🚀 [Windows升级] 启动升级脚本...');
      await Process.start(
        'cmd',
        ['/c', updaterScript],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      
      logger.info('✅ [Windows升级] 升级器已启动，应用即将退出');
      return true;
    } catch (e) {
      logger.error('❌ [Windows升级] 失败: $e');
      return false;
    }
  }

  /// macOS 升级器
  Future<bool> _startMacUpdater(String updateFilePath) async {
    try {
      final currentAppPath = Platform.resolvedExecutable;
      // macOS应用路径: /Applications/Youdu.app/Contents/MacOS/youdu
      final appBundlePath = path.dirname(path.dirname(path.dirname(currentAppPath)));
      final appName = path.basename(appBundlePath).replaceAll('.app', '');
      
      final updaterScript = path.join(Directory.systemTemp.path, 'youdu_updater.sh');
      final scriptContent = '''
#!/bin/bash
echo "正在准备更新..."
sleep 2

echo "正在关闭应用..."
pkill -f "$appName" || true
sleep 1

echo "正在挂载DMG..."
hdiutil attach "$updateFilePath" -nobrowse -quiet

echo "正在安装更新..."
cp -R "/Volumes/$appName/$appName.app" "/Applications/"

echo "正在卸载DMG..."
hdiutil detach "/Volumes/$appName" -quiet

echo "正在启动新版本..."
open "/Applications/$appName.app"

echo "清理临时文件..."
rm "$updateFilePath"
rm "\$0"
''';

      await File(updaterScript).writeAsString(scriptContent);
      await Process.run('chmod', ['+x', updaterScript]);
      
      await Process.start(
        'sh',
        [updaterScript],
        mode: ProcessStartMode.detached,
      );
      
      return true;
    } catch (e) {
      debugPrint('macOS 升级器启动失败: $e');
      return false;
    }
  }

  /// Linux 升级器
  Future<bool> _startLinuxUpdater(String updateFilePath) async {
    try {
      final currentAppPath = Platform.resolvedExecutable;
      final appDir = path.dirname(currentAppPath);
      final appName = path.basename(currentAppPath);
      
      final updaterScript = path.join(Directory.systemTemp.path, 'youdu_updater.sh');
      final scriptContent = '''
#!/bin/bash
echo "正在准备更新..."
sleep 2

echo "正在关闭应用..."
pkill -f "$appName" || true
sleep 1

echo "正在安装更新..."
chmod +x "$updateFilePath"
cp "$updateFilePath" "$appDir/$appName"

echo "正在启动新版本..."
"$appDir/$appName" &

echo "清理临时文件..."
rm "$updateFilePath"
rm "\$0"
''';

      await File(updaterScript).writeAsString(scriptContent);
      await Process.run('chmod', ['+x', updaterScript]);
      
      await Process.start(
        'sh',
        [updaterScript],
        mode: ProcessStartMode.detached,
      );
      
      return true;
    } catch (e) {
      debugPrint('Linux 升级器启动失败: $e');
      return false;
    }
  }
}
