import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youdu/utils/storage.dart';
import 'package:youdu/utils/app_localizations.dart';
import 'package:youdu/main.dart';
import 'package:youdu/services/update_service.dart';
import 'package:youdu/widgets/update_dialog.dart';
import 'package:youdu/models/update_info.dart';

/// 移动端设置页面
class MobileSettingsPage extends StatefulWidget {
  const MobileSettingsPage({super.key});

  @override
  State<MobileSettingsPage> createState() => _MobileSettingsPageState();
}

class _MobileSettingsPageState extends State<MobileSettingsPage> {
  // 语言设置
  String _selectedLanguage = '简体中文';

  // 消息通知设置
  bool _newMessageSoundEnabled = false;
  bool _newMessagePopupEnabled = true;
  
  // 版本信息
  String _versionInfo = '加载中...';
  String _releaseDate = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersionInfo();
  }

  /// 加载保存的设置
  Future<void> _loadSettings() async {
    final languageCode = await Storage.getLanguage();
    final soundEnabled = await Storage.getNewMessageSoundEnabled();
    final popupEnabled = await Storage.getNewMessagePopupEnabled();

    setState(() {
      _selectedLanguage = AppLocalizations.getLanguageName(languageCode);
      _newMessageSoundEnabled = soundEnabled;
      _newMessagePopupEnabled = popupEnabled;
    });
  }
  
  /// 加载版本信息
  Future<void> _loadVersionInfo() async {
    try {
      final versionData = await UpdateService.getCurrentVersion();
      final version = versionData['version'] ?? '未知';
      final versionCode = versionData['versionCode'] ?? version;
      
      // 格式化版本号：v1.0.4-1765520149
      String formattedVersion;
      if (version != versionCode && versionCode.isNotEmpty) {
        formattedVersion = 'v$version-$versionCode';
      } else {
        formattedVersion = 'v$version';
      }
      
      setState(() {
        _versionInfo = formattedVersion;
      });
    } catch (e) {
      setState(() {
        _versionInfo = 'v1.0.0';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90E2),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          i18n.translate('settings'),
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          // 设置项列表（去掉分组标题）
          Container(
            color: Colors.white,
            child: Column(
              children: [
                _buildLanguageSetting(),
                const Divider(height: 1, indent: 16),
                _buildSwitchItem(
                  title: i18n.translate('new_message_sound'),
                  value: _newMessageSoundEnabled,
                  onChanged: (value) async {
                    setState(() {
                      _newMessageSoundEnabled = value;
                    });
                    // 保存到本地存储
                    await Storage.saveNewMessageSoundEnabled(value);
                  },
                ),
                const Divider(height: 1, indent: 16),
                _buildSwitchItem(
                  title: i18n.translate('new_message_popup'),
                  value: _newMessagePopupEnabled,
                  onChanged: (value) async {
                    setState(() {
                      _newMessagePopupEnabled = value;
                    });
                    // 保存到本地存储
                    await Storage.saveNewMessagePopupEnabled(value);
                  },
                ),
                const Divider(height: 1, indent: 16),
                _buildArrowItem(
                  title: i18n.translate('about'),
                  subtitle: _versionInfo,
                  onTap: () {
                    _showAboutDialog();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          // 版权信息
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                i18n.translate('copyright'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// 语言设置项
  Widget _buildLanguageSetting() {
    final i18n = AppLocalizations.of(context);
    return InkWell(
      onTap: () {
        _showLanguageDialog();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Text(
              i18n.translate('language_setting'),
              style: const TextStyle(fontSize: 16, color: Color(0xFF333333)),
            ),
            const Spacer(),
            Text(
              _selectedLanguage,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 20, color: Color(0xFFCCCCCC)),
          ],
        ),
      ),
    );
  }

  /// 开关设置项
  Widget _buildSwitchItem({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, color: Color(0xFF333333)),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: const Color(0xFF4A90E2),
          ),
        ],
      ),
    );
  }

  /// 箭头设置项
  Widget _buildArrowItem({
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16, color: Color(0xFF333333)),
              ),
            ),
            if (subtitle != null) ...[
              Text(
                subtitle,
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.chevron_right, size: 20, color: Color(0xFFCCCCCC)),
          ],
        ),
      ),
    );
  }

  /// 显示语言选择对话框
  void _showLanguageDialog() {
    final i18n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.translate('language_setting')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildLanguageOption('简体中文'),
            _buildLanguageOption('English'),
            _buildLanguageOption('繁體中文'),
          ],
        ),
      ),
    );
  }

  /// 语言选项
  Widget _buildLanguageOption(String language) {
    final isSelected = _selectedLanguage == language;
    return RadioListTile<String>(
      title: Text(language),
      value: language,
      groupValue: _selectedLanguage,
      activeColor: const Color(0xFF4A90E2),
      selected: isSelected,
      onChanged: (value) async {
        if (value == null) return;

        setState(() {
          _selectedLanguage = value;
        });

        // 将语言名称转换为语言代码
        final languageCode = AppLocalizations.getLanguageCode(value);

        // 保存到本地存储
        await Storage.saveLanguage(languageCode);

        // 立即切换应用语言
        final locale = AppLocalizations.getLocaleFromCode(languageCode);
        if (mounted) {
          MyApp.setLocale(context, locale);
          Navigator.pop(context); // 关闭对话框
        }
      },
    );
  }

  /// 显示关于对话框
  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => const _AboutDialog(),
    );
  }

  /// 信息行
  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Text(
          '$label：',
          style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
        ),
      ],
    );
  }
}

