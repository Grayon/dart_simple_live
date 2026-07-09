import 'dart:async';

import 'package:video_player/video_player.dart' as vp;

import 'base_player.dart';

/// ExoPlayer (Media3) 播放器实现
///
/// 通过 video_player 包使用 Android 原生 ExoPlayer/Media3 引擎。
/// 优势：与 Android TV 系统兼容性更好，MediaCodec 硬解更稳定
/// 劣势：Dart 层不暴露缓冲/解码器精细控制（由 ExoPlayer 自动管理）
class ExoPlayerPlayer implements BasePlayer {
  final PlayerConfig _config;
  vp.VideoPlayerController? _controller;
  bool _disposed = false;

  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _widthController = StreamController<int?>.broadcast();
  final _heightController = StreamController<int?>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _logController = StreamController<PlayerLogEntry>.broadcast();

  final _recreateController = StreamController<void>.broadcast();
  @override
  Stream<void> get recreateStream => _recreateController.stream;

  vp.VideoPlayerController? get videoController => _controller;

  ExoPlayerPlayer(this._config);

  @override
  PlayerState get state {
    final c = _controller;
    if (c == null) return const PlayerState();
    return PlayerState(
      playing: c.value.isPlaying,
      buffering: c.value.isBuffering,
      width: c.value.size.width > 0 ? c.value.size.width.toInt() : null,
      height: c.value.size.height > 0 ? c.value.size.height.toInt() : null,
    );
  }

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Stream<int?> get widthStream => _widthController.stream;

  @override
  Stream<int?> get heightStream => _heightController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Stream<PlayerLogEntry> get logStream => _logController.stream;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    if (_disposed) return;

    await _controller?.dispose();

    _controller = vp.VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? {},
      videoPlayerOptions: vp.VideoPlayerOptions(mixWithOthers: true),
    );

    _controller!.addListener(_onControllerUpdate);

    try {
      await _controller!.initialize();
      _controller!.play();
    } catch (e) {
      _errorController.add('ExoPlayer 初始化失败: $e');
    }
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;

    _playingController.add(v.isPlaying);
    _bufferingController.add(v.isBuffering);

    if (v.size.width > 0) {
      _widthController.add(v.size.width.toInt());
    }
    if (v.size.height > 0) {
      _heightController.add(v.size.height.toInt());
    }

    if (v.hasError) {
      _errorController.add(v.errorDescription ?? 'ExoPlayer 播放错误');
    }

    // 直播流不会自然 completed，这里不处理
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    if (c == null) return;
    await c.pause();
    _playingController.add(false);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller?.removeListener(_onControllerUpdate);
    await _controller?.dispose();
    _controller = null;
    await _playingController.close();
    await _bufferingController.close();
    await _widthController.close();
    await _heightController.close();
    await _errorController.close();
    await _completedController.close();
    await _logController.close();
    await _recreateController.close();
  }

  @override
  Future<void> recreate() async {
    if (_disposed) return;
    _controller?.removeListener(_onControllerUpdate);
    await _controller?.dispose();
    _controller = null;
    _recreateController.add(null);
  }

  @override
  Future<void> setProperty(String key, String value) async {
    // ExoPlayer via video_player 不支持运行时属性设置
  }

  @override
  Future<String?> getProperty(String key) async {
    return null;
  }

  @override
  Future<void> applyVideoRenderConfig(VideoRenderConfig config) async {
    // ExoPlayer 自动管理渲染配置，无需手动设置
  }
}
