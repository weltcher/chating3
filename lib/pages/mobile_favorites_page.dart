import 'dart:io';
import 'package:flutter/material.dart';
import 'package:extended_text/extended_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:youdu/models/favorite_model.dart';
import 'package:youdu/services/api_service.dart';
import 'package:youdu/utils/storage.dart';
import 'package:youdu/utils/emoji_text_span_builder.dart';
import 'package:youdu/utils/logger.dart';
import 'package:youdu/utils/mobile_storage_permission_helper.dart';
import 'package:youdu/utils/app_localizations.dart';

/// 移动端收藏页面
class MobileFavoritesPage extends StatefulWidget {
  const MobileFavoritesPage({super.key});

  @override
  State<MobileFavoritesPage> createState() => _MobileFavoritesPageState();
}

class _MobileFavoritesPageState extends State<MobileFavoritesPage> {
  List<FavoriteModel> _favorites = [];
  bool _isLoading = false;
  String? _error;
  int _currentPage = 1;
  int _totalPages = 1;
  int _total = 0;
  final int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  // 加载收藏列表
  Future<void> _loadFavorites({int page = 1}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = '未登录';
        });
        return;
      }

      final response = await ApiService.getFavorites(
        token: token,
        page: page,
        pageSize: _pageSize,
      );

      if (response['code'] == 0 && response['data'] != null) {
        final data = response['data'];
        final favoritesData = data['favorites'] as List?;
        final favorites = (favoritesData ?? [])
            .map((json) => FavoriteModel.fromJson(json as Map<String, dynamic>))
            .toList();

        setState(() {
          _favorites = favorites;
          _currentPage = data['page'] as int? ?? 1;
          _totalPages = data['total_pages'] as int? ?? 1;
          _total = data['total'] as int? ?? 0;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _error = response['message'] ?? '加载收藏失败';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '加载收藏失败: $e';
      });
    }
  }

  // 删除收藏
  Future<void> _deleteFavorite(int favoriteId) async {
    try {
      final token = await Storage.getToken();
      if (token == null || token.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未登录')));
        }
        return;
      }

      final response = await ApiService.deleteFavorite(
        token: token,
        favoriteId: favoriteId,
      );

      if (mounted) {
        if (response['code'] == 0) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('删除成功')));
          // 重新加载当前页面
          _loadFavorites(page: _currentPage);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? '删除失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  // 显示收藏详情
  void _showFavoriteDetail(FavoriteModel favorite) {
    if (favorite.messageType == 'merged') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => _MergedMessageDetailPage(favorite: favorite),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => _GeneralFavoriteDetailPage(favorite: favorite),
        ),
      );
    }
  }

  // 获取文件图标
  IconData _getFileIcon(String? fileName) {
    if (fileName == null) return Icons.insert_drive_file;

    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90E2),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Text(
              i18n.translate('my_favorites'),
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            if (_total > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$_total',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(_error!, style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _loadFavorites(page: _currentPage),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                    ),
                    child: Text(i18n.translate('retry')),
                  ),
                ],
              ),
            )
          : _favorites.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star_border, size: 80, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    i18n.translate('no_favorites'),
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _loadFavorites(page: _currentPage),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _favorites.length,
                      itemBuilder: (context, index) {
                        final favorite = _favorites[index];
                        return _buildFavoriteItem(favorite);
                      },
                    ),
                  ),
                ),
                if (_totalPages > 1) _buildPagination(),
              ],
            ),
    );
  }

  // 构建收藏项
  Widget _buildFavoriteItem(FavoriteModel favorite) {
    final bool isMerged = favorite.messageType == 'merged';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: () => _showFavoriteDetail(favorite),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isMerged
                      ? const Color(0xFFFAAD14).withOpacity(0.1)
                      : const Color(0xFF4A90E2).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isMerged ? Icons.chat_bubble_outline : Icons.star,
                  color: isMerged
                      ? const Color(0xFFFAAD14)
                      : const Color(0xFF4A90E2),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              // 内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题行
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            favorite.senderName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (isMerged)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAAD14),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              '聊天记录',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 内容预览
                    favorite.messageType == 'image'
                        ? Row(
                            children: [
                              Icon(
                                Icons.image,
                                size: 16,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '[图片]',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          )
                        : favorite.messageType == 'file'
                        ? Row(
                            children: [
                              Icon(
                                _getFileIcon(favorite.fileName),
                                size: 16,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '[文件] ${favorite.fileName ?? "未知文件"}',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        : favorite.messageType == 'video'
                        ? Row(
                            children: [
                              Icon(
                                Icons.videocam,
                                size: 16,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '[视频]',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          )
                        : ExtendedText(
                            favorite.content,
                            specialTextSpanBuilder:
                                MessageEmojiTextSpanBuilder(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[700],
                            ),
                          ),
                    const SizedBox(height: 6),
                    // 时间
                    Text(
                      _formatTime(favorite.createdAt),
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              // 删除按钮
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.grey[400]),
                onPressed: () {
                  // 确认删除
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除收藏'),
                      content: const Text('确定要删除这条收藏吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _deleteFavorite(favorite.id);
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建分页控件
  Widget _buildPagination() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _currentPage > 1
                ? () => _loadFavorites(page: _currentPage - 1)
                : null,
            color: const Color(0xFF4A90E2),
          ),
          const SizedBox(width: 8),
          Text(
            '$_currentPage / $_totalPages',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _currentPage < _totalPages
                ? () => _loadFavorites(page: _currentPage + 1)
                : null,
            color: const Color(0xFF4A90E2),
          ),
        ],
      ),
    );
  }

  // 格式化时间
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays > 0) {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}小时前';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}分钟前';
    } else {
      return '刚刚';
    }
  }
}

