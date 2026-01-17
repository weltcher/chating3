import 'dart:io';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:sqflite/sqflite.dart';
// iOS 使用普通 sqflite（不加密），Android 使用 sqflite_sqlcipher（加密）
import 'package:sqflite_sqlcipher/sqflite.dart' as sqflite_cipher;
import 'package:sqlite3/open.dart' as sqlite3_open;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, kReleaseMode;
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/logger.dart';
import 'api_service.dart';
import 'database_provider.dart';
import 'mobile_database_provider.dart';
import 'desktop_database_provider.dart';

/// 本地SQLite数据库服务
/// 用于存储私聊消息和群聊消息
class LocalDatabaseService {
  static final LocalDatabaseService _instance =
      LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  dynamic _database; // 移动端：sqflite Database，桌面端：sqlite3 Database
  sqlite3.Database? _sqlite3Db; // 桌面端数据库 (sqlite3)
  String? _databaseKey; // 移动端使用
  String? _databaseUuid; // 保存原始UUID
  String? _dbPath; // 数据库文件路径
  
  // 数据库抽象层
  MobileDatabaseProvider? _mobileProvider; // 移动端Provider
  DesktopDatabaseProvider? _desktopProvider; // 桌面端Provider
  
  // 移动端密钥存储
  static const String _keyStorageKey = 'ydkey';
  static const String _uuidStorageKey = 'ydkey_uuid'; // 存储UUID的key
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  
  // 🔥 测试开关：是否在移动端启动时删除重建数据库
  // ⚠️  警告：开启后每次启动都会清空所有数据！仅用于测试！
  static const bool _forceRecreateDatabase = false; // 设为 false 可禁用此功能
  
  // iOS 备份排除 Method Channel
  static const MethodChannel _backupChannel = MethodChannel('com.youdu.app/backup');

  /// 将文件排除出 iCloud 备份（仅 iOS）
  Future<void> _excludeFromiCloudBackup(String path) async {
    if (!Platform.isIOS) return;
    
    try {
      final result = await _backupChannel.invokeMethod('excludeFromBackup', {'path': path});
      if (result == true) {
        logger.debug('✅ [iCloud] 数据库文件已排除出 iCloud 备份: $path');
      } else {
        logger.debug('⚠️ [iCloud] 排除 iCloud 备份失败');
      }
    } catch (e) {
      logger.debug('❌ [iCloud] 调用排除备份方法失败: $e');
    }
  }

  /// 获取数据库实例（懒加载）
  /// 移动端返回 sqflite Database，桌面端返回 sqlite3 Database
  Future<dynamic> get database async {
    if (_database != null) {
      logger.debug('📦 [数据库访问] 使用已存在的数据库实例');
      return _database!;
    }
    
    logger.debug('📦 [数据库访问] 数据库实例不存在，开始初始化...');
    logger.debug('📦 [数据库访问] Provider状态: mobile=${_mobileProvider != null}, desktop=${_desktopProvider != null}');
    
    // 🔴 检查是否有残留的Provider但数据库实例为null（Hot Restart 可能导致）
    if (_mobileProvider != null || _desktopProvider != null) {
      logger.debug('⚠️ [数据库访问] 检测到残留的Provider，但数据库实例为null（可能是Hot Restart导致）');
      logger.debug('⚠️ [数据库访问] 清理残留的Provider...');
      _mobileProvider = null;
      _desktopProvider = null;
      _sqlite3Db = null;
      logger.debug('✅ [数据库访问] Provider已清理');
    }
    
    _database = await _initDatabase();
    return _database!;
  }
  
  /// 确保Provider已初始化
  Future<void> _ensureProvidersInitialized() async {
    if (_isDesktopPlatform && _desktopProvider == null) {
      await database;
    } else if (!_isDesktopPlatform && _mobileProvider == null) {
      await database;
    }
  }
  
