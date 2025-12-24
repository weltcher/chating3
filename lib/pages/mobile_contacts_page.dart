import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart'; // 🔴 添加WebSocket服务
import '../models/contact_model.dart';
import '../models/group_model.dart';
import '../utils/logger.dart';
import '../utils/app_localizations.dart';
import '../utils/storage.dart';
import '../utils/sort_helper.dart';
import 'mobile_chat_page.dart';
import 'mobile_create_group_page.dart';
import 'mobile_home_page.dart'; // 🔴 新增：导入以访问 MobileChatListPage

/// 移动端通讯录页面
class MobileContactsPage extends StatefulWidget {
  final Function(int pendingCount)? onPendingCountChanged; // 待审核数量变化回调

  const MobileContactsPage({
    Key? key,
    this.onPendingCountChanged,
  }) : super(key: key);

  @override
  State<MobileContactsPage> createState() => _MobileContactsPageState();

  // 🔴 静态 StreamController：用于通知页面刷新
  static final StreamController<void> _refreshController = 
      StreamController<void>.broadcast();

  // 🔴 静态方法：清除缓存并通知刷新（供外部调用）
  static void clearCacheAndRefresh() {
    _MobileContactsPageState._clearStaticCache();
    _refreshController.add(null); // 发送刷新信号
  }

  /// 清除所有通讯录缓存（公开静态方法，供登录后调用）
  static void clearAllCache() {
    _MobileContactsPageState._clearStaticCache();
    logger.info('🗑️ [MobileContactsPage] 已清除所有通讯录缓存');
  }
}

