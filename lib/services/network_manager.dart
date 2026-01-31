import 'dart:async';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import '../utils/logger.dart';

/// 网络状态管理器（单例）
/// 
/// 这是应用中唯一可以修改真实网络状态的地方。
/// 所有页面应该通过监听此管理器来更新UI状态，而不是自己维护网络状态。
/// 
/// 使用方式：
/// ```dart
/// // 推荐方式：使用 Stream 监听（支持多个监听者）
/// final subscription = NetworkManager().statusStream.listen((bool isOnline) {
///   // 处理网络状态变化
/// });
/// // 记得在 dispose 时取消订阅
/// subscription.cancel();
/// 
/// // 或者使用 startListening（会自动启动底层监听）
/// NetworkManager().startListening((bool isOnline) {
///   if (isOnline) {
///     // 网络已连接
///   } else {
///     // 网络已断开
///   }
/// });
/// 
/// // 读取当前状态
/// bool isOnline = NetworkManager().isOnline;
/// ```
class NetworkManager {
  static final NetworkManager _instance = NetworkManager._internal();
  factory NetworkManager() => _instance;
  NetworkManager._internal();

  StreamSubscription<InternetStatus>? _internetSubscription;
  
  // 🔴 私有变量：真实的网络状态，只能通过内部方法修改
  bool _isOnline = true;
  
  // 🔴 标记是否已经初始化监听
  bool _isListening = false;
  
  // 🔴 只读getter：外部只能读取，不能修改
  bool get isOnline => _isOnline;

  // 🔴 广播流：用于通知所有监听者网络状态变化
  final _statusController = StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;
  
  // 🔴 存储所有回调函数（支持多个监听者）
  final List<Function(bool isOnline)> _callbacks = [];

  /// 开始监听网络状态变化
  /// 
  /// [onStatusChanged] 当网络状态变化时的回调函数
  /// 
  /// 🔴 关键修复：此方法现在支持多个监听者，不会取消之前的监听
  /// 底层的 InternetConnection 监听只会启动一次，所有回调都会被调用
  void startListening(Function(bool isOnline) onStatusChanged) {
    // 添加回调到列表
    if (!_callbacks.contains(onStatusChanged)) {
      _callbacks.add(onStatusChanged);
      logger.debug('📡 [NetworkManager] 添加新的网络状态回调，当前回调数量: ${_callbacks.length}');
    }
    
    // 如果还没有启动底层监听，则启动
    if (!_isListening) {
      _startInternalListening();
    }
    
    // 🔴 关键修复：立即通知当前状态给新的监听者
    // 这样新页面进入时能立即知道当前网络状态
    logger.debug('📡 [NetworkManager] 立即通知新监听者当前状态: $_isOnline');
    onStatusChanged(_isOnline);
  }
  
  /// 移除回调函数
  /// 
  /// 当页面 dispose 时应该调用此方法移除回调
  void removeCallback(Function(bool isOnline) callback) {
    _callbacks.remove(callback);
    logger.debug('📡 [NetworkManager] 移除网络状态回调，剩余回调数量: ${_callbacks.length}');
  }
  
  /// 启动底层网络监听（只会执行一次）
  void _startInternalListening() {
    if (_isListening) return;
    
    _isListening = true;
    logger.debug('🚀 [NetworkManager] 启动底层网络监听');
    
    _internetSubscription?.cancel();
    _internetSubscription = InternetConnection().onStatusChange.listen((InternetStatus status) {
      bool isConnected = status == InternetStatus.connected;
      logger.debug('${isConnected ? "✅" : "🔴"} [NetworkManager] 网络状态变化: ${isConnected ? "已连接" : "已断开"}');
      _updateStatus(isConnected);
    });

    // 检查初始状态
    _checkInitialStatus();
  }

  /// 检查初始网络状态
  Future<void> _checkInitialStatus() async {
    bool hasInternet = await InternetConnection().hasInternetAccess;
    logger.debug('${hasInternet ? "✅" : "🔴"} [NetworkManager] 初始状态: ${hasInternet ? "已连接" : "已断开"}');
    _updateStatus(hasInternet);
  }

  /// 更新状态并通知所有监听者
  void _updateStatus(bool isOnline) {
    bool stateChanged = _isOnline != isOnline;
    
    _isOnline = isOnline;
    
    if (stateChanged) {
      logger.debug('🔄 [NetworkManager] 状态已更新: $_isOnline，通知 ${_callbacks.length} 个回调');
    }
    
    // 🔴 关键修复：总是通知 Stream 监听者
    _statusController.add(_isOnline);
    
    // 🔴 关键修复：通知所有回调函数
    for (final callback in List.from(_callbacks)) {
      try {
        callback(_isOnline);
      } catch (e) {
        logger.error('❌ [NetworkManager] 回调执行失败', error: e);
      }
    }
  }

  /// 立即检查当前网络状态（异步）
  /// 
  /// 返回当前是否有网络连接
  Future<bool> checkNow() async {
    bool hasInternet = await InternetConnection().hasInternetAccess;
    logger.debug('🔍 [NetworkManager] 手动检查网络状态: ${hasInternet ? "已连接" : "已断开"}');
    
    // 如果状态发生变化，更新内部状态并通知所有监听者
    if (_isOnline != hasInternet) {
      _updateStatus(hasInternet);
    }
    
    return hasInternet;
  }

  /// 停止监听并释放资源
  void dispose() {
    logger.debug('🗑️ [NetworkManager] 释放资源');
    _internetSubscription?.cancel();
    _statusController.close();
    _callbacks.clear();
    _isListening = false;
  }
}
