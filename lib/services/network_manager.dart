import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import '../utils/logger.dart';

class NetworkManager {
  static final NetworkManager _instance = NetworkManager._internal();
  factory NetworkManager() => _instance;
  NetworkManager._internal();

  StreamSubscription? _connectivitySubscription;
  bool _isOnline = true;
  bool get isOnline => _isOnline;

  final _statusController = StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;

  void startListening(Function(bool isOnline) onStatusChanged) {
    _connectivitySubscription?.cancel();
    
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) async {
      if (results.contains(ConnectivityResult.none)) {
        logger.debug('🔴 [网络监听] 系统层显示断开，判定断网');
        _updateStatus(false, onStatusChanged);
      } else {
        logger.debug('🔄 [网络监听] 系统层显示有信号，进行真实连通性测试...');
        bool hasActualInternet = await InternetConnection().hasInternetAccess;
        logger.debug('${hasActualInternet ? "✅" : "❌"} [网络监听] 真实连通性测试结果: $hasActualInternet');
        _updateStatus(hasActualInternet, onStatusChanged);
      }
    });

    _checkInitialStatus(onStatusChanged);
  }

  Future<void> _checkInitialStatus(Function(bool isOnline) onStatusChanged) async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      logger.debug('🔴 [网络监听] 初始状态：断网');
      _updateStatus(false, onStatusChanged);
    } else {
      logger.debug('🔄 [网络监听] 初始状态：检测真实连通性...');
      bool hasActualInternet = await InternetConnection().hasInternetAccess;
      logger.debug('${hasActualInternet ? "✅" : "❌"} [网络监听] 初始真实连通性: $hasActualInternet');
      _updateStatus(hasActualInternet, onStatusChanged);
    }
  }

  void _updateStatus(bool isOnline, Function(bool isOnline) onStatusChanged) {
    if (_isOnline != isOnline) {
      _isOnline = isOnline;
      _statusController.add(isOnline);
      onStatusChanged(isOnline);
    }
  }

  Future<bool> checkNow() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      return false;
    }
    return await InternetConnection().hasInternetAccess;
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _statusController.close();
  }
}
