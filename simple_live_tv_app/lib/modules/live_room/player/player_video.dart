import 'dart:async';

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
/// 监听 player.recreateStream 以在播放器重建后自动重建渲染器。
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
  StreamSubscription<void>? _recreateSub;

  @override
  void initState() {
    super.initState();
    _recreateSub = widget.player.recreateStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _recreateSub?.cancel();
    super.dispose();
  }

  void updateVideoDisplay({double? aspectRatio, BoxFit? fit}) {
    widget.videoKey?.currentState?.update(
      aspectRatio: aspectRatio,
      fit: fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vc = widget.player.videoController;
    if (vc == null) {
      return const SizedBox.expand(child: ColoredBox(color: Colors.black));
    }
    return Video(
      key: widget.videoKey,
      controller: vc,
      pauseUponEnteringBackgroundMode: widget.config.pauseOnBackground,
      resumeUponEnteringForegroundMode: widget.config.resumeOnForeground,
      controls: widget.config.controlsBuilder,
      aspectRatio: widget.config.aspectRatio,
      fit: widget.config.fit,
    );
  }
}
