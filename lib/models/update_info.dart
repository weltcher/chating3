/// 升级信息模型
class UpdateInfo {
  final String version;           // 版本号
  final String versionCode;       // 版本代码
  final String downloadUrl;       // 下载地址
  final String releaseNotes;      // 更新说明
  final int fileSize;             // 文件大小（字节）
  final String md5;               // MD5校验值
  final bool forceUpdate;         // 是否强制更新
  final DateTime releaseDate;     // 发布日期

  UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.fileSize,
    required this.md5,
    this.forceUpdate = false,
    required this.releaseDate,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] ?? '',
      versionCode: json['version_code'] ?? '',
      downloadUrl: json['download_url'] ?? '',
      releaseNotes: json['release_notes'] ?? '',
      fileSize: json['file_size'] ?? 0,
      md5: json['md5'] ?? '',
      forceUpdate: json['force_update'] ?? false,
      releaseDate: DateTime.parse(json['release_date'] ?? DateTime.now().toIso8601String()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'version_code': versionCode,
      'download_url': downloadUrl,
      'release_notes': releaseNotes,
      'file_size': fileSize,
      'md5': md5,
      'force_update': forceUpdate,
      'release_date': releaseDate.toIso8601String(),
    };
  }

  /// 获取格式化的文件大小
  String get formattedFileSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(2)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}
