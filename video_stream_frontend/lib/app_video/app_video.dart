import 'package:flutter/material.dart';

import 'package:video_stream_frontend/app_video/widgets/app_controller.dart';
import 'package:video_player/video_player.dart';

class AppVideo extends StatelessWidget {
  final VideoPlayerController controller;
  final ImageProvider? thumbnail;
  final bool isActive;

  const AppVideo({
    super.key,
    required this.controller,
    this.thumbnail,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final showVideo = controller.value.isInitialized && isActive;
    print(
      '[AppVideo] Controller state: initialized=${controller.value.isInitialized}, playing=${controller.value.isPlaying}, isActive=$isActive, showVideo=$showVideo,position=${controller.value.position}, duration=${controller.value.duration}, thumbnail=${thumbnail != null}',
    );
    return Stack(
      fit: StackFit.expand,
      children: [if (showVideo) VideoPlayer(controller)],
    );
  }
}
