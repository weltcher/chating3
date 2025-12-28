import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/logger.dart';

/// 权限设置页面
class PermissionSettingsPage extends StatefulWidget {
  const PermissionSettingsPage({super.key});

  @override
  State<PermissionSettingsPage> createState() => _PermissionSettingsPageState();
}

class _PermissionSettingsPageState extends State<PermissionSettingsPage> 
    with WidgetsBindingObserver {
  final Map<Permission, bool> _permissionStates = {};
  final Map<Permission, bool> _loadingStates = {};

  final List<PermissionItem> _permissions = [
    PermissionItem(
      permission: Permission.systemAlertWindow,
      title: '在其他应用上层显示',
      description: '允许应用在其他应用上方显示内容（包括后台弹窗和悬浮窗），用于来电提醒等功能。',
      icon: Icons.layers,
      isSpecialPermission: true,
    ),
    PermissionItem(
      permission: Permission.notification,
      title: '通知权限',
      description: '允许应用发送通知，用于接收新消息提醒。',
      icon: Icons.notifications,
      isSpecialPermission: false,
    ),
    PermissionItem(
      permission: Permission.camera,
      title: '相机',
      description: '允许应用使用相机拍照和录制视频。',
      icon: Icons.camera_alt,
      isSpecialPermission: false,
    ),
    PermissionItem(
      permission: Permission.microphone,
      title: '麦克风',
      description: '允许应用录制音频。',
      icon: Icons.mic,
      isSpecialPermission: false,
    ),
    PermissionItem(
      permission: Permission.storage,
      title: '存储',
      description: '允许应用读取和写入设备存储。',
      icon: Icons.storage,
      isSpecialPermission: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 只检查权限状态，不主动请求
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // 当应用从后台返回前台时，重新检查权限状态
    if (state == AppLifecycleState.resumed) {
      logger.debug('应用返回前台，重新检查权限状态');
      _checkAllPermissions();
    }
  }

  Future<void> _checkAllPermissions() async {
    // 首先检查系统弹窗权限状态
    bool systemAlertGranted = false;
    try {
      final systemAlertStatus = await Permission.systemAlertWindow.status;
      systemAlertGranted = systemAlertStatus.isGranted;
    } catch (e) {
      logger.debug('检查系统弹窗权限失败: $e');
    }

    for (final item in _permissions) {
      try {
        if (item.permission == Permission.systemAlertWindow) {
          // 对于系统弹窗权限相关的项，统一使用相同的权限状态
          if (mounted) {
            setState(() {
              _permissionStates[item.permission] = systemAlertGranted;
              _loadingStates[item.permission] = false;
            });
          }
        } else {
          // 其他权限正常检查
          final status = await item.permission.status;
          if (mounted) {
            setState(() {
              _permissionStates[item.permission] = status.isGranted;
              _loadingStates[item.permission] = false;
            });
          }
        }
      } catch (e) {
        logger.debug('检查权限状态失败: $e');
        if (mounted) {
          setState(() {
            _permissionStates[item.permission] = false;
            _loadingStates[item.permission] = false;
          });
        }
      }
    }
  }

  Future<void> _togglePermission(PermissionItem item, bool value) async {
    if (_loadingStates[item.permission] == true) return;

    setState(() {
      _loadingStates[item.permission] = true;
    });

    try {
      if (value) {
        if (item.isSpecialPermission) {
          // 特殊权限（如系统弹窗权限）需要跳转到系统设置
          await _requestSpecialPermission(item);
        } else {
          // 普通权限直接请求
          final result = await item.permission.request();
          if (mounted) {
            setState(() {
              _permissionStates[item.permission] = result.isGranted;
              _loadingStates[item.permission] = false;
            });

            if (!result.isGranted) {
              // 权限被拒绝，显示引导
              _showPermissionDeniedSnackBar(item.title);
            }
          }
        }
      } else {
        // 不能直接关闭权限，引导用户到设置页面
        openAppSettings();
        setState(() {
          _loadingStates[item.permission] = false;
        });
      }
    } catch (e) {
      logger.debug('切换权限失败: $e');
      if (mounted) {
        setState(() {
          _loadingStates[item.permission] = false;
        });
      }
    }
  }

  /// 请求特殊权限（系统弹窗权限）
  Future<void> _requestSpecialPermission(PermissionItem item) async {
    // 显示说明对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.description),
            const SizedBox(height: 16),
            // 特别提示：说明权限用途
            if (item.title == '在其他应用上层显示') ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, 
                          size: 16, 
                          color: Colors.blue[700],
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '权限用途',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue[700],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '此权限用于显示来电弹窗、悬浮窗等功能，确保您不会错过重要的通话和消息。',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.blue[900],
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              '此权限需要在系统设置中手动开启。\n点击"确定"后将跳转到系统设置页面。',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // 跳转到系统设置
      openAppSettings();
      
      // 延迟检查权限状态
      Future.delayed(const Duration(seconds: 3), () async {
        if (mounted) {
          final status = await item.permission.status;
          
          // 更新所有相关的系统弹窗权限项
          setState(() {
            for (final permissionItem in _permissions) {
              if (permissionItem.permission == Permission.systemAlertWindow) {
                _permissionStates[permissionItem.permission] = status.isGranted;
                _loadingStates[permissionItem.permission] = false;
              }
            }
          });
          
          if (status.isGranted) {
            // 显示更友好的提示信息
            _showMultiplePermissionsGrantedSnackBar();
          }
        }
      });
    } else {
      setState(() {
        _loadingStates[item.permission] = false;
      });
    }
  }

  /// 显示权限授予成功提示
  void _showPermissionGrantedSnackBar(String permissionName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$permissionName权限已开启'),
        backgroundColor: Colors.green,
      ),
    );
  }

  /// 显示多个相关权限同时授予成功的提示
  void _showMultiplePermissionsGrantedSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '在其他应用上层显示权限已开启',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _showPermissionDeniedSnackBar(String permissionName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$permissionName权限被拒绝，请在系统设置中手动开启'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '权限设置',
          style: TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
        centerTitle: false,
      ),
      body: Column(
        children: [
          // 应用信息卡片
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.hexagon,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'youdu',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    Text(
                      '版本 1.0.0',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.info_outline, color: Colors.grey),
                  onPressed: () {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 权限说明提示
          Container(
            color: Colors.blue.withOpacity(0.05),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Colors.blue[700],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '点击下方权限开关可以跳转到系统设置页面进行管理。如果某些权限未显示，请先在应用中使用相关功能。',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue[900],
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 权限列表
          Expanded(
            child: ListView.builder(
              itemCount: _permissions.length,
              itemBuilder: (context, index) {
                final item = _permissions[index];
                final isGranted = _permissionStates[item.permission] ?? false;
                final isLoading = _loadingStates[item.permission] ?? false;

                return Container(
                  color: Colors.white,
                  margin: const EdgeInsets.only(bottom: 1),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        item.icon,
                        color: Colors.grey[600],
                        size: 24,
                      ),
                    ),
                    title: Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        item.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                          height: 1.3,
                        ),
                      ),
                    ),
                    trailing: isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Switch(
                            value: isGranted,
                            onChanged: (value) => _togglePermission(item, value),
                            activeColor: Colors.blue,
                            activeTrackColor: Colors.blue.withOpacity(0.3),
                            inactiveThumbColor: Colors.grey[400],
                            inactiveTrackColor: Colors.grey[300],
                          ),
                  ),
                );
              },
            ),
          ),

        ],
      ),
    );
  }
}

/// 权限项数据模型
class PermissionItem {
  final Permission permission;
  final String title;
  final String description;
  final IconData icon;
  final bool isSpecialPermission;

  const PermissionItem({
    required this.permission,
    required this.title,
    required this.description,
    required this.icon,
    this.isSpecialPermission = false,
  });
}
