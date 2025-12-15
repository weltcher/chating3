import '../utils/logger.dart';

/// 时区处理工具类
/// 
/// 统一时区处理方案：
/// - 所有消息时间都转换为上海时区（Asia/Shanghai，UTC+8）存储
/// - 客户端发送消息：获取本地时区 -> 转换为上海时区 -> 存储/发送
/// - 服务器接收消息：获取服务器时区 -> 转换为上海时区 -> 存储
/// - 客户端接收消息：获取本地时区 -> 转换为上海时区 -> 存储
class TimezoneHelper {
  /// 上海时区偏移量（UTC+8）
  static const int shanghaiOffsetHours = 8;
  
  /// 获取当前设备的时区偏移量（小时）
  static int getLocalTimezoneOffsetHours() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    return offset.inHours;
  }
  
  /// 获取当前设备的时区偏移量（分钟）
  static int getLocalTimezoneOffsetMinutes() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    return offset.inMinutes;
  }
  
  /// 获取当前设备的时区名称
  static String getLocalTimezoneName() {
    final now = DateTime.now();
    return now.timeZoneName;
  }
  
  /// 将本地时间转换为上海时区时间
  /// 
  /// 参数：
  /// - [localTime]: 本地时间的 DateTime 对象
  /// 
  /// 返回：上海时区的 DateTime 对象
  /// 
  /// 示例：
  /// - 如果本地是 UTC+0（伦敦），本地时间 10:00，转换后为 18:00（上海时间）
  /// - 如果本地是 UTC+8（上海），本地时间 10:00，转换后仍为 10:00
  /// - 如果本地是 UTC-5（纽约），本地时间 10:00，转换后为 23:00（上海时间）
  static DateTime localToShanghaiTime(DateTime localTime) {
    // 获取本地时区偏移量（分钟）
    final localOffsetMinutes = localTime.timeZoneOffset.inMinutes;
    
    // 上海时区偏移量（分钟）
    const shanghaiOffsetMinutes = shanghaiOffsetHours * 60;
    
    // 计算时差（分钟）：上海时区 - 本地时区
    final diffMinutes = shanghaiOffsetMinutes - localOffsetMinutes;
    
    // 转换为上海时区时间
    final shanghaiTime = localTime.add(Duration(minutes: diffMinutes));
    
    final logger = Logger();
    logger.debug('🕐 [时区转换] 本地时间 -> 上海时间');
    logger.debug('   本地时区偏移: ${localOffsetMinutes ~/ 60}小时${localOffsetMinutes % 60}分钟');
    logger.debug('   本地时间: ${localTime.toIso8601String()}');
    logger.debug('   上海时间: ${shanghaiTime.toIso8601String()}');
    
    return shanghaiTime;
  }
  
  /// 将 UTC 时间转换为上海时区时间
  /// 
  /// 参数：
  /// - [utcTime]: UTC 时间的 DateTime 对象
  /// 
  /// 返回：上海时区的 DateTime 对象
  static DateTime utcToShanghaiTime(DateTime utcTime) {
    // 确保输入是 UTC 时间
    final utc = utcTime.isUtc ? utcTime : utcTime.toUtc();
    
    // UTC + 8 = 上海时间
    final shanghaiTime = utc.add(const Duration(hours: shanghaiOffsetHours));
    
    return shanghaiTime;
  }
  
  /// 将上海时区时间转换为 UTC 时间
  /// 
  /// 参数：
  /// - [shanghaiTime]: 上海时区的 DateTime 对象
  /// 
  /// 返回：UTC 时间的 DateTime 对象
  static DateTime shanghaiToUtcTime(DateTime shanghaiTime) {
    // 上海时间 - 8 = UTC
    final utcTime = shanghaiTime.subtract(const Duration(hours: shanghaiOffsetHours));
    
    return DateTime.utc(
      utcTime.year,
      utcTime.month,
      utcTime.day,
      utcTime.hour,
      utcTime.minute,
      utcTime.second,
      utcTime.millisecond,
      utcTime.microsecond,
    );
  }
  
  /// 获取当前的上海时区时间
  /// 
  /// 返回：当前的上海时区 DateTime 对象
  static DateTime nowInShanghai() {
    return localToShanghaiTime(DateTime.now());
  }
  
  /// 获取当前上海时区时间的 ISO 8601 字符串
  /// 
  /// 返回：ISO 8601 格式的时间字符串（不带 Z 后缀，表示上海时区）
  static String nowInShanghaiString() {
    final shanghaiTime = nowInShanghai();
    // 不带 Z 后缀，表示这是上海时区时间
    return shanghaiTime.toIso8601String().replaceAll('Z', '');
  }
  
  /// 解析时间字符串为上海时区时间
  /// 
  /// 参数：
  /// - [timeString]: ISO 8601 格式的时间字符串
  /// - [isGroupMessage]: 是否是群组消息（默认false）
  /// - [assumeUtc]: 如果时间字符串没有时区信息，是否假设为 UTC（默认true）
  /// 
  /// 返回：上海时区的 DateTime 对象
  static DateTime parseToShanghaiTime(
    String timeString, {
    bool isGroupMessage = false,
    bool assumeUtc = true,
  }) {
    final logger = Logger();
    String s = timeString.trim();
    
    // 兼容错误数据：如果以多个Z结尾（例如 ...ZZ），压缩为单个Z
    if (RegExp(r'Z{2,}$').hasMatch(s)) {
      s = s.replaceFirst(RegExp(r'Z+$'), 'Z');
    }

    // 解析时间戳（带兜底）
    DateTime parsedTime;
    try {
      parsedTime = DateTime.parse(s);
    } catch (e) {
      // 再次尝试：移除末尾所有Z后重试
      try {
        final s2 = s.replaceFirst(RegExp(r'Z+$'), '');
        parsedTime = DateTime.parse(s2);
      } catch (e2) {
        logger.debug('⚠️ [时区解析] 无法解析时间字符串: $timeString，使用当前时间');
        return nowInShanghai();
      }
    }

    // 检查时间戳是否包含 Z 后缀（表示 UTC 时间）
    bool hasZSuffix = s.endsWith('Z');
  
    if (hasZSuffix && parsedTime.isUtc) {
      // 带 Z 后缀的时间是 UTC 时间，需要转换为上海时区
      return utcToShanghaiTime(parsedTime);
    } else if (assumeUtc && !hasZSuffix) {
      // 没有 Z 后缀但假设为 UTC，转换为上海时区
      final utcTime = DateTime.utc(
        parsedTime.year,
        parsedTime.month,
        parsedTime.day,
        parsedTime.hour,
        parsedTime.minute,
        parsedTime.second,
        parsedTime.millisecond,
        parsedTime.microsecond,
      );
      return utcToShanghaiTime(utcTime);
    } else {
      // 没有 Z 后缀且不假设为 UTC，认为已经是上海时区时间
      return parsedTime;
    }
  }
  
  /// 将 DateTime 转换为上海时区的 ISO 8601 字符串
  /// 
  /// 参数：
  /// - [dateTime]: DateTime 对象
  /// - [fromLocal]: 是否从本地时间转换（默认true）
  /// 
  /// 返回：ISO 8601 格式的时间字符串（不带 Z 后缀）
  static String toShanghaiTimeString(DateTime dateTime, {bool fromLocal = true}) {
    DateTime shanghaiTime;
    
    if (fromLocal) {
      shanghaiTime = localToShanghaiTime(dateTime);
    } else if (dateTime.isUtc) {
      shanghaiTime = utcToShanghaiTime(dateTime);
    } else {
      // 假设已经是上海时区时间
      shanghaiTime = dateTime;
    }
    
    // 返回不带 Z 后缀的字符串，表示这是上海时区时间
    return shanghaiTime.toIso8601String().replaceAll('Z', '');
  }
  
  /// 格式化上海时区时间为显示字符串
  /// 
  /// 参数：
  /// - [shanghaiTime]: 上海时区的 DateTime 对象
  /// 
  /// 返回：格式化的时间字符串（如 "10:30" 或 "昨天 10:30"）
  static String formatShanghaiTime(DateTime shanghaiTime) {
    final now = nowInShanghai();
    final difference = now.difference(shanghaiTime);

    if (difference.inDays == 0 && now.day == shanghaiTime.day) {
      // 今天，显示时间
      return '${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1 || (difference.inDays == 0 && now.day != shanghaiTime.day)) {
      // 昨天
      return '昨天 ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays < 7) {
      // 一周内
      final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return '${weekdays[shanghaiTime.weekday - 1]} ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (shanghaiTime.year == now.year) {
      // 今年
      return '${shanghaiTime.month}-${shanghaiTime.day} ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else {
      // 更早
      return '${shanghaiTime.year}-${shanghaiTime.month}-${shanghaiTime.day} ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    }
  }
  
  /// 调试方法：打印当前时区信息
  static void debugTimezoneInfo() {
    final logger = Logger();
    final now = DateTime.now();
    final utcNow = DateTime.now().toUtc();
    final shanghaiNow = nowInShanghai();
    
    logger.debug('═══════════════════════════════════════');
    logger.debug('🕐 [时区调试信息]');
    logger.debug('   设备时区名称: ${getLocalTimezoneName()}');
    logger.debug('   设备时区偏移: UTC${getLocalTimezoneOffsetHours() >= 0 ? '+' : ''}${getLocalTimezoneOffsetHours()}');
    logger.debug('   本地时间: ${now.toIso8601String()}');
    logger.debug('   UTC时间: ${utcNow.toIso8601String()}');
    logger.debug('   上海时间: ${shanghaiNow.toIso8601String()}');
    logger.debug('═══════════════════════════════════════');
  }
}
