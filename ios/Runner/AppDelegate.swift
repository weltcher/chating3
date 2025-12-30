import Flutter
import UIKit
import UserNotifications
import PushKit
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    // 消息通道
    private var messageChannel: FlutterMethodChannel?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        let controller = window?.rootViewController as! FlutterViewController
        
        // 🔴 初始化 CallKit 和 VoIP Push（用于后台来电）
        CallKitManager.shared.initialize(with: controller.binaryMessenger)
        
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
        
        // 🔴 设置消息弹窗 Method Channel
        messageChannel = FlutterMethodChannel(name: "com.example.youdu/message", binaryMessenger: controller.binaryMessenger)
        
        messageChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "showMessageOverlay":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing arguments", details: nil))
                    return
                }
                self?.showMessageNotification(args: args)
                result(true)
                
            case "dismissMessageOverlay":
                // iOS 不需要手动关闭，通知会自动消失
                result(true)
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        // 🔴 请求通知权限
        requestNotificationPermission()
        
        // 🔴 设置通知代理
        UNUserNotificationCenter.current().delegate = self
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    /// 显示消息通知（后台时显示系统横幅通知）
    private func showMessageNotification(args: [String: Any]) {
        let senderName = args["senderName"] as? String ?? "未知用户"
        let senderId = args["senderId"] as? Int ?? 0
        let content = args["content"] as? String ?? ""
        let messageType = args["messageType"] as? String ?? "text"
        let isGroupMessage = args["isGroupMessage"] as? Bool ?? false
        let groupId = args["groupId"] as? Int
        let groupName = args["groupName"] as? String
        
        print("📱 [iOS] 显示消息通知: \(senderName) - \(content)")
        
        let notificationContent = UNMutableNotificationContent()
        
        // 设置标题
        if isGroupMessage, let gName = groupName {
            notificationContent.title = "\(senderName) (\(gName))"
        } else {
            notificationContent.title = senderName
        }
        
        // 设置内容
        notificationContent.body = formatMessageContent(messageType: messageType, content: content)
        notificationContent.sound = .default
        
        // 添加自定义数据（用于点击通知后导航）
        var userInfo: [String: Any] = [
            "senderId": senderId,
            "senderName": senderName,
            "isGroupMessage": isGroupMessage
        ]
        if let gId = groupId {
            userInfo["groupId"] = gId
        }
        if let gName = groupName {
            userInfo["groupName"] = gName
        }
        notificationContent.userInfo = userInfo
        
        // 创建触发器（立即触发）
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        // 使用发送者ID作为通知标识符，同一个人的消息会更新
        let identifier = isGroupMessage ? "group_\(groupId ?? 0)" : "private_\(senderId)"
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: notificationContent,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("📱 [iOS] ❌ 显示消息通知失败: \(error.localizedDescription)")
            } else {
                print("📱 [iOS] ✅ 消息通知已显示")
            }
        }
    }
    
    /// 格式化消息内容
    private func formatMessageContent(messageType: String, content: String) -> String {
        switch messageType {
        case "image":
            return "[图片]"
        case "file":
            return "[文件]"
        case "voice":
            return "[语音]"
        case "video":
            return "[视频]"
        case "location":
            return "[位置]"
        default:
            return content
        }
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
    
    /// 用户点击通知 - 打开应用并导航到聊天页面
    override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        print("📱 [iOS] 用户点击通知: \(response.notification.request.content.title)")
        print("📱 [iOS] 通知数据: \(response.notification.request.content.userInfo)")
        
        let userInfo = response.notification.request.content.userInfo
        
        // 🔴 检查是否是消息通知（包含 senderId）
        if let senderId = userInfo["senderId"] as? Int {
            let senderName = userInfo["senderName"] as? String ?? "未知用户"
            let isGroupMessage = userInfo["isGroupMessage"] as? Bool ?? false
            let groupId = userInfo["groupId"] as? Int
            let groupName = userInfo["groupName"] as? String
            
            // 构建消息数据
            var messageData: [String: Any] = [
                "senderId": senderId,
                "senderName": senderName,
                "isGroupMessage": isGroupMessage
            ]
            if let gId = groupId {
                messageData["groupId"] = gId
            }
            if let gName = groupName {
                messageData["groupName"] = gName
            }
            
            // 通知 Flutter 打开聊天页面
            print("📱 [iOS] 通知 Flutter 打开聊天页面: \(messageData)")
            messageChannel?.invokeMethod("onMessageTapped", arguments: messageData)
        }
        
        completionHandler()
    }
}
