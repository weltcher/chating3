import 'dart:io';

/// 应用版本配置类
class AppVersionConfig {
  /// iOS 全局版本字段（格式：主版本号+buildNumber，例如：1.0.5+6）
  /// 登录时检测本地版本时，iOS 直接使用此字段
  /// 🔥 注意：每次发布新版本时，需要手动更新此字段以匹配 pubspec.yaml
  static const String iosVersion = '1.0.5+6';
  
  /// 获取 iOS 版本信息
  /// 返回格式：{'version': '1.0.4', 'versionCode': '1'}
  static Map<String, String>? getIOSVersion() {
    if (!Platform.isIOS) {
      return null;
    }
    
    try {
      final parts = iosVersion.split('+');
      if (parts.isEmpty || parts[0].isEmpty) {
        return null;
      }
      
      final version = parts[0].trim().replaceAll('v', '');
      final buildNumber = parts.length > 1 && parts[1].isNotEmpty 
          ? parts[1].trim() 
          : '1';
      
      return {
        'version': version,
        'versionCode': buildNumber,
      };
    } catch (e) {
      return null;
    }
  }
  
  /// 获取完整版本号（格式：1.0.5+6）
  static String? getIOSFullVersion() {
    if (!Platform.isIOS) {
      return null;
    }
    return iosVersion;
  }
}
