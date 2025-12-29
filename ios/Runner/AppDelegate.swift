import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        let controller = window?.rootViewController as! FlutterViewController
        
        // 设置 Method Channel 用于排除 iCloud 备份
        let backupChannel = FlutterMethodChannel(name: "com.youdu.app/backup", binaryMessenger: controller.binaryMessenger)
        
        backupChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
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
        
        // 🔴 请求通知权限
        requestNotificationPermission()
        
        // 🔴 设置通知代理
        UNUserNotificationCenter.current().delegate = self
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    /// 请求通知权限
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("📱 [iOS] ✅ 通知权限已授予")
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                print("📱 [iOS] ❌ 通知权限被拒绝: \(error?.localizedDescription ?? "未知错误")")
            }
        }
    }
    
    // MARK: - 远程通知处理
    
    /// 注册远程通知成功
    override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 [iOS] ✅ 远程通知注册成功，Device Token: \(tokenString)")
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }
    
    /// 注册远程通知失败
    override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("📱 [iOS] ❌ 远程通知注册失败: \(error.localizedDescription)")
        super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }
    
    /// 收到远程通知（后台）
    override func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📱 [iOS] ========== 收到远程通知 ==========")
        print("📱 [iOS] userInfo: \(userInfo)")
        print("📱 [iOS] 应用状态: \(application.applicationState.rawValue)")
        print("📱 [iOS] ================================")
        
        // 如果应用在后台，显示本地通知
        if application.applicationState == .background {
            showLocalNotification(userInfo: userInfo)
        }
        
        super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
    }
    
    /// 显示本地通知（用于后台时显示系统弹窗）
    /// 🔴 点击通知后打开应用
    private func showLocalNotification(userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        
        // 解析推送内容
        if let aps = userInfo["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                content.title = alert["title"] as? String ?? "新消息"
                content.body = alert["body"] as? String ?? ""
            } else if let alert = aps["alert"] as? String {
                content.title = "新消息"
                content.body = alert
            }
            
            if let badge = aps["badge"] as? Int {
                content.badge = NSNumber(value: badge)
            }
            
            if let sound = aps["sound"] as? String {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            } else {
                content.sound = .default
            }
        }
        
        // 添加自定义数据
        content.userInfo = userInfo
        
        // 创建触发器（立即触发）
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        // 创建请求
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        
        // 添加通知
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("📱 [iOS] ❌ 显示本地通知失败: \(error.localizedDescription)")
            } else {
                print("📱 [iOS] ✅ 本地通知已显示")
            }
        }
    }
    
    // MARK: - iCloud 备份排除
    
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

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate {
    
    /// 应用在前台时收到通知
    override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("📱 [iOS] 前台收到通知: \(notification.request.content.title)")
        
        // 在前台也显示通知横幅
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    
    /// 用户点击通知 - 打开应用
    override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        print("📱 [iOS] 用户点击通知: \(response.notification.request.content.title)")
        print("📱 [iOS] 通知数据: \(response.notification.request.content.userInfo)")
        
        // 🔴 点击通知后应用会自动打开（由系统处理）
        
        completionHandler()
    }
}