  /// 执行插入操作（统一接口）
  Future<int> _executeInsert(String table, Map<String, dynamic> values, {bool orIgnore = false}) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      return _desktopProvider!.insert(table, values, orIgnore: orIgnore);
    } else {
      return await _mobileProvider!.insertAsync(table, values, orIgnore: orIgnore);
    }
  }
  
  /// 执行查询操作（统一接口）
  Future<List<Map<String, dynamic>>> _executeQuery(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      return _desktopProvider!.query(
        table,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );
    } else {
      return await _mobileProvider!.queryAsync(
        table,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );
    }
  }
  
  /// 执行原始查询（统一接口）
  Future<List<Map<String, dynamic>>> _executeRawQuery(String sql, [List<Object?>? args]) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      return _desktopProvider!.rawQuery(sql, args);
    } else {
      return await _mobileProvider!.rawQueryAsync(sql, args);
    }
  }
  
  /// 执行更新操作（统一接口）
  Future<int> _executeUpdate(
    String table,
    Map<String, dynamic> values, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      return _desktopProvider!.update(table, values, where: where, whereArgs: whereArgs);
    } else {
      return await _mobileProvider!.updateAsync(table, values, where: where, whereArgs: whereArgs);
    }
  }
  
  /// 执行删除操作（统一接口）
  Future<int> _executeDelete(String table, {String? where, List<Object?>? whereArgs}) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      return _desktopProvider!.delete(table, where: where, whereArgs: whereArgs);
    } else {
      return await _mobileProvider!.deleteAsync(table, where: where, whereArgs: whereArgs);
    }
  }
  
  /// 执行原始删除（统一接口）
  Future<int> _executeRawDelete(String sql, [List<Object?>? args]) async {
    await _ensureProvidersInitialized();
    if (_isDesktopPlatform) {
      _desktopProvider!.rawDelete(sql, args);
      return 0; // 桌面端rawDelete没有返回值
    } else {
      return await _mobileProvider!.rawDeleteAsync(sql, args);
    }
  }

  // ============ 公开方法供外部服务使用 ============

  /// 执行原始查询（公开方法）
  Future<List<Map<String, dynamic>>> executeRawQuery(String sql, [List<Object?>? args]) async {
    return await _executeRawQuery(sql, args);
  }

  /// 执行更新操作（公开方法）
  Future<int> executeUpdate(
    String table,
    Map<String, dynamic> values, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    return await _executeUpdate(table, values, where: where, whereArgs: whereArgs);
  }

  /// 🔴 删除旧数据库文件（迁移到新数据库名称时使用）
  Future<void> _deleteOldDatabases(String dbDirPath) async {
    logger.debug('═══════════════════════════════════════════════════════════');
    logger.debug('🔄 [数据库迁移] 开始检查旧数据库文件...');
    logger.debug('🔄 [数据库迁移] 数据库目录: $dbDirPath');
    
    // 需要删除的旧数据库文件名列表
    final oldDbNames = [
      'youdu_storage.db',
      'youdu_messages.db',
      // 同时删除 SQLite 的临时文件
      'youdu_storage.db-journal',
      'youdu_storage.db-wal',
      'youdu_storage.db-shm',
      'youdu_messages.db-journal',
      'youdu_messages.db-wal',
      'youdu_messages.db-shm',
    ];
    
    int deletedCount = 0;
    for (final dbName in oldDbNames) {
      final oldDbPath = join(dbDirPath, dbName);
      final oldDbFile = File(oldDbPath);
      
      if (oldDbFile.existsSync()) {
        try {
          final fileSize = oldDbFile.lengthSync();
          logger.debug('🔍 [数据库迁移] 发现旧文件: $dbName (${(fileSize / 1024).toStringAsFixed(2)} KB)');
          await oldDbFile.delete();
          logger.debug('🗑️ [数据库迁移] ✅ 已删除: $dbName');
          deletedCount++;
        } catch (e) {
          logger.debug('⚠️ [数据库迁移] ❌ 删除失败: $dbName, 错误: $e');
        }
      }
    }
    
    if (deletedCount > 0) {
      logger.debug('🗑️ [数据库迁移] 共删除 $deletedCount 个旧数据库文件');
      
      // 🔴 清除首次同步标记，强制重新从服务器同步数据
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('first_sync_completed');
        logger.debug('🔄 [数据库迁移] ✅ 已清除首次同步标记，将从服务器重新同步数据');
      } catch (e) {
        logger.debug('⚠️ [数据库迁移] ❌ 清除首次同步标记失败: $e');
      }
    } else {
      logger.debug('✅ [数据库迁移] 没有发现旧数据库文件，无需迁移');
    }
    logger.debug('═══════════════════════════════════════════════════════════');
  }

  /// 判断是否是桌面端
  bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 获取 sqlite3 数据库实例（桌面端）
  sqlite3.Database get _db {
    if (_sqlite3Db == null) {
      throw Exception('桌面端数据库未初始化');
    }
    return _sqlite3Db!;
  }

  /// 生成数据库密钥（支持所有平台）
  /// 返回: Map包含'uuid'和'key'
  /// 
  /// 不同平台使用不同的盐值：
  Map<String, String> _generateDatabaseKey(String uuidString) {
    final String salt;

    // 根据平台获取不同的盐值
    if (Platform.isAndroid) {
      salt = '40BUJEyUH5L37fpEngty';
    } else if (Platform.isIOS) {
      salt = 'xkau40vbmKL1wJ3BzT6t';
    } else if (Platform.isWindows) {
      salt = 'fAu1ZbVr12jyHzRUekU5';
    } else {
      // 其他平台（macOS, Linux）使用 Windows 的盐值
      salt = 'fAu1ZbVr12jyHzRUekU5';
    }
    
    final combined = uuidString + salt;
    final bytes = utf8.encode(combined);
    final digest = md5.convert(bytes);
    final md5String = digest.toString();
    // 16位密钥：前8位 + 后8位
    final key = md5String.substring(0, 8) + md5String.substring(md5String.length - 8);

    return {'uuid': uuidString, 'key': key};
  }

  /// 获取系统平台名称
  String _getPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 收集系统信息
  Future<Map<String, dynamic>> _collectSystemInfo() async {
    final systemInfo = <String, dynamic>{};

    try {
      if (!kIsWeb) {
        systemInfo['os'] = Platform.operatingSystem;
        systemInfo['os_version'] = Platform.operatingSystemVersion;
        systemInfo['locale'] = Platform.localeName;
        systemInfo['number_of_processors'] = Platform.numberOfProcessors;
      }

      // 添加Flutter相关信息
      systemInfo['is_web'] = kIsWeb;
      systemInfo['is_debug'] = kDebugMode;

      logger.debug('收集到的系统信息: $systemInfo');
    } catch (e) {
      logger.debug('收集系统信息失败: $e');
    }

    return systemInfo;
  }

  /// 推送设备信息到服务器
  Future<void> _registerDeviceToServer(String uuid) async {
    try {
      logger.debug('🔄 开始推送设备信息到服务器...');

      final platform = _getPlatform();
      final systemInfo = await _collectSystemInfo();
      final installedAt = DateTime.now();

      // 调用API注册设备
      final response = await ApiService.registerDevice(
        uuid: uuid,
        platform: platform,
        systemInfo: systemInfo,
        installedAt: installedAt,
      );

      logger.debug('✅ 设备信息推送成功: ${response['message']}');
    } catch (e) {
      // 推送失败不影响应用启动，只记录日志
      logger.debug('⚠️ 设备信息推送失败（不影响使用）: $e');
    }
  }

  /// 获取或生成UUID（用于设备注册）
  Future<String> _getOrCreateUuid() async {
    if (_databaseUuid != null) return _databaseUuid!;

    try {
      // 检查数据库文件是否存在（判断是否需要推送）
      bool shouldPushToServer = false;
      if (!kIsWeb && _isDesktopPlatform) {
        final localAppData = Platform.environment['LOCALAPPDATA'];
        if (localAppData != null) {
          final dbFilePath = join(localAppData, 'ydapp', 'youdu_local_storage.db');
          final dbFile = File(dbFilePath);
          shouldPushToServer = !dbFile.existsSync();
          logger.debug('🔍 [数据库文件检查] 文件${shouldPushToServer ? "不存在" : "已存在"}: $dbFilePath');
        }
      } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        // 移动端：检查数据库文件是否存在
        try {
          final dbPath = await getDatabasesPath();
          final dbFilePath = join(dbPath, 'youdu_local_storage.db');
          final dbFile = File(dbFilePath);
          shouldPushToServer = !dbFile.existsSync();
          logger.debug('🔍 [数据库文件检查] 文件${shouldPushToServer ? "不存在" : "已存在"}: $dbFilePath');
        } catch (e) {
          logger.debug('⚠️ [移动端] 无法检查数据库文件: $e');
          shouldPushToServer = true; // 检查失败则默认需要推送
        }
      }

      // 🔴 双重存储策略：优先从 FlutterSecureStorage 读取，失败则从 SharedPreferences 读取
      String? storedUuid = await _secureStorage.read(key: _uuidStorageKey);
      
      // 🔴 如果 FlutterSecureStorage 读取失败（Hot Restart 常见问题），尝试从 SharedPreferences 读取
      if (storedUuid == null || storedUuid.isEmpty) {
        logger.debug('🔑 [UUID备份读取] FlutterSecureStorage 失败，尝试从 SharedPreferences 读取备份...');
        final prefs = await SharedPreferences.getInstance();
        storedUuid = prefs.getString(_uuidStorageKey);
        
        if (storedUuid != null && storedUuid.isNotEmpty) {
          logger.debug('✅ [UUID备份读取] 从 SharedPreferences 成功读取备份 UUID: $storedUuid');
          logger.debug('🔄 [UUID同步] 将备份 UUID 同步回 FlutterSecureStorage...');
          
          // 同步回 FlutterSecureStorage
          try {
            await _secureStorage.write(key: _uuidStorageKey, value: storedUuid);
          } catch (e) {
            logger.debug('⚠️ [UUID同步] 同步失败（Hot Restart 后可能无法写入）: $e');
          }
        } else {
          logger.debug('⚠️ [UUID备份读取] SharedPreferences 也没有备份 UUID');
        }
      }
      
      if (storedUuid != null && storedUuid.isNotEmpty) {
        _databaseUuid = storedUuid;
        
        // 如果数据库文件不存在，推送设备信息到服务器
        if (shouldPushToServer) {
          _registerDeviceToServer(_databaseUuid!).catchError((e) {
            logger.debug('设备信息推送异步处理失败: $e');
          });
        } else {
          logger.debug('✅ 数据库文件已存在，跳过设备信息推送');
        }
        
        return _databaseUuid!;
      }

      // 如果没有存储的UUID，说明是首次启动或读取失败
      logger.debug('⚠️ [UUID生成] 未读取到有效的UUID');
      logger.debug('🎉 [UUID生成] 生成新的UUID并保存到 FlutterSecureStorage...');
      final newUuid = const Uuid().v4();
      logger.debug('🔑 [UUID生成] 新UUID: $newUuid');

      // 🔴 双重保存：同时保存到 FlutterSecureStorage 和 SharedPreferences
      logger.debug('💾 [UUID保存] 开始保存到 FlutterSecureStorage 和 SharedPreferences...');
      
      // 1. 保存到 FlutterSecureStorage
      try {
        await _secureStorage.write(key: _uuidStorageKey, value: newUuid);
        logger.debug('✅ [UUID保存] FlutterSecureStorage 保存成功');
        
        // 立即验证是否保存成功
        final verifyUuid = await _secureStorage.read(key: _uuidStorageKey);
        if (verifyUuid == newUuid) {
          logger.debug('✅ [UUID验证] FlutterSecureStorage 验证成功');
        } else {
          logger.debug('⚠️ [UUID验证] FlutterSecureStorage 验证失败！');
          logger.debug('⚠️ [UUID验证] 预期: $newUuid, 实际: $verifyUuid');
        }
      } catch (e) {
        logger.debug('❌ [UUID保存] FlutterSecureStorage 保存失败: $e');
      }
      
      // 2. 保存到 SharedPreferences 作为备份
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_uuidStorageKey, newUuid);
        logger.debug('✅ [UUID备份保存] SharedPreferences 备份保存成功');
        
        // 验证备份
        final verifyBackup = prefs.getString(_uuidStorageKey);
        if (verifyBackup == newUuid) {
          logger.debug('✅ [UUID备份验证] SharedPreferences 备份验证成功');
        } else {
          logger.debug('⚠️ [UUID备份验证] SharedPreferences 备份验证失败！');
        }
      } catch (e) {
        logger.debug('❌ [UUID备份保存] SharedPreferences 保存失败: $e');
      }
      
      _databaseUuid = newUuid;

      // 异步推送设备信息到服务器（不阻塞数据库初始化）
      _registerDeviceToServer(newUuid).catchError((e) {
        logger.debug('设备信息推送异步处理失败: $e');
      });

      return _databaseUuid!;
    } catch (e) {
      logger.debug('获取UUID失败: $e');
      rethrow;
    }
  }

  /// 加载 SQLCipher 动态库（仅桌面端）
  /// 移动端（Android/iOS）不会调用此方法，它们使用 sqflite_cipher 插件
  Future<void> _loadSQLCipherLibrary() async {
    try {
      if (Platform.isWindows) {
        // Windows: 加载 SQLCipher DLL
        // 优先尝试直接用文件名加载（系统会从可执行文件目录和 PATH 中查找）
        String dllPath = 'sqlite3.dll';
        bool useRelativePath = true;
        
        // 如果直接加载失败，再尝试用绝对路径
        try {
          // 先测试能否直接加载
          ffi.DynamicLibrary.open(dllPath);
          logger.debug('📚 使用相对路径加载 SQLCipher DLL: $dllPath');
        } catch (e) {
          // 直接加载失败，尝试用绝对路径
          useRelativePath = false;
          logger.debug('⚠️ 相对路径加载失败，尝试绝对路径: $e');
          
          final executablePath = Platform.resolvedExecutable;
          var executableDir = File(executablePath).parent.path;
          
          // 规范化路径
          if (executableDir.startsWith(r'\\?\')) {
            executableDir = executableDir.substring(4);
          }
          if (executableDir.startsWith(r'UNC\')) {
            executableDir = r'\\' + executableDir.substring(4);
          }
          
          // 如果路径异常，尝试当前工作目录
          if (executableDir.contains('System Volume Information')) {
            executableDir = Directory.current.path;
            logger.debug('📍 使用当前工作目录: $executableDir');
          }
          
          dllPath = join(executableDir, 'sqlite3.dll');
          
          if (!File(dllPath).existsSync()) {
            throw Exception('SQLCipher DLL 不存在: $dllPath\n请确保 sqlite3.dll 与可执行文件在同一目录');
          }
          logger.debug('📚 使用绝对路径加载 SQLCipher DLL: $dllPath');
        }
        
        // 配置 sqlite3 库使用我们的 DLL
        sqlite3_open.open.overrideFor(
          sqlite3_open.OperatingSystem.windows,
          () => ffi.DynamicLibrary.open(dllPath),
        );
        logger.debug('✅ SQLCipher DLL 加载成功');
      } else if (Platform.isMacOS) {
        // macOS: 查找 libsqlcipher.dylib
        logger.debug('📚 加载 SQLCipher (macOS)');
        sqlite3_open.open.overrideFor(
          sqlite3_open.OperatingSystem.macOS,
          () => ffi.DynamicLibrary.open('libsqlcipher.dylib'),
        );
        logger.debug('✅ SQLCipher 配置成功 (macOS)');
      } else if (Platform.isLinux) {
        // Linux: 查找 libsqlcipher.so
        logger.debug('📚 加载 SQLCipher (Linux)');
        sqlite3_open.open.overrideFor(
          sqlite3_open.OperatingSystem.linux,
          () => ffi.DynamicLibrary.open('libsqlcipher.so'),
        );
        logger.debug('✅ SQLCipher 配置成功 (Linux)');
      } else {
        // 移动端（Android/iOS）不应该执行到这里
        // 它们使用 sqflite_cipher 插件，走不同的初始化路径
        throw Exception('❌ 不支持的平台: ${Platform.operatingSystem}\n移动端应该使用 sqflite_cipher 插件，而不是调用此方法');
      }
      logger.debug('🔐 数据库将使用 SQLCipher 加密');
    } catch (e) {
      logger.debug('❌ 加载 SQLCipher 库失败: $e');
      logger.debug('⚠️  将使用默认 SQLite（不加密）');
      throw e;
    }
  }

  /// 初始化桌面端加密数据库
  /// 完全按照测试文件 test_db_encryption2.dart 中验证有效的实现
  /// 返回 sqlite3.Database 对象
  /// 
  /// 参数：
  /// - path: 数据库文件路径
  /// - databaseEncryptoStr: 16位加密密钥（由UUID+盐值MD5后取前8+后8组成）
  Future<dynamic> _initDesktopDatabase(String path, String databaseEncryptoStr) async {
    try {
      final dbFile = File(path);
      final dbExists = dbFile.existsSync();
    
      // 1. 首先加载 SQLCipher 库（与测试案例完全相同）
      await _loadSQLCipherLibrary();
      
      // 2. 使用 sqlite3.open() 打开数据库（与测试案例完全相同）
      _sqlite3Db = sqlite3.sqlite3.open(path);
      _dbPath = path;
      logger.debug('✅ 数据库文件已打开');
      
      // 3. 设置加密密钥（16位密钥）
      _sqlite3Db!.execute("PRAGMA key = '$databaseEncryptoStr';");
      // 5. 如果是新数据库，创建表结构
      if (!dbExists) {
        logger.debug('📝 创建新数据库表结构...');
        _createDesktopDatabaseTables(_sqlite3Db!);
      } else {
        // 已存在的数据库，执行升级检查
        logger.debug('📝 检查桌面端数据库升级...');
        _upgradeDesktopDatabase(_sqlite3Db!);
      }
      
      // 创建桌面端Provider
      _desktopProvider = DesktopDatabaseProvider(_sqlite3Db!);
      
      logger.debug('✅ 桌面端数据库初始化完成（数据库连接保持打开）');
      return _sqlite3Db;
    } catch (e) {
      logger.debug('❌ 初始化桌面端数据库失败: $e');
      rethrow;
    }
  }
  
  /// 桌面端数据库升级
  void _upgradeDesktopDatabase(sqlite3.Database db) {
    try {
      // 检查 group_messages 表是否有 file_size 字段
      final columns = db.select("PRAGMA table_info(group_messages)");
      final columnNames = columns.map((row) => row['name'] as String).toSet();
      
      // 添加缺失的字段
      if (!columnNames.contains('file_size')) {
        logger.debug('📝 [桌面端升级] 添加 group_messages.file_size 字段');
        db.execute('ALTER TABLE group_messages ADD COLUMN file_size INTEGER');
      }
      if (!columnNames.contains('is_read')) {
        logger.debug('📝 [桌面端升级] 添加 group_messages.is_read 字段');
        db.execute('ALTER TABLE group_messages ADD COLUMN is_read BOOLEAN DEFAULT 0');
      }
      if (!columnNames.contains('is_recalled')) {
        logger.debug('📝 [桌面端升级] 添加 group_messages.is_recalled 字段');
        db.execute('ALTER TABLE group_messages ADD COLUMN is_recalled BOOLEAN DEFAULT 0');
      }
      
      logger.debug('✅ 桌面端数据库升级检查完成');
    } catch (e) {
      logger.debug('⚠️ 桌面端数据库升级失败: $e');
      // 升级失败不阻止应用启动
    }
  }

  /// 创建桌面端数据库表结构
  void _createDesktopDatabaseTables(sqlite3.Database db) {
    logger.debug('📝 创建桌面端数据库表...');
    
    // 创建私聊消息表（与移动端保持一致）
    db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        sender_id INTEGER NOT NULL,
        receiver_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        is_read BOOLEAN DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER,
        read_at TIMESTAMP,
        sender_name VARCHAR(50),
        receiver_name VARCHAR(50),
        file_name VARCHAR(255),
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        deleted_by_users TEXT DEFAULT '',
        sender_avatar TEXT,
        receiver_avatar TEXT,
        call_type VARCHAR(20),
        voice_duration INTEGER
      )
    ''');

    // 创建群聊消息表（与移动端保持一致）
    db.execute('''
      CREATE TABLE group_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        group_id INTEGER NOT NULL,
        sender_id INTEGER,
        sender_name VARCHAR(100) NOT NULL,
        sender_nickname VARCHAR(100),
        sender_full_name VARCHAR(100),
        group_name TEXT,
        group_avatar TEXT,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        file_size INTEGER,
        is_read BOOLEAN DEFAULT 0,
        is_recalled BOOLEAN DEFAULT 0,
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER,
        sender_avatar TEXT,
        mentioned_user_ids TEXT,
        mentions TEXT,
        deleted_by_users TEXT DEFAULT '',
        call_type VARCHAR(20),
        channel_name VARCHAR(255),
        voice_duration INTEGER
      )
    ''');

    // 创建群聊消息已读记录表（与移动端保持一致）
    db.execute('''
      CREATE TABLE group_message_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_message_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(group_message_id, user_id)
      )
    ''');

    // 创建收藏消息表（与移动端保持一致）
    db.execute('''
      CREATE TABLE favorites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        user_id INTEGER NOT NULL,
        message_id INTEGER,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        sender_id INTEGER NOT NULL,
        sender_name VARCHAR(100) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        sync_status VARCHAR(20) DEFAULT 'synced'
      )
    ''');

    // 创建常用联系人表（与移动端保持一致）
    db.execute('''
      CREATE TABLE favorite_contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        contact_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, contact_id)
      )
    ''');

    // 创建常用群组表（与移动端保持一致）
    db.execute('''
      CREATE TABLE favorite_groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        group_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, group_id)
      )
    ''');

    // 🆕 创建群组成员表（用于在SQL层面过滤用户所属的群组）
    db.execute('''
      CREATE TABLE group_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        role VARCHAR(20) DEFAULT 'member',
        joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(group_id, user_id)
      )
    ''');
    db.execute(
      'CREATE INDEX idx_group_members_user ON group_members(user_id, group_id)',
    );

    // 创建文件助手消息表（与移动端保持一致）
    db.execute('''
      CREATE TABLE file_assistant_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        user_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER
      )
    ''');

    // 创建联系人快照表（缓存联系人/群组基础信息）
    db.execute('''
      CREATE TABLE contact_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id INTEGER NOT NULL,
        contact_id INTEGER NOT NULL,
        contact_type VARCHAR(20) NOT NULL,
        username VARCHAR(100),
        full_name VARCHAR(100),
        avatar TEXT,
        remark TEXT,
        metadata TEXT,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(owner_id, contact_id, contact_type)
      )
    ''');
    db.execute(
      'CREATE INDEX idx_contact_snapshots_owner ON contact_snapshots(owner_id, updated_at DESC)',
    );

    // 创建系统版本表（存储当前应用版本信息）
    db.execute('''
      CREATE TABLE system_version (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        version VARCHAR(50) NOT NULL,
        version_code VARCHAR(50),
        file_size INTEGER DEFAULT 0,
        release_notes TEXT,
        release_date TEXT,
        platform VARCHAR(20) NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    logger.debug('✅ 桌面端数据库表创建完成');
  }

  Future<void> _ensureContactSnapshotTable() async {
    const createTableSql = '''
      CREATE TABLE IF NOT EXISTS contact_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id INTEGER NOT NULL,
        contact_id INTEGER NOT NULL,
        contact_type VARCHAR(20) NOT NULL,
        username VARCHAR(100),
        full_name VARCHAR(100),
        avatar TEXT,
        remark TEXT,
        metadata TEXT,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(owner_id, contact_id, contact_type)
      )
    ''';
    const createIndexSql =
        'CREATE INDEX IF NOT EXISTS idx_contact_snapshots_owner ON contact_snapshots(owner_id, updated_at DESC)';

    try {
      if (_isDesktopPlatform) {
        _desktopProvider?.execute(createTableSql);
        _desktopProvider?.execute(createIndexSql);
      } else if (_mobileProvider != null) {
        await _mobileProvider!.executeAsync(createTableSql);
        await _mobileProvider!.executeAsync(createIndexSql);
      }
    } catch (e) {
      logger.debug('⚠️ 确保联系人快照表存在失败: $e');
    }
  }

  /// 初始化数据库
  /// 移动端返回 sqflite Database，桌面端返回 sqlite3 Database
  Future<dynamic> _initDatabase() async {
    try {
      String path;
      bool isNew = false;

      // 移动端使用不同的数据库实现
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        // 桌面端路径
        String dbDirPath;
        if (Platform.isWindows) {
           await _loadSQLCipherLibrary();
          // Windows: C:\Users\User\AppData\Local\ydapp
          final localAppData = Platform.environment['LOCALAPPDATA'];
          if (localAppData != null) {
            dbDirPath = join(localAppData, 'ydapp');
          } else {
            // 兜底：如果获取不到环境变量，使用文档目录
            final appDocDir = await getApplicationDocumentsDirectory();
            dbDirPath = join(appDocDir.path, 'ydapp');
          }
        } else {
          final appDocDir = await getApplicationDocumentsDirectory();
          dbDirPath = join(appDocDir.path, 'youdu_db');
        }

        final dbDir = Directory(dbDirPath);
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
          isNew = true;
        }
        path = join(dbDir.path, 'youdu_local_storage.db');
        
        // 🔴 删除旧数据库文件
        await _deleteOldDatabases(dbDir.path);
      } else {
        // 移动端路径（Android/iOS）
        final dbPath = await getDatabasesPath();
        path = join(dbPath, 'youdu_local_storage.db');
        
        // 🔴 删除旧数据库文件
        await _deleteOldDatabases(dbPath);
        
        // 🔴 检查数据库文件是否存在
        final dbFile = File(path);
        final dbExists = dbFile.existsSync();
        if (dbExists) {
          final dbSize = dbFile.lengthSync();
        }
      }

      // 获取数据库加密密钥（16位MD5派生密钥）
      final databaseKeyInfo = await getDatabaseKey();
      final databaseKey = databaseKeyInfo['key']!;
      final databaseUUID = databaseKeyInfo['uuid']!;
      
      // 移动端和桌面端使用不同的加密方式
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        Database db;
        
        // iOS 使用普通 sqflite（不加密），Android 使用 sqflite_cipher（加密）
        if (Platform.isIOS) {
          
          try {
            db = await openDatabase(
              path,
              version: 8,
              onCreate: _createDatabase,
              onUpgrade: _upgradeDatabase,
            );
          } catch (e, stackTrace) {
            logger.debug('❌ [数据库初始化] iOS openDatabase 失败！');
            logger.debug('❌ [数据库初始化] 错误类型: ${e.runtimeType}');
            logger.debug('❌ [数据库初始化] 错误信息: $e');
            logger.debug('❌ [数据库初始化] 堆栈跟踪:\n$stackTrace');
            rethrow;
          }
        } else {
          // Android 使用 sqflite_cipher 加密
          
          try {
            db = await sqflite_cipher.openDatabase(
              path,
              password: databaseKey, // 🔐 设置数据库密码（复杂密钥）
              version: 8, // 🔴 升级到版本8（添加created_at_ms字段）
              onCreate: _createDatabase,
              onUpgrade: _upgradeDatabase,
            );
          } catch (e, stackTrace) {
            logger.debug('❌ [数据库初始化] sqflite_cipher.openDatabase 失败！');
            logger.debug('❌ [数据库初始化] 错误类型: ${e.runtimeType}');
            logger.debug('❌ [数据库初始化] 错误信息: $e');
            logger.debug('❌ [数据库初始化] 堆栈跟踪:\n$stackTrace');
            rethrow;
          }
        }
        
        // 创建移动端Provider
        _mobileProvider = MobileDatabaseProvider(db);
        
        // 🔴 iOS: 将数据库文件排除出 iCloud 备份
        if (Platform.isIOS) {
          await _excludeFromiCloudBackup(path);
        }
        
        await _ensureContactSnapshotTable();
        
        // 🔴 验证voice_duration列是否存在
        await _ensureVoiceDurationColumn(db);
        
        logger.debug('✅ 数据库初始化成功（移动端）');
        return db;
      } else {
        // 桌面端返回 sqlite3.Database
        var db = await _initDesktopDatabase(path, databaseKey);
        await _ensureContactSnapshotTable();
        return db;
      }
    } catch (e, stackTrace) {
      logger.debug('❌❌❌ 数据库初始化失败 ❌❌❌');
      logger.debug('❌ 错误类型: ${e.runtimeType}');
      logger.debug('❌ 错误信息: $e');
      logger.debug('❌ 完整堆栈:\n$stackTrace');
      rethrow;
    }
  }

  /// 创建数据库表结构
  Future<void> _createDatabase(Database db, int version) async {
    logger.debug('创建数据库表...');

    // 创建私聊消息表
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        sender_id INTEGER NOT NULL,
        receiver_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        is_read BOOLEAN DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER,
        read_at TIMESTAMP,
        sender_name VARCHAR(50),
        receiver_name VARCHAR(50),
        file_name VARCHAR(255),
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        deleted_by_users TEXT DEFAULT '',
        sender_avatar TEXT,
        receiver_avatar TEXT,
        call_type VARCHAR(20),
        voice_duration INTEGER
      )
    ''');

    // 创建群聊消息表
    await db.execute('''
      CREATE TABLE group_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        group_id INTEGER NOT NULL,
        sender_id INTEGER,
        sender_name VARCHAR(100) NOT NULL,
        sender_nickname VARCHAR(100),
        sender_full_name VARCHAR(100),
        group_name TEXT,
        group_avatar TEXT,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        file_size INTEGER,
        is_read BOOLEAN DEFAULT 0,
        is_recalled BOOLEAN DEFAULT 0,
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER,
        sender_avatar TEXT,
        mentioned_user_ids TEXT,
        mentions TEXT,
        deleted_by_users TEXT DEFAULT '',
        call_type VARCHAR(20),
        channel_name VARCHAR(255),
        voice_duration INTEGER
      )
    ''');

    // 创建群聊消息已读记录表
    await db.execute('''
      CREATE TABLE group_message_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_message_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(group_message_id, user_id)
      )
    ''');

    // 创建收藏消息表
    await db.execute('''
      CREATE TABLE favorites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        user_id INTEGER NOT NULL,
        message_id INTEGER,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        sender_id INTEGER NOT NULL,
        sender_name VARCHAR(100) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        sync_status VARCHAR(20) DEFAULT 'synced'
      )
    ''');

    // 创建常用联系人表
    await db.execute('''
      CREATE TABLE favorite_contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        contact_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, contact_id)
      )
    ''');

    // 创建常用群组表
    await db.execute('''
      CREATE TABLE favorite_groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        group_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, group_id)
      )
    ''');

    // 🆕 创建群组成员表（用于在SQL层面过滤用户所属的群组）
    await db.execute('''
      CREATE TABLE group_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        role VARCHAR(20) DEFAULT 'member',
        joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(group_id, user_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_group_members_user ON group_members(user_id, group_id)',
    );

    // 创建文件助手消息表
    await db.execute('''
      CREATE TABLE file_assistant_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        user_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        message_type VARCHAR(20) DEFAULT 'text',
        file_name VARCHAR(255),
        quoted_message_id INTEGER,
        quoted_message_content TEXT,
        status VARCHAR(20) DEFAULT 'normal',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at_ms INTEGER
      )
    ''');

    // 创建联系人快照表
    await db.execute('''
      CREATE TABLE contact_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id INTEGER NOT NULL,
        contact_id INTEGER NOT NULL,
        contact_type VARCHAR(20) NOT NULL,
        username VARCHAR(100),
        full_name VARCHAR(100),
        avatar TEXT,
        remark TEXT,
        metadata TEXT,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(owner_id, contact_id, contact_type)
      )
    ''');

    // 创建系统版本表（存储当前应用版本信息）
    await db.execute('''
      CREATE TABLE system_version (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        version VARCHAR(50) NOT NULL,
        version_code VARCHAR(50),
        file_size INTEGER DEFAULT 0,
        release_notes TEXT,
        release_date TEXT,
        platform VARCHAR(20) NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 创建索引
    await db.execute(
      'CREATE INDEX idx_messages_sender_receiver ON messages(sender_id, receiver_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_created_at ON messages(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_group_messages_group_id ON group_messages(group_id)',
    );
    await db.execute(
      'CREATE INDEX idx_group_messages_created_at ON group_messages(created_at)',
    );
    await db.execute(
      'CREATE INDEX idx_favorites_user_id ON favorites(user_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_favorite_contacts_user_id ON favorite_contacts(user_id)',
    );
    await db.execute(
      'CREATE INDEX idx_favorite_groups_user_id ON favorite_groups(user_id)',
    );
    await db.execute(
      'CREATE INDEX idx_file_assistant_messages_user_id ON file_assistant_messages(user_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_contact_snapshots_owner ON contact_snapshots(owner_id, updated_at DESC)',
    );

    logger.debug('数据库表创建成功');
  }

  /// 数据库升级
  Future<void> _upgradeDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    logger.debug('数据库升级: $oldVersion -> $newVersion');
    
    // 版本1 -> 版本2: 添加group_name和group_avatar字段
    if (oldVersion < 2) {
      logger.debug('执行数据库升级: 添加group_messages表的group_name和group_avatar字段');
      try {
        await db.execute('ALTER TABLE group_messages ADD COLUMN group_name TEXT');
        await db.execute('ALTER TABLE group_messages ADD COLUMN group_avatar TEXT');
        logger.debug('✅ 数据库升级完成: group_name和group_avatar字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }
    
    // 版本2 -> 版本3: 添加call_type和channel_name字段
    if (oldVersion < 3) {
      logger.debug('执行数据库升级: 添加group_messages表的call_type和channel_name字段');
      try {
        await db.execute('ALTER TABLE group_messages ADD COLUMN call_type VARCHAR(20)');
        await db.execute('ALTER TABLE group_messages ADD COLUMN channel_name VARCHAR(255)');
        logger.debug('✅ 数据库升级完成: call_type和channel_name字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }
    
    // 版本3 -> 版本4: 添加sender_nickname和sender_full_name字段
    if (oldVersion < 4) {
      logger.debug('执行数据库升级: 添加group_messages表的sender_nickname和sender_full_name字段');
      try {
        await db.execute('ALTER TABLE group_messages ADD COLUMN sender_nickname VARCHAR(100)');
        await db.execute('ALTER TABLE group_messages ADD COLUMN sender_full_name VARCHAR(100)');
        logger.debug('✅ 数据库升级完成: sender_nickname和sender_full_name字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }
    
    // 版本4 -> 版本5: 添加voice_duration字段（语音消息时长）
    if (oldVersion < 5) {
      logger.debug('执行数据库升级: 添加messages和group_messages表的voice_duration字段');
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN voice_duration INTEGER');
        await db.execute('ALTER TABLE group_messages ADD COLUMN voice_duration INTEGER');
        logger.debug('✅ 数据库升级完成: voice_duration字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }

    // 版本5 -> 版本6: 添加favorites表的server_id和sync_status字段（收藏同步）
    if (oldVersion < 6) {
      logger.debug('执行数据库升级: 添加favorites表的server_id和sync_status字段');
      try {
        await db.execute('ALTER TABLE favorites ADD COLUMN server_id INTEGER');
        await db.execute("ALTER TABLE favorites ADD COLUMN sync_status VARCHAR(20) DEFAULT 'synced'");
        logger.debug('✅ 数据库升级完成: server_id和sync_status字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }

    // 版本6 -> 版本7: 添加group_messages表的file_size、is_read、is_recalled字段
    if (oldVersion < 7) {
      logger.debug('执行数据库升级: 添加group_messages表的file_size、is_read、is_recalled字段');
      try {
        await db.execute('ALTER TABLE group_messages ADD COLUMN file_size INTEGER');
        await db.execute('ALTER TABLE group_messages ADD COLUMN is_read BOOLEAN DEFAULT 0');
        await db.execute('ALTER TABLE group_messages ADD COLUMN is_recalled BOOLEAN DEFAULT 0');
        logger.debug('✅ 数据库升级完成: file_size、is_read、is_recalled字段已添加');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }

    // 版本7 -> 版本8: 添加created_at_ms字段（毫秒时间戳，用于精确排序）
    if (oldVersion < 8) {
      logger.debug('执行数据库升级: 添加messages和group_messages表的created_at_ms字段');
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN created_at_ms INTEGER');
        await db.execute('ALTER TABLE group_messages ADD COLUMN created_at_ms INTEGER');
        await db.execute('ALTER TABLE file_assistant_messages ADD COLUMN created_at_ms INTEGER');
        logger.debug('✅ 数据库升级完成: created_at_ms字段已添加');
        
        // 🔴 迁移现有数据：将created_at转换为毫秒时间戳
        logger.debug('🔄 开始迁移现有消息的时间戳...');
        await _migrateCreatedAtToMs(db);
        logger.debug('✅ 时间戳迁移完成');
      } catch (e) {
        logger.error('❌ 数据库升级失败: $e');
        rethrow;
      }
    }
  }

  /// 🔴 迁移现有消息的created_at到created_at_ms
  Future<void> _migrateCreatedAtToMs(Database db) async {
    try {
      // 迁移私聊消息
      final messages = await db.rawQuery('SELECT id, created_at FROM messages WHERE created_at_ms IS NULL');
      for (var msg in messages) {
        final id = msg['id'] as int;
        final createdAt = msg['created_at'] as String?;
        if (createdAt != null && createdAt.isNotEmpty) {
          try {
            final timeStr = createdAt.endsWith('Z') ? createdAt : '${createdAt}Z';
            final ms = DateTime.parse(timeStr).millisecondsSinceEpoch;
            await db.execute('UPDATE messages SET created_at_ms = ? WHERE id = ?', [ms, id]);
          } catch (e) {
            // 忽略解析错误
          }
        }
      }
      
      // 迁移群聊消息
      final groupMessages = await db.rawQuery('SELECT id, created_at FROM group_messages WHERE created_at_ms IS NULL');
      for (var msg in groupMessages) {
        final id = msg['id'] as int;
        final createdAt = msg['created_at'] as String?;
        if (createdAt != null && createdAt.isNotEmpty) {
          try {
            final timeStr = createdAt.endsWith('Z') ? createdAt : '${createdAt}Z';
            final ms = DateTime.parse(timeStr).millisecondsSinceEpoch;
            await db.execute('UPDATE group_messages SET created_at_ms = ? WHERE id = ?', [ms, id]);
          } catch (e) {
            // 忽略解析错误
          }
        }
      }
      
      // 迁移文件助手消息
      final fileMessages = await db.rawQuery('SELECT id, created_at FROM file_assistant_messages WHERE created_at_ms IS NULL');
      for (var msg in fileMessages) {
        final id = msg['id'] as int;
        final createdAt = msg['created_at'] as String?;
        if (createdAt != null && createdAt.isNotEmpty) {
          try {
            final timeStr = createdAt.endsWith('Z') ? createdAt : '${createdAt}Z';
            final ms = DateTime.parse(timeStr).millisecondsSinceEpoch;
            await db.execute('UPDATE file_assistant_messages SET created_at_ms = ? WHERE id = ?', [ms, id]);
          } catch (e) {
            // 忽略解析错误
          }
        }
      }
    } catch (e) {
      logger.error('❌ 迁移时间戳失败: $e');
    }
  }

  /// 确保voice_duration列存在（用于修复旧数据库）
  Future<void> _ensureVoiceDurationColumn(Database db) async {
    try {
      // 检查messages表是否有voice_duration列
      final messagesColumns = await db.rawQuery('PRAGMA table_info(messages)');
      final hasVoiceDurationInMessages = messagesColumns.any((col) => col['name'] == 'voice_duration');
      
      if (!hasVoiceDurationInMessages) {
        await db.execute('ALTER TABLE messages ADD COLUMN voice_duration INTEGER');
      }
      
      // 检查group_messages表是否有voice_duration列
      final groupMessagesColumns = await db.rawQuery('PRAGMA table_info(group_messages)');
      final hasVoiceDurationInGroupMessages = groupMessagesColumns.any((col) => col['name'] == 'voice_duration');
      
      if (!hasVoiceDurationInGroupMessages) {
        logger.debug('⚠️ group_messages表缺少voice_duration列，正在添加...');
        await db.execute('ALTER TABLE group_messages ADD COLUMN voice_duration INTEGER');
      }
    } catch (e) {
      logger.error('❌ 验证voice_duration列失败: $e');
      // 不抛出异常，允许应用继续运行
    }
  }

  // ============ 私聊消息操作 ============

  /// 检查是否有任何消息（用于判断是否首次安装）
  Future<bool> hasAnyMessages(int userId) async {
    try {
      // 检查私聊消息
      final privateMessages = await _executeRawQuery('''
        SELECT COUNT(*) as count FROM messages 
        WHERE sender_id = ? OR receiver_id = ?
        LIMIT 1
      ''', [userId, userId]);
      
      final privateCount = privateMessages.isNotEmpty 
          ? (privateMessages.first['count'] as int? ?? 0) 
          : 0;
      
      if (privateCount > 0) {
        return true;
      }
      
      // 检查群聊消息
      final groupMessages = await _executeRawQuery('''
        SELECT COUNT(*) as count FROM group_messages 
        WHERE sender_id = ?
        LIMIT 1
      ''', [userId]);
      
      final groupCount = groupMessages.isNotEmpty 
          ? (groupMessages.first['count'] as int? ?? 0) 
          : 0;
      
      if (groupCount > 0) {
        return true;
      }
      
      return false;
    } catch (e) {
      logger.debug('❌ [hasAnyMessages] 检查消息失败: $e');
      return false;
    }
  }

  /// 插入私聊消息
  /// [orIgnore] 如果为true，遇到重复ID时忽略插入（用于离线消息去重）
  Future<int> insertMessage(Map<String, dynamic> message, {bool orIgnore = false}) async {
    try {
      final content = message['content']?.toString() ?? '';
      final preview = content.length > 30 ? content.substring(0, 30) : content;
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📝 [insertMessage-DB] 开始插入私聊消息');
      logger.debug('📝 [insertMessage-DB] sender_id: ${message['sender_id']}');
      logger.debug('📝 [insertMessage-DB] receiver_id: ${message['receiver_id']}');
      logger.debug('📝 [insertMessage-DB] server_id: ${message['server_id']}');
      logger.debug('📝 [insertMessage-DB] content: "$preview..."');
      logger.debug('📝 [insertMessage-DB] orIgnore: $orIgnore');
      
      // 🔴 自动计算并添加毫秒时间戳（用于精确排序）
      // 注意：created_at 可能是上海时区时间（无Z后缀）或UTC时间（有Z后缀）
      if (message['created_at_ms'] == null && message['created_at'] != null) {
        try {
          final createdAtStr = message['created_at'].toString();
          DateTime parsedTime;
          
          if (createdAtStr.endsWith('Z')) {
            // 带 Z 后缀的是 UTC 时间，直接解析
            parsedTime = DateTime.parse(createdAtStr);
          } else {
            // 🔴 修复：没有 Z 后缀的是上海时区时间，不要加 Z
            // 直接解析为本地时间，然后转换为 UTC 计算毫秒时间戳
            parsedTime = DateTime.parse(createdAtStr);
            // 上海时区是 UTC+8，需要减去8小时得到 UTC 时间
            parsedTime = parsedTime.subtract(const Duration(hours: 8));
          }
          
          message['created_at_ms'] = parsedTime.millisecondsSinceEpoch;
          logger.debug('📝 [insertMessage-DB] 时间解析: createdAtStr=$createdAtStr, 计算的ms=${message['created_at_ms']}');
        } catch (e) {
          logger.debug('📝 [insertMessage-DB] ⚠️ 时间解析失败: $e，使用当前时间');
          message['created_at_ms'] = DateTime.now().millisecondsSinceEpoch;
        }
      } else if (message['created_at_ms'] == null) {
        message['created_at_ms'] = DateTime.now().millisecondsSinceEpoch;
      }
      
      logger.debug('📝 [insertMessage-DB] created_at: ${message['created_at']}');
      logger.debug('📝 [insertMessage-DB] created_at_ms: ${message['created_at_ms']}');
      
      final id = await _executeInsert('messages', message, orIgnore: orIgnore);
      
      if (id > 0) {
        logger.debug('📝 [insertMessage-DB] ✅ 插入成功，本地ID: $id');
      } else {
        logger.debug('📝 [insertMessage-DB] ⚠️ 插入返回ID为0或负数: $id');
      }
      logger.debug('═══════════════════════════════════════════════════════════');
      
      return id;
    } catch (e) {
      logger.error('❌ [insertMessage-DB] 插入私聊消息失败: $e');
      rethrow;
    }
  }

  /// 根据本地数据库ID更新私聊消息状态（用于乐观更新）
  /// [localId] 本地数据库ID
  /// [status] 新的消息状态（'sending', 'sent', 'failed', 'forbidden'等）
  /// [serverId] 可选的服务器返回的消息ID（保存到server_id字段）
  Future<int> updateMessageStatusById({
    required int localId,
    required String status,
    int? serverId,
  }) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
      };
      
      // 🔴 如果提供了serverId，也更新server_id字段
      if (serverId != null) {
        updates['server_id'] = serverId;
        logger.debug('🔴 [updateMessageStatusById] 更新server_id - localId: $localId, serverId: $serverId');
      }
      
      final count = await _executeUpdate(
        'messages',
        updates,
        where: 'id = ?',
        whereArgs: [localId],
      );
      
      if (count > 0) {
        logger.debug('✅ 私聊消息状态更新成功 - local_id: $localId, status: $status${serverId != null ? ", server_id: $serverId" : ""}');
      } else {
        logger.debug('⚠️ 未找到匹配的私聊消息 - local_id: $localId');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ 更新私聊消息状态失败: $e');
      rethrow;
    }
  }

  /// 根据created_at更新私聊消息状态（用于乐观更新）
  /// [createdAt] 消息创建时间（ISO 8601格式），作为唯一标识
  /// [status] 新的消息状态（'sending', 'sent', 'failed', 'forbidden'等）
  /// [serverId] 可选的服务器返回的消息ID
  Future<int> updateMessageStatusByCreatedAt({
    required String createdAt,
    required String status,
    int? serverId,
  }) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
      };
      
      // 如果有服务器ID，同时更新ID字段
      if (serverId != null) {
        updates['id'] = serverId;
      }
      
      final count = await _executeUpdate(
        'messages',
        updates,
        where: 'created_at = ?',
        whereArgs: [createdAt],
      );
      
      if (count > 0) {
        logger.debug('✅ 私聊消息状态更新成功 - created_at: $createdAt, status: $status, 更新了 $count 条');
      } else {
        logger.debug('⚠️ 未找到匹配的私聊消息 - created_at: $createdAt');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ 更新私聊消息状态失败: $e');
      rethrow;
    }
  }

  /// 清理重复的私聊消息
  Future<int> cleanDuplicateMessages() async {
    try {
      final result = await _executeRawDelete('''
        DELETE FROM messages
        WHERE id NOT IN (
          SELECT MIN(id)
          FROM messages
          GROUP BY sender_id, receiver_id, content, created_at
        )
      ''');
      logger.debug('清理重复私聊消息: 删除了 $result 条重复消息');
      return result;
    } catch (e) {
      logger.debug('清理重复私聊消息失败: $e');
      rethrow;
    }
  }

  /// 获取私聊消息列表
  /// [userId1] 和 [userId2] 是两个聊天用户的ID
  /// [limit] 限制返回的消息数量
  /// [beforeId] 获取此ID之前的消息（用于加载更多历史）
  Future<List<Map<String, dynamic>>> getMessages({
    required int userId1,
    required int userId2,
    int limit = 100,
    int? beforeId,
  }) async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📊 [getMessages-DB] 开始查询私聊消息');
      logger.debug('📊 [getMessages-DB] userId1: $userId1, userId2: $userId2');
      logger.debug('📊 [getMessages-DB] limit: $limit, beforeId: $beforeId');
      
      // 🔴 修改：不再过滤撤回的消息，让UI层显示"消息已撤回"
      String whereClause = '((sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?)) '
          'AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE ?)';
      List<dynamic> whereArgs = [
        userId1, userId2, userId2, userId1,
        '%$userId1%'
      ];
      
      // 🔴 如果指定了 beforeId，添加条件获取更早的消息
      if (beforeId != null) {
        whereClause += ' AND id < ?';
        whereArgs.add(beforeId);
      }
      
      logger.debug('📊 [getMessages-DB] SQL WHERE: $whereClause');
      logger.debug('📊 [getMessages-DB] SQL ARGS: $whereArgs');
      
      final results = await _executeQuery(
        'messages',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'id DESC',
        limit: limit,
      );
      
      logger.debug('📊 [getMessages-DB] 查询到 ${results.length} 条消息');
      
      // 反转列表，使消息按时间正序排列（旧消息在前，新消息在后）
      final sortedResults = results.reversed.toList();
      
      // 🔴 打印所有消息的信息（用于调试）
      if (sortedResults.isNotEmpty) {
        logger.debug('📊 [getMessages-DB] 消息列表详情:');
        for (int i = 0; i < sortedResults.length && i < 10; i++) {
          final msg = sortedResults[i];
          final content = msg['content']?.toString() ?? '';
          final preview = content.length > 30 ? content.substring(0, 30) : content;
          logger.debug('   - [$i] id=${msg['id']}, server_id=${msg['server_id']}, sender_id=${msg['sender_id']}, content="$preview..."');
        }
        if (sortedResults.length > 10) {
          logger.debug('   ... 还有 ${sortedResults.length - 10} 条消息');
        }
        final lastMsg = sortedResults.last;
        final lastContent = lastMsg['content']?.toString() ?? '';
        final lastPreview = lastContent.length > 30 ? lastContent.substring(0, 30) : lastContent;
        logger.debug('📊 [getMessages-DB] 最新消息: id=${lastMsg['id']}, server_id=${lastMsg['server_id']}, sender_id=${lastMsg['sender_id']}, content="$lastPreview..."');
      } else {
        logger.debug('📊 [getMessages-DB] ⚠️ 没有查询到任何消息！');
      }
      logger.debug('═══════════════════════════════════════════════════════════');
      
      return sortedResults;
    } catch (e) {
      logger.error('❌ [getMessages-DB] 获取私聊消息失败: $e');
      rethrow;
    }
  }

  /// 获取最近联系人列表（包含最后一条消息）
  /// 合并私聊消息和群聊消息，返回每个联系人/群组的最后一条消息
  Future<List<Map<String, dynamic>>> getRecentContacts(int userId) async {
    try {
      logger.debug('═══════════════════════════════════════════════════════════');
      logger.debug('📊 [getRecentContacts] 开始查询最近联系人列表 - userId: $userId');
      
      final allContacts = <Map<String, dynamic>>[];
      
      // 🔴 调试：先查询一下数据库中is_read=0的消息数量
      final unreadMessages = await _executeRawQuery(
        'SELECT id, sender_id, receiver_id, is_read, content FROM messages WHERE receiver_id = ? AND is_read = 0 LIMIT 10',
        [userId],
      );
      logger.debug('📊 [getRecentContacts] 数据库中未读消息数量: ${unreadMessages.length}');
      for (final msg in unreadMessages) {
        final content = msg['content']?.toString() ?? '';
        final preview = content.length > 20 ? content.substring(0, 20) : content;
        logger.debug('📊 [getRecentContacts] 未读消息: sender_id=${msg['sender_id']}, content="$preview..."');
      }
      
      // 1. 获取私聊最近联系人
      // 🔴 修改：不再过滤撤回的消息，添加status字段让UI层判断是否显示"消息已撤回"
      // 🔴 修复：使用明确的表别名避免子查询列引用混淆
      final userContacts = await _executeRawQuery(
        '''
        SELECT 
          'user' as contact_type,
          CASE WHEN m.sender_id = ? THEN m.receiver_id ELSE m.sender_id END as contact_id,
          m.created_at as last_message_time,
          m.created_at_ms as last_message_time_ms,
          m.sender_id,
          m.receiver_id,
          m.content,
          m.message_type,
          m.status,
          m.sender_name,
          m.receiver_name,
          m.sender_avatar,
          m.receiver_avatar,
          m.file_name,
          NULL as group_name,
          NULL as group_avatar,
          (SELECT COUNT(*) FROM messages m2
           WHERE m2.receiver_id = ?
             AND m2.sender_id = CASE WHEN m.sender_id = ? THEN m.receiver_id ELSE m.sender_id END
             AND m2.is_read = 0 
             AND (m2.status IS NULL OR m2.status = '' OR m2.status = 'normal')
             AND (m2.deleted_by_users IS NULL OR m2.deleted_by_users NOT LIKE '%' || ? || '%')
          ) as unread_count
        FROM messages m
        WHERE m.id IN (
          SELECT MAX(id)
          FROM messages
          WHERE (sender_id = ? OR receiver_id = ?)
            AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE '%' || ? || '%')
            AND NOT (sender_id = ? AND receiver_id = ?)
          GROUP BY CASE WHEN sender_id = ? THEN receiver_id ELSE sender_id END
        )
        ''',
        [userId, userId, userId, userId.toString(), userId, userId, userId.toString(), userId, userId, userId],
      );
      
      allContacts.addAll(userContacts);
      
      // 2. 获取群聊最近联系人
      // 🔴 修改：不再过滤撤回的消息，添加status字段让UI层判断
      final groupContacts = await _executeRawQuery(
        '''
        SELECT 
          'group' as contact_type,
          group_id as contact_id,
          created_at as last_message_time,
          created_at_ms as last_message_time_ms,
          sender_id,
          group_id as receiver_id,
          content,
          message_type,
          status,
          sender_name,
          NULL as receiver_name,
          sender_avatar,
          NULL as receiver_avatar,
          file_name,
          group_name,
          group_avatar,
          (SELECT COUNT(*) FROM group_messages gm2
           WHERE gm2.group_id = gm.group_id
             AND gm2.sender_id != ?
             AND (gm2.status IS NULL OR gm2.status = '' OR gm2.status = 'normal')
             AND (gm2.deleted_by_users IS NULL OR gm2.deleted_by_users NOT LIKE '%' || ? || '%')
             AND NOT EXISTS (
               SELECT 1 FROM group_message_reads gmr
               WHERE gmr.group_message_id = gm2.id AND gmr.user_id = ?
             )
          ) as unread_count
        FROM group_messages gm
        WHERE id IN (
          SELECT MAX(gm2.id)
          FROM group_messages gm2
          INNER JOIN group_members gmbr ON gm2.group_id = gmbr.group_id AND gmbr.user_id = ?
          WHERE (gm2.deleted_by_users IS NULL OR gm2.deleted_by_users NOT LIKE '%' || ? || '%')
          GROUP BY gm2.group_id
        )
        ''',
        [userId, userId.toString(), userId, userId, userId.toString()],
      );
      allContacts.addAll(groupContacts);
      
      // 3. 获取文件传输助手最近消息
      // 🔴 修改：不再过滤撤回的消息，添加status字段让UI层判断
      final fileAssistant = await _executeRawQuery(
        '''
        SELECT 
          'file_assistant' as contact_type,
          0 as contact_id,
          created_at as last_message_time,
          created_at_ms as last_message_time_ms,
          ? as sender_id,
          ? as receiver_id,
          content,
          message_type,
          status,
          NULL as sender_name,
          '文件传输助手' as receiver_name,
          NULL as sender_avatar,
          NULL as receiver_avatar,
          file_name,
          NULL as group_name,
          NULL as group_avatar,
          0 as unread_count
        FROM file_assistant_messages
        WHERE user_id = ?
        ORDER BY created_at DESC
        LIMIT 1
        ''',
        [userId, userId, userId],
      );
      allContacts.addAll(fileAssistant);
      
      // 4. 按时间排序（🔴 优先使用毫秒时间戳排序）
      // 🔍 调试：打印排序前的时间
      for (int i = 0; i < allContacts.length && i < 10; i++) {
        final c = allContacts[i];
        final name = c['contact_type'] == 'group' 
            ? (c['group_name'] ?? 'group_${c['contact_id']}')
            : (c['sender_name'] ?? c['receiver_name'] ?? 'user_${c['contact_id']}');
      }
      
      allContacts.sort((a, b) {
        final aTimeStr = a['last_message_time'] as String?;
        final bTimeStr = b['last_message_time'] as String?;
        if (aTimeStr == null || aTimeStr.isEmpty) return 1;
        if (bTimeStr == null || bTimeStr.isEmpty) return -1;
        
        // 🔴 优先使用毫秒时间戳排序（更精确）
        final aMs = a['last_message_time_ms'] as int?;
        final bMs = b['last_message_time_ms'] as int?;
        
        // 如果两个都有毫秒时间戳，直接比较
        if (aMs != null && bMs != null) {
          return bMs.compareTo(aMs); // 降序：最新的在前
        }
        
        // 🔴 回退：使用字符串时间解析
        int aMillis;
        int bMillis;
        
        // 优先使用毫秒时间戳
        if (aMs != null) {
          aMillis = aMs;
        } else {
          try {
            // 不带Z的本地时间需要手动指定为UTC解析，避免被当作本地时间处理
            if (aTimeStr.endsWith('Z')) {
              aMillis = DateTime.parse(aTimeStr).millisecondsSinceEpoch;
            } else {
              // 本地时间字符串，直接当作UTC解析（因为服务器存的就是上海时间的字面值）
              aMillis = DateTime.parse('${aTimeStr}Z').millisecondsSinceEpoch;
            }
          } catch (e) {
            aMillis = 0;
          }
        }
        
        if (bMs != null) {
          bMillis = bMs;
        } else {
          try {
            if (bTimeStr.endsWith('Z')) {
              bMillis = DateTime.parse(bTimeStr).millisecondsSinceEpoch;
            } else {
              // 本地时间字符串，直接当作UTC解析
              bMillis = DateTime.parse('${bTimeStr}Z').millisecondsSinceEpoch;
            }
          } catch (e) {
            bMillis = 0;
          }
        }
        
        return bMillis.compareTo(aMillis); // 降序：最新的在前
      });
      
      // 🔍 调试：打印排序后的联系人列表
      logger.debug('📊 [getRecentContacts] 排序后联系人列表 (共 ${allContacts.length} 个):');
      for (int i = 0; i < allContacts.length && i < 10; i++) {
        final c = allContacts[i];
        final contactType = c['contact_type'];
        final name = contactType == 'group' 
            ? (c['group_name'] ?? 'group_${c['contact_id']}')
            : (c['sender_name'] ?? c['receiver_name'] ?? 'user_${c['contact_id']}');
        final unreadCount = c['unread_count'];
        final content = c['content']?.toString() ?? '';
        final preview = content.length > 20 ? content.substring(0, 20) : content;
        logger.debug('📊 [getRecentContacts] [$contactType] $name: unread=$unreadCount, lastMsg="$preview..."');
      }
      
      logger.debug('═══════════════════════════════════════════════════════════');

      return allContacts;
    } catch (e) {
      logger.debug('获取最近联系人失败: $e');
      rethrow;
    }
  }

  /// 更新消息已读状态
  Future<void> updateMessageReadStatus(int messageId) async {
    try {
      await _executeUpdate(
        'messages',
        {'is_read': 1, 'read_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [messageId],
      );
    } catch (e) {
      logger.debug('更新消息已读状态失败: $e');
      rethrow;
    }
  }

  /// 🔴 根据服务器消息ID更新消息已读状态
  /// 用于离线消息同步时，将已存在的消息标记为未读
  /// [serverId] 服务器消息ID
  /// [isRead] 是否已读
  /// 返回更新的行数
  /// 🔴 修复：同时检查 id 和 server_id 字段，因为离线消息的服务器ID可能存储在 id 字段中
  Future<int> updateMessageReadStatusByServerId(int serverId, bool isRead) async {
    try {
      // 🔴 修复：先尝试通过 server_id 字段更新
      var count = await _executeUpdate(
        'messages',
        {
          'is_read': isRead ? 1 : 0,
          if (!isRead) 'read_at': null, // 如果标记为未读，清除已读时间
        },
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      
      // 🔴 如果 server_id 字段没有匹配，尝试通过 id 字段更新
      // 因为离线消息插入时，服务器ID可能直接存储在 id 字段中
      if (count == 0) {
        count = await _executeUpdate(
          'messages',
          {
            'is_read': isRead ? 1 : 0,
            if (!isRead) 'read_at': null,
          },
          where: 'id = ?',
          whereArgs: [serverId],
        );
        if (count > 0) {
          logger.debug('✅ 根据id字段更新消息已读状态成功 - id: $serverId, isRead: $isRead');
        }
      } else {
        logger.debug('✅ 根据server_id字段更新消息已读状态成功 - serverId: $serverId, isRead: $isRead');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ 根据服务器ID更新消息已读状态失败: $e');
      return 0;
    }
  }

  /// 🔴 根据服务器消息ID查询消息是否存在
  /// 用于离线消息去重
  Future<Map<String, dynamic>?> getMessageByServerId(int serverId) async {
    try {
      // 先通过 server_id 字段查询
      var results = await _executeQuery(
        'messages',
        where: 'server_id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      
      if (results.isNotEmpty) {
        return results.first;
      }
      
      // 如果 server_id 字段没有匹配，尝试通过 id 字段查询
      // 因为旧的离线消息可能直接存储在 id 字段中
      results = await _executeQuery(
        'messages',
        where: 'id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      logger.debug('❌ 根据服务器ID查询消息失败: $e');
      return null;
    }
  }

  /// 批量更新用户头像（用于头像更新通知）
  Future<int> updateUserAvatarInMessages(int userId, String? newAvatar) async {
    try {
      int updatedCount = 0;
      
      // 更新该用户作为发送者的所有消息
      final senderResult = await _executeUpdate(
        'messages',
        {'sender_avatar': newAvatar},
        where: 'sender_id = ?',
        whereArgs: [userId],
      );
      updatedCount += senderResult;
      
      // 更新该用户作为接收者的私聊消息（排除群聊消息）
      final receiverResult = await _executeUpdate(
        'messages',
        {'receiver_avatar': newAvatar},
        where: 'receiver_id = ? AND message_type != ?',
        whereArgs: [userId, 'group'],
      );
      updatedCount += receiverResult;
      
      return updatedCount;
    } catch (e) {
      logger.debug('❌ 数据库头像更新失败: $e');
      return 0;
    }
  }

  /// 批量更新用户头像在联系人快照表中（用于头像更新通知）
  Future<int> updateUserAvatarInContactSnapshots(int userId, String? newAvatar) async {
    try {
      // 更新联系人快照表中该用户的头像
      final updatedCount = await _executeUpdate(
        'contact_snapshots',
        {
          'avatar': newAvatar,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'contact_id = ? AND contact_type = ?',
        whereArgs: [userId, 'user'],
      );
      
      logger.debug('💾 联系人快照头像更新完成 - 用户ID: $userId, 更新了 $updatedCount 条快照记录');
      return updatedCount;
    } catch (e) {
      logger.debug('❌ 联系人快照头像更新失败: $e');
      return 0;
    }
  }

  /// 批量更新群组成员昵称（用于群组昵称更新通知）
  Future<int> updateGroupMemberNickname(int groupId, int userId, String newNickname) async {
    try {
      // 先查询该用户在群组中的消息数量，用于调试
      // 群组消息存储在group_messages表中，不是messages表
      final queryResult = await _executeQuery(
        'group_messages',
        where: 'group_id = ? AND sender_id = ?',
        whereArgs: [groupId, userId],
      );
      logger.debug('🔍 [调试] 查询到用户 $userId 在群组 $groupId 中的消息: ${queryResult.length} 条');
      
      // 显示前3条消息的详细信息用于调试
      for (int i = 0; i < queryResult.length && i < 3; i++) {
        final msg = queryResult[i];
        logger.debug('🔍 [调试] 消息${i+1}: sender_id=${msg['sender_id']}, sender_name="${msg['sender_name']}", content="${msg['content']}", created_at=${msg['created_at']}');
      }
      
      // 更新该用户在指定群组中发送的所有消息的sender_name字段
      // 群组消息存储在group_messages表中，查询条件是group_id和sender_id
      final updatedCount = await _executeUpdate(
        'group_messages',
        {'sender_name': newNickname},
        where: 'group_id = ? AND sender_id = ?',
        whereArgs: [groupId, userId],
      );
      
      logger.debug('💾 数据库群组昵称更新完成 - 群组ID: $groupId, 用户ID: $userId, 新昵称: $newNickname, 更新了 $updatedCount 条消息记录');
      return updatedCount;
    } catch (e) {
      logger.debug('❌ 数据库群组昵称更新失败: $e');
      return 0;
    }
  }

  /// 批量更新群组信息（用于群组信息更新通知，包括群组头像、名称等）
  Future<int> updateGroupInfoInMessages({
    required int groupId,
    String? groupName,
    String? groupAvatar,
  }) async {
    try {
      // 构建更新数据
      final updateData = <String, dynamic>{};
      if (groupName != null) {
        updateData['group_name'] = groupName;
      }
      if (groupAvatar != null) {
        updateData['group_avatar'] = groupAvatar;
      }

      if (updateData.isEmpty) {
        logger.debug('⚠️ 没有需要更新的群组信息');
        return 0;
      }

      // 更新group_messages表中该群组的所有消息
      final updatedCount = await _executeUpdate(
        'group_messages',
        updateData,
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      
      logger.debug('💾 数据库群组信息更新完成 - 群组ID: $groupId, 更新了 $updatedCount 条消息记录');
      if (groupName != null) {
        logger.debug('   - 群组名称: $groupName');
      }
      if (groupAvatar != null) {
        logger.debug('   - 群组头像: $groupAvatar');
      }
      
      return updatedCount;
    } catch (e) {
      logger.error('❌ 数据库群组信息更新失败: $e');
      return 0;
    }
  }

  /// 撤回消息
  Future<void> recallMessage(int messageId) async {
    try {
      await _executeUpdate(
        'messages',
        {'status': 'recalled'},
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('撤回消息: ID=$messageId');
    } catch (e) {
      logger.debug('撤回消息失败: $e');
      rethrow;
    }
  }

  /// 通过服务器ID撤回消息（用于接收撤回通知时更新本地数据库）
  Future<void> recallMessageByServerId(int serverId) async {
    try {
      await _executeUpdate(
        'messages',
        {'status': 'recalled'},
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      logger.debug('通过服务器ID撤回消息: serverId=$serverId');
    } catch (e) {
      logger.debug('通过服务器ID撤回消息失败: $e');
      rethrow;
    }
  }

  /// 删除消息（添加用户ID到deleted_by_users）
  Future<void> deleteMessage(int messageId, int userId) async {
    try {
      // 先获取当前的deleted_by_users
      final results = await _executeQuery(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );

      if (results.isNotEmpty) {
        final deletedByUsers = (results.first['deleted_by_users'] ?? '') as String;
        final userIds = deletedByUsers.isEmpty
            ? <String>[]
            : deletedByUsers.split(',');

        if (!userIds.contains(userId.toString())) {
          userIds.add(userId.toString());
          await _executeUpdate(
            'messages',
            {'deleted_by_users': userIds.join(',')},
            where: 'id = ?',
            whereArgs: [messageId],
          );
        }
      }

      logger.debug('删除消息: ID=$messageId, UserID=$userId');
    } catch (e) {
      logger.debug('删除消息失败: $e');
      rethrow;
    }
  }

  /// 删除与指定联系人的所有私聊消息（软删除：标记为已删除）
  Future<int> deleteAllMessagesWithContact(int userId1, int userId2) async {
    try {
      // 查询所有相关消息
      final messages = await _executeQuery(
        'messages',
        where: '(sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?)',
        whereArgs: [userId1, userId2, userId2, userId1],
      );

      int count = 0;
      // 对每条消息添加userId1到deleted_by_users
      for (var message in messages) {
        final messageId = message['id'] as int;
        final deletedByUsers = (message['deleted_by_users'] as String?) ?? '';
        
        final userIds = deletedByUsers.isEmpty
            ? <String>[]
            : deletedByUsers.split(',');
        
        if (!userIds.contains(userId1.toString())) {
          userIds.add(userId1.toString());
          await _executeUpdate(
            'messages',
            {'deleted_by_users': userIds.join(',')},
            where: 'id = ?',
            whereArgs: [messageId],
          );
          count++;
        }
      }
      
      logger.debug('标记与联系人的所有私聊消息为已删除: userId1=$userId1, userId2=$userId2, 标记数量=$count');
      return count;
    } catch (e) {
      logger.error('标记私聊消息删除失败: $e', error: e);
      rethrow;
    }
  }

  /// 🔴 物理删除两个用户之间的所有私聊消息
  /// 用于好友审核通过/驳回时清空历史消息
  Future<int> deleteMessagesBetweenUsers(int userId1, int userId2) async {
    try {
      final count = await _executeRawDelete(
        'DELETE FROM messages WHERE (sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?)',
        [userId1, userId2, userId2, userId1],
      );
      logger.debug('🗑️ 物理删除两用户间的私聊消息: userId1=$userId1, userId2=$userId2, 删除数量=$count');
      return count;
    } catch (e) {
      logger.error('物理删除私聊消息失败: $e', error: e);
      rethrow;
    }
  }

  /// 删除指定群组的所有消息（软删除：标记为已删除）
  Future<int> deleteAllGroupMessages(int groupId, int userId) async {
    try {
      // 查询所有相关消息
      final messages = await _executeQuery(
        'group_messages',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );

      int count = 0;
      // 对每条消息添加userId到deleted_by_users
      for (var message in messages) {
        final messageId = message['id'] as int;
        final deletedByUsers = (message['deleted_by_users'] as String?) ?? '';
        
        final userIds = deletedByUsers.isEmpty
            ? <String>[]
            : deletedByUsers.split(',');
        
        if (!userIds.contains(userId.toString())) {
          userIds.add(userId.toString());
          await _executeUpdate(
            'group_messages',
            {'deleted_by_users': userIds.join(',')},
            where: 'id = ?',
            whereArgs: [messageId],
          );
          count++;
        }
      }
      
      logger.debug('标记群组的所有消息为已删除: groupId=$groupId, userId=$userId, 标记数量=$count');
      return count;
    } catch (e) {
      logger.error('标记群聊消息删除失败: $e', error: e);
      rethrow;
    }
  }

  /// 删除文件传输助手的所有消息（硬删除）
  Future<int> deleteAllFileAssistantMessages(int userId) async {
    try {
      final count = await _executeDelete(
        'file_assistant_messages',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      
      logger.debug('删除文件传输助手的所有消息: userId=$userId, 删除数量=$count');
      return count;
    } catch (e) {
      logger.error('删除文件传输助手消息失败: $e', error: e);
      rethrow;
    }
  }

  // ============ 群聊消息操作 ============

  /// 插入群聊消息
  /// [orIgnore] 如果为true，遇到重复ID时忽略插入（用于离线消息去重）
  Future<int> insertGroupMessage(Map<String, dynamic> message, {bool orIgnore = false}) async {
    logger.debug('💾 [LocalDB-群组] insertGroupMessage被调用');
    logger.debug('   - message_type: ${message['message_type']}');
    logger.debug('   - voice_duration: ${message['voice_duration']} (类型: ${message['voice_duration']?.runtimeType})');
    
    try {
      // 🔴 自动计算并添加毫秒时间戳（用于精确排序）
      // 注意：created_at 可能是上海时区时间（无Z后缀）或UTC时间（有Z后缀）
      if (message['created_at_ms'] == null && message['created_at'] != null) {
        try {
          final createdAtStr = message['created_at'].toString();
          DateTime parsedTime;
          
          if (createdAtStr.endsWith('Z')) {
            // 带 Z 后缀的是 UTC 时间，直接解析
            parsedTime = DateTime.parse(createdAtStr);
          } else {
            // 🔴 修复：没有 Z 后缀的是上海时区时间，不要加 Z
            // 直接解析为本地时间，然后转换为 UTC 计算毫秒时间戳
            parsedTime = DateTime.parse(createdAtStr);
            // 上海时区是 UTC+8，需要减去8小时得到 UTC 时间
            parsedTime = parsedTime.subtract(const Duration(hours: 8));
          }
          
          message['created_at_ms'] = parsedTime.millisecondsSinceEpoch;
          logger.debug('💾 [LocalDB-群组] 时间解析: createdAtStr=$createdAtStr, 计算的ms=${message['created_at_ms']}');
        } catch (e) {
          logger.debug('💾 [LocalDB-群组] ⚠️ 时间解析失败: $e，使用当前时间');
          message['created_at_ms'] = DateTime.now().millisecondsSinceEpoch;
        }
      } else if (message['created_at_ms'] == null) {
        message['created_at_ms'] = DateTime.now().millisecondsSinceEpoch;
      }
      
      final id = await _executeInsert('group_messages', message, orIgnore: orIgnore);
      if (id > 0) {
        logger.debug('💾 [LocalDB-群组] 插入群聊消息成功: ID=$id, created_at_ms: ${message['created_at_ms']}');
        
        // 🔴 立即查询刚插入的数据验证
        if (message['message_type'] == 'voice') {
          final db = await database;
          final inserted = await db.query(
            'group_messages',
            where: 'id = ?',
            whereArgs: [id],
          );
          if (inserted.isNotEmpty) {
            logger.debug('💾 [LocalDB-群组] 验证插入结果:');
            logger.debug('   - 数据库中的voice_duration: ${inserted.first['voice_duration']}');
          }
        }
      } else if (orIgnore) {
        logger.debug('群聊消息已存在，跳过插入: ID=${message['id']}');
      }
      return id;
    } catch (e) {
      logger.debug('插入群聊消息失败: $e');
      rethrow;
    }
  }

  /// 🔴 根据服务器消息ID查询群组消息是否存在
  /// 用于离线消息去重
  Future<Map<String, dynamic>?> getGroupMessageByServerId(int serverId) async {
    try {
      // 先通过 server_id 字段查询
      var results = await _executeQuery(
        'group_messages',
        where: 'server_id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      
      if (results.isNotEmpty) {
        return results.first;
      }
      
      // 如果 server_id 字段没有匹配，尝试通过 id 字段查询
      // 因为旧的离线消息可能直接存储在 id 字段中
      results = await _executeQuery(
        'group_messages',
        where: 'id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      logger.debug('❌ 根据服务器ID查询群组消息失败: $e');
      return null;
    }
  }

  /// 根据本地数据库ID更新群聊消息状态（用于乐观更新）
  /// [localId] 本地数据库ID
  /// [status] 新的消息状态（'sending', 'sent', 'failed', 'forbidden'等）
  /// [serverId] 可选的服务器返回的消息ID（保存到server_id字段）
  Future<int> updateGroupMessageStatusById({
    required int localId,
    required String status,
    int? serverId,
  }) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
      };
      
      // 🔴 如果提供了serverId，也更新server_id字段
      if (serverId != null) {
        updates['server_id'] = serverId;
        logger.debug('🔴 [updateGroupMessageStatusById] 更新server_id - localId: $localId, serverId: $serverId');
      }
      
      final count = await _executeUpdate(
        'group_messages',
        updates,
        where: 'id = ?',
        whereArgs: [localId],
      );
      
      if (count > 0) {
        logger.debug('✅ 群聊消息状态更新成功 - local_id: $localId, status: $status${serverId != null ? ", server_id: $serverId" : ""}');
      } else {
        logger.debug('⚠️ 未找到匹配的群聊消息 - local_id: $localId');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ 更新群聊消息状态失败: $e');
      rethrow;
    }
  }

  /// 🔴 新增：更新最近发送的群聊消息的server_id
  /// 查找最近一条server_id为空的消息，更新其server_id
  /// [serverId] 服务器返回的消息ID
  Future<int> updateGroupMessageServerId(int serverId) async {
    try {
      // 查找最近一条server_id为空的消息
      final db = await database;
      final results = await db.query(
        'group_messages',
        where: 'server_id IS NULL',
        orderBy: 'id DESC',
        limit: 1,
      );
      
      if (results.isEmpty) {
        logger.debug('⚠️ [updateGroupMessageServerId] 未找到server_id为空的群聊消息');
        return 0;
      }
      
      final localId = results.first['id'] as int;
      
      final count = await _executeUpdate(
        'group_messages',
        {'server_id': serverId, 'status': 'sent'},
        where: 'id = ?',
        whereArgs: [localId],
      );
      
      if (count > 0) {
        logger.debug('✅ [updateGroupMessageServerId] 更新成功 - localId: $localId, serverId: $serverId');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ [updateGroupMessageServerId] 更新失败: $e');
      rethrow;
    }
  }

  /// 根据created_at更新群聊消息状态（用于乐观更新）
  /// [createdAt] 消息创建时间（ISO 8601格式），作为唯一标识
  /// [status] 新的消息状态（'sending', 'sent', 'failed', 'forbidden'等）
  /// [serverId] 可选的服务器返回的消息ID
  Future<int> updateGroupMessageStatusByCreatedAt({
    required String createdAt,
    required String status,
    int? serverId,
  }) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
      };
      
      // 如果有服务器ID，同时更新ID字段
      if (serverId != null) {
        updates['id'] = serverId;
      }
      
      final count = await _executeUpdate(
        'group_messages',
        updates,
        where: 'created_at = ?',
        whereArgs: [createdAt],
      );
      
      if (count > 0) {
        logger.debug('✅ 群聊消息状态更新成功 - created_at: $createdAt, status: $status, 更新了 $count 条');
      } else {
        logger.debug('⚠️ 未找到匹配的群聊消息 - created_at: $createdAt');
      }
      
      return count;
    } catch (e) {
      logger.debug('❌ 更新群聊消息状态失败: $e');
      rethrow;
    }
  }

  /// 清理重复的群聊消息
  Future<int> cleanDuplicateGroupMessages() async {
    try {
      final result = await _executeRawDelete('''
        DELETE FROM group_messages
        WHERE id NOT IN (
          SELECT MIN(id)
          FROM group_messages
          GROUP BY group_id, sender_id, content, created_at
        )
      ''');
      logger.debug('清理重复群聊消息: 删除了 $result 条重复消息');
      return result;
    } catch (e) {
      logger.debug('清理重复群聊消息失败: $e');
      rethrow;
    }
  }

  /// 获取群聊消息列表
  /// [beforeId] 获取此ID之前的消息（用于加载更多历史）
  Future<List<Map<String, dynamic>>> getGroupMessages({
    required int groupId,
    int? userId,  // 可选参数，用于过滤当前用户已删除的消息
    int limit = 100,
    int? beforeId,
  }) async {
    
    try {
      // 🔴 修改：不再过滤撤回的消息，让UI层显示"消息已撤回"
      String where = 'group_id = ?';
      List<dynamic> whereArgs = [groupId];
      
      // 如果提供了userId，则过滤该用户已删除的消息
      if (userId != null) {
        where += ' AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE ?)';
        whereArgs.add('%$userId%');
      }
      
      // 🔴 如果指定了 beforeId，添加条件获取更早的消息
      if (beforeId != null) {
        where += ' AND id < ?';
        whereArgs.add(beforeId);
      }
      
      // 🔴 修复：先按 id DESC 获取最新的消息，然后反转为正序显示
      final results = await _executeQuery(
        'group_messages',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'id DESC',
        limit: limit,
      );
      
      // 反转列表，使消息按时间正序排列（旧消息在前，新消息在后）
      final sortedResults = results.reversed.toList();
      
      // 🔴 打印前3条语音消息的voice_duration
      int voiceCount = 0;
      for (var msg in sortedResults) {
        if (msg['message_type'] == 'voice' && voiceCount < 3) {
          voiceCount++;
        }
      }
      
      return sortedResults;
    } catch (e) {
      logger.debug('获取群聊消息失败: $e');
      rethrow;
    }
  }

  /// 撤回群聊消息
  Future<void> recallGroupMessage(int messageId) async {
    try {
      await _executeUpdate(
        'group_messages',
        {'status': 'recalled'},
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('撤回群聊消息: ID=$messageId');
    } catch (e) {
      logger.debug('撤回群聊消息失败: $e');
      rethrow;
    }
  }

  /// 通过服务器ID撤回群聊消息（用于接收撤回通知时更新本地数据库）
  Future<void> recallGroupMessageByServerId(int serverId) async {
    try {
      await _executeUpdate(
        'group_messages',
        {'status': 'recalled'},
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      logger.debug('通过服务器ID撤回群聊消息: serverId=$serverId');
    } catch (e) {
      logger.debug('通过服务器ID撤回群聊消息失败: $e');
      rethrow;
    }
  }

  Future<void> deleteGroupMessage(int messageId, int userId) async {
    try {
      // 先获取当前的deleted_by_users
      final results = await _executeQuery(
        'group_messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final deletedByUsers = results.first['deleted_by_users'] as String;
        final userIds = deletedByUsers.isEmpty
            ? <String>[]
            : deletedByUsers.split(',');

        if (!userIds.contains(userId.toString())) {
          userIds.add(userId.toString());
          await _executeUpdate(
            'group_messages',
            {'deleted_by_users': userIds.join(',')},
            where: 'id = ?',
            whereArgs: [messageId],
          );
        }
      }

      logger.debug('删除群聊消息: ID=$messageId, UserID=$userId');
    } catch (e) {
      logger.debug('删除群聊消息失败: $e');
      rethrow;
    }
  }

  /// 🔴 物理删除群聊消息（用于服务器端删除通知）
  /// 与deleteGroupMessage不同，这个方法是真正从数据库删除记录，而不是标记删除
  Future<void> deleteGroupMessageById(int messageId) async {
    try {
      await _executeDelete(
        'group_messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('✅ 物理删除群聊消息: ID=$messageId');
    } catch (e) {
      logger.debug('❌ 物理删除群聊消息失败: $e');
      rethrow;
    }
  }

  /// 🔴 更新群聊消息类型（用于将按钮消息转换为普通系统消息）
  /// [messageId] 服务器端的消息ID（server_id）
  Future<void> updateGroupMessageType(int messageId, String newMessageType) async {
    try {
      // 🔴 修复：使用 server_id 或 id 来匹配消息
      // 服务器发送的 message_id 是服务器端的ID，对应本地的 server_id 字段
      // 但有些消息可能 server_id 为空，此时用 id 匹配
      final db = await database;
      
      // 首先尝试用 server_id 匹配
      int count = await _executeUpdate(
        'group_messages',
        {'message_type': newMessageType},
        where: 'server_id = ?',
        whereArgs: [messageId],
      );
      
      // 如果 server_id 没有匹配到，尝试用 id 匹配
      if (count == 0) {
        count = await _executeUpdate(
          'group_messages',
          {'message_type': newMessageType},
          where: 'id = ?',
          whereArgs: [messageId],
        );
      }
      
      if (count > 0) {
        logger.debug('✅ 更新群聊消息类型: ID=$messageId, newType=$newMessageType');
      } else {
        logger.debug('⚠️ 未找到需要更新的群聊消息: ID=$messageId');
      }
    } catch (e) {
      logger.debug('❌ 更新群聊消息类型失败: $e');
      rethrow;
    }
  }

  /// 🔴 物理删除私聊消息（用于服务器端删除通知）
  /// 与标记删除不同，这个方法是真正从数据库删除记录
  Future<void> deleteMessageById(int messageId) async {
    try {
      await _executeDelete(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('✅ 物理删除私聊消息: ID=$messageId');
    } catch (e) {
      logger.debug('❌ 物理删除私聊消息失败: $e');
      rethrow;
    }
  }

  /// 记录群聊消息已读
  Future<void> markGroupMessageAsRead(int groupMessageId, int userId) async {
    try {
      // 注意：SQLite3不支持conflictAlgorithm参数，需要使用INSERT OR REPLACE
      if (_isDesktopPlatform) {
        await _executeRawQuery(
          'INSERT OR REPLACE INTO group_message_reads (group_message_id, user_id, read_at) VALUES (?, ?, ?)',
          [groupMessageId, userId, DateTime.now().toIso8601String()],
        );
      } else {
        // 移动端使用原有方式
        final db = await database;
        await _executeInsert('group_message_reads', {
          'group_message_id': groupMessageId,
          'user_id': userId,
          'read_at': DateTime.now().toIso8601String(),
        });
      }
      logger.debug('标记群聊消息已读: MessageID=$groupMessageId, UserID=$userId');
    } catch (e) {
      logger.debug('标记群聊消息已读失败: $e');
      rethrow;
    }
  }

  /// 🔴 通过服务器ID记录群聊消息已读
  Future<void> markGroupMessageAsReadByServerId(int serverId, int userId) async {
    try {
      // 先通过server_id查找本地消息ID
      final results = await _executeRawQuery(
        'SELECT id FROM group_messages WHERE server_id = ?',
        [serverId],
      );
      
      if (results.isEmpty) {
        logger.debug('未找到server_id=$serverId的群聊消息，跳过标记已读');
        return;
      }
      
      final localId = results.first['id'] as int;
      
      // 使用本地ID标记已读
      if (_isDesktopPlatform) {
        await _executeRawQuery(
          'INSERT OR REPLACE INTO group_message_reads (group_message_id, user_id, read_at) VALUES (?, ?, ?)',
          [localId, userId, DateTime.now().toIso8601String()],
        );
      } else {
        await _executeInsert('group_message_reads', {
          'group_message_id': localId,
          'user_id': userId,
          'read_at': DateTime.now().toIso8601String(),
        });
      }
      logger.debug('通过server_id标记群聊消息已读: serverId=$serverId, localId=$localId, userId=$userId');
    } catch (e) {
      logger.debug('通过server_id标记群聊消息已读失败: $e');
      rethrow;
    }
  }

  /// 批量标记群组消息为已读
  Future<void> markGroupMessagesAsRead(int groupId, int userId) async {
    try {
      // 获取该群组中当前用户未读的所有消息ID
      final results = await _executeRawQuery(
        '''
        SELECT gm.id FROM group_messages gm
        WHERE gm.group_id = ?
          AND gm.sender_id != ?
          AND (gm.status IS NULL OR gm.status = '' OR gm.status != 'recalled')
          AND (gm.deleted_by_users IS NULL OR gm.deleted_by_users NOT LIKE '%' || ? || '%')
          AND NOT EXISTS (
            SELECT 1 FROM group_message_reads gmr
            WHERE gmr.group_message_id = gm.id AND gmr.user_id = ?
          )
      ''',
        [groupId, userId, userId.toString(), userId],
      );

      if (results.isEmpty) {
        logger.debug('群组 $groupId 没有未读消息需要标记');
        return;
      }

      // 批量插入已读记录
      final now = DateTime.now().toIso8601String();
      if (_isDesktopPlatform) {
        // 桌面端使用批处理
        for (var row in results) {
          final messageId = row['id'] as int;
          await _executeRawQuery(
            'INSERT OR REPLACE INTO group_message_reads (group_message_id, user_id, read_at) VALUES (?, ?, ?)',
            [messageId, userId, now],
          );
        }
      } else {
        // 移动端使用批量插入
        final db = await database;
        final batch = db.batch();
        for (var row in results) {
          final messageId = row['id'] as int;
          batch.insert(
            'group_message_reads',
            {
              'group_message_id': messageId,
              'user_id': userId,
              'read_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }

      logger.debug('批量标记群组 $groupId 的 ${results.length} 条消息为已读');
    } catch (e) {
      logger.debug('批量标记群组消息已读失败: $e');
      rethrow;
    }
  }

  /// 获取群聊消息已读状态
  Future<List<Map<String, dynamic>>> getGroupMessageReads(
    int groupMessageId,
  ) async {
    try {
      final results = await _executeQuery(
        'group_message_reads',
        where: 'group_message_id = ?',
        whereArgs: [groupMessageId],
      );
      return results;
    } catch (e) {
      logger.debug('获取群聊消息已读状态失败: $e');
      rethrow;
    }
  }

  /// 获取未读消息数量（私聊）
  Future<int> getUnreadMessageCount(int receiverId) async {
    try {
      final results = await _executeRawQuery(
        '''
        SELECT COUNT(*) as count FROM messages
        WHERE receiver_id = ? AND is_read = 0 AND status = 'normal'
      ''',
        [receiverId],
      );

      if (_isDesktopPlatform) {
        return _desktopProvider!.firstIntValue(results) ?? 0;
      } else {
        return Sqflite.firstIntValue(results) ?? 0;
      }
    } catch (e) {
      logger.debug('获取未读消息数量失败: $e');
      rethrow;
    }
  }

  /// 获取来自特定联系人的未读消息数量（私聊）
  Future<int> getUnreadMessageCountFromContact(int receiverId, int senderId) async {
    try {
      final results = await _executeRawQuery(
        '''
        SELECT COUNT(*) as count FROM messages
        WHERE receiver_id = ? 
          AND sender_id = ? 
          AND is_read = 0 
          AND (status IS NULL OR status = '' OR status = 'normal')
          AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE '%' || ? || '%')
      ''',
        [receiverId, senderId, receiverId.toString()],
      );

      if (_isDesktopPlatform) {
        return _desktopProvider!.firstIntValue(results) ?? 0;
      } else {
        return Sqflite.firstIntValue(results) ?? 0;
      }
    } catch (e) {
      logger.debug('获取来自特定联系人的未读消息数量失败: $e');
      rethrow;
    }
  }

  /// 获取群组未读消息数量
  Future<int> getGroupUnreadMessageCount(int groupId, int userId) async {
    try {
      final results = await _executeRawQuery(
        '''
        SELECT COUNT(*) as count FROM group_messages gm
        WHERE gm.group_id = ? 
          AND gm.sender_id != ?
          AND (gm.status IS NULL OR gm.status = '' OR gm.status = 'normal')
          AND (gm.deleted_by_users IS NULL OR gm.deleted_by_users NOT LIKE '%' || ? || '%')
          AND NOT EXISTS (
            SELECT 1 FROM group_message_reads gmr
            WHERE gmr.group_message_id = gm.id AND gmr.user_id = ?
          )
      ''',
        [groupId, userId, userId.toString(), userId],
      );

      if (_isDesktopPlatform) {
        return _desktopProvider!.firstIntValue(results) ?? 0;
      } else {
        return Sqflite.firstIntValue(results) ?? 0;
      }
    } catch (e) {
      logger.debug('获取群组未读消息数量失败: $e');
      rethrow;
    }
  }

  /// 批量标记消息为已读（私聊）
  Future<void> markMessagesAsRead(int senderId, int receiverId) async {
    try {
      logger.debug('🔍 [markMessagesAsRead] 开始标记消息为已读 - senderId: $senderId, receiverId: $receiverId');
      
      // 先查询需要标记为已读的消息数量
      final countResults = await _executeRawQuery(
        '''
        SELECT COUNT(*) as count FROM messages
        WHERE sender_id = ? 
          AND receiver_id = ? 
          AND is_read = 0
          AND (status IS NULL OR status = '' OR status != 'recalled')
          AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE '%' || ? || '%')
      ''',
        [senderId, receiverId, receiverId.toString()],
      );

      final count = _isDesktopPlatform
          ? _desktopProvider!.firstIntValue(countResults) ?? 0
          : Sqflite.firstIntValue(countResults) ?? 0;

      logger.debug('🔍 [markMessagesAsRead] 查询到 $count 条未读消息需要标记');

      if (count == 0) {
        logger.debug('🔍 [markMessagesAsRead] 发送者 $senderId 没有未读消息需要标记，跳过');
        return;
      }

      // 🔴 修复：使用正确的方法执行UPDATE语句
      final updateCount = await _executeUpdate(
        'messages',
        {
          'is_read': 1,
          'read_at': DateTime.now().toIso8601String(),
        },
        where: '''sender_id = ? 
          AND receiver_id = ? 
          AND is_read = 0
          AND (status IS NULL OR status = '' OR status != 'recalled')
          AND (deleted_by_users IS NULL OR deleted_by_users NOT LIKE '%' || ? || '%')''',
        whereArgs: [senderId, receiverId, receiverId.toString()],
      );
      logger.debug('✅ [markMessagesAsRead] 批量标记 $updateCount 条私聊消息为已读 (senderId: $senderId, receiverId: $receiverId)');
      
      // 🔴 验证：查询更新后的未读消息数量
      final verifyResults = await _executeRawQuery(
        'SELECT COUNT(*) as count FROM messages WHERE sender_id = ? AND receiver_id = ? AND is_read = 0',
        [senderId, receiverId],
      );
      final remainingUnread = _isDesktopPlatform
          ? _desktopProvider!.firstIntValue(verifyResults) ?? 0
          : Sqflite.firstIntValue(verifyResults) ?? 0;
      logger.debug('🔍 [markMessagesAsRead] 验证：更新后剩余 $remainingUnread 条未读消息');
    } catch (e) {
      logger.debug('❌ [markMessagesAsRead] 批量标记消息为已读失败: $e');
      rethrow;
    }
  }

  // ============ 收藏消息操作 ============

  /// 添加收藏消息
  Future<int> insertFavorite(Map<String, dynamic> favorite) async {
    try {
      final id = await _executeInsert('favorites', favorite);
      logger.debug('添加收藏消息成功: ID=$id');
      return id;
    } catch (e) {
      logger.debug('添加收藏消息失败: $e');
      rethrow;
    }
  }

  /// 获取用户的收藏列表
  Future<List<Map<String, dynamic>>> getFavorites({
    required int userId,
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      final results = await _executeQuery(
        'favorites',
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'created_at DESC',
        limit: limit,
        offset: offset,
      );
      logger.debug('获取收藏列表: ${results.length}条');
      return results;
    } catch (e) {
      logger.debug('获取收藏列表失败: $e');
      rethrow;
    }
  }

  /// 删除收藏消息
  Future<void> deleteFavorite(int id, int userId) async {
    try {
      await _executeDelete(
        'favorites',
        where: 'id = ? AND user_id = ?',
        whereArgs: [id, userId],
      );
      logger.debug('删除收藏消息: ID=$id');
    } catch (e) {
      logger.debug('删除收藏消息失败: $e');
      rethrow;
    }
  }

  /// 检查消息是否已被收藏
  Future<Map<String, dynamic>?> checkFavoriteExists({
    required int userId,
    int? messageId,
    String? content,
    int? senderId,
  }) async {
    try {
      List<Map<String, dynamic>> results;
      if (messageId != null) {
        // 私聊消息通过messageId查询
        results = await _executeQuery(
          'favorites',
          where: 'user_id = ? AND message_id = ?',
          whereArgs: [userId, messageId],
          limit: 1,
        );
      } else if (content != null && senderId != null) {
        // 群聊消息通过内容和发送者查询
        results = await _executeQuery(
          'favorites',
          where: 'user_id = ? AND message_id IS NULL AND content = ? AND sender_id = ?',
          whereArgs: [userId, content, senderId],
          limit: 1,
        );
      } else {
        return null;
      }
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      logger.debug('检查收藏是否存在失败: $e');
      rethrow;
    }
  }

  /// 根据ID获取收藏信息
  Future<Map<String, dynamic>?> getFavoriteById(int id, int userId) async {
    try {
      final results = await _executeQuery(
        'favorites',
        where: 'id = ? AND user_id = ?',
        whereArgs: [id, userId],
        limit: 1,
      );
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      logger.debug('获取收藏信息失败: $e');
      rethrow;
    }
  }

  /// 更新收藏的服务器信息（server_id和sync_status）
  Future<void> updateFavoriteServerInfo({
    required int localId,
    required int serverId,
    required String syncStatus,
  }) async {
    try {
      await _executeUpdate(
        'favorites',
        {
          'server_id': serverId,
          'sync_status': syncStatus,
        },
        where: 'id = ?',
        whereArgs: [localId],
      );
      logger.debug('更新收藏服务器信息: localId=$localId, serverId=$serverId');
    } catch (e) {
      logger.debug('更新收藏服务器信息失败: $e');
      rethrow;
    }
  }

  /// 获取待同步的收藏列表（sync_status = 'pending'）
  Future<List<Map<String, dynamic>>> getPendingFavorites(int userId) async {
    try {
      final results = await _executeQuery(
        'favorites',
        where: 'user_id = ? AND sync_status = ?',
        whereArgs: [userId, 'pending'],
        orderBy: 'created_at ASC',
      );
      logger.debug('获取待同步收藏: ${results.length}条');
      return results;
    } catch (e) {
      logger.debug('获取待同步收藏失败: $e');
      rethrow;
    }
  }

  /// 根据server_id检查收藏是否存在
  Future<bool> checkFavoriteExistsByServerId(int userId, int serverId) async {
    try {
      final results = await _executeQuery(
        'favorites',
        where: 'user_id = ? AND server_id = ?',
        whereArgs: [userId, serverId],
        limit: 1,
      );
      return results.isNotEmpty;
    } catch (e) {
      logger.debug('检查收藏是否存在失败: $e');
      rethrow;
    }
  }

  // ============ 常用联系人操作 ============

  /// 添加常用联系人
  Future<void> addFavoriteContact(int userId, int contactId) async {
    try {
      await _executeInsert(
        'favorite_contacts',
        {
          'user_id': userId,
          'contact_id': contactId,
          'created_at': DateTime.now().toIso8601String(),
        },
      );
      logger.debug('添加常用联系人: UserID=$userId, ContactID=$contactId');
    } catch (e) {
      logger.debug('添加常用联系人失败: $e');
      rethrow;
    }
  }

  /// 移除常用联系人
  Future<void> removeFavoriteContact(int userId, int contactId) async {
    try {
      await _executeDelete(
        'favorite_contacts',
        where: 'user_id = ? AND contact_id = ?',
        whereArgs: [userId, contactId],
      );
      logger.debug('移除常用联系人: UserID=$userId, ContactID=$contactId');
    } catch (e) {
      logger.debug('移除常用联系人失败: $e');
      rethrow;
    }
  }

  /// 获取常用联系人列表
  Future<List<Map<String, dynamic>>> getFavoriteContacts(int userId) async {
    try {
      final results = await _executeQuery(
        'favorite_contacts',
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'created_at DESC',
      );
      logger.debug('获取常用联系人: ${results.length}个');
      return results;
    } catch (e) {
      logger.debug('获取常用联系人失败: $e');
      rethrow;
    }
  }

  /// 检查是否为常用联系人
  Future<bool> isFavoriteContact(int userId, int contactId) async {
    try {
      final results = await _executeQuery(
        'favorite_contacts',
        where: 'user_id = ? AND contact_id = ?',
        whereArgs: [userId, contactId],
        limit: 1,
      );
      return results.isNotEmpty;
    } catch (e) {
      logger.debug('检查常用联系人失败: $e');
      rethrow;
    }
  }

  // ============ 群组成员操作 ============

  /// 同步群组成员到本地数据库（从服务器API获取后调用）
  Future<void> syncGroupMembers(int groupId, List<Map<String, dynamic>> members) async {
    try {
      // 先删除该群组的所有旧成员记录
      await _executeDelete(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );

      // 插入新的成员记录
      for (final member in members) {
        await _executeInsert(
          'group_members',
          {
            'group_id': groupId,
            'user_id': member['user_id'] ?? member['id'],
            'role': member['role'] ?? 'member',
            'joined_at': member['joined_at'] ?? DateTime.now().toIso8601String(),
          },
        );
      }
      
      logger.debug('✅ 群组成员已同步到本地: GroupID=$groupId, 成员数=${members.length}');
    } catch (e) {
      logger.debug('❌ 同步群组成员失败: $e');
      rethrow;
    }
  }

  /// 添加群组成员（如果已存在则忽略）
  Future<void> addGroupMember(int groupId, int userId, {String role = 'member'}) async {
    try {
      // 先检查是否已存在
      final existing = await _executeQuery(
        'group_members',
        where: 'group_id = ? AND user_id = ?',
        whereArgs: [groupId, userId],
        limit: 1,
      );
      
      if (existing.isEmpty) {
        await _executeInsert(
          'group_members',
          {
            'group_id': groupId,
            'user_id': userId,
            'role': role,
            'joined_at': DateTime.now().toIso8601String(),
          },
        );
      }
    } catch (e) {
      logger.debug('❌ 添加群组成员失败: $e');
      rethrow;
    }
  }

  /// 移除群组成员
  Future<void> removeGroupMember(int groupId, int userId) async {
    try {
      await _executeDelete(
        'group_members',
        where: 'group_id = ? AND user_id = ?',
        whereArgs: [groupId, userId],
      );
      logger.debug('✅ 移除群组成员: GroupID=$groupId, UserID=$userId');
    } catch (e) {
      logger.debug('❌ 移除群组成员失败: $e');
      rethrow;
    }
  }

  // ============ 常用群组操作 ============

  /// 添加常用群组
  Future<void> addFavoriteGroup(int userId, int groupId) async {
    try {
      await _executeInsert(
        'favorite_groups',
        {
          'user_id': userId,
          'group_id': groupId,
          'created_at': DateTime.now().toIso8601String(),
        },
      );
      logger.debug('添加常用群组: UserID=$userId, GroupID=$groupId');
    } catch (e) {
      logger.debug('添加常用群组失败: $e');
      rethrow;
    }
  }

  /// 移除常用群组
  Future<void> removeFavoriteGroup(int userId, int groupId) async {
    try {
      await _executeDelete(
        'favorite_groups',
        where: 'user_id = ? AND group_id = ?',
        whereArgs: [userId, groupId],
      );
      logger.debug('移除常用群组: UserID=$userId, GroupID=$groupId');
    } catch (e) {
      logger.debug('移除常用群组失败: $e');
      rethrow;
    }
  }

  /// 获取常用群组列表
  Future<List<Map<String, dynamic>>> getFavoriteGroups(int userId) async {
    try {
      final results = await _executeQuery(
        'favorite_groups',
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'created_at DESC',
      );
      logger.debug('获取常用群组: ${results.length}个');
      return results;
    } catch (e) {
      logger.debug('获取常用群组失败: $e');
      rethrow;
    }
  }

  /// 检查是否为常用群组
  Future<bool> isFavoriteGroup(int userId, int groupId) async {
    try {
      final results = await _executeQuery(
        'favorite_groups',
        where: 'user_id = ? AND group_id = ?',
        whereArgs: [userId, groupId],
        limit: 1,
      );
      return results.isNotEmpty;
    } catch (e) {
      logger.debug('检查常用群组失败: $e');
      rethrow;
    }
  }

  // ============ 文件助手消息操作 ============

  /// 插入文件助手消息
  Future<int> insertFileAssistantMessage(Map<String, dynamic> message) async {
    try {
      final id = await _executeInsert('file_assistant_messages', message);
      logger.debug('插入文件助手消息成功: ID=$id');
      return id;
    } catch (e) {
      logger.debug('插入文件助手消息失败: $e');
      rethrow;
    }
  }

  /// 获取文件助手消息列表
  Future<List<Map<String, dynamic>>> getFileAssistantMessages({
    required int userId,
    int limit = 100,
  }) async {
    try {
      final results = await _executeQuery(
        'file_assistant_messages',
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'id ASC',
        limit: limit,
      );
      logger.debug('获取文件助手消息: ${results.length}条');
      return results;
    } catch (e) {
      logger.debug('获取文件助手消息失败: $e');
      rethrow;
    }
  }

  /// 撤回文件助手消息
  Future<void> recallFileAssistantMessage(int messageId) async {
    try {
      await _executeUpdate(
        'file_assistant_messages',
        {'status': 'recalled'},
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('撤回文件助手消息: ID=$messageId');
    } catch (e) {
      logger.debug('撤回文件助手消息失败: $e');
      rethrow;
    }
  }

  /// 删除文件助手消息
  Future<void> deleteFileAssistantMessage(int messageId) async {
    try {
      await _executeDelete(
        'file_assistant_messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );
      logger.debug('删除文件助手消息: ID=$messageId');
    } catch (e) {
      logger.debug('删除文件助手消息失败: $e');
      rethrow;
    }
  }

  // ============ 联系人快照缓存 ============

  /// 获取联系人或群组的缓存信息
  Future<Map<String, dynamic>?> getContactSnapshot({
    required int ownerId,
    required int contactId,
    required String contactType,
  }) async {
    try {
      final results = await _executeQuery(
        'contact_snapshots',
        where: 'owner_id = ? AND contact_id = ? AND contact_type = ?',
        whereArgs: [ownerId, contactId, contactType],
        limit: 1,
      );
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      logger.debug('获取联系人快照失败: $e');
      rethrow;
    }
  }

  /// 批量获取联系人快照
  Future<List<Map<String, dynamic>>> getContactSnapshots(
    int ownerId, {
    String? contactType,
  }) async {
    try {
      return await _executeQuery(
        'contact_snapshots',
        where: contactType != null ? 'owner_id = ? AND contact_type = ?' : 'owner_id = ?',
        whereArgs: contactType != null ? [ownerId, contactType] : [ownerId],
        orderBy: 'updated_at DESC',
      );
    } catch (e) {
      logger.debug('批量获取联系人快照失败: $e');
      rethrow;
    }
  }

  /// 写入或更新联系人快照
  Future<void> upsertContactSnapshot({
    required int ownerId,
    required int contactId,
    required String contactType,
    String? username,
    String? fullName,
    String? avatar,
    String? remark,
    String? metadata,
  }) async {
    try {
      final normalizedType = contactType.toLowerCase();
      final existing = await _executeQuery(
        'contact_snapshots',
        where: 'owner_id = ? AND contact_id = ? AND contact_type = ?',
        whereArgs: [ownerId, contactId, normalizedType],
        limit: 1,
      );

      final now = DateTime.now().toIso8601String();
      final payload = <String, dynamic>{
        'owner_id': ownerId,
        'contact_id': contactId,
        'contact_type': normalizedType,
        'username': username,
        'full_name': fullName,
        'avatar': avatar,
        'remark': remark,
        'metadata': metadata,
        'updated_at': now,
      };

      if (existing.isEmpty) {
        payload['created_at'] = now;
        await _executeInsert('contact_snapshots', payload);
      } else {
        await _executeUpdate(
          'contact_snapshots',
          payload,
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
      }
    } catch (e) {
      logger.debug('写入联系人快照失败: $e');
      rethrow;
    }
  }

  /// 批量写入联系人快照
  Future<void> upsertContactSnapshots({
    required int ownerId,
    required List<Map<String, dynamic>> snapshots,
    String contactType = 'user',
  }) async {
    if (snapshots.isEmpty) return;
    for (final snapshot in snapshots) {
      final snapshotContactId = snapshot['contact_id'];
      final parsedContactId = snapshotContactId is int
          ? snapshotContactId
          : int.tryParse(snapshotContactId == null ? '' : snapshotContactId.toString());
      if (parsedContactId == null) {
        continue;
      }
      await upsertContactSnapshot(
        ownerId: ownerId,
        contactId: parsedContactId,
        contactType: snapshot['contact_type']?.toString() ?? contactType,
        username: snapshot['username'] as String?,
        fullName: snapshot['full_name'] as String?,
        avatar: snapshot['avatar'] as String?,
        remark: snapshot['remark'] as String?,
        metadata: snapshot['metadata']?.toString(),
      );
    }
  }

  /// 清空指定用户的联系人快照
  Future<void> clearContactSnapshots(int ownerId) async {
    try {
      await _executeDelete(
        'contact_snapshots',
        where: 'owner_id = ?',
        whereArgs: [ownerId],
      );
    } catch (e) {
      logger.debug('清空联系人快照失败: $e');
      rethrow;
    }
  }

  /// 清空数据库（用于退出登录等场景）
  Future<void> clearAllData() async {
    try {
      await _executeDelete('messages');
      await _executeDelete('group_messages');
      await _executeDelete('group_message_reads');
      await _executeDelete('favorites');
      await _executeDelete('favorite_contacts');
      await _executeDelete('favorite_groups');
      await _executeDelete('file_assistant_messages');
      await _executeDelete('contact_snapshots');
      logger.debug('清空数据库成功');
    } catch (e) {
      logger.debug('清空数据库失败: $e');
      rethrow;
    }
  }

  /// 关闭数据库
  Future<void> close() async {
    try {
      if (_mobileProvider != null) {
        await _mobileProvider!.closeAsync();
        _mobileProvider = null;
      }
      if (_desktopProvider != null) {
        _desktopProvider!.close();
        _desktopProvider = null;
      }
      if (_database != null) {
        if (_isDesktopPlatform && _sqlite3Db != null) {
          _sqlite3Db!.dispose();
          _sqlite3Db = null;
        } else if (!_isDesktopPlatform) {
          await (_database as Database).close();
        }
        _database = null;
      }
      logger.debug('数据库已关闭');
    } catch (e) {
      logger.debug('关闭数据库失败: $e');
      rethrow;
    }
  }

  /// 获取数据库密钥
  /// 返回: Map包含'uuid'和'key'
  Future<Map<String, String>> getDatabaseKey() async {
    final databaseUUID = await _getOrCreateUuid();
    return _generateDatabaseKey(databaseUUID);
  }
}

// ============ 系统版本管理扩展 ============

/// 系统版本管理扩展
extension SystemVersionExtension on LocalDatabaseService {
  /// 确保系统版本表存在（用于数据库升级场景）
  Future<void> ensureSystemVersionTable() async {
    try {
      if (_isDesktopPlatform) {
        _desktopProvider?.execute('''
          CREATE TABLE IF NOT EXISTS system_version (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version VARCHAR(50) NOT NULL,
            version_code VARCHAR(50),
            file_size INTEGER DEFAULT 0,
            release_notes TEXT,
            release_date TEXT,
            platform VARCHAR(20) NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
          )
        ''');
      } else {
        final db = await database;
        await db.execute('''
          CREATE TABLE IF NOT EXISTS system_version (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version VARCHAR(50) NOT NULL,
            version_code VARCHAR(50),
            file_size INTEGER DEFAULT 0,
            release_notes TEXT,
            release_date TEXT,
            platform VARCHAR(20) NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
          )
        ''');
      }
      logger.debug('✅ 系统版本表已确保存在');
    } catch (e) {
      logger.error('❌ 确保系统版本表存在失败: $e');
    }
  }

  /// 获取当前存储的版本信息
  Future<Map<String, dynamic>?> getStoredVersion(String platform) async {
    try {
      await ensureSystemVersionTable();
      final results = await _executeQuery(
        'system_version',
        where: 'platform = ?',
        whereArgs: [platform],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (results.isNotEmpty) {
        logger.debug('📦 [版本查询] 本地版本: ${results.first['version']}');
        return results.first;
      }
      logger.debug('📦 [版本查询] 本地无版本记录');
      return null;
    } catch (e) {
      logger.error('❌ 获取本地版本信息失败: $e');
      return null;
    }
  }

  /// 保存版本信息（升级成功后调用）
  Future<void> saveVersion({
    required String version,
    String? versionCode,
    int fileSize = 0,
    String? releaseNotes,
    String? releaseDate,
    required String platform,
  }) async {
    try {
      await ensureSystemVersionTable();
      
      // 先删除该平台的旧版本记录
      await _executeDelete(
        'system_version',
        where: 'platform = ?',
        whereArgs: [platform],
      );
      
      // 插入新版本记录
      await _executeInsert('system_version', {
        'version': version,
        'version_code': versionCode ?? version,
        'file_size': fileSize,
        'release_notes': releaseNotes ?? '',
        'release_date': releaseDate ?? DateTime.now().toIso8601String(),
        'platform': platform,
        'updated_at': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });
      
      logger.info('✅ [版本保存] 已保存版本信息: $version ($platform)');
    } catch (e) {
      logger.error('❌ 保存版本信息失败: $e');
      rethrow;
    }
  }

  /// 检查是否需要更新（比较本地版本和服务器版本）
  Future<bool> needsUpdate(String serverVersion, String platform) async {
    try {
      final localVersion = await getStoredVersion(platform);
      if (localVersion == null) {
        logger.info('📦 [版本比较] 本地无版本记录，需要更新');
        return true;
      }
      
      final localVer = localVersion['version'] as String;
      final needUpdate = _compareVersionsStatic(serverVersion, localVer) > 0;
      
      logger.info('📦 [版本比较] 本地: $localVer, 服务器: $serverVersion, 需要更新: $needUpdate');
      return needUpdate;
    } catch (e) {
      logger.error('❌ 版本比较失败: $e');
      return true; // 出错时默认需要更新
    }
  }

  /// 比较版本号（语义化版本）
  /// 返回: >0 表示v1更新, <0 表示v2更新, =0 表示相同
  static int _compareVersionsStatic(String v1, String v2) {
    // 去掉版本号中的 build number 部分（-后面的内容）
    final v1Clean = v1.split('-')[0];
    final v2Clean = v2.split('-')[0];
    
    final parts1 = v1Clean.split('.');
    final parts2 = v2Clean.split('.');
    
    final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;
    
    for (var i = 0; i < maxLen; i++) {
      final num1 = i < parts1.length ? int.tryParse(parts1[i]) ?? 0 : 0;
      final num2 = i < parts2.length ? int.tryParse(parts2[i]) ?? 0 : 0;
      
      if (num1 > num2) return 1;
      if (num1 < num2) return -1;
    }
    return 0;
  }
}
