import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'base_player.dart';

/// media_kit (mpv) 播放器实现
class MediaKitPlayer implements BasePlayer {
  late final Player _player;
  late final VideoController _videoController;
  VideoRenderConfig? _currentRenderConfig;

  MediaKitPlayer(PlayerConfig config) {
    _player = Player(
      configuration: PlayerConfiguration(
        title: config.title,
        logLevel: _toMpvLogLevel(config.logLevel),
        bufferSize: config.bufferSizeBytes,
      ),
    );
  }

  VideoController get videoController => _videoController;

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
  }

  @override
  PlayerState get state => PlayerState(
        playing: _player.state.playing,
        buffering: _player.state.buffering,
        width: _player.state.width,
        height: _player.state.height,
      );

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<int?> get widthStream => _player.stream.width;

  @override
  Stream<int?> get heightStream => _player.stream.height;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Stream<bool> get completedStream =>
      _player.stream.completed.map((e) => e == true);

  @override
  Stream<PlayerLogEntry> get logStream =>
      _player.stream.log.map(_toPlayerLogEntry);

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
    await _player.dispose();
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
    // vo/hwdec 不能运行时切换，需要重建 VideoController
    // 这里只处理可以运行时设置的属性
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