class _MobileContactsPageState extends State<MobileContactsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 联系人相关
  List<ContactModel> _contacts = [];
  bool _isLoadingContacts = false; // 🔴 默认false，不显示加载动画
  String? _contactsError;

  // 群组相关
  List<GroupModel> _groups = [];
  bool _isLoadingGroups = false; // 🔴 默认false，不显示加载动画
  String? _groupsError;

  // 群通知相关（待审核的群组成员）
  List<Map<String, dynamic>> _pendingGroupMembers = [];
  bool _isLoadingPendingMembers = false; // 🔴 默认false，不显示加载动画
  String? _pendingMembersError;

  // 搜索
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  
  // 当前用户ID
  int? _currentUserId;

  // 🔴 新增：刷新监听器
  StreamSubscription<void>? _refreshSubscription;

  // 🔴 网络连接状态
  final WebSocketService _wsService = WebSocketService();
  bool _isConnecting = false; // 是否正在连接网络
  bool _isNetworkConnected = false; // 网络是否已连接
  Timer? _networkStatusTimer; // 网络状态监听定时器

  // 🔴 新增：缓存相关
  static List<ContactModel>? _cachedContacts;
  static List<GroupModel>? _cachedGroups;
  static List<Map<String, dynamic>>? _cachedPendingMembers;
  static Map<int, int>? _cachedGroupMemberCounts; // 群组成员数量缓存
  static DateTime? _cacheTimestamp;
  static const Duration _cacheDuration = Duration(minutes: 5); // 缓存5分钟
  static const int _apiVersion = 4; // API版本号，变更API时递增此值
  static int? _cachedApiVersion;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 2);

    // 🔴 同步加载缓存数据
    final bool hasCache = _isCacheValid();
    if (hasCache) {
      _contacts = _cachedContacts != null ? List.from(_cachedContacts!) : [];
      _groups = _cachedGroups != null ? List.from(_cachedGroups!) : [];
      _pendingGroupMembers = _cachedPendingMembers != null
          ? List.from(_cachedPendingMembers!)
          : [];
      logger.debug('📦 [同步] 使用缓存的通讯录数据');
      logger.debug('  - 联系人: ${_contacts.length}条');
      logger.debug('  - 群组: ${_groups.length}条');
      logger.debug('  - 待审核: ${_pendingGroupMembers.length}条');
      if (_cachedGroupMemberCounts != null) {
        logger.debug('  - 群组成员数量缓存: ${_cachedGroupMemberCounts!.length}个群组');
      }
    }

    // 异步加载数据（如果缓存过期会重新获取）
    _loadData();
    
    // 🔴 初始化当前用户ID并通知待审核数量
    _initCurrentUserId().then((_) {
      // 只有在有缓存数据时才立即通知（避免通知0）
      // 如果没有缓存，等待 _loadContacts() 完成后会自动通知
      if (hasCache && _contacts.isNotEmpty) {
        logger.debug('📢 [初始化] 使用缓存数据通知待审核数量');
        _notifyPendingCount();
      } else {
        logger.debug('📢 [初始化] 无缓存或缓存为空，等待数据加载完成后通知');
      }
    });

    // 🔴 监听刷新信号
    _refreshSubscription = MobileContactsPage._refreshController.stream.listen((_) {
      logger.debug('📢 收到刷新信号，重新加载通讯录数据（联系人、群组、待审核成员）');
      // 同时刷新联系人、群组和待审核成员
      _loadContacts();
      _loadGroups();
      _loadPendingGroupMembers();
    });

    // 🔴 设置网络状态监听
    _setupNetworkStatusListener();
    
    // 🔴 检查初始连接状态，如果未连接则触发真正的刷新
    if (!_wsService.isConnected) {
      setState(() {
        _isConnecting = true;
      });
      logger.debug('🔄 [网络状态-通讯录] 应用启动时检测到未连接，显示正在刷新并触发重连...');
      // 🔴 关键修复：触发真正的刷新操作
      _performRealRefresh();
    }
  }

  // 🔴 新增：执行真正的刷新操作，会循环尝试重连直到成功
  Future<void> _performRealRefresh() async {
    logger.debug('🔄 [自动刷新-通讯录] 开始执行真正的刷新操作...');
    
    const int retryIntervalSeconds = 3; // 重试间隔（秒）
    const int maxRetries = 100; // 最大重试次数，防止无限循环
    int retryCount = 0;
    
    while (mounted && retryCount < maxRetries) {
      retryCount++;
      logger.debug('🔌 [自动刷新-通讯录] 第 $retryCount 次尝试重新连接WebSocket...');
      
      try {
        // 1. 尝试重新连接WebSocket
        await _wsService.connect();
        
        // 2. 等待连接建立
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 3. 检查是否连接成功
        if (_wsService.isConnected) {
          logger.debug('✅ [自动刷新-通讯录] WebSocket连接成功！');
          
          // 4. 重新加载所有数据
          logger.debug('📋 [自动刷新-通讯录] 刷新通讯录数据...');
          await Future.wait([
            _loadContacts(),
            _loadGroups(),
            _loadPendingGroupMembers(),
          ]);
          
          logger.debug('✅ [自动刷新-通讯录] 刷新完成');
          
          // 5. 连接成功，隐藏刷新状态并退出循环
          if (mounted) {
            setState(() {
              _isConnecting = false;
            });
            logger.debug('🎯 [自动刷新-通讯录] 已隐藏刷新提示');
          }
          return; // 退出循环
        } else {
          logger.debug('⚠️ [自动刷新-通讯录] 连接未成功，${retryIntervalSeconds}秒后重试...');
        }
      } catch (e) {
        logger.error('❌ [自动刷新-通讯录] 第 $retryCount 次连接失败: $e');
      }
      
      // 等待一段时间后重试
      if (mounted && retryCount < maxRetries) {
        await Future.delayed(Duration(seconds: retryIntervalSeconds));
      }
    }
    
    // 达到最大重试次数仍未成功
    if (mounted) {
      logger.debug('⚠️ [自动刷新-通讯录] 达到最大重试次数 $maxRetries，停止重试');
      setState(() {
        _isConnecting = false;
      });
    }
  }

  // 初始化当前用户ID
  Future<void> _initCurrentUserId() async {
    try {
      _currentUserId = await Storage.getUserId();
      if (mounted) {
        setState(() {}); // 触发UI更新
      }
    } catch (e) {
      logger.debug('获取当前用户ID失败: $e');
    }
  }

  // 🔴 检查缓存是否有效
  bool _isCacheValid() {
    // 检查API版本号，如果不匹配则清除缓存
    if (_cachedApiVersion != _apiVersion) {
      logger.debug('📦 API版本变更 ($_cachedApiVersion -> $_apiVersion)，清除缓存');
      _clearCache();
      return false;
    }
    
    // 检查缓存时间戳
    if (_cacheTimestamp == null) {
      return false;
    }
    
    // 检查缓存是否过期
    final now = DateTime.now();
    final isNotExpired = now.difference(_cacheTimestamp!) < _cacheDuration;
    
    // 只要联系人或群组任一缓存存在且未过期，就认为缓存有效
    if (isNotExpired && (_cachedContacts != null || _cachedGroups != null)) {
      return true;
    }
    
    return false;
  }

  // 🔴 清除缓存（实例方法）
  void _clearCache() {
    _clearStaticCache();
  }

  // 🔴 清除缓存（静态方法，供外部调用）
  static void _clearStaticCache() {
    _cachedContacts = null;
    _cachedGroups = null;
    _cachedPendingMembers = null;
    _cachedGroupMemberCounts = null;
    _cacheTimestamp = null;
    _cachedApiVersion = null;
    logger.debug('🗑️ 通讯录缓存已清除');
  }

  // 🔴 更新缓存时间戳
  void _updateCacheTimestamp() {
    _cacheTimestamp = DateTime.now();
    _cachedApiVersion = _apiVersion; // 同时更新API版本号
  }

  // 🔴 设置网络状态监听
  void _setupNetworkStatusListener() {
    // 取消之前的定时器（如果存在）
    _networkStatusTimer?.cancel();
    
    // 初始化网络连接状态
    _isNetworkConnected = _wsService.isConnected;
    
    // 监听WebSocket连接状态变化
    _networkStatusTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final currentConnected = _wsService.isConnected;
      
      // 检测连接状态变化
      if (currentConnected != _isNetworkConnected) {
        setState(() {
          _isNetworkConnected = currentConnected;
          
          if (!currentConnected && !_isConnecting) {
            // 连接断开，显示正在刷新
            _isConnecting = true;
            logger.debug('🔄 [网络状态-通讯录] 检测到连接断开，显示正在刷新...');
          } else if (currentConnected && _isConnecting) {
            // 重连成功，开始数据同步（但不立即隐藏刷新提示）
            logger.debug('✅ [网络状态-通讯录] 重连成功，开始数据同步和UI渲染...');
            
            // 异步执行数据同步和UI渲染，完成后才隐藏刷新提示
            _syncDataAfterReconnect().then((_) {
              if (mounted) {
                setState(() {
                  _isConnecting = false; // 数据同步和UI渲染完成后才隐藏提示
                });
                logger.debug('🎯 [网络状态-通讯录] 数据同步和UI渲染完成，已隐藏刷新提示');
              }
            }).catchError((error) {
              logger.error('❌ [网络状态-通讯录] 数据同步失败，隐藏刷新提示', error: error);
              if (mounted) {
                setState(() {
                  _isConnecting = false; // 即使失败也要隐藏提示
                });
              }
            });
          }
        });
      }
    });
  }

  // 🔴 网络重连后同步数据
  Future<void> _syncDataAfterReconnect() async {
    try {
      logger.debug('🔄 [数据同步-通讯录] 开始重连后数据同步...');
      
      // 1. 清空所有缓存
      _clearStaticCache();
      logger.debug('🗑️ [数据同步-通讯录] 已清空所有缓存');
      
      // 2. 重新加载所有数据
      await Future.wait([
        _loadContacts(),
        _loadGroups(), 
        _loadPendingGroupMembers(),
      ]);
      
      // 3. 等待UI完全渲染完成后才隐藏"正在刷新..."提示
      logger.debug('🎨 [UI渲染-通讯录] 等待通讯录UI完全渲染完成...');
      
      // 使用WidgetsBinding确保UI渲染完成
      if (mounted) {
        await WidgetsBinding.instance.endOfFrame;
        
        // 额外等待一帧，确保TabBarView和ListView完全构建完成
        await Future.delayed(const Duration(milliseconds: 100));
        
        // 确保UI完全渲染后才隐藏刷新提示
        if (mounted) {
          setState(() {
            // 这里不需要设置任何状态，只是触发一次渲染检查
          });
          
          // 再等待一帧确保setState完成
          await WidgetsBinding.instance.endOfFrame;
          
          logger.debug('✅ [UI渲染-通讯录] 通讯录UI渲染完成，可以隐藏刷新提示');
        }
      }
      
      logger.debug('✅ [数据同步-通讯录] 重连后数据同步和UI渲染完成');
    } catch (e) {
      logger.error('❌ [数据同步-通讯录] 重连后数据同步失败', error: e);
    }
  }

  // 🔴 下拉刷新方法
  Future<void> _onRefresh() async {
    logger.debug('🔄 [下拉刷新-通讯录] 用户触发下拉刷新');
    
    setState(() {
      _isConnecting = true;
    });
    
    try {
      // 尝试重新连接WebSocket
      await _wsService.connect();
      
      // 重新加载数据
      await _loadData();
      
      logger.debug('✅ [下拉刷新-通讯录] 刷新完成');
    } catch (e) {
      logger.error('❌ [下拉刷新-通讯录] 刷新失败', error: e);
    }
    
    // 延迟1秒后隐藏刷新状态
    Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _refreshSubscription?.cancel(); // 🔴 取消刷新监听
    _networkStatusTimer?.cancel(); // 🔴 取消网络状态监听定时器
    super.dispose();
  }

  Future<void> _loadData() async {
    // 🔴 如果缓存有效且所有数据都已加载，跳过
    // 注意：必须同时检查联系人和群组，避免部分数据缺失
    final hasCompleteCache = _isCacheValid() && 
                             (_contacts.isNotEmpty || _groups.isNotEmpty);
    
    if (hasCompleteCache) {
      logger.debug('📦 缓存有效且完整，跳过数据加载');
      return;
    }

    logger.debug('📦 缓存无效或不完整，重新加载数据');
    await Future.wait([
      _loadContacts(),
      _loadGroups(),
      _loadPendingGroupMembers(),
    ]);
  }

  Future<void> _loadContacts() async {
    try {
      // 🔴 不再设置 loading 状态，避免显示转圈动画

      final token = await Storage.getToken();
      if (token == null) {
        throw Exception('No token found');
      }

      // 同时获取已通过审核的联系人和待审核的联系人申请
      final results = await Future.wait([
        ApiService.getContacts(token: token),
        ApiService.getPendingContactRequests(token: token),
      ]);

      final contactsResponse = results[0];
      final requestsResponse = results[1];

      logger.debug('成功获取联系人响应: ${contactsResponse['code']}');
      logger.debug('成功获取待审核申请响应: ${requestsResponse['code']}');

      // 解析已通过审核的联系人
      final contactsData = contactsResponse['data']?['contacts'] as List?;
      final approvedContacts = (contactsData ?? [])
          .map((json) => ContactModel.fromJson(json as Map<String, dynamic>))
          .toList();

      // 解析待审核的联系人申请
      final requestsData = requestsResponse['data']?['requests'] as List?;
      final pendingRequests = (requestsData ?? [])
          .map((json) => ContactModel.fromJson(json as Map<String, dynamic>))
          .toList();

      // 合并两个列表
      final contacts = [...approvedContacts, ...pendingRequests];

      logger.debug('成功加载联系人列表: 已通过 ${approvedContacts.length} 个, 待审核 ${pendingRequests.length} 个, 总计 ${contacts.length} 个');

      await Storage.syncPendingContactsFromModels(contacts);

      if (mounted) {
        setState(() {
          _contacts = contacts;
          _isLoadingContacts = false;
          _contactsError = null;
        });

        // 🔴 更新缓存
        _cachedContacts = List.from(contacts);
        _updateCacheTimestamp();
        logger.debug('💾 联系人缓存已更新');

        _notifyPendingCount();
      }
    } catch (e) {
      logger.error('加载联系人失败: $e');
      if (mounted) {
        setState(() {
          _contactsError = e.toString();
          _isLoadingContacts = false;
        });
      }
    }
  }

  Future<void> _loadGroups() async {
    try {
      // 🔴 检查缓存是否有效，如果有效则直接使用缓存数据
      if (_isCacheValid() && _cachedGroups != null) {
        if (mounted) {
          setState(() {
            _groups = List.from(_cachedGroups!);
            _isLoadingGroups = false;
            _groupsError = null;
          });
          logger.debug('📦 [群组] 使用缓存数据: ${_groups.length}条');
          if (_cachedGroupMemberCounts != null) {
            logger.debug('📦 [群组成员数量] 使用缓存数据: ${_cachedGroupMemberCounts!.length}个群组');
          }
        }
        return;
      }

      // 🔴 不再设置 loading 状态，避免显示转圈动画

      final token = await Storage.getToken();
      if (token == null) {
        throw Exception('No token found');
      }

      final response = await ApiService.getUserGroups(token: token);
      final groupsData = response['data']['groups'] as List?;
      final groups = (groupsData ?? [])
          .map((json) => GroupModel.fromJson(json))
          .toList();

      // 🔴 同时获取并缓存每个群组的成员数量
      final Map<int, int> memberCounts = {};
      if (groups.isNotEmpty) {
        logger.debug('📊 [群组成员数量] 开始获取 ${groups.length} 个群组的成员数量');
        final countFutures = groups.map((group) async {
          try {
            final count = await _fetchGroupMemberCount(group.id, token);
            memberCounts[group.id] = count;
            return count;
          } catch (e) {
            logger.debug('获取群组 ${group.id} 成员数量失败: $e');
            memberCounts[group.id] = 0;
            return 0;
          }
        }).toList();
        
        await Future.wait(countFutures);
        logger.debug('📊 [群组成员数量] 完成获取 ${memberCounts.length} 个群组的成员数量');
      }

      if (mounted) {
        setState(() {
          _groups = groups;
          _isLoadingGroups = false;
          _groupsError = null;
        });

        // 🔴 更新缓存（包括群组列表和成员数量）
        _cachedGroups = List.from(groups);
        _cachedGroupMemberCounts = Map.from(memberCounts);
        _updateCacheTimestamp();
        logger.debug('💾 群组缓存已更新 (${groups.length}条)');
        logger.debug('💾 群组成员数量缓存已更新 (${memberCounts.length}个群组)');
      }
    } catch (e) {
      logger.error('加载群组失败: $e');
      if (mounted) {
        setState(() {
          _groupsError = e.toString();
          _isLoadingGroups = false;
        });
      }
    }
  }

  // 🔴 获取群组成员数量（用于缓存）
  Future<int> _fetchGroupMemberCount(int groupId, String token) async {
    try {
      final response = await ApiService.getGroupDetail(
        token: token,
        groupId: groupId,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final data = response['data'];
        final members = data['members'] as List?;
        if (members != null) {
          // 只统计已通过审核的成员（approval_status = 'approved'）
          // 排除待审核（pending）和已移除（rejected）的成员
          final approvedMembers = members.where((m) {
            final approvalStatus = m['approval_status'] as String? ?? 'approved';
            return approvalStatus == 'approved';
          }).toList();

          return approvedMembers.length;
        }
      }
    } catch (e) {
      logger.debug('获取群组 $groupId 成员数量失败: $e');
    }
    
    return 0;
  }

  // 加载待审核的群组成员
  Future<void> _loadPendingGroupMembers() async {
    if (!mounted) return;

    // 🔴 不再设置 loading 状态

    try {
      final token = await Storage.getToken();
      if (token == null) {
        if (mounted) {
          setState(() {
            _isLoadingPendingMembers = false;
            _pendingMembersError = '未登录';
          });
        }
        return;
      }

      // 获取所有群组
      final groupsResponse = await ApiService.getUserGroups(token: token);
      if (!mounted) return;

      if (groupsResponse['code'] != 0) {
        if (mounted) {
          setState(() {
            _isLoadingPendingMembers = false;
            _pendingMembersError = groupsResponse['message'] ?? '加载群组失败';
          });
        }
        return;
      }

      final groupsData = groupsResponse['data']['groups'] as List?;
      if (groupsData == null || groupsData.isEmpty) {
        if (mounted) {
          setState(() {
            _pendingGroupMembers = [];
            _isLoadingPendingMembers = false;
          });

          // 🔴 更新缓存
          _cachedPendingMembers = [];
          _updateCacheTimestamp();
        }
        return;
      }

      // 遍历每个群组，获取待审核成员
      final List<Map<String, dynamic>> allPendingMembers = [];

      for (var groupJson in groupsData) {
        if (!mounted) return; // 检查是否还在树中

        final groupId = groupJson['id'] as int;
        final groupName = groupJson['name'] as String;

        // 获取群组详情
        final detailResponse = await ApiService.getGroupDetail(
          token: token,
          groupId: groupId,
        );

        if (!mounted) return; // 每次异步操作后检查

        if (detailResponse['code'] == 0 && detailResponse['data'] != null) {
          final data = detailResponse['data'];
          final groupData = data['group'] as Map<String, dynamic>?;
          final members = data['members'] as List?;
          final memberRole = data['member_role'] as String?;

          // 获取群组的邀请确认状态
          final inviteConfirmation =
              groupData?['invite_confirmation'] as bool? ?? false;

          // 只有开启了"群聊邀请确认"的群组，且当前用户是群主或管理员时，才显示待审核成员
          if (inviteConfirmation &&
              (memberRole == 'owner' || memberRole == 'admin')) {
            if (members != null) {
              // 筛选出待审核的成员（approval_status = 'pending'）
              for (var member in members) {
                final approvalStatus =
                    member['approval_status'] as String? ?? 'approved';
                if (approvalStatus == 'pending') {
                  allPendingMembers.add({
                    'groupId': groupId,
                    'groupName': groupName,
                    'userId': member['user_id'],
                    'displayName':
                        member['full_name'] ?? member['username'] ?? '未知用户',
                    'avatar': member['avatar'],
                    'joinedAt': member['joined_at'],
                  });
                }
              }
            }
          }
        }
      }

      if (!mounted) return;

      setState(() {
        _pendingGroupMembers = allPendingMembers;
        _isLoadingPendingMembers = false;
      });

      // 🔴 更新缓存
      _cachedPendingMembers = List.from(allPendingMembers);
      _updateCacheTimestamp();
      logger.debug('💾 待审核成员缓存已更新 (${allPendingMembers.length}条)');

      logger.debug('成功加载待审核群组成员: ${allPendingMembers.length} 个');
      _notifyPendingCount();
    } catch (e) {
      logger.error('加载待审核群组成员失败: $e');
      if (mounted) {
        setState(() {
          _pendingMembersError = e.toString();
          _isLoadingPendingMembers = false;
        });
      }
    }
  }

  // 新联系人（待审核的联系人）
  List<ContactModel> get _filteredNewContacts {
    // 使用已存储的当前用户ID，如果为空则返回空列表
    if (_currentUserId == null) return [];
    
    var pendingContacts = _contacts.where((c) => c.isPendingForUser(_currentUserId!)).toList();
    
    // 按名称首字母排序
    pendingContacts = SortHelper.sortContactsByName(
      pendingContacts,
      (contact) => contact.displayName,
    );
    
    if (_searchText.isEmpty) return pendingContacts;

    return pendingContacts.where((contact) {
      final name = (contact.fullName ?? contact.username).toLowerCase();
      final search = _searchText.toLowerCase();
      return name.contains(search);
    }).toList();
  }

  // 待审核的群组成员
  List<Map<String, dynamic>> get _filteredPendingMembers {
    if (_searchText.isEmpty) return _pendingGroupMembers;

    return _pendingGroupMembers.where((member) {
      final name = (member['displayName'] as String).toLowerCase();
      final groupName = (member['groupName'] as String).toLowerCase();
      final search = _searchText.toLowerCase();
      return name.contains(search) || groupName.contains(search);
    }).toList();
  }

  // 联系人（已通过审核的）
  List<ContactModel> get _filteredContacts {
    // 过滤出已通过审核、未删除的联系人（包括被拉黑的联系人）
    var approvedContacts = _contacts
        .where((c) => c.isApproved && !c.isDeleted)
        .toList();
    
    // 按名称首字母排序
    approvedContacts = SortHelper.sortContactsByName(
      approvedContacts,
      (contact) => contact.displayName,
    );
    
    if (_searchText.isEmpty) return approvedContacts;

    return approvedContacts.where((contact) {
      final name = (contact.fullName ?? contact.username).toLowerCase();
      final search = _searchText.toLowerCase();
      return name.contains(search);
    }).toList();
  }

  List<GroupModel> get _filteredGroups {
    // 按名称首字母排序
    var sortedGroups = SortHelper.sortGroupsByName(
      _groups,
      (group) => group.name,
    );
    
    if (_searchText.isEmpty) return sortedGroups;

    return sortedGroups.where((group) {
      final name = group.name.toLowerCase();
      final search = _searchText.toLowerCase();
      return name.contains(search);
    }).toList();
  }

  // 通知父组件待审核数量变化
  void _notifyPendingCount() {
    if (widget.onPendingCountChanged != null) {
      final newContactCount = _currentUserId != null 
          ? _contacts.where((c) => c.isPendingForUser(_currentUserId!)).length 
          : 0;
      final groupNotificationCount = _pendingGroupMembers.length;
      final totalCount = newContactCount + groupNotificationCount;

      logger.debug(
        '📊 通讯录待审核数量 - 新联系人: $newContactCount, 群通知: $groupNotificationCount, 总计: $totalCount',
      );

      widget.onPendingCountChanged!(totalCount);
    }
  }

  void _showCreateGroupDialog() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MobileCreateGroupPage(
          contacts: _contacts,
          onCreateGroup: (group) {
            // 创建成功后清除缓存并重新加载
            logger.debug('🔄 创建群组成功（onCreateGroup回调），清除缓存并强制重新加载群组');
            _clearCache();
            // 直接强制重新加载群组列表，不依赖缓存检查
            _loadGroups();
          },
        ),
      ),
    );

    // 如果创建成功，清除缓存并重新加载所有数据
    if (result == true) {
      logger.debug('🔄 创建群组成功（返回标记），清除缓存并强制重新加载群组');
      _clearCache();
      // 直接强制重新加载群组列表，不依赖缓存检查
      _loadGroups();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        // 搜索框
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFFEEF1F6),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.translate('search_contacts'),
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(25),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
            ),
            onChanged: (value) {
              setState(() => _searchText = value);
            },
          ),
        ),

        // Tab栏
        Container(
          color: Colors.white,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 计算每个tab的宽度
              final double totalWidth = constraints.maxWidth;
              final double firstTabWidth =
                  (totalWidth / 4) + 32; // 第一个tab额外加32像素
              final double otherTabWidth =
                  (totalWidth - firstTabWidth) / 3; // 其他3个tab均分剩余空间

              return TabBar(
                controller: _tabController,
                labelColor: const Color(0xFF4A90E2),
                unselectedLabelColor: Colors.grey[600],
                indicatorColor: const Color(0xFF4A90E2),
                labelPadding: EdgeInsets.zero,
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: [
                  Tab(
                    child: SizedBox(
                      width: firstTabWidth,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppLocalizations.of(context).translate('new_contacts')),
                          if (_filteredNewContacts.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_filteredNewContacts.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Tab(
                    child: SizedBox(
                      width: otherTabWidth,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppLocalizations.of(context).translate('group_notifications')),
                          if (_filteredPendingMembers.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_filteredPendingMembers.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Tab(
                    child: SizedBox(
                      width: otherTabWidth,
                      child: Center(child: Text(l10n.translate('contacts_tab'))),
                    ),
                  ),
                  Tab(
                    child: SizedBox(
                      width: otherTabWidth,
                      child: Center(child: Text(AppLocalizations.of(context).translate('groups'))),
                    ),
                  ),
                ],
              );
            },
          ),
        ),

        // Tab内容
        Expanded(
          child: Container(
            color: const Color(0xFFEEF1F6),
            child: TabBarView(
              controller: _tabController,
              children: [
                // 新联系人列表
                _buildNewContactsList(),

                // 群通知列表
                _buildPendingMembersList(),

                // 联系人列表
                _buildContactsList(),

                // 群组列表
                _buildGroupsList(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 新联系人列表（待审核的联系人）
  Widget _buildNewContactsList() {
    if (_isLoadingContacts) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_contactsError != null) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_contactsError!, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadContacts,
                child: Text(AppLocalizations.of(context).translate('retry')),
              ),
            ],
          ),
        ),
      );
    }

    final contacts = _filteredNewContacts;

    if (contacts.isEmpty) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.person_add_outlined,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                _searchText.isEmpty 
                    ? AppLocalizations.of(context).translate('no_new_contacts')
                    : AppLocalizations.of(context).translate('no_search_contacts_results'),
                style: const TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFFEEF1F6),
      child: RefreshIndicator(
        onRefresh: () async {
          // 🔴 优先调用网络刷新方法（包含网络重连）
          await _onRefresh();
        },
        child: ListView.builder(
          itemCount: contacts.length,
          itemBuilder: (context, index) {
            final contact = contacts[index];
            return _buildNewContactItem(contact);
          },
        ),
      ),
    );
  }

  // 群通知列表（待审核的群组成员）
  Widget _buildPendingMembersList() {
    if (_isLoadingPendingMembers) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_pendingMembersError != null) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _pendingMembersError!,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadPendingGroupMembers,
                child: Text(AppLocalizations.of(context).translate('retry')),
              ),
            ],
          ),
        ),
      );
    }

    final members = _filteredPendingMembers;

    if (members.isEmpty) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.notifications_none,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                _searchText.isEmpty 
                    ? AppLocalizations.of(context).translate('no_pending_members')
                    : AppLocalizations.of(context).translate('no_search_contacts_results'),
                style: const TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFFEEF1F6),
      child: RefreshIndicator(
        onRefresh: () async {
          // 🔴 优先调用网络刷新方法（包含网络重连）
          await _onRefresh();
        },
        child: ListView.builder(
          itemCount: members.length,
          itemBuilder: (context, index) {
            final member = members[index];
            return _buildPendingMemberItem(member);
          },
        ),
      ),
    );
  }

  // 联系人列表（已通过审核的）
  Widget _buildContactsList() {
    if (_isLoadingContacts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_contactsError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_contactsError!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadContacts,
              child: Text(AppLocalizations.of(context).translate('retry')),
            ),
          ],
        ),
      );
    }

    final contacts = _filteredContacts;

    if (contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.people_outline, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              _searchText.isEmpty
                  ? AppLocalizations.of(context).translate('no_contacts')
                  : AppLocalizations.of(context).translate('no_search_results'),
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return Container(
      color: const Color(0xFFEEF1F6),
      child: RefreshIndicator(
        onRefresh: () async {
          // 🔴 优先调用网络刷新方法（包含网络重连）
          await _onRefresh();
        },
        child: ListView.builder(
          itemCount: contacts.length,
          itemBuilder: (context, index) {
            final contact = contacts[index];
            return _buildContactItem(contact);
          },
        ),
      ),
    );
  }

  Widget _buildGroupsList() {
    if (_isLoadingGroups) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_groupsError != null) {
      return Container(
        color: const Color(0xFFEEF1F6),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_groupsError!, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadGroups,
                child: Text(AppLocalizations.of(context).translate('retry')),
              ),
            ],
          ),
        ),
      );
    }

    final groups = _filteredGroups;

    return Container(
      color: const Color(0xFFEEF1F6),
      child: RefreshIndicator(
        onRefresh: () async {
          // 🔴 优先调用网络刷新方法（包含网络重连）
          await _onRefresh();
        },
        child: groups.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.group_outlined,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _searchText.isEmpty
                          ? AppLocalizations.of(context).translate('no_groups')
                          : AppLocalizations.of(
                              context,
                            ).translate('no_search_results'),
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                    if (_searchText.isEmpty) ...[
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _showCreateGroupDialog,
                        icon: const Icon(Icons.add),
                        label: Text(
                          AppLocalizations.of(
                            context,
                          ).translate('create_group'),
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : ListView.builder(
                itemCount: groups.length + 1, // +1 for create button
                itemBuilder: (context, index) {
                  if (index == 0) {
                    // 创建群组按钮
                    return ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A90E2),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Icon(
                          Icons.group_add,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        AppLocalizations.of(context).translate('create_group'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF4A90E2),
                        ),
                      ),
                      onTap: _showCreateGroupDialog,
                    );
                  }

                  final group = groups[index - 1];
                  return _buildGroupItem(group);
                },
              ),
      ),
    );
  }

  Widget _buildContactItem(ContactModel contact) {
    return InkWell(
      onTap: () async {
        // 🔴 打开聊天前，先检查并移除删除标记（如果存在）
        final contactKey = Storage.generateContactKey(
          isGroup: false,
          id: contact.friendId,
        );
        final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
        if (isDeleted) {
          logger.debug('🔄 [通讯录] 从已删除的会话打开聊天，移除删除标记: $contactKey');
          await Storage.removeDeletedChatForCurrentUser(contactKey);
        }
        
        // 点击整行进入聊天页面
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MobileChatPage(
              userId: contact.friendId,
              displayName: contact.fullName ?? contact.username,
              isGroup: false,
              avatar: contact.avatar,
              onChatClosed: (int contactId, bool isGroup) async {
                // 🔴 聊天页面关闭时，刷新最近联系人列表
                logger.debug('📤 [通讯录] 聊天页面关闭，准备刷新最近联系人列表');
                // 通过通知主页面刷新（使用广播）
                MobileChatListPage.needRefresh();
              },
            ),
          ),
        );
      },
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 头像
            GestureDetector(
              onTap: () {
                // 阻止事件冒泡，显示用户信息
                _showUserInfo(contact.friendId);
              },
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: contact.avatar.isNotEmpty
                        ? Colors.transparent
                        : const Color(0xFF4A90E2),
                    backgroundImage: contact.avatar.isNotEmpty
                        ? NetworkImage(contact.avatar)
                        : null,
                    child: contact.avatar.isEmpty
                        ? Text(
                            (contact.fullName ?? contact.username).isNotEmpty
                                ? (contact.fullName ?? contact.username)[0]
                                      .toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          )
                        : null,
                  ),
                  // 在线状态指示器
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _buildStatusIndicator(contact.status),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 联系人信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.fullName ?? contact.username,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                    ),
                  ),
                  if (contact.workSignature != null &&
                      contact.workSignature!.isNotEmpty)
                    Text(
                      contact.workSignature!,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            // 仅保留删除按钮（列表不再显示拉黑按钮）
            SizedBox(
              height: 32,
              child: ElevatedButton(
                onPressed: () => _handleDeleteContact(contact),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935), // 红色
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(60, 32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                child: const Text('删除', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupItem(GroupModel group) {
    final hasAvatar = group.avatar != null && group.avatar!.isNotEmpty;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        radius: 26,
        backgroundColor: hasAvatar
            ? Colors.transparent
            : const Color(0xFF52C41A),
        backgroundImage: hasAvatar ? NetworkImage(group.avatar!) : null,
        child: hasAvatar
            ? null
            : const Icon(Icons.people, color: Colors.white, size: 26),
      ),
      title: Text(
        group.name,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
      ),
      subtitle: FutureBuilder<int>(
        future: _getGroupMemberCount(group.id),
        builder: (context, snapshot) {
          final memberCount = snapshot.data ?? 0;
          return Text(
            '${memberCount}人',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          );
        },
      ),
      onTap: () async {
        // 🔴 打开群聊前，先检查并移除删除标记（如果存在）
        final contactKey = Storage.generateContactKey(
          isGroup: true,
          id: group.id,
        );
        final isDeleted = await Storage.isChatDeletedForCurrentUser(contactKey);
        if (isDeleted) {
          logger.debug('🔄 [通讯录] 从已删除的群聊打开聊天，移除删除标记: $contactKey');
          await Storage.removeDeletedChatForCurrentUser(contactKey);
        }
        
        // 跳转到群聊页面
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MobileChatPage(
              userId: 0, // 群聊时userId可以设为0或当前用户ID
              displayName: group.name,
              isGroup: true,
              groupId: group.id, // 添加群组ID
              onChatClosed: (int contactId, bool isGroup) async {
                // 🔴 聊天页面关闭时，刷新最近联系人列表
                logger.debug('📤 [通讯录] 群聊页面关闭，准备刷新最近联系人列表');
                // 通过通知主页面刷新（使用广播）
                MobileChatListPage.needRefresh();
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusIndicator(String status) {
    Color color;
    switch (status) {
      case 'online':
        color = Colors.green;
        break;
      case 'busy':
        color = Colors.red;
        break;
      case 'away':
        color = Colors.orange;
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }

  // 新联系人项（待审核，带审核按钮）
  Widget _buildNewContactItem(ContactModel contact) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: contact.avatar.isNotEmpty
            ? Colors.transparent
            : const Color(0xFFFAAD14),
        backgroundImage: contact.avatar.isNotEmpty
            ? NetworkImage(contact.avatar)
            : null,
        child: contact.avatar.isEmpty
            ? Text(
                (contact.fullName ?? contact.username).isNotEmpty
                    ? (contact.fullName ?? contact.username)[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              )
            : null,
      ),
      title: Text(
        contact.fullName ?? contact.username,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
      ),
      subtitle: contact.department != null && contact.department!.isNotEmpty
          ? Text(
              contact.department!,
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拒绝按钮
          ElevatedButton(
            onPressed: () => _handleContactApproval(contact, 'rejected'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[300],
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(60, 32),
            ),
            child: Text(AppLocalizations.of(context).translate('reject'), style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          // 通过按钮
          ElevatedButton(
            onPressed: () => _handleContactApproval(contact, 'approved'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90E2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(60, 32),
            ),
            child: Text(AppLocalizations.of(context).translate('approve'), style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // 待审核群组成员项
  Widget _buildPendingMemberItem(Map<String, dynamic> member) {
    final displayName = member['displayName'] as String;
    final groupName = member['groupName'] as String;
    final avatar = member['avatar'] as String?;
    
    // 如果昵称超过9个字符，截断并添加省略号
    final truncatedName = displayName.length > 9 
        ? '${displayName.substring(0, 9)}...' 
        : displayName;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: avatar != null && avatar.isNotEmpty
            ? Colors.transparent
            : const Color(0xFFFF9800),
        backgroundImage: avatar != null && avatar.isNotEmpty
            ? NetworkImage(avatar)
            : null,
        child: avatar == null || avatar.isEmpty
            ? Text(
                displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              )
            : null,
      ),
      title: Text(
        truncatedName,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
      ),
      subtitle: Text(
        '申请加入：$groupName',
        style: TextStyle(color: Colors.grey[600], fontSize: 14),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拒绝按钮
          ElevatedButton(
            onPressed: () => _handleGroupMemberApproval(member, false),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[300],
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(60, 32),
            ),
            child: Text(AppLocalizations.of(context).translate('reject'), style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          // 通过按钮
          ElevatedButton(
            onPressed: () => _handleGroupMemberApproval(member, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90E2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(60, 32),
            ),
            child: Text(AppLocalizations.of(context).translate('approve'), style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // 处理联系人审核
  Future<void> _handleContactApproval(
    ContactModel contact,
    String approvalStatus,
  ) async {
    final token = await Storage.getToken();
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    // 🔴 乐观更新：先立即更新UI，再请求接口
    // 1. 立即从列表中移除该联系人
    final removedContact = contact;
    if (mounted) {
      setState(() {
        _contacts.removeWhere((c) => c.relationId == contact.relationId);
      });
      // 立即通知待审核数量变化
      _notifyPendingCount();
      // 显示操作提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(approvalStatus == 'approved' ? '已通过' : '已拒绝'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // 2. 异步请求接口
    try {
      final response = await ApiService.updateContactApprovalStatus(
        token: token,
        relationId: contact.relationId,
        approvalStatus: approvalStatus,
      );

      if (response['code'] == 0) {
        await Storage.removePendingContactForCurrentUser(contact.friendId);
        // 🔴 更新缓存
        _cachedContacts = List.from(_contacts);
        _updateCacheTimestamp();
      } else {
        // 🔴 接口失败，回滚UI：将联系人重新添加回列表
        logger.error('审核联系人接口失败: ${response['message']}');
        if (mounted) {
          setState(() {
            _contacts.add(removedContact);
          });
          _notifyPendingCount();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '操作失败，已恢复')),
          );
        }
      }
    } catch (e) {
      // 🔴 请求异常，回滚UI：将联系人重新添加回列表
      logger.error('审核联系人失败: $e');
      if (mounted) {
        setState(() {
          _contacts.add(removedContact);
        });
        _notifyPendingCount();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败: $e，已恢复')));
      }
    }
  }

  // 处理群组成员审核
  Future<void> _handleGroupMemberApproval(
    Map<String, dynamic> member,
    bool approve,
  ) async {
    final token = await Storage.getToken();
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    final groupId = member['groupId'] as int;
    final userId = member['userId'] as int;

    try {
      final response = approve
          ? await ApiService.approveGroupMember(
              token: token,
              groupId: groupId,
              userId: userId,
            )
          : await ApiService.rejectGroupMember(
              token: token,
              groupId: groupId,
              userId: userId,
            );

      if (response['code'] == 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(approve ? '已通过' : '已拒绝')));
        }
        // 重新加载待审核成员列表
        await _loadPendingGroupMembers();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '操作失败')),
          );
        }
      }
    } catch (e) {
      logger.error('审核群组成员失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败: $e')));
      }
    }
  }

  void _showUserInfo(int userId) {
    // 从联系人列表中找到对应的联系人
    final contact = _contacts.firstWhere(
      (c) => c.friendId == userId,
      orElse: () => _contacts.first, // 如果找不到，返回第一个（理论上不应该发生）
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        // 在弹窗内部维护一个局部的拉黑状态，便于按钮即时切换
        bool localBlocked = contact.isBlocked ||
            (_currentUserId != null &&
                contact.blockedByUserId == _currentUserId);

        return StatefulBuilder(
          builder: (context, setStateModal) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              maxChildSize: 0.9,
              minChildSize: 0.5,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(
                      children: [
                        // 顶部指示器
                        Container(
                          margin:
                              const EdgeInsets.only(top: 8, bottom: 16),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),

                        // 头像
                        CircleAvatar(
                          radius: 50,
                          backgroundColor: contact.avatar.isNotEmpty
                              ? Colors.transparent
                              : const Color(0xFF4A90E2),
                          backgroundImage: contact.avatar.isNotEmpty
                              ? NetworkImage(contact.avatar)
                              : null,
                          child: contact.avatar.isEmpty
                              ? Text(
                                  contact.displayName.isNotEmpty
                                      ? contact.displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 32,
                                  ),
                                )
                              : null,
                        ),

                        const SizedBox(height: 16),

                        // 显示名称
                        Text(
                          contact.displayName,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 8),

                        // 用户名（如果与显示名称不同）
                        if (contact.fullName != null &&
                            contact.fullName!.isNotEmpty)
                          Text(
                            '用户名: ${contact.username}',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                          ),

                        const SizedBox(height: 24),

                        // 详细信息列表
                        _buildInfoSection(contact),

                        const SizedBox(height: 24),

                        // 底部操作按钮：左侧拉黑/恢复，右侧去聊天
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24.0),
                          child: Row(
                            children: [
                              // 左侧：拉黑 / 恢复
                              Expanded(
                                child: SizedBox(
                                  height: 44,
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      // 根据当前状态决定是拉黑还是恢复
                                      if (localBlocked) {
                                        await _handleUnblockContact(contact);
                                        setStateModal(() {
                                          localBlocked = false;
                                        });
                                      } else {
                                        await _handleBlockContact(contact);
                                        setStateModal(() {
                                          localBlocked = true;
                                        });
                                      }
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: localBlocked
                                          ? const Color(0xFF4CAF50) // 恢复
                                          : const Color(0xFFFF9800), // 拉黑
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(22),
                                      ),
                                    ),
                                    child: Text(
                                      localBlocked ? '恢复' : '拉黑',
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              // 右侧：去聊天
                              Expanded(
                                child: SizedBox(
                                  height: 44,
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      // 打开聊天前，先检查并移除删除标记（如果存在）
                                      final contactKey =
                                          Storage.generateContactKey(
                                        isGroup: false,
                                        id: contact.friendId,
                                      );
                                      final isDeleted = await Storage
                                          .isChatDeletedForCurrentUser(
                                              contactKey);
                                      if (isDeleted) {
                                        logger.debug(
                                            '🔄 [通讯录] 从个人信息面板进入聊天，移除删除标记: $contactKey');
                                        await Storage
                                            .removeDeletedChatForCurrentUser(
                                                contactKey);
                                      }

                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => MobileChatPage(
                                            userId: contact.friendId,
                                            displayName: contact.fullName ??
                                                contact.username,
                                            isGroup: false,
                                            avatar: contact.avatar,
                                            onChatClosed: (int contactId,
                                                bool isGroup) async {
                                              logger.debug(
                                                  '📤 [通讯录] 从个人信息面板返回，刷新最近联系人列表');
                                              MobileChatListPage.needRefresh();
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          const Color(0xFF4A90E2),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(22),
                                      ),
                                    ),
                                    child: const Text(
                                      '去聊天',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // 构建信息区域
  Widget _buildInfoSection(ContactModel contact) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // 个性签名
          if (contact.workSignature != null && contact.workSignature!.isNotEmpty)
            _buildInfoItem(
              icon: Icons.edit_note,
              label: '个性签名',
              value: contact.workSignature!,
            ),
          
          // 部门
          if (contact.department != null && contact.department!.isNotEmpty)
            _buildInfoItem(
              icon: Icons.business,
              label: '部门',
              value: contact.department!,
            ),
          
          // 职位
          if (contact.position != null && contact.position!.isNotEmpty)
            _buildInfoItem(
              icon: Icons.work,
              label: '职位',
              value: contact.position!,
            ),
          
          // 手机号
          if (contact.phone != null && contact.phone!.isNotEmpty)
            _buildInfoItem(
              icon: Icons.phone,
              label: '手机号',
              value: contact.phone!,
            ),
          
          // 邮箱
          if (contact.email != null && contact.email!.isNotEmpty)
            _buildInfoItem(
              icon: Icons.email,
              label: '邮箱',
              value: contact.email!,
            ),
        ],
      ),
    );
  }

  // 构建单个信息项
  Widget _buildInfoItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 24,
            color: const Color(0xFF4A90E2),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 恢复联系人（取消拉黑）
  Future<void> _handleUnblockContact(ContactModel contact) async {
    final token = await Storage.getToken();
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    try {
      // 调用API恢复联系人
      final response = await ApiService.unblockContact(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        if (mounted) {
          setState(() {
            final index = _contacts.indexWhere(
              (c) => c.relationId == contact.relationId,
            );
            if (index != -1) {
              _contacts[index] = _contacts[index].copyWith(
                isBlocked: false,
                isBlockedByMe: false,
              );
            }
          });
        }

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已恢复联系人')));
        }

        // 重新加载联系人列表以同步服务器最新状态
        await _loadContacts();
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '恢复失败')),
          );
        }
      }
    } catch (e) {
      logger.error('恢复联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
      }
    }
  }

  // 拉黑联系人
  Future<void> _handleBlockContact(ContactModel contact) async {
    final token = await Storage.getToken();
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    try {
      // 调用API拉黑联系人
      final response = await ApiService.blockContact(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        if (mounted) {
          setState(() {
            final index = _contacts.indexWhere(
              (c) => c.relationId == contact.relationId,
            );
            if (index != -1) {
              _contacts[index] = _contacts[index].copyWith(
                isBlocked: true,
                isBlockedByMe: true,
              );
            }
          });
        }

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已拉黑联系人')));
        }

        // 重新加载联系人列表以同步服务器最新状态
        await _loadContacts();
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '拉黑失败')),
          );
        }
      }
    } catch (e) {
      logger.error('拉黑联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拉黑失败: $e')));
      }
    }
  }

  // 删除联系人
  Future<void> _handleDeleteContact(ContactModel contact) async {
    final token = await Storage.getToken();
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未登录')));
      }
      return;
    }

    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除联系人 ${contact.fullName ?? contact.username} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE53935),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      // 调用API删除联系人
      final response = await ApiService.deleteContactById(
        token: token,
        friendId: contact.friendId,
      );

      if (response['code'] == 0 || response['code'] == 200) {
        // 更新本地联系人状态
        if (mounted) {
          setState(() {
            final index = _contacts.indexWhere(
              (c) => c.relationId == contact.relationId,
            );
            if (index != -1) {
              _contacts[index] = _contacts[index].copyWith(isDeleted: true);
            }
          });
        }

        // 从最近联系人列表中删除该联系人
        final contactKey = Storage.generateContactKey(
          isGroup: false,
          id: contact.friendId,
        );
        await Storage.addDeletedChatForCurrentUser(contactKey);
        logger.debug('已从最近联系人列表中删除联系人: $contactKey');

        // 显示成功提示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已删除联系人')));
        }

        // 重新加载联系人列表以同步服务器最新状态
        await _loadContacts();
      } else {
        // 显示错误提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '删除失败')),
          );
        }
      }
    } catch (e) {
      logger.error('删除联系人失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  // 获取群组成员数量（只统计已通过审核的成员）
  // 🔴 优先使用缓存数据，如果缓存中没有则从API获取
  Future<int> _getGroupMemberCount(int groupId) async {
    // 🔴 优先使用缓存数据
    if (_cachedGroupMemberCounts != null && _cachedGroupMemberCounts!.containsKey(groupId)) {
      final cachedCount = _cachedGroupMemberCounts![groupId]!;
      logger.debug('📦 [群组成员数量] 使用缓存: 群组 $groupId = $cachedCount 人');
      return cachedCount;
    }

    // 如果缓存中没有，则从API获取
    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        return 0;
      }

      final count = await _fetchGroupMemberCount(groupId, token);
      
      // 🔴 更新缓存
      if (_cachedGroupMemberCounts == null) {
        _cachedGroupMemberCounts = {};
      }
      _cachedGroupMemberCounts![groupId] = count;
      logger.debug('💾 [群组成员数量] 从API获取并缓存: 群组 $groupId = $count 人');
      
      return count;
    } catch (e) {
      logger.debug('获取群组成员数量失败: $e');
    }
    
    return 0;
  }
}
