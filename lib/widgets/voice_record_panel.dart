import 'dart:async';
import 'package:flutter/material.dart';
import '../services/voice_record_service.dart';

/// 语音录制面板 - 优化版
class VoiceRecordPanel extends StatefulWidget {
  final Function(String filePath, int duration) onRecordComplete;

  const VoiceRecordPanel({
    super.key,
    required this.onRecordComplete,
  });

  @override
  State<VoiceRecordPanel> createState() => _VoiceRecordPanelState();
}

class _VoiceRecordPanelState extends State<VoiceRecordPanel>
    with SingleTickerProviderStateMixin {
  final VoiceRecordService _recordService = VoiceRecordService();
  bool _isCancelling = false;
  double _startY = 0;
  Timer? _updateTimer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // 脉冲动画控制器
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 初始化录音服务
    _recordService.init().catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('录音器初始化失败: $e')),
        );
      }
    });

    // 设置回调
    _recordService.onMaxDurationReached = () {
      if (mounted) {
        _stopAndSend();
      }
    };

    // 设置时长更新回调
    _recordService.onDurationUpdate = (duration) {
      if (mounted) {
        setState(() {});
      }
    };
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _stopAndSend() async {
    _pulseController.stop();
    final result = await _recordService.stopRecording();
    if (mounted) {
      Navigator.pop(context);
      if (result != null) {
        widget.onRecordComplete(
          result['path'] as String,
          result['duration'] as int,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          // 拖动指示器
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          // 标题区域
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Text(
                  '语音消息',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[800],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '最长60秒',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // 录音状态显示区域
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _recordService.isRecording
                ? _buildRecordingIndicator()
                : const SizedBox(height: 60),
          ),
          const SizedBox(height: 20),
          // 录音按钮
          _buildRecordButton(),
          const SizedBox(height: 16),
          // 提示文字
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              _recordService.isRecording
                  ? (_isCancelling ? '松开取消发送' : '↑ 上滑取消')
                  : '长按开始录音',
              key: ValueKey(_recordService.isRecording.toString() + _isCancelling.toString()),
              style: TextStyle(
                fontSize: 13,
                color: _isCancelling ? Colors.red[400] : Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 36),
        ],
      ),
    );
  }

  // 录音状态指示器
  Widget _buildRecordingIndicator() {
    final duration = _recordService.currentDuration;
    final minutes = (duration ~/ 60).toString().padLeft(2, '0');
    final seconds = (duration % 60).toString().padLeft(2, '0');

    return Container(
      key: const ValueKey('recording'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: _isCancelling 
            ? Colors.red.withValues(alpha: 0.08)
            : const Color(0xFF4A90E2).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 录音波形动画
          _buildWaveAnimation(),
          const SizedBox(width: 12),
          // 时间显示
          Text(
            '$minutes:$seconds',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: _isCancelling ? Colors.red[400] : const Color(0xFF4A90E2),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          // 录音波形动画（右侧）
          _buildWaveAnimation(),
        ],
      ),
    );
  }

  // 波形动画
  Widget _buildWaveAnimation() {
    return SizedBox(
      width: 32,
      height: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(4, (index) {
          return _WaveBar(
            index: index,
            isActive: _recordService.isRecording && !_isCancelling,
            color: _isCancelling ? Colors.red[300]! : const Color(0xFF4A90E2),
          );
        }),
      ),
    );
  }

  // 录音按钮
  Widget _buildRecordButton() {
    return GestureDetector(
      onLongPressStart: (details) async {
        _startY = details.globalPosition.dy;
        final success = await _recordService.startRecording();
        if (success && mounted) {
          _pulseController.repeat(reverse: true);
          setState(() {});
        }
      },
      onLongPressMoveUpdate: (details) {
        final deltaY = _startY - details.globalPosition.dy;
        setState(() {
          _isCancelling = deltaY > 50;
        });
      },
      onLongPressEnd: (details) async {
        _pulseController.stop();
        if (_isCancelling) {
          await _recordService.cancelRecording();
          if (mounted) {
            Navigator.pop(context);
          }
        } else {
          await _stopAndSend();
        }
        if (mounted) {
          setState(() {
            _isCancelling = false;
          });
        }
      },
      onLongPressCancel: () async {
        _pulseController.stop();
        await _recordService.cancelRecording();
        if (mounted) {
          setState(() {
            _isCancelling = false;
          });
        }
      },
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          final scale = _recordService.isRecording ? _pulseAnimation.value : 1.0;
          return Transform.scale(
            scale: scale,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _recordService.isRecording ? 80 : 70,
              height: _recordService.isRecording ? 80 : 70,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _isCancelling
                      ? [Colors.red[400]!, Colors.red[600]!]
                      : [const Color(0xFF5B9FE8), const Color(0xFF4A90E2)],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (_isCancelling ? Colors.red : const Color(0xFF4A90E2))
                        .withValues(alpha: _recordService.isRecording ? 0.4 : 0.25),
                    blurRadius: _recordService.isRecording ? 24 : 16,
                    spreadRadius: _recordService.isRecording ? 4 : 2,
                  ),
                ],
              ),
              child: Icon(
                _isCancelling ? Icons.close_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: _recordService.isRecording ? 36 : 32,
              ),
            ),
          );
        },
      ),
    );
  }
}

// 波形条动画组件
class _WaveBar extends StatefulWidget {
  final int index;
  final bool isActive;
  final Color color;

  const _WaveBar({
    required this.index,
    required this.isActive,
    required this.color,
  });

  @override
  State<_WaveBar> createState() => _WaveBarState();
}

class _WaveBarState extends State<_WaveBar> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: Duration(milliseconds: 300 + widget.index * 100),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_WaveBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0.3;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 4,
          height: 24 * (widget.isActive ? _animation.value : 0.3),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: widget.isActive ? 1.0 : 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}
