import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../utils/logger.dart';

/// 移动端资讯页面
class MobileNewsPage extends StatefulWidget {
  const MobileNewsPage({Key? key}) : super(key: key);

  @override
  State<MobileNewsPage> createState() => _MobileNewsPageState();
}

class _MobileNewsPageState extends State<MobileNewsPage>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  bool _isLoading = true;
  String _currentUrl = 'https://mil.huanqiu.com/';
  bool _isDisposed = false;

  @override
  bool get wantKeepAlive => true;

  // 预设的新闻网站
  final List<Map<String, String>> _newsWebsites = [
    {'name': '环球军事', 'url': 'https://mil.huanqiu.com/'},
    {'name': '新浪新闻', 'url': 'https://news.sina.com.cn/'},
    {'name': '腾讯新闻', 'url': 'https://news.qq.com/'},
    {'name': '网易新闻', 'url': 'https://news.163.com/'},
    {'name': '搜狐新闻', 'url': 'https://news.sohu.com/'},
    {'name': '凤凰网', 'url': 'https://www.ifeng.com/'},
    {'name': 'BBC中文', 'url': 'https://www.bbc.com/zhongwen/simp'},
  ];

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
    }
    super.dispose();
  }

  void _initializeWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      // 设置桌面端 User-Agent，让网站识别为PC端浏览器
      // ..setUserAgent(
      //   'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      // )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (mounted && !_isDisposed) {
              setState(() {
                _isLoading = true;
                _currentUrl = url;
              });
            }
          },
          onPageFinished: (url) {
            if (mounted && !_isDisposed) {
              setState(() => _isLoading = false);
            }
          },
          onWebResourceError: (error) {
            logger.error('WebView加载错误: ${error.description}');
            if (mounted && !_isDisposed) {
              setState(() => _isLoading = false);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _loadUrl(String url) {
    if (_isDisposed) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    _controller.loadRequest(Uri.parse(url));
  }

  void _showQuickLinks() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '快速访问',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _newsWebsites.length,
                itemBuilder: (context, index) {
                  final site = _newsWebsites[index];
                  return ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          site['name']![0],
                          style: const TextStyle(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ),
                    title: Text(site['name']!),
                    subtitle: Text(
                      site['url']!,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      _loadUrl(site['url']!);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      body: Column(
        children: [
          // 工具栏
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                // 后退按钮
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () async {
                    if (await _controller.canGoBack()) {
                      _controller.goBack();
                    }
                  },
                ),

                // 前进按钮
                IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 20),
                  onPressed: () async {
                    if (await _controller.canGoForward()) {
                      _controller.goForward();
                    }
                  },
                ),

                const Spacer(),

                // 刷新按钮
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => _controller.reload(),
                ),

                // 更多选项
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onPressed: _showQuickLinks,
                ),
              ],
            ),
          ),

          // WebView内容区域
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),

                // 加载指示器
                if (_isLoading)
                  const LinearProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF4A90E2),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