/// 合并消息详细页面
class _MergedMessageDetailPage extends StatelessWidget {
  final FavoriteModel favorite;

  const _MergedMessageDetailPage({required this.favorite});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90E2),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          '聊天记录详情',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _buildChatContent(),
      ),
    );
  }

  // 构建聊天内容
  Widget _buildChatContent() {
    final lines = favorite.content.split('\n');
    final List<Widget> chatWidgets = [];
    final Set<String> senders = {};
    String? leftSender;

    // 收集所有发送者
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final timePattern = RegExp(r'^(\d{2}:\d{2}:\d{2})\s+(.+):$');
      final match = timePattern.firstMatch(line);
      if (match != null) {
        final sender = match.group(2)!;
        leftSender ??= sender;
        senders.add(sender);
      }
    }

    // 构建消息气泡
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.contains('【聊天记录】') || line.contains('────')) {
        chatWidgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              line,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF666666),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
        continue;
      }

      if (line.trim().isEmpty) continue;

      final timePattern = RegExp(r'^(\d{2}:\d{2}:\d{2})\s+(.+):$');
      final match = timePattern.firstMatch(line);

      if (match != null) {
        final time = match.group(1)!;
        final sender = match.group(2)!;
        String content = '';
        if (i + 1 < lines.length) {
          content = lines[i + 1];
          i++;
        }
        final bool isLeft = (sender == leftSender);
        chatWidgets.add(_buildMessageBubble(time, sender, content, isLeft));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: chatWidgets,
    );
  }

  // 构建消息气泡
  Widget _buildMessageBubble(
    String time,
    String sender,
    String content,
    bool isLeft,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isLeft
            ? MainAxisAlignment.start
            : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLeft) ...[
            _buildAvatar(sender, isLeft),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isLeft
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isLeft) ...[
                        Text(
                          time,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF999999),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        sender,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isLeft
                              ? const Color(0xFF4A90E2)
                              : const Color(0xFF52C41A),
                        ),
                      ),
                      if (isLeft) ...[
                        const SizedBox(width: 6),
                        Text(
                          time,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxWidth: 280),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isLeft ? Colors.white : const Color(0xFFDCF8C6),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(isLeft ? 4 : 12),
                      topRight: Radius.circular(isLeft ? 12 : 4),
                      bottomLeft: const Radius.circular(12),
                      bottomRight: const Radius.circular(12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: ExtendedText(
                    content,
                    specialTextSpanBuilder: MessageEmojiTextSpanBuilder(),
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF333333),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!isLeft) ...[
            const SizedBox(width: 8),
            _buildAvatar(sender, isLeft),
          ],
        ],
      ),
    );
  }

  // 构建头像
  Widget _buildAvatar(String sender, bool isLeft) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: isLeft ? const Color(0xFF4A90E2) : const Color(0xFF52C41A),
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: Alignment.center,
      child: Text(
        sender.isNotEmpty ? sender[0] : '?',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 通用收藏详情页面
class _GeneralFavoriteDetailPage extends StatefulWidget {
  final FavoriteModel favorite;

  const _GeneralFavoriteDetailPage({required this.favorite});

  @override
  State<_GeneralFavoriteDetailPage> createState() =>
      _GeneralFavoriteDetailPageState();
}

class _GeneralFavoriteDetailPageState
    extends State<_GeneralFavoriteDetailPage> {
  bool _isDownloading = false;
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isVideoInitializing = false;
  String? _videoError;

  @override
  void initState() {
    super.initState();
    // 如果是视频类型，初始化视频播放器
    if (widget.favorite.messageType == 'video') {
      _initializeVideoPlayer();
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  // 初始化视频播放器
  Future<void> _initializeVideoPlayer() async {
    setState(() {
      _isVideoInitializing = true;
      _videoError = null;
    });

    try {
      final videoUrl = widget.favorite.content;
      logger.debug('📹 开始初始化视频播放器');
      logger.debug('📹 视频URL: $videoUrl');
      logger.debug('📹 文件名: ${widget.favorite.fileName}');

      _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl));

      logger.debug('📹 VideoPlayerController 创建成功，开始初始化...');
      await _videoController!.initialize();
      logger.debug('📹 视频初始化成功');
      logger.debug('📹 视频时长: ${_videoController!.value.duration}');
      logger.debug('📹 视频尺寸: ${_videoController!.value.size}');
      logger.debug('📹 视频宽高比: ${_videoController!.value.aspectRatio}');

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: false,
        looping: false,
        aspectRatio: _videoController!.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          logger.error('📹 Chewie播放器错误: $errorMessage');
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  '视频播放失败',
                  style: TextStyle(color: Colors.grey[600], fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  errorMessage,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        },
      );

      logger.debug('📹 ChewieController 创建成功');

      if (mounted) {
        setState(() {
          _isVideoInitializing = false;
          _videoError = null;
        });
      }
    } catch (e, stackTrace) {
      logger.error('❌ 初始化视频播放器失败: $e');
      logger.error('❌ 堆栈跟踪: $stackTrace');

      String errorMessage = '未知错误';
      if (e.toString().contains('403')) {
        errorMessage = '视频访问被拒绝(403)，可能已过期或无权限';
      } else if (e.toString().contains('404')) {
        errorMessage = '视频文件不存在(404)';
      } else if (e.toString().contains('network')) {
        errorMessage = '网络连接失败，请检查网络';
      } else if (e.toString().contains('timeout')) {
        errorMessage = '连接超时，请重试';
      } else if (e.toString().contains('format')) {
        errorMessage = '视频格式不支持';
      } else {
        errorMessage = e.toString();
      }

      if (mounted) {
        setState(() {
          _isVideoInitializing = false;
          _videoError = errorMessage;
        });
      }
    }
  }

  // 下载文件
  Future<void> _downloadFile() async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
    });

    try {
      // 桌面端使用原有的文件选择器方式（不修改PC端代码）
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        await _downloadFileDesktop();
        return;
      }

      // 移动端：使用统一的权限检测方法
      final hasPermission =
          await MobileStoragePermissionHelper.checkAndRequestStoragePermission(
            context,
            forSaving: true,
          );

      if (!hasPermission) {
        return;
      }

      // 显示下载提示
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在下载...')));
      }

      final fileUrl = widget.favorite.content;

      // 确定文件名
      String fileName = widget.favorite.fileName ?? 'download';
      if (!fileName.contains('.')) {
        final uri = Uri.parse(fileUrl);
        final segments = uri.pathSegments;
        if (segments.isNotEmpty) {
          fileName = segments.last;
        } else {
          // 根据消息类型添加扩展名
          if (widget.favorite.messageType == 'image') {
            fileName = '${fileName}.jpg';
          } else if (widget.favorite.messageType == 'video') {
            fileName = '${fileName}.mp4';
          }
        }
      }

      // 下载文件
      final response = await http.get(Uri.parse(fileUrl));
      if (response.statusCode != 200) {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }

      // 获取保存路径
      Directory? directory;
      if (Platform.isAndroid) {
        // Android: 保存到 Downloads 目录
        directory = Directory('/storage/emulated/0/Download/Youdu');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
      } else {
        // iOS: 保存到应用文档目录
        directory = await getApplicationDocumentsDirectory();
      }

      // 保存文件
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);

      logger.debug('文件已保存到: $filePath');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已保存到: ${Platform.isAndroid ? 'Download/Youdu' : '应用文档目录'}/$fileName',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      logger.error('下载文件失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  // 桌面端下载文件（保留原有逻辑）
  Future<void> _downloadFileDesktop() async {
    try {
      final fileUrl = widget.favorite.content;
      String defaultFileName = widget.favorite.fileName ?? 'download';
      if (!defaultFileName.contains('.')) {
        final uri = Uri.parse(fileUrl);
        final segments = uri.pathSegments;
        if (segments.isNotEmpty) {
          defaultFileName = segments.last;
        }
      }

      final String? outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: defaultFileName,
      );

      if (outputPath == null) {
        return;
      }

      final response = await http.get(Uri.parse(fileUrl));

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('下载成功')));
        }
      } else {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  // 获取文件图标
  IconData _getFileIcon(String? fileName) {
    if (fileName == null) return Icons.insert_drive_file;
    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  @override
  Widget build(BuildContext context) {
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
          _getTitle(),
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: _buildContent(),
    );
  }

  String _getTitle() {
    switch (widget.favorite.messageType) {
      case 'image':
        return '收藏的图片';
      case 'file':
        return '收藏的文件';
      case 'video':
        return '收藏的视频';
      default:
        return '收藏的消息';
    }
  }

  Widget _buildContent() {
    switch (widget.favorite.messageType) {
      case 'image':
        return _buildImageContent();
      case 'file':
        return _buildFileContent();
      case 'video':
        return _buildVideoContent();
      default:
        return _buildTextContent();
    }
  }

  Widget _buildTextContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ExtendedText(
          widget.favorite.content,
          specialTextSpanBuilder: MessageEmojiTextSpanBuilder(),
          style: const TextStyle(
            fontSize: 16,
            color: Color(0xFF333333),
            height: 1.6,
          ),
        ),
      ),
    );
  }

  Widget _buildImageContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GestureDetector(
                onTap: () => _showImagePreview(widget.favorite.content),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    widget.favorite.content,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey[300],
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.broken_image,
                              size: 64,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 16),
                            Text('图片加载失败'),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Text(
            '点击图片可放大预览',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: _isDownloading ? null : _downloadFile,
              icon: _isDownloading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_isDownloading ? '下载中...' : '下载图片'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 显示图片预览对话框
  void _showImagePreview(String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Stack(
              children: [
                // 图片内容
                Center(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: 300,
                            height: 300,
                            color: const Color(0xFF333333),
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                  size: 60,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  '图片加载失败',
                                  style: TextStyle(color: Colors.white54, fontSize: 14),
                                ),
                              ],
                            ),
                          );
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            width: 300,
                            height: 300,
                            color: const Color(0xFF333333),
                            child: Center(
                              child: CircularProgressIndicator(
                                value: loadingProgress.expectedTotalBytes != null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                        loadingProgress.expectedTotalBytes!
                                    : null,
                                color: Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                // 关闭按钮
                Positioned(
                  top: 40,
                  right: 20,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 32),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFileContent() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                _getFileIcon(widget.favorite.fileName),
                size: 64,
                color: const Color(0xFF4A90E2),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              widget.favorite.fileName ?? '未知文件',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isDownloading ? null : _downloadFile,
              icon: _isDownloading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_isDownloading ? '下载中...' : '下载文件'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                minimumSize: const Size(200, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoContent() {
    return Column(
      children: [
        // 视频播放器区域
        Expanded(
          child: Container(
            color: Colors.black,
            child: Center(
              child: _isVideoInitializing
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text('视频加载中...', style: TextStyle(color: Colors.white)),
                      ],
                    )
                  : _chewieController != null &&
                        _videoController != null &&
                        _videoController!.value.isInitialized
                  ? Chewie(controller: _chewieController!)
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.white70,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '视频加载失败',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (_videoError != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.red.withOpacity(0.3),
                              ),
                            ),
                            child: Text(
                              _videoError!,
                              style: TextStyle(
                                color: Colors.grey[300],
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () {
                            _initializeVideoPlayer();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新加载'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4A90E2),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        // 视频信息和下载按钮
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 视频文件名
              if (widget.favorite.fileName != null &&
                  widget.favorite.fileName!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.video_library, color: Color(0xFF4A90E2)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.favorite.fileName!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              // 下载按钮
              ElevatedButton.icon(
                onPressed: _isDownloading ? null : _downloadFile,
                icon: _isDownloading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_isDownloading ? '下载中...' : '下载视频'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90E2),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
