import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:audioplayers/audioplayers.dart' as audioplayers;
import 'package:flutter_sound/flutter_sound.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';

/// 语音消息气泡组件
/// 
/// 功能：
/// - 显示语音时长
/// - 点击播放/暂停
/// - 播放进度动画
/// - 支持OPUS格式
class VoiceMessageBubble extends StatefulWidget {
  final String url; // 语音文件URL
  final int duration; // 语音时长（秒）
  final bool isMe; // 是否是自己发送的消息

  const VoiceMessageBubble({
    super.key,
    required this.url,
    required this.duration,
    required this.isMe,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble>
    with SingleTickerProviderStateMixin {
  // 根据平台选择不同的播放器
  final bool _isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  
  // just_audio 播放器（Android）
  just_audio.AudioPlayer? _justAudioPlayer;
  
  // audioplayers 播放器（桌面端）
  audioplayers.AudioPlayer? _audioPlayersPlayer;
  
  // flutter_sound 播放器（iOS）- 参考官方示例
  FlutterSoundPlayer? _flutterSoundPlayer;
  bool _flutterSoundPlayerInited = false;
  
  // 播放状态
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  
  // 本地缓存文件路径
  String? _localFilePath;
  
  // 动画控制器
  late AnimationController _animationController;
  
  // 订阅（just_audio）
  StreamSubscription<just_audio.PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  
  // 订阅（audioplayers）
  StreamSubscription<void>? _audioPlayersCompleteSubscription;
  StreamSubscription<Duration>? _audioPlayersPositionSubscription;
  StreamSubscription<Duration>? _audioPlayersDurationSubscription;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    // 根据平台初始化不同的播放器
    // iOS 使用 flutter_sound（参考官方示例，最可靠）
    // Android 使用 just_audio
    // 桌面端使用 audioplayers
    if (Platform.isIOS) {
      _initFlutterSoundPlayer();
    } else if (_isDesktop) {
      _audioPlayersPlayer = audioplayers.AudioPlayer();
      _setupAudioPlayersPlayer();
    } else {
      _justAudioPlayer = just_audio.AudioPlayer();
      _setupJustAudioPlayer();
    }
  }
  
  /// 初始化 flutter_sound 播放器（iOS）- 参考官方示例
  Future<void> _initFlutterSoundPlayer() async {
    _flutterSoundPlayer = FlutterSoundPlayer();
    
    try {
      // 打开播放器
      await _flutterSoundPlayer!.openPlayer();
      
      // 配置音频会话（参考官方示例）
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
      
      if (mounted) {
        setState(() {
          _flutterSoundPlayerInited = true;
        });
      }
      logger.debug('✅ flutter_sound 播放器初始化成功');
    } catch (e) {
      logger.error('❌ flutter_sound 播放器初始化失败', error: e);
    }
  }

  void _setupJustAudioPlayer() {
    if (_justAudioPlayer == null) return;
    
    // 监听播放状态
    _playerStateSubscription = _justAudioPlayer!.playerStateStream.listen((state) {
      if (!mounted) return;
      
      setState(() {
        _isPlaying = state.playing;
        _isLoading = state.processingState == just_audio.ProcessingState.loading ||
                     state.processingState == just_audio.ProcessingState.buffering;
      });
      
      if (state.playing) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
      
      // 播放完成后重置
      if (state.processingState == just_audio.ProcessingState.completed) {
        _justAudioPlayer!.seek(Duration.zero);
        _justAudioPlayer!.pause();
      }
    });
    
    // 监听播放位置
    _positionSubscription = _justAudioPlayer!.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });
    });
    
    // 监听总时长
    _durationSubscription = _justAudioPlayer!.durationStream.listen((duration) {
      if (!mounted) return;
      if (duration != null) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });
  }
  
  void _setupAudioPlayersPlayer() {
    if (_audioPlayersPlayer == null) return;
    
    // 监听播放完成
    _audioPlayersCompleteSubscription = _audioPlayersPlayer!.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _currentPosition = Duration.zero;
      });
      _animationController.reverse();
    });
    
    // 监听播放位置
    _audioPlayersPositionSubscription = _audioPlayersPlayer!.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });
    });
    
    // 监听总时长
    _audioPlayersDurationSubscription = _audioPlayersPlayer!.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() {
        _totalDuration = duration;
        _isLoading = false;
      });
    });
  }

  @override
  void dispose() {
    // just_audio 订阅
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    
    // audioplayers 订阅
    _audioPlayersCompleteSubscription?.cancel();
    _audioPlayersPositionSubscription?.cancel();
    _audioPlayersDurationSubscription?.cancel();
    
    _animationController.dispose();
    
    // 释放播放器
    _justAudioPlayer?.dispose();
    _audioPlayersPlayer?.dispose();
    _flutterSoundPlayer?.closePlayer();
    
    super.dispose();
  }

  /// 下载语音文件到本地缓存
  Future<String?> _downloadVoiceFile() async {
    try {
      // 如果已经下载过，直接返回
      if (_localFilePath != null && File(_localFilePath!).existsSync()) {
        return _localFilePath;
      }

      logger.debug('🎤 开始下载语音文件: ${widget.url}');
      
      // 获取临时目录
      final tempDir = await getTemporaryDirectory();
      final fileName = widget.url.split('/').last;
      final filePath = '${tempDir.path}/voice_cache/$fileName';
      
      // 创建目录
      final file = File(filePath);
      await file.parent.create(recursive: true);
      
      // 下载文件
      final response = await http.get(Uri.parse(widget.url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        _localFilePath = filePath;
        logger.debug('✅ 语音文件下载成功: $filePath');
        return filePath;
      } else {
        logger.error('❌ 下载语音文件失败: HTTP ${response.statusCode}');
        return null;
      }
    } catch (e) {
      logger.error('❌ 下载语音文件异常', error: e);
      return null;
    }
  }

  Future<void> _togglePlay() async {
    try {
      // 🔴 iOS 使用 flutter_sound（先下载到本地再播放）
      if (Platform.isIOS && _flutterSoundPlayer != null) {
        if (!_flutterSoundPlayerInited) {
          logger.debug('⏳ flutter_sound 播放器尚未初始化');
          return;
        }
        
        if (_isPlaying) {
          await _flutterSoundPlayer!.stopPlayer();
          setState(() {
            _isPlaying = false;
            _currentPosition = Duration.zero;
          });
          _animationController.reverse();
        } else {
          setState(() {
            _isLoading = true;
          });
          
          logger.debug('🎤 [iOS] 开始加载语音文件: ${widget.url}');
          
          // 先下载到本地
          final localPath = await _downloadVoiceFile();
          if (localPath == null) {
            throw Exception('下载语音文件失败');
          }
          
          logger.debug('🎤 [iOS] 使用本地文件播放: $localPath');
          
          // 使用本地文件播放，让系统自动检测编解码器
          await _flutterSoundPlayer!.startPlayer(
            fromURI: localPath,
            codec: Codec.defaultCodec,  // 让系统自动检测
            whenFinished: () {
              if (!mounted) return;
              setState(() {
                _isPlaying = false;
                _currentPosition = Duration.zero;
              });
              _animationController.reverse();
              logger.debug('✅ [iOS] 语音播放完成');
            },
          );
          
          setState(() {
            _isPlaying = true;
            _isLoading = false;
            _totalDuration = Duration(seconds: widget.duration);
          });
          _animationController.forward();
          logger.debug('✅ [iOS] 语音开始播放');
        }
      } else if (_isDesktop && _audioPlayersPlayer != null) {
        // 桌面端使用 audioplayers
        if (_isPlaying) {
          await _audioPlayersPlayer!.pause();
          setState(() {
            _isPlaying = false;
          });
          _animationController.reverse();
        } else {
          setState(() {
            _isLoading = true;
          });
          await _audioPlayersPlayer!.play(audioplayers.UrlSource(widget.url));
          setState(() {
            _isPlaying = true;
            _isLoading = false;
          });
          _animationController.forward();
        }
      } else if (_justAudioPlayer != null) {
        // Android 使用 just_audio
        if (_isPlaying) {
          await _justAudioPlayer!.pause();
        } else {
          // 如果还没加载，先加载
          if (_justAudioPlayer!.audioSource == null) {
            setState(() {
              _isLoading = true;
            });
            
            logger.debug('🎤 [Android] 开始加载语音文件: ${widget.url}');
            
            // Android 可以直接播放网络URL
            await _justAudioPlayer!.setUrl(widget.url);
            logger.debug('✅ 语音文件加载成功（网络URL）');
          }
          await _justAudioPlayer!.play();
        }
      }
    } catch (e) {
      logger.error('播放语音失败', error: e);
      setState(() {
        _isLoading = false;
        _isPlaying = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败: ${e.toString()}')),
        );
      }
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '$minutes:${secs.toString().padLeft(2, '0')}';
    }
    return '$secs"';
  }

  @override
  Widget build(BuildContext context) {
    // 计算气泡宽度（根据时长动态调整，最小100，最大200）
    final bubbleWidth = 100.0 + (widget.duration / 60.0 * 100.0).clamp(0.0, 100.0);
    
    // 计算播放进度
    final progress = _totalDuration.inMilliseconds > 0
        ? _currentPosition.inMilliseconds / _totalDuration.inMilliseconds
        : 0.0;

    return GestureDetector(
      onTap: _togglePlay,
      child: Container(
        width: bubbleWidth,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: widget.isMe ? const Color(0xFFBDD7F3) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 播放按钮/加载指示器
            SizedBox(
              width: 18,
              height: 18,
              child: _isLoading
                  ? const CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                    )
                  : AnimatedIcon(
                      icon: AnimatedIcons.play_pause,
                      progress: _animationController,
                      size: 18,
                      color: widget.isMe ? Colors.black87 : Colors.grey[700],
                    ),
            ),
            const SizedBox(width: 6),
            // 波形动画
            Expanded(
              child: _buildWaveform(progress),
            ),
            const SizedBox(width: 6),
            // 时长显示
            Text(
              _isPlaying
                  ? _formatDuration(_currentPosition.inSeconds)
                  : _formatDuration(widget.duration),
              style: TextStyle(
                fontSize: 11,
                color: widget.isMe ? Colors.black54 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaveform(double progress) {
    return SizedBox(
      height: 18,
      child: CustomPaint(
        painter: _WaveformPainter(
          progress: progress,
          isMe: widget.isMe,
          isPlaying: _isPlaying,
        ),
        child: Container(),
      ),
    );
  }
}

/// 波形图绘制器
class _WaveformPainter extends CustomPainter {
  final double progress;
  final bool isMe;
  final bool isPlaying;

  _WaveformPainter({
    required this.progress,
    required this.isMe,
    required this.isPlaying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // 波形数据（模拟）
    final waveData = [
      0.3, 0.5, 0.8, 0.4, 0.9, 0.6, 0.7, 0.5, 0.8, 0.4,
      0.6, 0.9, 0.5, 0.7, 0.4, 0.8, 0.6, 0.5, 0.7, 0.3,
    ];

    const barWidth = 2.0;
    const barSpacing = 2.0;
    final totalBars = (size.width / (barWidth + barSpacing)).floor();

    for (int i = 0; i < totalBars && i < waveData.length; i++) {
      final x = i * (barWidth + barSpacing) + barWidth / 2;
      final barHeight = waveData[i % waveData.length] * size.height * 0.8;
      final y1 = (size.height - barHeight) / 2;
      final y2 = y1 + barHeight;

      // 根据播放进度设置颜色
      if (progress > 0 && i / totalBars <= progress) {
        paint.color = isMe
            ? Colors.black.withOpacity(0.7)
            : const Color(0xFF4A90E2);
      } else {
        paint.color = isMe
            ? Colors.black.withOpacity(0.3)
            : Colors.grey.withOpacity(0.4);
      }

      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isPlaying != isPlaying;
  }
}