/// 关于对话框
class _AboutDialog extends StatefulWidget {
  const _AboutDialog();

  @override
  State<_AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<_AboutDialog> {
  bool _isLoadingVersion = true;
  bool _isChecking = true;
  bool _hasUpdate = false;
  String _currentVersion = '';
  String _statusText = '';
  String? _newVersion;
  String? _releaseNotes;
  UpdateInfo? _updateInfo; // 保存完整的更新信息

  @override
  void initState() {
    super.initState();
    _loadVersionAndCheckUpdate();
  }

  /// 加载版本信息并检查更新（每次都实时查询接口）
  Future<void> _loadVersionAndCheckUpdate() async {
    // 1. 先实时查询当前版本
    try {
      final versionData = await UpdateService.getCurrentVersion();
      final version = versionData['version'] ?? '未知';
      final versionCode = versionData['versionCode'] ?? version;
      
      // 格式化版本号：v1.0.4-1765520149
      String formattedVersion;
      if (version != versionCode && versionCode.isNotEmpty) {
        formattedVersion = 'v$version-$versionCode';
      } else {
        formattedVersion = 'v$version';
      }
      
      if (mounted) {
        setState(() {
          _currentVersion = formattedVersion;
          _isLoadingVersion = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentVersion = 'v1.0.0';
          _isLoadingVersion = false;
        });
      }
    }

    // 2. 再检查更新
    await _checkForUpdate();
  }

  /// 检查更新
  Future<void> _checkForUpdate() async {
    try {
      final updateService = UpdateService();
      final updateInfo = await updateService.checkUpdate();

      if (mounted) {
        final i18n = AppLocalizations.of(context);
        if (updateInfo != null) {
          setState(() {
            _isChecking = false;
            _hasUpdate = true;
            _updateInfo = updateInfo; // 保存完整的更新信息
            _newVersion = updateInfo.version;
            _releaseNotes = updateInfo.releaseNotes;
            _statusText = '${i18n.translate('new_version_available')} ${updateInfo.version}';
          });
        } else {
          setState(() {
            _isChecking = false;
            _hasUpdate = false;
            _statusText = i18n.translate('no_update');
          });
        }
      }
    } catch (e) {
      if (mounted) {
        final i18n = AppLocalizations.of(context);
        setState(() {
          _isChecking = false;
          _hasUpdate = false;
          _statusText = i18n.translate('no_update');
        });
      }
    }
  }

  /// 开始更新
  void _startUpdate() async {
    // 检查是否有保存的更新信息
    final updateInfo = _updateInfo;
    if (updateInfo == null) {
      return;
    }

    // iOS 平台：直接打开浏览器访问下载链接
    if (Platform.isIOS) {
      await _openDownloadUrlInBrowser(updateInfo.downloadUrl);
      return;
    }

    // 关闭当前对话框
    Navigator.pop(context);

    // 直接使用已检查到的更新信息显示更新对话框
    if (mounted) {
      await UpdateDialog.show(
        context,
        updateInfo,
        onUpdateComplete: () {
          // 更新完成回调
        },
      );
    }
  }

  /// iOS 平台：打开系统浏览器访问下载链接
  Future<void> _openDownloadUrlInBrowser(String downloadUrl) async {
    if (downloadUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载链接为空')),
      );
      return;
    }

    try {
      final uri = Uri.parse(downloadUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        // 关闭对话框
        if (mounted) {
          Navigator.pop(context);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开下载链接')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开下载链接失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    // 初始化默认文本
    if (_currentVersion.isEmpty) {
      _currentVersion = i18n.translate('loading');
    }
    if (_statusText.isEmpty) {
      _statusText = i18n.translate('checking_update');
    }
    
    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF4A90E2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.chat_bubble,
              size: 28,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Text(i18n.translate('app_title')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow(i18n.translate('version_number').replaceAll('：', '').replaceAll(':', ''), _currentVersion),
          const SizedBox(height: 24),
          if (_isChecking)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  i18n.translate('checking_update'),
                  style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
                ),
              ],
            )
          else ...[
            Text(
              _statusText,
              style: TextStyle(
                fontSize: 14,
                color: _hasUpdate ? const Color(0xFF4A90E2) : const Color(0xFF666666),
                fontWeight: _hasUpdate ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            if (_hasUpdate && _releaseNotes != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _releaseNotes!,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
                ),
              ),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_hasUpdate ? i18n.translate('later') : i18n.translate('confirm')),
        ),
        if (_hasUpdate)
          ElevatedButton(
            onPressed: _startUpdate,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90E2),
              foregroundColor: Colors.white,
            ),
            child: Text(i18n.translate('update_now')),
          ),
      ],
    );
  }

  /// 信息行
  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Text(
          '$label：',
          style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
        ),
      ],
    );
  }
}
