import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mediakit_player.dart';

/// 视频渲染组件配置
class PlayerVideoConfig {
  final bool pauseOnBackground;
  final bool resumeOnForeground;
  final double? aspectRatio;
  final BoxFit fit;
  final Widget Function(VideoState state)? controlsBuilder;

  const PlayerVideoConfig({
    this.pauseOnBackground = true,
    this.resumeOnForeground = true,
    this.aspectRatio,
    this.fit = BoxFit.contain,
    this.controlsBuilder,
  });
}

/// 视频渲染组件
///
/// 封装 media_kit 的 Video widget，对外暴露统一接口。
class PlayerVideo extends StatefulWidget {
  final MediaKitPlayer player;
  final GlobalKey<VideoState>? videoKey;
  final PlayerVideoConfig config;

  const PlayerVideo({
    super.key,
    required this.player,
    this.videoKey,
    this.config = const PlayerVideoConfig(),
  });

  @override
  State<PlayerVideo> createState() => PlayerVideoState();
}

class PlayerVideoState extends State<PlayerVideo> {
  void updateVideoDisplay({double? aspectRatio, BoxFit? fit}) {
    widget.videoKey?.currentState?.update(
      aspectRatio: aspectRatio,
      fit: fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Video(
      key: widget.videoKey,
      controller: widget.player.videoController,
      pauseUponEnteringBackgroundMode: widget.config.pauseOnBackground,
      resumeUponEnteringForegroundMode: widget.config.resumeOnForeground,
      controls: widget.config.controlsBuilder,
      aspectRatio: widget.config.aspectRatio,
      fit: widget.config.fit,
    );
  }
}
