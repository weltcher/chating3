import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';
import '../utils/storage.dart';

/// 代理IP信息模型
class ProxyInfo {
  final String proxyIp;
  final String server;
  final int areaCode;
  final String area;
  final String isp;
  final String taskId;
  final String deadline;

  ProxyInfo({
    required this.proxyIp,
    required this.server,
    required this.areaCode,
    required this.area,
    required this.isp,
    required this.taskId,
    required this.deadline,
  });

  factory ProxyInfo.fromJson(Map<String, dynamic> json) {
    return ProxyInfo(
      proxyIp: json['proxy_ip'] ?? '',
      server: json['server'] ?? '',
      areaCode: json['area_code'] ?? 0,
      area: json['area'] ?? '',
      isp: json['isp'] ?? '',
      taskId: json['task_id'] ?? '',
      deadline: json['deadline'] ?? '',
    );
  }

  /// 获取代理IP地址
  String get ip => proxyIp;

  /// 获取代理端口
  int get port {
    if (server.contains(':')) {
      return int.tryParse(server.split(':').last) ?? 0;
    }
    return 0;
  }

  @override
  String toString() {
    return 'ProxyInfo(ip: $proxyIp, server: $server, area: $area, isp: $isp, deadline: $deadline)';
  }
}

/// 代理服务 - 管理代理IP的获取和使用
class ProxyService {
  // 单例模式
  static final ProxyService _instance = ProxyService._internal();
  factory ProxyService() => _instance;
  ProxyService._internal();

  // 独享代理API地址
  static const String _proxyApiUrl = 'https://exclusive.proxy.qg.net/get';
  static const String _proxyApiKey = 'F4551F27';

  // 当前代理信息
  ProxyInfo? _currentProxy;

  /// 获取当前代理信息
  ProxyInfo? get currentProxy => _currentProxy;

  /// 是否有有效的代理
  bool get hasValidProxy => _currentProxy != null;

  /// 获取代理IP
  /// 返回代理信息，如果获取失败返回null
  Future<ProxyInfo?> fetchProxyIp() async {
    try {
      logger.debug('🌐 [ProxyService] 开始获取独享代理IP...');

      final url = '$_proxyApiUrl?key=$_proxyApiKey';
      logger.debug('🌐 [ProxyService] 请求URL: $url');

      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('获取代理IP超时');
        },
      );

      logger.debug('🌐 [ProxyService] 响应状态码: ${response.statusCode}');
      logger.debug('🌐 [ProxyService] 响应内容: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // 独享代理响应格式: {"code":"SUCCESS","data":{"task_id":"xxx","ips":[...],"num":1}}
        if (data['code'] == 'SUCCESS' && data['data'] != null) {
          final responseData = data['data'];
          final taskId = responseData['task_id'] ?? '';
          final ips = responseData['ips'] as List?;

          if (ips != null && ips.isNotEmpty) {
            final proxyData = ips[0] as Map<String, dynamic>;
            // 将 task_id 添加到 proxyData 中
            proxyData['task_id'] = taskId;
            _currentProxy = ProxyInfo.fromJson(proxyData);

            logger.debug('✅ [ProxyService] 获取独享代理IP成功: $_currentProxy');
            return _currentProxy;
          } else {
            logger.debug('❌ [ProxyService] 获取代理IP失败: ips列表为空');
            return null;
          }
        } else {
          logger.debug(
              '❌ [ProxyService] 获取代理IP失败: code=${data['code']}, message=${data['message'] ?? 'unknown'}');
          return null;
        }
      } else {
        logger.debug(
            '❌ [ProxyService] 获取代理IP请求失败: ${response.statusCode}, body: ${response.body}');
        return null;
      }
    } catch (e) {
      logger.debug('❌ [ProxyService] 获取代理IP异常: $e');
      return null;
    }
  }

  /// 清除当前代理
  void clearProxy() {
    _currentProxy = null;
    logger.debug('🗑️ [ProxyService] 已清除代理信息');
  }

  /// 检查代理是否过期
  bool isProxyExpired() {
    if (_currentProxy == null) return true;

    try {
      final deadline = DateTime.parse(_currentProxy!.deadline);
      return DateTime.now().isAfter(deadline);
    } catch (e) {
      logger.debug('⚠️ [ProxyService] 解析代理过期时间失败: $e');
      return true;
    }
  }

  /// 获取有效的代理（如果过期则重新获取）
  Future<ProxyInfo?> getValidProxy() async {
    // 检查是否启用了代理
    final useProxy = await Storage.getUseProxy();
    if (!useProxy) {
      logger.debug('ℹ️ [ProxyService] 代理未启用，跳过获取');
      return null;
    }

    // 如果当前代理有效且未过期，直接返回
    if (_currentProxy != null && !isProxyExpired()) {
      logger.debug('✅ [ProxyService] 使用缓存的代理: $_currentProxy');
      return _currentProxy;
    }

    // 否则重新获取
    return await fetchProxyIp();
  }
}
