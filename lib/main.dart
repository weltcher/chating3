import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'utils/app_localizations.dart';
import 'utils/storage.dart';
import 'utils/logger.dart';
import 'services/local_database_service.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// HTTPS 证书信任配置（仅开发环境）
/// ⚠️ 生产环境绝不要使用此配置！
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        // 仅在开发环境信任自签名证书
        if (kDebugMode) {
          logger.debug('🔓 开发环境：信任自签名证书 - $host:$port');
          return true;
        }
        return false;
      };
  }
}

/// 检查并保存当前版本信息到数据库
/// 在应用启动时调用，确保数据库中有当前版本的记录
Future<void> _checkAndSaveVersion() async {
  try {
    final platform = Platform.operatingSystem;
    final packageInfo = await PackageInfo.fromPlatform();
    String version = packageInfo.version;
    String buildNumber = packageInfo.buildNumber;
    
    // 修复旧版本格式问题：如果 version 包含错误格式（如 1.0.41765520149）
    // 需要拆分成正确的 version 和 buildNumber
    if (version.contains(RegExp(r'\d+\.\d+\.\d+\d{10}'))) {
      // 匹配类似 1.0.41765520149 的格式
      final match = RegExp(r'^(\d+\.\d+\.\d+)(\d{10})$').firstMatch(version);
      if (match != null) {
        version = match.group(1)!; // 1.0.4
        buildNumber = match.group(2)!; // 1765520149
        logger.info('🔧 [版本检查] 修复版本格式: ${packageInfo.version} -> $version + $buildNumber');
      }
    }
    
    logger.info('📱 [版本检查] 当前应用版本: $version (build: $buildNumber)');
    
    // 从数据库获取已保存的版本
    final dbService = LocalDatabaseService();
    final storedVersion = await dbService.getStoredVersion(platform);
    
    if (storedVersion == null) {
      // 数据库中没有版本记录，保存当前版本
      logger.info('💾 [版本检查] 数据库中无版本记录，保存当前版本');
      await dbService.saveVersion(
        version: version,
        versionCode: buildNumber,
        fileSize: 0,
        releaseNotes: '当前安装版本',
        releaseDate: DateTime.now().toIso8601String(),
        platform: platform,
      );
    } else {
      final storedVersionStr = storedVersion['version'] as String;
      final storedVersionCode = storedVersion['version_code'] as String? ?? storedVersionStr;
      
      // 比较版本号，如果不同则更新
      if (storedVersionStr != version || storedVersionCode != buildNumber) {
        logger.info('🔄 [版本检查] 检测到版本变化: $storedVersionStr ($storedVersionCode) -> $version ($buildNumber)');
        await dbService.saveVersion(
          version: version,
          versionCode: buildNumber,
          fileSize: 0,
          releaseNotes: '应用已更新',
          releaseDate: DateTime.now().toIso8601String(),
          platform: platform,
        );
      } else {
        logger.info('✅ [版本检查] 版本信息已是最新');
      }
    }
  } catch (e) {
    logger.error('❌ [版本检查] 检查并保存版本失败: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔒 配置 HTTPS 证书信任（仅开发环境）
  if (kDebugMode) {
    HttpOverrides.global = MyHttpOverrides();
  }

  // 初始化日志系统
  await logger.init();
  logger.info('========== 应用启动 ==========');
  logger.info('🆔 进程ID: $pid');

  // 初始化本地数据库
  try {
    final localDb = LocalDatabaseService();
    await localDb.database; // 触发数据库初始化
    logger.info('✅ 本地数据库初始化成功');
    
    // 检查并保存当前版本信息到数据库
    await _checkAndSaveVersion();
  } catch (e) {
    logger.info('❌ 本地数据库初始化失败: $e');
  }

  // 初始化通知服务（仅移动端）
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await NotificationService.instance.initialize();
      NotificationService.instance.startLifecycleObserver();
      logger.info('✅ 通知服务初始化成功');
    } catch (e) {
      logger.info('❌ 通知服务初始化失败: $e');
    }
  }

  // 初始化窗口管理器（仅限桌面平台）
  if (!Platform.isAndroid && !Platform.isIOS) {
    await windowManager.ensureInitialized();

    // 加载保存的窗口缩放设置
    final zoomFactor = await Storage.getWindowZoom();
    logger.debug('📐 加载窗口缩放设置: ${zoomFactor}x');

    // 设置窗口选项
    const baseWidth = 1280.0;
    const baseHeight = 900.0;
    final windowWidth = baseWidth * zoomFactor;
    final windowHeight = baseHeight * zoomFactor;

    WindowOptions windowOptions = WindowOptions(
      size: Size(windowWidth, windowHeight),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(const Size(800, 600));
      await windowManager.setSize(Size(windowWidth, windowHeight));
      await windowManager.setTitle('有度'); // 设置窗口标题
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      // 设置阻止窗口关闭，这样我们可以在onWindowClose中拦截关闭事件
      await windowManager.setPreventClose(true);
      logger.debug('✅ 窗口已显示，大小: $windowWidth x $windowHeight');
    });
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  /// 全局语言切换方法
  static void setLocale(BuildContext context, Locale newLocale) {
    final state = context.findAncestorStateOfType<_MyAppState>();
    state?.setLocale(newLocale);
  }
}

