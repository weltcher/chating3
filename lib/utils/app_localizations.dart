import 'package:flutter/material.dart';

/// 应用国际化资源管理
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  /// 从上下文获取当前语言资源
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  /// 支持的语言列表
  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'), // 简体中文
    Locale('en', 'US'), // 英文
    Locale('zh', 'TW'), // 繁体中文
  ];

  /// 所有翻译资源
  static final Map<String, Map<String, String>> _localizedValues = {
    // 简体中文
    'zh_CN': {
      // 登录页面
      'app_title': '有度',
      'login': '登录',
      'register': '注册',
      'forgot_password': '忘记密码',
      'forgot_password_question': '忘记密码？',
      'go_to_register': '去注册？',
      'username': '用户名',
      'password': '密码',
      'account': '账号',
      'account_login': '账号登录',
      'verify_code_login': '验证码登录',
      'phone_number': '手机号',
      'verify_code': '验证码',
      'get_verify_code': '获取验证码',
      'resend_after': '秒后重新获取',
      'remember_password': '记住密码',
      'auto_login_next_time': '下次自动登录',

      // 主页
      'chat': '会话33',
      'contacts': '通讯录',
      'news': '资讯',
      'todo': '待办',
      'settings': '设置',
      
      // 待办页面
      'add_todo': '添加待办',
      'pending': '未完成',
      'completed': '已完成',
      'no_todo_content': '暂无待办内容',
      'mark_incomplete': '标记未完成',
      'mark_complete': '标记完成',
      'description': '描述',
      'no_description': '暂无描述',
      'title': '标题',
      'description_optional': '描述（可选）',
      'confirm_delete': '确认删除',
      'confirm_delete_todo': '确定要删除这条待办吗？',

      // 设置页面
      'settings_title': '设置',
      'general': '通用',
      'message_notification': '消息通知',
      'shortcuts': '快捷键',
      'about': '关于',

      // 通用设置
      'message_storage_path': '消息存储路径',
      'message_storage_hint': '账号记录、服务器地址设置、消息等会存放于此',
      'file_storage_path': '文件存储路径',
      'file_storage_hint': '接收的文件、图片、头像、视频、音频、应用图标会存放于此',
      'auto_download': '自动下载小于',
      'auto_download_hint': '(0-1024) MB的文件',
      'mouse_keyboard_idle': '鼠标键盘无操作',
      'auto_offline_hint': '分钟后，自动发送离线消息',
      'language_setting': '语言设置',
      'window_zoom': '窗口缩放',
      'window_zoom_default': '75%（默认）',
      'change': '更改',
      'path_saved': '路径已保存',
      'window_zoom_applied': '窗口缩放已设置为',
      'window_resize_failed': '设置窗口大小失败',

      // 消息通知设置
      'new_message_sound': '新消息提示音',
      'new_message_popup': '新消息弹窗显示（系统通知）',

      // 快捷键设置
      'send_message_shortcut': '发送消息',
      'toggle_window_shortcut': '显示/隐藏主窗',
      'screenshot_shortcut': '截屏',
      'restore_default': '恢复默认',
      'press_shortcut_key': '请按下快捷键...',

      // 关于页面
      'app_version': '有度2025-release',
      'version_number': '版本号：',
      'version_value': '10.0.12-2025102401',
      'copy': '复制',
      'check_update': '检查新版本',
      'copyright': 'Copyright (c) 2014-2025 youdu.cn All rights reserved',

      // 语言选项
      'chinese_simplified': '简体中文',
      'english': 'English',
      'chinese_traditional': '繁體中文',

      // 用户状态
      'status_online': '在线',
      'status_busy': '忙碌',
      'status_away': '离开',
      'status_offline': '离线',

      // 搜索和操作
      'search': '搜索',
      'search_contacts': '搜索联系人',
      'send': '发送',
      'cancel': '取消',
      'confirm': '确认',
      'save': '保存',
      'delete': '删除',
      'edit': '编辑',
      'close': '关闭',

      // 消息相关
      'send_message': '发送消息',
      'message_input_hint': '请输入消息内容...',
      'message_input_hint_pc': '输入消息 (Shift+Enter换行)',
      'message_input_hint_mobile': '输入消息...',
      'muted_cannot_send': '已被禁言，无法发送消息',
      'quote_message': '引用消息',
      'forward_message': '转发消息',
      'delete_message': '删除消息',
      'copy_message': '复制消息',
      'select_mode': '多选模式',
      'select_all': '全选',
      'deselect_all': '取消全选',

      // 文件和媒体
      'send_file': '发送文件',
      'send_image': '发送图片',
      'screenshot': '截图',
      'download': '下载',
      'open_file': '打开文件',
      'save_as': '另存为',

      // 群组和联系人
      'create_group': '创建群组',
      'group_name': '群组名称',
      'group_members': '群组成员',
      'add_member': '添加成员',
      'remove_member': '移除成员',
      'view_profile': '查看资料',
      'edit_profile': '编辑资料',
      'new_contacts': '新联系人',
      'group_notifications': '群通知',
      'contacts_tab': '联系人',
      'groups': '群组',
      'no_new_contacts': '暂无新的联系人',
      'no_search_contacts_results': '无搜索结果',
      'no_contacts_data': '暂无联系人',
      'no_groups_data': '暂无群组',
      'no_pending_members': '暂无群通知',
      'approve': '同意',
      'reject': '拒绝',
      'send_message': '发消息',

      // 收藏夹
      'favorites': '收藏',
      'add_to_favorites': '添加到收藏夹',
      'remove_from_favorites': '从收藏夹移除',
      'my_favorites': '我的收藏',
      'no_favorites': '暂无收藏',
      'favorites_count': '条',

      // 其他
      'loading': '加载中...',
      'no_data': '暂无数据',
      'no_conversations': '暂无会话',
      'no_contacts': '暂无联系人',
      'no_groups': '暂无群组',
      'no_search_results': '暂无搜索结果',
      'retry': '重试',
      'error': '错误',
      'success': '成功',
      'logout': '退出登录',
      'change_password': '修改密码',

      // 个人菜单
      'add_work_signature': '添加工作签名...',
      'file_transfer_assistant': '文件传输助手',
      'status': '状态',
      'customer_service': '客服与帮助',
      'switch_account': '切换账号',
      'exit_youdu': '退出有度',
      'edit_work_signature': '编辑工作签名',
      'work_signature_hint': '请输入工作签名',
      'work_signature_updated': '工作签名更新成功',
      'update_failed': '更新失败',
      'please_login_first': '请先登录',
      'status_updated': '状态已更新',
      'update_status_failed': '更新状态失败',
      'exit_youdu_title': '退出有道',
      'confirm_logout': '确定要退出登录吗',

      // 升级模块
      'new_version_available': '发现新版本',
      'current_version': '当前版本',
      'latest_version': '最新版本',
      'file_size': '文件大小：',
      'release_date': '发布日期：',
      'update_content': '更新内容',
      'preparing': '准备中...',
      'downloading': '正在下载...',
      'download_complete': '下载完成',
      'download_failed': '下载失败',
      'installing': '正在安装...',
      'install_now': '立即更新',
      'update_now': '立即更新',
      'later': '稍后',
      'checking_update': '正在检查更新...',
      'no_update': '已是最新版本',
      'update_check_failed': '检查更新失败',
      'force_update_hint': '此版本为强制更新，请立即更新',
      'download_progress': '下载进度',
      'verify_failed': '文件校验失败，请重新下载',
    },

    // 英文
    'en_US': {
      // 登录页面
      'app_title': '有度',
      'login': 'Login',
      'register': 'Register',
      'forgot_password': 'Forgot Password',
      'forgot_password_question': 'Forgot Password?',
      'go_to_register': 'Register?',
      'username': 'Username',
      'password': 'Password',
      'account': 'Account',
      'account_login': 'Account Login',
      'verify_code_login': 'Verification Code Login',
      'phone_number': 'Phone Number',
      'verify_code': 'Verification Code',
      'get_verify_code': 'Get Code',
      'resend_after': 's to resend',
      'remember_password': 'Remember Password',
      'auto_login_next_time': 'Auto Login Next Time',

      // 主页
      'chat': 'Chat',
      'contacts': 'Contacts',
      'news': 'News',
      'todo': 'Todo',
      'settings': 'Settings',
      
      // 待办页面
      'add_todo': 'Add Todo',
      'pending': 'Pending',
      'completed': 'Completed',
      'no_todo_content': 'No Todos',
      'mark_incomplete': 'Mark as Incomplete',
      'mark_complete': 'Mark as Complete',
      'description': 'Description',
      'no_description': 'No Description',
      'title': 'Title',
      'description_optional': 'Description (Optional)',
      'confirm_delete': 'Confirm Delete',
      'confirm_delete_todo': 'Are you sure you want to delete this todo?',

      // 设置页面
      'settings_title': 'Settings',
      'general': 'General',
      'message_notification': 'Notifications',
      'shortcuts': 'Shortcuts',
      'about': 'About',

      // 通用设置
      'message_storage_path': 'Message Storage Path',
      'message_storage_hint': 'Account records, server address settings, messages, etc. will be stored here',
      'file_storage_path': 'File Storage Path',
      'file_storage_hint': 'Received files, images, avatars, videos, audio, app icons will be stored here',
      'auto_download': 'Auto download files less than',
      'auto_download_hint': '(0-1024) MB',
      'mouse_keyboard_idle': 'Mouse/Keyboard idle',
      'auto_offline_hint': 'minutes, send offline status',
      'language_setting': 'Language',
      'window_zoom': 'Window Zoom',
      'window_zoom_default': '75% (Default)',
      'change': 'Change',
      'path_saved': 'Path saved',
      'window_zoom_applied': 'Window zoom set to',
      'window_resize_failed': 'Failed to set window size',

      // 消息通知设置
      'new_message_sound': 'New Message Sound',
      'new_message_popup': 'New Message Popup (System Notification)',

      // 快捷键设置
      'send_message_shortcut': 'Send Message',
      'toggle_window_shortcut': 'Show/Hide Main Window',
      'screenshot_shortcut': 'Screenshot',
      'restore_default': 'Restore Default',
      'press_shortcut_key': 'Press shortcut key...',

      // 关于页面
      'app_version': 'Youdu 2025-release',
      'version_number': 'Version: ',
      'version_value': '10.0.12-2025102401',
      'copy': 'Copy',
      'check_update': 'Check for Updates',
      'copyright': 'Copyright (c) 2014-2025 youdu.cn All rights reserved',

      // 语言选项
      'chinese_simplified': '简体中文',
      'english': 'English',
      'chinese_traditional': '繁體中文',

      // 用户状态
      'status_online': 'Online',
      'status_busy': 'Busy',
      'status_away': 'Away',
      'status_offline': 'Offline',

      // 搜索和操作
      'search': 'Search',
      'search_contacts': 'Search Contacts',
      'send': 'Send',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'save': 'Save',
      'delete': 'Delete',
      'edit': 'Edit',
      'close': 'Close',

      // 消息相关
      'send_message': 'Send Message',
      'message_input_hint': 'Type a message...',
      'message_input_hint_pc': 'Type a message (Shift+Enter for new line)',
      'message_input_hint_mobile': 'Type a message...',
      'muted_cannot_send': 'Muted, cannot send messages',
      'quote_message': 'Quote',
      'forward_message': 'Forward',
      'delete_message': 'Delete Message',
      'copy_message': 'Copy',
      'select_mode': 'Multi-Select Mode',
      'select_all': 'Select All',
      'deselect_all': 'Deselect All',

      // 文件和媒体
      'send_file': 'Send File',
      'send_image': 'Send Image',
      'screenshot': 'Screenshot',
      'download': 'Download',
      'open_file': 'Open File',
      'save_as': 'Save As',

      // 群组和联系人
      'create_group': 'Create Group',
      'group_name': 'Group Name',
      'group_members': 'Group Members',
      'add_member': 'Add Member',
      'remove_member': 'Remove Member',
      'view_profile': 'View Profile',
      'edit_profile': 'Edit Profile',
      'new_contacts': 'New Contacts',
      'group_notifications': 'Group Notifications',
      'contacts_tab': 'Contacts',
      'groups': 'Groups',
      'no_new_contacts': 'No New Contacts',
      'no_search_contacts_results': 'No Search Results',
      'no_contacts_data': 'No Contacts',
      'no_groups_data': 'No Groups',
      'no_pending_members': 'No Pending Notifications',
      'approve': 'Approve',
      'reject': 'Reject',
      'send_message': 'Message',

      // 收藏夹
      'favorites': 'Favorites',
      'add_to_favorites': 'Add to Favorites',
      'remove_from_favorites': 'Remove from Favorites',
      'my_favorites': 'My Favorites',
      'no_favorites': 'No Favorites',
      'favorites_count': 'items',

      // 其他
      'loading': 'Loading...',
      'no_data': 'No Data',
      'no_conversations': 'No Conversations',
      'no_contacts': 'No Contacts',
      'no_groups': 'No Groups',
      'no_search_results': 'No Search Results',
      'retry': 'Retry',
      'error': 'Error',
      'success': 'Success',
      'logout': 'Logout',
      'change_password': 'Change Password',

      // 个人菜单
      'add_work_signature': 'Add Work Signature...',
      'file_transfer_assistant': 'File Transfer Assistant',
      'status': 'Status',
      'customer_service': 'Customer Service & Help',
      'switch_account': 'Switch Account',
      'exit_youdu': 'Exit Youdu',
      'edit_work_signature': 'Edit Work Signature',
      'work_signature_hint': 'Enter your work signature',
      'work_signature_updated': 'Work signature updated successfully',
      'update_failed': 'Update failed',
      'please_login_first': 'Please login first',
      'status_updated': 'Status updated',
      'update_status_failed': 'Failed to update status',
      'exit_youdu_title': 'Exit Youdu',
      'confirm_logout': 'Are you sure you want to logout?',

      // Update module
      'new_version_available': 'New Version Available',
      'current_version': 'Current Version',
      'latest_version': 'Latest Version',
      'file_size': 'File Size: ',
      'release_date': 'Release Date: ',
      'update_content': 'What\'s New',
      'preparing': 'Preparing...',
      'downloading': 'Downloading...',
      'download_complete': 'Download Complete',
      'download_failed': 'Download Failed',
      'installing': 'Installing...',
      'install_now': 'Install Now',
      'update_now': 'Update Now',
      'later': 'Later',
      'checking_update': 'Checking for updates...',
      'no_update': 'You\'re up to date',
      'update_check_failed': 'Failed to check for updates',
      'force_update_hint': 'This is a mandatory update, please update now',
      'download_progress': 'Download Progress',
      'verify_failed': 'File verification failed, please download again',
    },

    // 繁体中文
    'zh_TW': {
      // 登录页面
      'app_title': '有度',
      'login': '登錄',
      'register': '註冊',
      'forgot_password': '忘記密碼',
      'forgot_password_question': '忘記密碼？',
      'go_to_register': '去註冊？',
      'username': '用戶名',
      'password': '密碼',
      'account': '賬號',
      'account_login': '賬號登錄',
      'verify_code_login': '驗證碼登錄',
      'phone_number': '手機號',
      'verify_code': '驗證碼',
      'get_verify_code': '獲取驗證碼',
      'resend_after': '秒後重新獲取',
      'remember_password': '記住密碼',
      'auto_login_next_time': '下次自動登錄',

      // 主页
      'chat': '會話',
      'contacts': '通訊錄',
      'news': '資訊',
      'todo': '待辦',
      'settings': '設置',
      
      // 待办页面
      'add_todo': '添加待辦',
      'pending': '未完成',
      'completed': '已完成',
      'no_todo_content': '暫無待辦內容',
      'mark_incomplete': '標記未完成',
      'mark_complete': '標記完成',
      'description': '描述',
      'no_description': '暫無描述',
      'title': '標題',
      'description_optional': '描述（可選）',
      'confirm_delete': '確認刪除',
      'confirm_delete_todo': '確定要刪除這條待辦嗎？',

      // 设置页面
      'settings_title': '設置',
      'general': '通用',
      'message_notification': '消息通知',
      'shortcuts': '快捷鍵',
      'about': '關於',

      // 通用设置
      'message_storage_path': '消息存儲路徑',
      'message_storage_hint': '賬號記錄、服務器地址設置、消息等會存放於此',
      'file_storage_path': '文件存儲路徑',
      'file_storage_hint': '接收的文件、圖片、頭像、視頻、音頻、應用圖標會存放於此',
      'auto_download': '自動下載小於',
      'auto_download_hint': '(0-1024) MB的文件',
      'mouse_keyboard_idle': '鼠標鍵盤無操作',
      'auto_offline_hint': '分鐘後，自動發送離線消息',
      'language_setting': '語言設置',
      'window_zoom': '窗口縮放',
      'window_zoom_default': '75%（默認）',
      'change': '更改',
      'path_saved': '路徑已保存',
      'window_zoom_applied': '窗口縮放已設置為',
      'window_resize_failed': '設置窗口大小失敗',

      // 消息通知設置
      'new_message_sound': '新消息提示音',
      'new_message_popup': '新消息彈窗顯示（系統通知）',

      // 快捷鍵設置
      'send_message_shortcut': '發送消息',
      'toggle_window_shortcut': '顯示/隱藏主窗',
      'screenshot_shortcut': '截屏',
      'restore_default': '恢復默認',
      'press_shortcut_key': '請按下快捷鍵...',

      // 關於頁面
      'app_version': '有度2025-release',
      'version_number': '版本號：',
      'version_value': '10.0.12-2025102401',
      'copy': '複製',
      'check_update': '檢查新版本',
      'copyright': 'Copyright (c) 2014-2025 youdu.cn All rights reserved',

      // 语言选项
      'chinese_simplified': '简体中文',
      'english': 'English',
      'chinese_traditional': '繁體中文',

      // 用户状态
      'status_online': '在線',
      'status_busy': '忙碌',
      'status_away': '離開',
      'status_offline': '離線',

      // 搜索和操作
      'search': '搜索',
      'search_contacts': '搜索聯繫人',
      'send': '發送',
      'cancel': '取消',
      'confirm': '確認',
      'save': '保存',
      'delete': '刪除',
      'edit': '編輯',
      'close': '關閉',

      // 消息相关
      'send_message': '發送消息',
      'message_input_hint': '請輸入消息內容...',
      'message_input_hint_pc': '輸入消息 (Shift+Enter換行)',
      'message_input_hint_mobile': '輸入消息...',
      'muted_cannot_send': '已被禁言，無法發送消息',
      'quote_message': '引用消息',
      'forward_message': '轉發消息',
      'delete_message': '刪除消息',
      'copy_message': '複製消息',
      'select_mode': '多選模式',
      'select_all': '全選',
      'deselect_all': '取消全選',

      // 文件和媒体
      'send_file': '發送文件',
      'send_image': '發送圖片',
      'screenshot': '截圖',
      'download': '下載',
      'open_file': '打開文件',
      'save_as': '另存為',

      // 群组和联系人
      'create_group': '創建群組',
      'group_name': '群組名稱',
      'group_members': '群組成員',
      'add_member': '添加成員',
      'remove_member': '移除成員',
      'view_profile': '查看資料',
      'edit_profile': '編輯資料',
      'new_contacts': '新聯繫人',
      'group_notifications': '群通知',
      'contacts_tab': '聯繫人',
      'groups': '群組',
      'no_new_contacts': '暫無新的聯繫人',
      'no_search_contacts_results': '無搜索結果',
      'no_contacts_data': '暫無聯繫人',
      'no_groups_data': '暫無群組',
      'no_pending_members': '暫無群通知',
      'approve': '同意',
      'reject': '拒絕',
      'send_message': '發消息',

      // 收藏夾
      'favorites': '收藏',
      'add_to_favorites': '添加到收藏夾',
      'remove_from_favorites': '從收藏夾移除',
      'my_favorites': '我的收藏',
      'no_favorites': '暫無收藏',
      'favorites_count': '條',

      // 其他
      'loading': '加載中...',
      'no_data': '暫無數據',
      'no_conversations': '暫無會話',
      'no_contacts': '暫無聯繫人',
      'no_groups': '暫無群組',
      'no_search_results': '暫無搜索結果',
      'retry': '重試',
      'error': '錯誤',
      'success': '成功',
      'logout': '退出登錄',
      'change_password': '修改密碼',

      // 个人菜单
      'add_work_signature': '添加工作簽名...',
      'file_transfer_assistant': '文件傳輸助手',
      'status': '狀態',
      'customer_service': '客服與幫助',
      'switch_account': '切換賬號',
      'exit_youdu': '退出有度',
      'edit_work_signature': '編輯工作簽名',
      'work_signature_hint': '請輸入工作簽名',
      'work_signature_updated': '工作簽名更新成功',
      'update_failed': '更新失敗',
      'please_login_first': '請先登錄',
      'status_updated': '狀態已更新',
      'update_status_failed': '更新狀態失敗',
      'exit_youdu_title': '退出有道',
      'confirm_logout': '確定要退出登錄嗎',

      // 升級模組
      'new_version_available': '發現新版本',
      'current_version': '當前版本',
      'latest_version': '最新版本',
      'file_size': '文件大小：',
      'release_date': '發布日期：',
      'update_content': '更新內容',
      'preparing': '準備中...',
      'downloading': '正在下載...',
      'download_complete': '下載完成',
      'download_failed': '下載失敗',
      'installing': '正在安裝...',
      'install_now': '立即更新',
      'update_now': '立即更新',
      'later': '稍後',
      'checking_update': '正在檢查更新...',
      'no_update': '已是最新版本',
      'update_check_failed': '檢查更新失敗',
      'force_update_hint': '此版本為強制更新，請立即更新',
      'download_progress': '下載進度',
      'verify_failed': '文件校驗失敗，請重新下載',
    },
  };

  /// 获取翻译文本
  String translate(String key) {
    final languageCode = '${locale.languageCode}_${locale.countryCode}';
    return _localizedValues[languageCode]?[key] ?? key;
  }

  /// 语言代码转换为显示名称
  static String getLanguageName(String languageCode) {
    switch (languageCode) {
      case 'zh_CN':
        return '简体中文';
      case 'en_US':
        return 'English';
      case 'zh_TW':
        return '繁體中文';
      default:
        return '简体中文';
    }
  }

  /// 显示名称转换为语言代码
  static String getLanguageCode(String languageName) {
    switch (languageName) {
      case '简体中文':
        return 'zh_CN';
      case 'English':
        return 'en_US';
      case '繁體中文':
        return 'zh_TW';
      default:
        return 'zh_CN';
    }
  }

  /// 语言代码转换为 Locale
  static Locale getLocaleFromCode(String code) {
    switch (code) {
      case 'zh_CN':
        return const Locale('zh', 'CN');
      case 'en_US':
        return const Locale('en', 'US');
      case 'zh_TW':
        return const Locale('zh', 'TW');
      default:
        return const Locale('zh', 'CN');
    }
  }
}

/// 国际化代理
class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (l) => l.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
