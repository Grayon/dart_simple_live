import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

import 'base_player.dart';
import 'exoplayer_player.dart';
import 'mediakit_player.dart';

/// 视频渲染组件配置
class PlayerVideoConfig {
  final bool pauseOnBackground;
  final bool resumeOnForeground;
  final double? aspectRatio;
  final BoxFit fit;
  final Widget Function(BuildContext context)? controlsBuilder;

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
/// 根据播放器引擎类型自动选择渲染 widget：
/// - MediaKitPlayer → media_kit Video widget
/// - ExoPlayerPlayer → video_player VideoPlayer widget
///
/// 监听 player.recreateStream 以在播放器重建后自动重建渲染器。
class PlayerVideo extends StatefulWidget {
  final BasePlayer player;
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
    final player = widget.player;
    final controls = widget.config.controlsBuilder;

    if (player is MediaKitPlayer) {
      final vc = player.videoController;
      if (vc == null) {
        return const SizedBox.expand(child: ColoredBox(color: Colors.black));
      }
      return Video(
        key: widget.videoKey,
        controller: vc,
        pauseUponEnteringBackgroundMode: widget.config.pauseOnBackground,
        resumeUponEnteringForegroundMode: widget.config.resumeOnForeground,
        controls: controls != null
            ? (VideoState state) => controls(state.context)
            : null,
        aspectRatio: widget.config.aspectRatio,
        fit: widget.config.fit,
      );
    }

    if (player is ExoPlayerPlayer) {
      final vc = player.videoController;
      if (vc == null) {
        return const SizedBox.expand(child: ColoredBox(color: Colors.black));
      }
      final video = Center(
        child: AspectRatio(
          aspectRatio: widget.config.aspectRatio ??
              (vc.value.size.width > 0 && vc.value.size.height > 0
                  ? vc.value.size.width / vc.value.size.height
                  : 16 / 9),
          child: vp.VideoPlayer(vc),
        ),
      );
      if (controls == null) return video;
      return Stack(
        children: [
          video,
          Positioned.fill(
            child: Builder(builder: (ctx) => controls(ctx)),
          ),
        ],
      );
    }

    return const SizedBox.expand(child: ColoredBox(color: Colors.black));
  }
}
