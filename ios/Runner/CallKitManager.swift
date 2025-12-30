import Foundation
import CallKit
import AVFoundation
import Flutter

/// CallKit 管理器
/// 用于在 iOS 锁屏/后台状态下显示系统来电界面
class CallKitManager: NSObject {
    
    static let shared = CallKitManager()
    
    // CallKit 提供者
    private var callProvider: CXProvider?
    
    // 当前通话 UUID
    private var currentCallUUID: UUID?
    
    // 当前通话信息
    private var currentCallInfo: [String: Any]?
    
    // Flutter Method Channel
    private var methodChannel: FlutterMethodChannel?
    
    // 是否已初始化
    private var isInitialized = false
    
    // 🔴 新增：通话是否已接听（用于区分拒绝和挂断）
    private var isCallConnected = false
    
    private override init() {
        super.init()
    }
    
    /// 初始化 CallKit
    func initialize(with binaryMessenger: FlutterBinaryMessenger) {
        guard !isInitialized else {
            print("📞 [CallKit] 已初始化，跳过")
            return
        }
        
        print("📞 [CallKit] 开始初始化...")
        
        // 设置 Flutter Method Channel
        methodChannel = FlutterMethodChannel(
            name: "com.example.youdu/callkit",
            binaryMessenger: binaryMessenger
        )
        
        methodChannel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result: result)
        }
        
        // 配置 CallKit
        setupCallKit()
        
        isInitialized = true
        print("📞 [CallKit] ✅ 初始化完成")
    }
    
    /// 配置 CallKit
    private func setupCallKit() {
        // 使用兼容 iOS 13 的初始化方式
        let config: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            config = CXProviderConfiguration()
        } else {
            config = CXProviderConfiguration(localizedName: "有度")
        }
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        
        // 设置来电铃声（可选，使用系统默认）
        // config.ringtoneSound = "ringtone.caf"
        
        // 设置应用图标（可选）
        if let iconImage = UIImage(named: "AppIcon") {
            config.iconTemplateImageData = iconImage.pngData()
        }
        
        callProvider = CXProvider(configuration: config)
        callProvider?.setDelegate(self, queue: nil)
        
        print("📞 [CallKit] Provider 配置完成")
    }
    
    /// 处理 Flutter Method Channel 调用
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "endCall":
            endCurrentCall()
            result(true)
            
        case "reportCallConnected":
            reportCallConnected()
            result(true)
            
        case "reportCallEnded":
            if let args = call.arguments as? [String: Any],
               let reason = args["reason"] as? Int {
                reportCallEnded(reason: CXCallEndedReason(rawValue: reason) ?? .remoteEnded)
            } else {
                reportCallEnded(reason: .remoteEnded)
            }
            result(true)
            
        case "reportIncomingCall":
            // 从 Flutter 调用显示来电界面（WebSocket 触发）
            if let args = call.arguments as? [String: Any],
               let callerId = args["caller_id"] as? Int,
               let callerName = args["caller_name"] as? String,
               let callType = args["call_type"] as? String,
               let channelName = args["channel_name"] as? String,
               let token = args["token"] as? String {
                
                let isGroupCall = args["is_group_call"] as? Bool ?? false
                let groupId = args["group_id"] as? Int
                let members = args["members"] as? [[String: Any]]
                
                reportIncomingCall(
                    callerId: callerId,
                    callerName: callerName,
                    callType: callType,
                    channelName: channelName,
                    token: token,
                    isGroupCall: isGroupCall,
                    groupId: groupId,
                    members: members
                )
                result(true)
            } else {
                print("📞 [CallKit] ❌ reportIncomingCall 参数不完整")
                result(FlutterError(code: "INVALID_ARGS", message: "参数不完整", details: nil))
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    /// 显示来电界面
    /// - Parameters:
    ///   - callerId: 来电者 ID
    ///   - callerName: 来电者名称
    ///   - callType: 通话类型 (voice/video)
    ///   - channelName: 通话频道名称
    ///   - token: Agora Token
    ///   - isGroupCall: 是否是群组通话
    ///   - groupId: 群组 ID
    ///   - members: 群组成员列表
    func reportIncomingCall(
        callerId: Int,
        callerName: String,
        callType: String,
        channelName: String,
        token: String,
        isGroupCall: Bool = false,
        groupId: Int? = nil,
        members: [[String: Any]]? = nil
    ) {
        print("📞 [CallKit] 收到来电通知")
        print("   - 来电者: \(callerName) (ID: \(callerId))")
        print("   - 类型: \(callType)")
        print("   - 频道: \(channelName)")
        print("   - 群组通话: \(isGroupCall)")
        
        let uuid = UUID()
        currentCallUUID = uuid
        
        // 保存通话信息
        currentCallInfo = [
            "caller_id": callerId,
            "caller_name": callerName,
            "call_type": callType,
            "channel_name": channelName,
            "token": token,
            "is_group_call": isGroupCall,
            "group_id": groupId as Any,
            "members": members as Any
        ]
        
        // 配置来电更新
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: String(callerId))
        
        // 设置来电显示名称（通过 remoteHandle 的 value 或使用 localizedCallerName）
        // 注意：iOS 14+ localizedCallerName 是只读的，需要通过其他方式设置
        update.hasVideo = (callType == "video")
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false
        
        // 报告来电（来电者名称通过 CXHandle 传递）
        // 使用 CXHandle 的 phoneNumber 类型可以显示名称
        let displayName = isGroupCall ? "\(callerName) (群组通话)" : callerName
        let handle = CXHandle(type: .generic, value: displayName)
        update.remoteHandle = handle
        
        // 报告来电
        callProvider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                print("📞 [CallKit] ❌ 报告来电失败: \(error.localizedDescription)")
                self?.currentCallUUID = nil
                self?.currentCallInfo = nil
            } else {
                print("📞 [CallKit] ✅ 来电界面已显示")
            }
        }
    }
    
    /// 报告通话已连接
    func reportCallConnected() {
        guard let uuid = currentCallUUID else {
            print("📞 [CallKit] ⚠️ 没有活跃的通话")
            return
        }
        
        isCallConnected = true  // 🔴 标记通话已接听
        callProvider?.reportOutgoingCall(with: uuid, connectedAt: Date())
        print("📞 [CallKit] 通话已连接")
    }
    
    /// 报告通话结束
    func reportCallEnded(reason: CXCallEndedReason) {
        guard let uuid = currentCallUUID else {
            print("📞 [CallKit] ⚠️ 没有活跃的通话")
            return
        }
        
        callProvider?.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentCallUUID = nil
        currentCallInfo = nil
        isCallConnected = false  // 🔴 重置状态
        print("📞 [CallKit] 通话已结束，原因: \(reason.rawValue)")
    }
    
    /// 结束当前通话
    func endCurrentCall() {
        guard let uuid = currentCallUUID else {
            print("📞 [CallKit] ⚠️ 没有活跃的通话")
            return
        }
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        let callController = CXCallController()
        callController.request(transaction) { error in
            if let error = error {
                print("📞 [CallKit] ❌ 结束通话失败: \(error.localizedDescription)")
            } else {
                print("📞 [CallKit] ✅ 通话已结束")
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    
    func providerDidReset(_ provider: CXProvider) {
        print("📞 [CallKit] Provider 已重置")
        currentCallUUID = nil
        currentCallInfo = nil
    }
    
    /// 用户接听来电
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║ 📞 [CallKit-Answer] 用户点击接听按钮                           ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
        print("📞 [CallKit-Answer] currentCallUUID: \(currentCallUUID?.uuidString ?? "nil")")
        print("📞 [CallKit-Answer] isCallConnected: \(isCallConnected)")
        print("📞 [CallKit-Answer] currentCallInfo: \(currentCallInfo ?? [:])")
        
        // 配置音频会话
        print("📞 [CallKit-Answer] 配置音频会话...")
        configureAudioSession()
        print("📞 [CallKit-Answer] 音频会话配置完成")
        
        // 🔴 标记通话已接听
        isCallConnected = true
        print("📞 [CallKit-Answer] isCallConnected 设置为 true")
        
        // 🔴 保存通话信息和UUID的副本，因为后面会清空
        let callInfoCopy = currentCallInfo
        let uuidCopy = currentCallUUID
        print("📞 [CallKit-Answer] 已保存 callInfoCopy 和 uuidCopy")
        
        // 🔴 立即清理状态，防止后续的 CXEndCallAction 触发 onCallEnded
        print("📞 [CallKit-Answer] 清理状态...")
        currentCallUUID = nil
        currentCallInfo = nil
        isCallConnected = false  // 🔴 重置状态，这样后续的 endCall 不会触发 onCallEnded
        print("📞 [CallKit-Answer] 状态已清理: currentCallUUID=nil, currentCallInfo=nil, isCallConnected=false")
        
        // 🔴 关键：先 fulfill 让 CallKit 知道我们接听了
        print("📞 [CallKit-Answer] 调用 action.fulfill()...")
        action.fulfill()
        print("📞 [CallKit-Answer] action.fulfill() 完成")
        
        // 🔴 通知 Flutter 用户接听了来电（Flutter 会打开通话页面）
        // 先通知 Flutter，让它开始接听流程
        DispatchQueue.main.async { [weak self] in
            print("╔═══════════════════════════════════════════════════════════════╗")
            print("║ 📞 [CallKit-Answer] 主线程回调开始                             ║")
            print("╚═══════════════════════════════════════════════════════════════╝")
            print("📞 [CallKit-Answer] self 是否存在: \(self != nil)")
            print("📞 [CallKit-Answer] methodChannel 是否存在: \(self?.methodChannel != nil)")
            print("📞 [CallKit-Answer] callInfoCopy: \(callInfoCopy ?? [:])")
            
            // 通知 Flutter 用户接听了来电（Flutter 会打开通话页面）
            if let callInfo = callInfoCopy {
                print("📞 [CallKit-Answer] 调用 invokeMethod('onCallAccepted')...")
                self?.methodChannel?.invokeMethod("onCallAccepted", arguments: callInfo)
                print("📞 [CallKit-Answer] invokeMethod('onCallAccepted') 已调用")
            } else {
                print("📞 [CallKit-Answer] ⚠️ callInfoCopy 为 nil，无法通知 Flutter")
            }
            
            print("╔═══════════════════════════════════════════════════════════════╗")
            print("║ 📞 [CallKit-Answer] 主线程回调结束                             ║")
            print("╚═══════════════════════════════════════════════════════════════╝")
        }
        
        // 🔴 延迟关闭 CallKit 通话界面，给 iOS 足够时间将应用拉到前台
        // 延迟 1 秒后关闭 CallKit
        if let uuid = uuidCopy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                print("📞 [CallKit-Answer] 延迟 1 秒后关闭 CallKit 界面...")
                self?.callProvider?.reportCall(with: uuid, endedAt: Date(), reason: .answeredElsewhere)
                print("📞 [CallKit-Answer] CallKit 界面关闭命令已发送")
            }
        }
        
        print("📞 [CallKit-Answer] provider 方法即将返回")
    }
    
    /// 用户拒绝/结束来电
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║ 📞 [CallKit-EndCall] 收到结束通话请求                          ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
        print("📞 [CallKit-EndCall] isCallConnected: \(isCallConnected)")
        print("📞 [CallKit-EndCall] currentCallUUID: \(currentCallUUID?.uuidString ?? "nil")")
        print("📞 [CallKit-EndCall] currentCallInfo: \(currentCallInfo ?? [:])")
        
        // 🔴 如果 currentCallUUID 为 nil，说明通话已经在 accept 时被关闭了
        // 这种情况下不应该触发任何回调
        guard currentCallUUID != nil || currentCallInfo != nil else {
            print("📞 [CallKit-EndCall] ⚠️ currentCallUUID 和 currentCallInfo 都为 nil")
            print("📞 [CallKit-EndCall] ⚠️ 通话已在接听时关闭，忽略此 endCall 事件")
            action.fulfill()
            print("📞 [CallKit-EndCall] action.fulfill() 完成（忽略模式）")
            return
        }
        
        // 🔴 根据通话状态区分是拒绝还是挂断
        if isCallConnected {
            // 通话已接听，这是挂断操作
            print("📞 [CallKit-EndCall] 通话已接听 (isCallConnected=true)，这是挂断操作")
            if let callInfo = currentCallInfo {
                print("📞 [CallKit-EndCall] 调用 invokeMethod('onCallEnded')...")
                methodChannel?.invokeMethod("onCallEnded", arguments: callInfo)
                print("📞 [CallKit-EndCall] invokeMethod('onCallEnded') 已调用")
            } else {
                print("📞 [CallKit-EndCall] ⚠️ currentCallInfo 为 nil，无法通知 Flutter")
            }
        } else {
            // 通话未接听，这是拒绝操作
            print("📞 [CallKit-EndCall] 通话未接听 (isCallConnected=false)，这是拒绝操作")
            if let callInfo = currentCallInfo {
                print("📞 [CallKit-EndCall] 调用 invokeMethod('onCallRejected')...")
                methodChannel?.invokeMethod("onCallRejected", arguments: callInfo)
                print("📞 [CallKit-EndCall] invokeMethod('onCallRejected') 已调用")
            } else {
                print("📞 [CallKit-EndCall] ⚠️ currentCallInfo 为 nil，无法通知 Flutter")
            }
        }
        
        print("📞 [CallKit-EndCall] 清理状态...")
        currentCallUUID = nil
        currentCallInfo = nil
        isCallConnected = false  // 🔴 重置状态
        print("📞 [CallKit-EndCall] 状态已清理")
        
        print("📞 [CallKit-EndCall] 调用 action.fulfill()...")
        action.fulfill()
        print("📞 [CallKit-EndCall] action.fulfill() 完成")
        
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║ 📞 [CallKit-EndCall] 处理完成                                  ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
    }
    
    /// 音频会话激活状态变化
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("📞 [CallKit] 🔊 音频会话已激活")
        
        // 通知 Flutter 音频会话已激活
        methodChannel?.invokeMethod("onAudioSessionActivated", arguments: nil)
    }
    
    /// 音频会话停用
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("📞 [CallKit] 🔇 音频会话已停用")
        
        // 通知 Flutter 音频会话已停用
        methodChannel?.invokeMethod("onAudioSessionDeactivated", arguments: nil)
    }
    
    /// 配置音频会话
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true)
            print("📞 [CallKit] ✅ 音频会话配置成功")
        } catch {
            print("📞 [CallKit] ❌ 音频会话配置失败: \(error.localizedDescription)")
        }
    }
}
