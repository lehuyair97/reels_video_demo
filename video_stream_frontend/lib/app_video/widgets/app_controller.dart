import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class AppController extends StatefulWidget {
  final VideoPlayerController controller;
  const AppController({super.key, required this.controller});
  @override
  State<AppController> createState() => _AppControllerState();
}

class _AppControllerState extends State<AppController> {
  bool _showPlayPause = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
  }

  void _onControllerUpdate() {
    if (mounted) setState(() {});
  }

  void _onTogglePlay() {
    _hideTimer?.cancel();
    setState(() {
      _showPlayPause = true;
    });
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showPlayPause = false;
        });
      }
    });
    if (!mounted || !widget.controller.value.isInitialized) return;
    try {
      if (widget.controller.value.isPlaying) {
        widget.controller.pause();
      } else {
        widget.controller.play();
      }
    } catch (e) {
      debugPrint('AppController: controller disposed or error: $e');
    }
  }

  void _onTapVideo() {
    _hideTimer?.cancel();
    setState(() {
      _showPlayPause = true;
    });
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showPlayPause = false;
        });
      }
    });
  }

  void _onSeek(double value) {
    if (!mounted || !widget.controller.value.isInitialized) return;
    try {
      final duration = widget.controller.value.duration;
      final seekTo = duration * value;
      widget.controller.seekTo(seekTo);
    } catch (e) {
      debugPrint('AppController: controller disposed or error: $e');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isInit = mounted && widget.controller.value.isInitialized;
    final isPlay = isInit ? widget.controller.value.isPlaying : false;
    final position = isInit ? widget.controller.value.position : Duration.zero;
    final duration = isInit ? widget.controller.value.duration : Duration.zero;
    return GestureDetector(
      onTap: _onTapVideo,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _showPlayPause ? 1 : 0,
            child: GestureDetector(
              onTap: _onTogglePlay,
              child: Container(
                color: Colors.transparent,
                width: double.infinity,
                height: double.infinity,
                child: Center(
                  child: Icon(
                    isPlay ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white,
                    size: 64,
                  ),
                ),
              ),
            ),
          ),
          // Progress bar luôn ở dưới cùng
          if (isInit)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value:
                      duration.inMilliseconds == 0
                          ? 0
                          : position.inMilliseconds / duration.inMilliseconds,
                  onChanged: (value) => _onSeek(value),
                  activeColor: Colors.white,
                  inactiveColor: Colors.white38,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
