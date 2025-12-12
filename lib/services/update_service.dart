import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/update_info.dart';
import '../config/api_config.dart';
import '../utils/logger.dart';
import 'local_database_service.dart';

/// 升级服务
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  /// 获取当前版本信息
  /// 优先从本地数据库获取，如果没有则从包信息获取
  static Future<Map<String, String>> getCurrentVersion() async {
    try {
      final platform = Platform.operatingSystem;
      
      // 优先从本地数据库获取版本信息
      final dbService = LocalDatabaseService();
      final storedVersion = await dbService.getStoredVersion(platform);
      
      if (storedVersion != null) {
        final version = storedVersion['version'] as String;
        final versionCode = storedVersion['version_code'] as String? ?? version;
        logger.debug('📱 [版本信息] 从数据库获取: $version (代码: $versionCode)');
        return {
          'version': version,
          'versionCode': versionCode,
        };
      }
      
      // 数据库没有记录，从包信息获取
      final packageInfo = await PackageInfo.fromPlatform();
      logger.debug('📱 [版本信息] 从包信息获取: ${packageInfo.version} (代码: ${packageInfo.buildNumber})');
      return {
        'version': packageInfo.version,
        'versionCode': packageInfo.buildNumber,
      };
    } catch (e) {
      logger.error('❌ [版本信息] 获取失败: $e');
      return {
        'version': '1.0.0',
        'versionCode': '1',
      };
    }
  }

  /// 保存版本信息到本地数据库（升级成功后调用）
  static Future<void> saveVersionToDatabase(UpdateInfo updateInfo) async {
    try {
      final platform = Platform.operatingSystem;
      final dbService = LocalDatabaseService();
      
      await dbService.saveVersion(
        version: updateInfo.version,
        versionCode: updateInfo.versionCode,
        fileSize: updateInfo.fileSize,
        releaseNotes: updateInfo.releaseNotes,
        releaseDate: updateInfo.releaseDate.toIso8601String(),
        platform: platform,
      );
      
      logger.info('✅ [版本保存] 版本信息已保存到数据库: ${updateInfo.version}');
    } catch (e) {
      logger.error('❌ [版本保存] 保存失败: $e');
    }
  }

  /// 检查更新
  Future<UpdateInfo?> checkUpdate() async {
    try {
      final versionInfo = await getCurrentVersion();
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

      logger.debug('📡 [检查更新] 响应状态码: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        logger.debug('📦 [检查更新] 响应数据: $data');
        
        if (data['has_update'] == true && data['update_info'] != null) {
          final updateInfo = UpdateInfo.fromJson(data['update_info']);
          logger.info('✅ [检查更新] 发现新版本: ${updateInfo.version}');
          return updateInfo;
        } else {
          logger.info('ℹ️ [检查更新] 无可用更新');
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

  /// 下载更新包（完全静默，不影响主线程）
  Future<String?> downloadUpdate(
    UpdateInfo updateInfo,
    Function(int received, int total)? onProgress,
  ) async {
    try {
      final dir = await _getDownloadDirectory();
      final fileName = _getUpdateFileName(updateInfo.downloadUrl);
      final filePath = path.join(dir.path, fileName);
      final file = File(filePath);

      // 如果文件已存在且MD5匹配，直接返回
      if (await file.exists()) {
        final isValid = await verifyFile(filePath, updateInfo.md5);
        if (isValid) {
          return filePath;
        }
        await file.delete();
      }

      // 静默下载，不打印日志避免影响主线程
      final request = http.Request('GET', Uri.parse(updateInfo.downloadUrl));
      final response = await request.send();

      if (response.statusCode != 200) {
        throw Exception('下载失败: ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? updateInfo.fileSize;
      int received = 0;

      final sink = file.openWrite();
      await for (var chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        // 调用进度回调（由调用方负责节流）
        onProgress?.call(received, contentLength);
      }
      await sink.close();
      return filePath;
    } catch (e) {
      return null;
    }
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
        return false;
      }

      // 如果没有提供MD5，跳过校验
      if (expectedMd5.isEmpty) {
        return true;
      }

      final bytes = await file.readAsBytes();
      final digest = md5.convert(bytes);
      final fileMd5 = digest.toString();

      return fileMd5.toLowerCase() == expectedMd5.toLowerCase();
    } catch (e) {
      return false;
    }
  }

  /// 获取更新文件名
  /// 优先从下载URL中提取文件扩展名，如果无法提取则使用默认扩展名
  String _getUpdateFileName(String downloadUrl) {
    // 从URL中提取文件名和扩展名
    try {
      final uri = Uri.parse(downloadUrl);
      final urlPath = uri.path;
      final urlFileName = path.basename(urlPath);
      
      // 如果URL包含有效的文件扩展名，使用它
      if (urlFileName.contains('.')) {
        final extension = path.extension(urlFileName);
        if (extension.isNotEmpty) {
          return 'youdu_update$extension';
        }
      }
    } catch (e) {
      // 忽略错误
    }

    // 使用默认扩展名
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
      
      final scriptContent = '''
@echo off
chcp 65001 >nul
echo ========================================
echo           Youdu Update Script
echo ========================================
echo.

set "DOWNLOAD_URL=$downloadUrl"
set "ZIP_FILE=$zipFile"
set "TMP_DIR=$tmpDir"
set "APP_DIR=$appDir"
set "APP_NAME=$appName"
set "APP_EXE=$currentExePath"
set "EXPECTED_MD5=${updateInfo.md5}"

echo [1/7] Downloading update package...
echo URL: %DOWNLOAD_URL%
echo Saving to: %ZIP_FILE%
echo.
powershell -Command "& { \$ProgressPreference = 'Continue'; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%ZIP_FILE%' -UseBasicParsing }"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to download update package!
    pause
    exit /b 1
)
echo Download completed!
echo.

echo [2/7] Verifying file integrity...
for %%A in ("%ZIP_FILE%") do set "FILE_SIZE=%%~zA"
echo File size: %FILE_SIZE% bytes
if "%EXPECTED_MD5%" NEQ "" (
    for /f "skip=1 tokens=* delims=" %%# in ('certutil -hashfile "%ZIP_FILE%" MD5') do (
        if not defined FILE_MD5 set "FILE_MD5=%%#"
    )
    set "FILE_MD5=%FILE_MD5: =%"
    echo Expected MD5: %EXPECTED_MD5%
    echo Actual MD5: %FILE_MD5%
    if /I not "%FILE_MD5%"=="%EXPECTED_MD5%" (
        echo ERROR: MD5 verification failed!
        del "%ZIP_FILE%" >nul 2>&1
        pause
        exit /b 1
    )
    echo MD5 verification passed!
) else (
    echo Skipping MD5 verification...
)
echo.

echo [3/7] Closing application...
taskkill /F /IM %APP_NAME%.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [4/7] Extracting update package...
powershell -Command "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%TMP_DIR%' -Force"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to extract update package!
    pause
    exit /b 1
)

echo [5/7] Finding extracted version directory...
for /d %%D in ("%TMP_DIR%\\*") do (
    set "VERSION_DIR=%%D"
)
echo Found version directory: %VERSION_DIR%

echo [6/7] Replacing application files...
echo Deleting old files in %APP_DIR%...
del /Q "%APP_DIR%\\*.*" >nul 2>&1
for /d %%D in ("%APP_DIR%\\*") do (
    if /I not "%%~nxD"=="tmp" rmdir /S /Q "%%D" >nul 2>&1
)

echo Copying new files from %VERSION_DIR%...
xcopy /E /Y /I "%VERSION_DIR%\\*" "%APP_DIR%\\" >nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to copy new files!
    pause
    exit /b 1
)

echo [7/7] Starting new version...
start /b cmd /c start "" "%APP_EXE%"

echo.
echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
rmdir /S /Q "%VERSION_DIR%" >nul 2>&1
del "%ZIP_FILE%" >nul 2>&1

echo ========================================
echo      Update completed successfully!
echo ========================================
timeout /t 1 /nobreak >nul
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
      
      if (fileExtension == '.zip') {
        // ZIP包：解压到tmp目录，然后替换应用目录
        // ZIP解压后会得到一个以版本号命名的目录
        scriptContent = '''
@echo off
chcp 65001 >nul
echo ========================================
echo           Youdu Update Script
echo ========================================
echo.

set "ZIP_FILE=$updateFilePath"
set "TMP_DIR=$tmpDir"
set "APP_DIR=$appDir"
set "APP_NAME=$appName"
set "APP_EXE=$currentExePath"

echo [1/6] Preparing update...
timeout /t 2 /nobreak >nul

echo [2/6] Closing application...
taskkill /F /IM %APP_NAME%.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [3/6] Extracting update package to tmp directory...
powershell -Command "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%TMP_DIR%' -Force"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to extract update package!
    pause
    exit /b 1
)

echo [4/6] Finding extracted version directory...
for /d %%D in ("%TMP_DIR%\\*") do (
    set "VERSION_DIR=%%D"
)
echo Found version directory: %VERSION_DIR%

echo [5/6] Replacing application files...
echo Deleting old files in %APP_DIR%...
del /Q "%APP_DIR%\\*.*" >nul 2>&1
for /d %%D in ("%APP_DIR%\\*") do (
    if /I not "%%~nxD"=="tmp" rmdir /S /Q "%%D" >nul 2>&1
)

echo Copying new files from %VERSION_DIR%...
xcopy /E /Y /I "%VERSION_DIR%\\*" "%APP_DIR%\\" >nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to copy new files!
    pause
    exit /b 1
)

echo [6/6] Starting new version...
start /b cmd /c start "" "%APP_EXE%"

echo.
echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
rmdir /S /Q "%VERSION_DIR%" >nul 2>&1
del "%ZIP_FILE%" >nul 2>&1

echo ========================================
echo      Update completed successfully!
echo ========================================
timeout /t 1 /nobreak >nul
exit
''';
      } else if (fileExtension == '.exe') {
        // EXE安装包：直接运行安装程序
        scriptContent = '''
@echo off
chcp 65001 >nul
echo Preparing update...
timeout /t 2 /nobreak >nul

echo Closing application...
taskkill /F /IM $appName.exe >nul 2>&1
timeout /t 1 /nobreak >nul

echo Installing update...
start /wait "" "$updateFilePath" /S /D="$appDir"

echo Starting new version...
start /b cmd /c start "" "$currentExePath"

echo Cleaning temporary files...
timeout /t 2 /nobreak >nul
del "$updateFilePath" >nul 2>&1
echo Update completed!
timeout /t 1 /nobreak >nul
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
