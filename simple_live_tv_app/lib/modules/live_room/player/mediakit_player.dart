import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'base_player.dart';

/// media_kit (mpv) 播放器实现
class MediaKitPlayer implements BasePlayer {
  final PlayerConfig _config;
  Player _player;
  VideoController? _videoController;
  VideoRenderConfig? _currentRenderConfig;
  bool _disposed = false;

  // 广播流控制器，recreate 时重新绑定底层流
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _widthController = StreamController<int?>.broadcast();
  final _heightController = StreamController<int?>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _logController = StreamController<PlayerLogEntry>.broadcast();

  // 重建通知（PlayerVideo 监听此流来重建渲染器）
  final _recreateController = StreamController<void>.broadcast();
  Stream<void> get recreateStream => _recreateController.stream;

  List<StreamSubscription> _subscriptions = [];

  MediaKitPlayer(this._config)
      : _player = Player(
          configuration: PlayerConfiguration(
            title: _config.title,
            logLevel: _toMpvLogLevel(_config.logLevel),
            bufferSize: _config.bufferSizeBytes,
          ),
        );

  VideoController? get videoController => _videoController;

  void initVideoController(VideoRenderConfig config) {
    _currentRenderConfig = config;
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: config.enableHardwareAcceleration,
        vo: config.vo,
        hwdec: config.hwdec,
        androidAttachSurfaceAfterVideoParameters:
            config.androidAttachSurfaceAfterVideoParameters,
      ),
    );
    _bindStreams();
  }

  void _bindStreams() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions = [];

    _subscriptions.add(
      _player.stream.playing.listen((e) => _playingController.add(e)),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((e) => _bufferingController.add(e)),
    );
    _subscriptions.add(
      _player.stream.width.listen((e) => _widthController.add(e)),
    );
    _subscriptions.add(
      _player.stream.height.listen((e) => _heightController.add(e)),
    );
    _subscriptions.add(
      _player.stream.error.listen((e) => _errorController.add(e)),
    );
    _subscriptions.add(
      _player.stream.completed
          .map((e) => e == true)
          .listen((e) => _completedController.add(e)),
    );
    _subscriptions.add(
      _player.stream.log
          .map(_toPlayerLogEntry)
          .listen((e) => _logController.add(e)),
    );
  }

  @override
  PlayerState get state => PlayerState(
        playing: _player.state.playing,
        buffering: _player.state.buffering,
        width: _player.state.width,
        height: _player.state.height,
      );

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
    await _player.open(
      Media(url, httpHeaders: headers),
    );
  }

  @override
  Future<void> stop() async {
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
    await _player.dispose();
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
    final renderConfig = _currentRenderConfig;

    // 取消旧订阅
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions = [];

    // 销毁旧播放器和渲染器
    await _player.dispose();

    // 创建新播放器
    _player = Player(
      configuration: PlayerConfiguration(
        title: _config.title,
        logLevel: _toMpvLogLevel(_config.logLevel),
        bufferSize: _config.bufferSizeBytes,
      ),
    );

    // 重建 VideoController
    if (renderConfig != null) {
      _videoController = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: renderConfig.enableHardwareAcceleration,
          vo: renderConfig.vo,
          hwdec: renderConfig.hwdec,
          androidAttachSurfaceAfterVideoParameters:
              renderConfig.androidAttachSurfaceAfterVideoParameters,
        ),
      );
    }

    // 重新绑定流
    _bindStreams();

    // 通知 PlayerVideo 重建渲染器
    _recreateController.add(null);
  }

  @override
  Future<void> setProperty(String key, String value) async {
    final pp = _player.platform as NativePlayer;
    await pp.setProperty(key, value);
  }

  @override
  Future<String?> getProperty(String key) async {
    final pp = _player.platform as NativePlayer;
    return await pp.getProperty(key);
  }

  @override
  Future<void> applyVideoRenderConfig(VideoRenderConfig config) async {
    if (config.hwdec != null && Platform.isAndroid) {
      await setProperty('hwdec', config.hwdec!);
    }
    _currentRenderConfig = config;
  }

  MPVLogLevel _toMpvLogLevel(PlayerLogLevel level) {
    switch (level) {
      case PlayerLogLevel.none:
        return MPVLogLevel.error;
      case PlayerLogLevel.error:
        return MPVLogLevel.error;
      case PlayerLogLevel.warn:
        return MPVLogLevel.warn;
      case PlayerLogLevel.info:
        return MPVLogLevel.info;
      case PlayerLogLevel.debug:
        return MPVLogLevel.debug;
      case PlayerLogLevel.verbose:
        return MPVLogLevel.trace;
    }
  }

  PlayerLogEntry _toPlayerLogEntry(PlayerLog log) {
    return PlayerLogEntry(
      prefix: log.prefix,
      level: _fromMpvLogLevel(log.level),
      text: log.text,
    );
  }

  PlayerLogLevel _fromMpvLogLevel(String level) {
    switch (level) {
      case 'fatal':
        return PlayerLogLevel.fatal;
      case 'error':
        return PlayerLogLevel.error;
      case 'warn':
        return PlayerLogLevel.warn;
      case 'info':
        return PlayerLogLevel.info;
      case 'debug':
        return PlayerLogLevel.debug;
      case 'trace':
        return PlayerLogLevel.verbose;
      default:
        return PlayerLogLevel.info;
    }
  }
}
