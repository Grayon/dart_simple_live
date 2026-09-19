import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'base_player.dart';
import 'exoplayer_player.dart';
import 'ijk_player.dart';
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
/// - ExoPlayerPlayer → Flutter Texture widget（由原生插件创建）
///
/// 监听 player.recreateStream 以在播放器重建后自动重建渲染器。
class PlayerVideo extends StatefulWidget {
  final BasePlayer player;
  final PlayerVideoConfig config;

  const PlayerVideo({
    super.key,
    required this.player,
    this.config = const PlayerVideoConfig(),
  });

  @override
  State<PlayerVideo> createState() => PlayerVideoState();
}

class PlayerVideoState extends State<PlayerVideo> {
  StreamSubscription<void>? _recreateSub;
  StreamSubscription<void>? _vcReadySub;
  StreamSubscription<int>? _textureReadySub;
  int? _exoTextureId;
  double? _aspectRatio;
  BoxFit? _fit;

  @override
  void initState() {
    super.initState();
    _aspectRatio = widget.config.aspectRatio;
    _fit = widget.config.fit;
    _recreateSub = widget.player.recreateStream.listen((_) {
      if (mounted) {
        setState(() {
          _exoTextureId = null;
        });
      }
    });
    final player = widget.player;
    if (player is ExoPlayerPlayer) {
      _exoTextureId = player.textureId;
      _textureReadySub = player.textureReadyStream.listen((id) {
        if (mounted) {
          setState(() => _exoTextureId = id);
        }
      });
    } else if (player is IjkPlayer) {
      _exoTextureId = player.textureId;
      _textureReadySub = player.textureReadyStream.listen((id) {
        if (mounted) {
          setState(() => _exoTextureId = id);
        }
      });
    } else if (player is MediaKitPlayer) {
      _vcReadySub = player.videoControllerReadyStream.listen((_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _recreateSub?.cancel();
    _vcReadySub?.cancel();
    _textureReadySub?.cancel();
    super.dispose();
  }

  int? _getTextureId(BasePlayer player) {
    if (player is ExoPlayerPlayer) return player.textureId;
    if (player is IjkPlayer) return player.textureId;
    return null;
  }

  void updateVideoDisplay({double? aspectRatio, BoxFit? fit}) {
    if (aspectRatio != null) _aspectRatio = aspectRatio;
    if (fit != null) _fit = fit;
    if (mounted) setState(() {});
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
        key: ValueKey(vc),
        controller: vc,
        pauseUponEnteringBackgroundMode: widget.config.pauseOnBackground,
        resumeUponEnteringForegroundMode: widget.config.resumeOnForeground,
        controls: controls != null
            ? (VideoState state) => controls(state.context)
            : null,
        aspectRatio: _aspectRatio,
        fit: _fit ?? BoxFit.contain,
      );
    }

    if (player is ExoPlayerPlayer || player is IjkPlayer) {
      final textureId = _exoTextureId ?? _getTextureId(player);
      if (textureId == null) {
        return const SizedBox.expand(child: ColoredBox(color: Colors.black));
      }
      final video = Center(
        child: AspectRatio(
          aspectRatio: _aspectRatio ?? 16 / 9,
          child: Texture(textureId: textureId),
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