class _MyAppState extends State<MyApp> with WindowListener {
  Locale _locale = const Locale('zh', 'CN'); // 默认简体中文

  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.addListener(this);
    }
    _loadSavedLanguage();
  }

  @override
  void dispose() {
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // 🔴 修改：直接退出应用进程，不进行窗口管理
    // 注意：关闭应用弹窗时，不会清除任何本地配置（包括"记住密码"和"下次自动登录"）
    // 这些配置会保留，下次打开应用时会自动恢复
    logger.info('🚪 窗口关闭，立即退出应用进程');

    // 立即强制退出，不等待其他操作
    exit(0);
  }

  /// 加载保存的语言设置
  Future<void> _loadSavedLanguage() async {
    final languageCode = await Storage.getLanguage();
    final locale = AppLocalizations.getLocaleFromCode(languageCode);
    setState(() {
      _locale = locale;
    });
  }

  /// 设置新的语言
  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '有度',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90E2)),
        useMaterial3: true,
      ),
      locale: _locale,
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // 使用 onGenerateRoute 来动态决定初始路由
      onGenerateRoute: (settings) {
        // 如果是初始路由，需要检查登录状态和自动登录配置
        if (settings.name == '/' || settings.name == null) {
          return _generateInitialRoute();
        }
        // 其他路由
        switch (settings.name) {
          case '/login':
            return MaterialPageRoute(builder: (_) => const LoginPage());
          case '/home':
            return MaterialPageRoute(builder: (_) => const HomePage());
          default:
            return MaterialPageRoute(builder: (_) => const LoginPage());
        }
      },
      initialRoute: '/',
    );
  }

  /// 生成初始路由，检查登录状态和自动登录配置
  Route<dynamic> _generateInitialRoute() {
    return MaterialPageRoute(builder: (context) => _InitialRouteChecker());
  }
}

/// 初始路由检查器，用于检查登录状态和自动登录配置
class _InitialRouteChecker extends StatefulWidget {
  @override
  State<_InitialRouteChecker> createState() => _InitialRouteCheckerState();
}

class _InitialRouteCheckerState extends State<_InitialRouteChecker> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  /// 检查登录状态和自动登录配置
  Future<void> _checkLoginStatus() async {
    try {
      // 获取最近一次登录的用户ID
      final lastUserId = await Storage.getLastLoggedInUserId();
      
      logger.debug('🔍 应用启动检查：');
      logger.debug('   - 最近登录的用户ID: $lastUserId');

      if (lastUserId != null) {
        // 检查是否勾选了自动登录
        final autoLogin = await Storage.getAutoLogin(lastUserId);
        logger.debug('   - 自动登录配置: $autoLogin');

        if (autoLogin) {
          // 获取保存的账号密码
          final savedAccount = await Storage.getSavedAccountForLastUser();
          final savedPassword = await Storage.getSavedPasswordForLastUser();

          logger.debug('   - 保存的账号: ${savedAccount != null ? "存在" : "不存在"}');
          logger.debug('   - 保存的密码: ${savedPassword != null ? "存在" : "不存在"}');

          if (savedAccount != null && savedAccount.isNotEmpty &&
              savedPassword != null && savedPassword.isNotEmpty) {
            logger.debug('🚀 执行自动登录...');
            // 尝试自动登录
            final success = await _performAutoLogin(savedAccount, savedPassword);
            if (success) {
              return; // 自动登录成功，已跳转到主页
            }
          }
        }

        // 如果有保存的密码但没有勾选自动登录，跳转到登录页面（会自动填充账号密码）
        final savedPassword = await Storage.getSavedPasswordForLastUser();
        if (savedPassword != null && savedPassword.isNotEmpty) {
          logger.debug('📝 有保存的密码但未勾选自动登录，跳转到登录页面');
          if (mounted) {
            Navigator.of(context).pushReplacementNamed('/login');
          }
          return;
        }
      }

      // 否则，跳转到登录页面
      logger.debug('📝 没有保存的登录信息，跳转到登录页面');
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    } catch (e) {
      logger.debug('❌ 检查登录状态失败: $e');
      // 出错时，默认跳转到登录页面
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    }
  }

  /// 执行自动登录
  Future<bool> _performAutoLogin(String username, String password) async {
    try {
      final result = await ApiService.login(
        username: username,
        password: password,
      );

      if (result['code'] == 0) {
        // 登录成功
        final token = result['data']['token'];
        final user = result['data']['user'];

        // 保存token和用户信息
        await Storage.saveLoginInfo(
          token: token,
          userId: user['id'],
          username: user['username'],
          fullName: user['full_name'],
          avatar: user['avatar'],
        );

        // 重新初始化日志系统（使用用户ID）
        await logger.init(userId: user['id'].toString());
        logger.info('📝 日志系统已重新初始化，用户ID: ${user['id']}');
        logger.info('✅ 自动登录成功');

        // 获取上次保存的页面路径
        final lastRoute = await Storage.getLastPageRoute(user['id']);
        
        // 移动端始终跳转到/home，页面恢复由MobileHomePage自己处理
        // PC端可以跳转到具体的页面路径
        String targetRoute = '/home';
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          // PC端：使用保存的路由或默认主页
          targetRoute = lastRoute ?? '/home';
        } else {
          // 移动端：始终跳转到主页，由MobileHomePage恢复tab索引
          targetRoute = '/home';
          if (lastRoute != null) {
            logger.info('📍 移动端自动登录，将在主页恢复到: $lastRoute');
          }
        }
        
        logger.info('📍 自动登录后跳转到: $targetRoute');

        // 跳转到目标页面（上次保存的页面或主页）
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(targetRoute);
        }
        return true;
      } else {
        logger.debug('⚠️ 自动登录失败: ${result['message']}，跳转到登录页面');
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/login');
        }
        return false;
      }
    } catch (e) {
      logger.debug('❌ 自动登录异常: $e，跳转到登录页面');
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 显示加载界面
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
