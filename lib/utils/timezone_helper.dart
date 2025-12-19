import '../utils/logger.dart';

/// 时区处理工具类
/// 
/// 统一时区处理方案：
/// - 服务器存储和发送 UTC 时间（带 Z 后缀）
/// - 客户端接收 UTC 时间后转换为本地时间显示
/// - 客户端发送消息时使用本地时间（服务器会转换为 UTC 存储）
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
  static DateTime localToShanghaiTime(DateTime localTime) {
    final localOffsetMinutes = localTime.timeZoneOffset.inMinutes;
    const shanghaiOffsetMinutes = shanghaiOffsetHours * 60;
    final diffMinutes = shanghaiOffsetMinutes - localOffsetMinutes;
    final shanghaiTime = localTime.add(Duration(minutes: diffMinutes));
    
    final logger = Logger();
    logger.debug('🕐 [时区转换] 本地时间 -> 上海时间');
    logger.debug('   本地时区偏移: ${localOffsetMinutes ~/ 60}小时${localOffsetMinutes % 60}分钟');
    logger.debug('   本地时间: ${localTime.toIso8601String()}');
    logger.debug('   上海时间: ${shanghaiTime.toIso8601String()}');
    
    return shanghaiTime;
  }
  
  /// 将 UTC 时间转换为本地时间（用于显示）
  static DateTime utcToLocalTime(DateTime utcTime) {
    final logger = Logger();
    final utc = utcTime.isUtc ? utcTime : utcTime.toUtc();
    final localTime = utc.toLocal();
    
    logger.debug('🕐 [utcToLocalTime] UTC时间: ${utc.toString()}');
    logger.debug('🕐 [utcToLocalTime] 本地时间: ${localTime.toString()}');
    
    return localTime;
  }
  
  /// 将 UTC 时间转换为上海时区时间
  static DateTime utcToShanghaiTime(DateTime utcTime) {
    final logger = Logger();
    final utc = utcTime.isUtc ? utcTime : utcTime.toUtc();
    
    // UTC + 8 = 上海时间
    final shanghaiTime = utc.add(const Duration(hours: shanghaiOffsetHours));
    logger.debug('🕐 [utcToShanghaiTime] UTC时间: ${utc.toString()}');
    logger.debug('🕐 [utcToShanghaiTime] 上海时间: ${shanghaiTime.toString()}');
    return shanghaiTime;
  }
  
  /// 将上海时区时间转换为 UTC 时间
  static DateTime shanghaiToUtcTime(DateTime shanghaiTime) {
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
  static DateTime nowInShanghai() {
    return localToShanghaiTime(DateTime.now());
  }
  
  /// 获取当前上海时区时间的 ISO 8601 字符串
  static String nowInShanghaiString() {
    final shanghaiTime = nowInShanghai();
    return shanghaiTime.toIso8601String().replaceAll('Z', '');
  }
  
  /// 解析时间字符串并转换为本地时间（用于显示）
  /// 
  /// 参数：
  /// - [timeString]: ISO 8601 格式的时间字符串
  /// - [assumeUtc]: 如果时间字符串没有时区信息，是否假设为 UTC（默认true）
  /// 
  /// 返回：本地时间的 DateTime 对象（用于显示）
  static DateTime parseToShanghaiTime(
    String timeString, {
    bool isGroupMessage = false,
    bool assumeUtc = true,
  }) {
    final logger = Logger();
    String s = timeString.trim();
    
    logger.debug('🕐 [parseToShanghaiTime] ===== 开始解析 =====');
    logger.debug('🕐 [parseToShanghaiTime] 输入timeString: $timeString');
    logger.debug('🕐 [parseToShanghaiTime] assumeUtc: $assumeUtc');
    
    // 兼容错误数据：如果以多个Z结尾，压缩为单个Z
    final multiZPattern = RegExp(r'Z{2,}$');
    if (multiZPattern.hasMatch(s)) {
      s = s.replaceFirst(RegExp(r'Z+$'), 'Z');
      logger.debug('🕐 [parseToShanghaiTime] 修正多个Z后: $s');
    }

    // 解析时间戳
    DateTime parsedTime;
    try {
      parsedTime = DateTime.parse(s);
      logger.debug('🕐 [parseToShanghaiTime] 解析成功: ${parsedTime.toString()}');
      logger.debug('🕐 [parseToShanghaiTime] parsedTime.isUtc: ${parsedTime.isUtc}');
    } catch (e) {
      try {
        final s2 = s.replaceFirst(RegExp(r'Z+$'), '');
        parsedTime = DateTime.parse(s2);
        logger.debug('🕐 [parseToShanghaiTime] 移除Z后解析成功: ${parsedTime.toString()}');
      } catch (e2) {
        logger.debug('⚠️ [时区解析] 无法解析时间字符串: $timeString，使用当前时间');
        return nowInShanghai();
      }
    }

    bool hasZSuffix = s.endsWith('Z');
    logger.debug('🕐 [parseToShanghaiTime] hasZSuffix: $hasZSuffix');
  
    if (hasZSuffix && parsedTime.isUtc) {
      // 带 Z 后缀的时间是 UTC 时间，转换为上海时区
      logger.debug('🕐 [parseToShanghaiTime] 走分支1: hasZSuffix && isUtc，调用utcToShanghaiTime');
      final result = utcToShanghaiTime(parsedTime);
      logger.debug('🕐 [parseToShanghaiTime] 转换结果: ${result.toString()}');
      logger.debug('🕐 [parseToShanghaiTime] ===== 解析结束 =====');
      return result;
    } else if (assumeUtc && !hasZSuffix) {
      // 没有 Z 后缀但假设为 UTC，转换为上海时区
      logger.debug('🕐 [parseToShanghaiTime] 走分支2: assumeUtc && !hasZSuffix');
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
      logger.debug('🕐 [parseToShanghaiTime] 构造的utcTime: ${utcTime.toString()}');
      final result = utcToShanghaiTime(utcTime);
      logger.debug('🕐 [parseToShanghaiTime] 转换结果: ${result.toString()}');
      logger.debug('🕐 [parseToShanghaiTime] ===== 解析结束 =====');
      return result;
    } else {
      // 没有 Z 后缀且不假设为 UTC，认为已经是上海时区时间
      logger.debug('🕐 [parseToShanghaiTime] 走分支3: 直接返回parsedTime');
      logger.debug('🕐 [parseToShanghaiTime] ===== 解析结束 =====');
      return parsedTime;
    }
  }
  
  /// 将 DateTime 转换为上海时区的 ISO 8601 字符串
  static String toShanghaiTimeString(DateTime dateTime, {bool fromLocal = true}) {
    DateTime shanghaiTime;
    
    if (fromLocal) {
      shanghaiTime = localToShanghaiTime(dateTime);
    } else if (dateTime.isUtc) {
      shanghaiTime = utcToShanghaiTime(dateTime);
    } else {
      shanghaiTime = dateTime;
    }
    
    return shanghaiTime.toIso8601String().replaceAll('Z', '');
  }
  
  /// 格式化上海时区时间为显示字符串
  static String formatShanghaiTime(DateTime shanghaiTime) {
    final now = nowInShanghai();
    final difference = now.difference(shanghaiTime);

    if (difference.inDays == 0 && now.day == shanghaiTime.day) {
      return '${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1 || (difference.inDays == 0 && now.day != shanghaiTime.day)) {
      return '昨天 ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays < 7) {
      final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return '${weekdays[shanghaiTime.weekday - 1]} ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else if (shanghaiTime.year == now.year) {
      return '${shanghaiTime.month}-${shanghaiTime.day} ${shanghaiTime.hour.toString().padLeft(2, '0')}:${shanghaiTime.minute.toString().padLeft(2, '0')}';
    } else {
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
