import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // 设置 Method Channel 用于排除 iCloud 备份
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.youdu.app/backup", binaryMessenger: controller.binaryMessenger)
    
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "excludeFromBackup" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing path argument", details: nil))
          return
        }
        
        let success = self?.excludeFromiCloudBackup(path: path) ?? false
        result(success)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  /// 将文件排除出 iCloud 备份
  private func excludeFromiCloudBackup(path: String) -> Bool {
    var url = URL(fileURLWithPath: path)
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    
    do {
      try url.setResourceValues(resourceValues)
      print("✅ 已将文件排除出 iCloud 备份: \(path)")
      return true
    } catch {
      print("❌ 排除 iCloud 备份失败: \(error)")
      return false
    }
  }
}
