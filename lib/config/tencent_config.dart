/// 腾讯云 TUICallKit 配置文件
/// 请在 https://console.cloud.tencent.com/trtc 获取您的 SDKAppID 和 SecretKey
class TencentConfig {
  /// 是否使用海外版（国际版）
  /// true = 海外版（新加坡等海外节点）
  /// false = 国内版（中国大陆节点）
  static const bool isOverseas = false;

  /// 腾讯云 SDKAppID
  /// 获取方式：
  /// 1. 访问 https://console.cloud.tencent.com/trtc
  /// 2. 创建应用或使用现有应用
  /// 3. 复制 SDKAppID
  static const int sdkAppId = isOverseas ? 20032098 : 1600120945;

  /// 腾讯云 SecretKey（仅用于测试，生产环境请使用服务端生成 UserSig）
  /// 获取方式：
  /// 1. 访问 https://console.cloud.tencent.com/trtc
  /// 2. 进入应用详情
  /// 3. 复制 SecretKey
  /// 
  /// ⚠️ 警告：SecretKey 不应该在客户端代码中暴露
  /// 生产环境请使用服务端生成 UserSig
  static const String secretKey = isOverseas 
      ? '94dc40f82ec4e54efeaa7cc59f5d2231e0ab2075869ceff9b608493a51bcee6f'  // 海外
      : 'd114b2b7000f73737246a15d3e45c1b1b59e6ba4ce43d5d2daf7762e7062ceb1'; // 国内

  /// UserSig 有效期（秒）
  /// 默认 7 天
  static const int expireTime = 604800;
}
