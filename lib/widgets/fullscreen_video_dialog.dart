import 'package:flutter/material.dart';
import 'package:tencent_calls_uikit/tencent_calls_uikit.dart';

/// 全屏视频展示弹窗
/// 用于在群组视频通话中全屏展示某个成员的摄像头画面
/// 
/// 注意：TUICallKit 提供了内置的视频视图组件 TUICallVideoView
class FullscreenVideoDialog extends StatefulWidget {
  final String memberName;
  final int userId;
  final bool isLocalVideo;
  final String? channelId;
  final bool isMobile;

  const FullscreenVideoDialog({
    super.key,
    required this.memberName,
    required this.userId,
    this.isLocalVideo = false,
    this.channelId,
    this.isMobile = false,
  });

  @override
  State<FullscreenVideoDialog> createState() => _FullscreenVideoDialogState();

  /// 显示全屏视频对话框
  static Future<void> show({
    required BuildContext context,
    required String memberName,
    required int userId,
    bool isLocalVideo = false,
    String? channelId,
    bool isMobile = false,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black,
      builder: (context) => FullscreenVideoDialog(
        memberName: memberName,
        userId: userId,
        isLocalVideo: isLocalVideo,
        channelId: channelId,
        isMobile: isMobile,
      ),
    );
  }
}

class _FullscreenVideoDialogState extends State<FullscreenVideoDialog> {
  Widget? _fullscreenVideoView;

  @override
  void initState() {
    super.initState();
    _createFullscreenVideoView();
  }

  @override
  void dispose() {
    _fullscreenVideoView = null;
    super.dispose();
  }

  /// 创建全屏视频视图
  void _createFullscreenVideoView() {
    try {
      // TUICallKit 的 CallVideoView 不接受 userId 参数
      // 它会自动显示当前通话的视频流
      // 对于全屏显示，我们使用 CallVideoView 组件
      _fullscreenVideoView = const CallVideoView();
      
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('❌ 创建全屏视频视图失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          // 全屏视频内容
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.isMobile ? () {
                debugPrint('📱 [移动端全屏] 点击视频区域，关闭全屏弹窗');
                Navigator.of(context).pop();
              } : null,
              child: Container(
                color: Colors.black,
                child: Center(
                  child: _fullscreenVideoView != null
                      ? widget.isMobile
                          ? SizedBox.expand(
                              child: ClipRRect(
                                borderRadius: BorderRadius.zero,
                                child: _fullscreenVideoView!,
                              ),
                            )
                          : AspectRatio(
                              aspectRatio: 16 / 9,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _fullscreenVideoView!,
                              ),
                            )
                      : _buildPlaceholder(),
                ),
              ),
            ),
          ),

          // 顶部信息栏
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: widget.isMobile ? 50 : 40,
                left: widget.isMobile ? 16 : 20,
                right: widget.isMobile ? 16 : 20,
                bottom: widget.isMobile ? 16 : 20,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.memberName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.isLocalVideo ? '本地视频' : '远程视频',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        debugPrint('📹 [全屏视频] 点击关闭按钮');
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(widget.isMobile ? 28 : 24),
                      child: Container(
                        width: widget.isMobile ? 56 : 48,
                        height: widget.isMobile ? 56 : 48,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(widget.isMobile ? 28 : 24),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.3),
                            width: widget.isMobile ? 2 : 1,
                          ),
                        ),
                        child: Icon(
                          Icons.close,
                          color: Colors.white,
                          size: widget.isMobile ? 28 : 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 底部操作栏
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                left: widget.isMobile ? 16 : 20,
                right: widget.isMobile ? 16 : 20,
                bottom: widget.isMobile ? 50 : 40,
                top: widget.isMobile ? 16 : 20,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.isMobile)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '点击屏幕任意位置关闭全屏',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  if (widget.isMobile) const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'ID: ${widget.userId}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    if (widget.isMobile) {
      return SizedBox.expand(
        child: Container(
          color: Colors.grey[900],
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.isLocalVideo ? Icons.videocam : Icons.person,
                size: 120,
                color: Colors.white54,
              ),
              const SizedBox(height: 24),
              Text(
                widget.isLocalVideo ? '本地视频' : '远程视频',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '正在连接视频...',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      return Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(100),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.isLocalVideo ? Icons.videocam : Icons.person,
              size: 60,
              color: Colors.white54,
            ),
            const SizedBox(height: 12),
            Text(
              widget.isLocalVideo ? '本地视频' : '远程视频',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }
  }
}
