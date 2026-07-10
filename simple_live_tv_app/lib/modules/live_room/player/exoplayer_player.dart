import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'base_player.dart';

/// ExoPlayer (Media3) 播放器实现
///
/// 通过自定义 MethodChannel 调用 Android 原生 LiveExoPlayerPlugin，
/// 针对直播流优化：enableDecoderFallback、小缓冲 LoadControl、LiveConfiguration。
/// 视频通过 Flutter Texture 渲染。
class ExoPlayerPlayer implements BasePlayer {
  final PlayerConfig _config;
  bool _disposed = false;
  int? _textureId;
  bool _created = false;

  static const _methodChannel =
      MethodChannel('com.xycz.simple_live_tv/exo_player');
  static const _eventChannel =
      EventChannel('com.xycz.simple_live_tv/exo_player_events');

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

  final _textureReadyController = StreamController<int>.broadcast();

  /// Texture 就绪通知（PlayerVideo 监听此流来重建渲染器）
  Stream<int> get textureReadyStream => _textureReadyController.stream;

  StreamSubscription? _eventSubscription;

  int? get textureId => _textureId;

  /// 供 PlayerVideo 提前初始化 Texture（渲染器需要 textureId 才能构建）
  Future<void> ensureCreatedForRender() async {
    if (_disposed) return;
    await _ensureCreated();
    // 首次创建时输出设备 codec 和硬件信息到日志
    await _dumpDeviceCodecInfo();
  }

  Future<void> _dumpDeviceCodecInfo() async {
    try {
      final hwInfo = await _methodChannel.invokeMethod<Map>('getDeviceHwInfo');
      if (hwInfo != null) {
        _logController.add(PlayerLogEntry(
          prefix: 'device_hw',
          level: PlayerLogLevel.info,
          text: '设备硬件信息: ${_formatHwInfo(hwInfo)}',
        ));
      }
    } catch (e) {
      // 忽略，不影响播放
    }
    try {
      final codecInfo = await _methodChannel.invokeMethod<Map>('getCodecInfo');
      if (codecInfo != null) {
        _logController.add(PlayerLogEntry(
          prefix: 'device_codec',
          level: PlayerLogLevel.info,
          text: '设备MediaCodec能力: ${_formatCodecInfo(codecInfo)}',
        ));
      }
    } catch (e) {
      // 忽略
    }
  }

  String _formatHwInfo(Map info) {
    final build = info['buildInfo'] as Map?;
    final cpu = info['cpuInfo'] as Map?;
    final gpu = info['gpuInfo'] as Map?;
    final mem = info['memInfo'] as Map?;
    final parts = <String>[];
    if (build != null) {
      parts.add('${build['MANUFACTURER']} ${build['MODEL']}');
      parts.add('hardware=${build['HARDWARE']} device=${build['DEVICE']}');
      parts.add('SDK=${build['SDK_INT']} Android=${build['RELEASE']}');
      parts.add('ABIs=${build['SUPPORTED_ABIS']}');
    }
    if (cpu != null) {
      final hw = cpu['Hardware'] ?? cpu['model name'] ?? '';
      final cores = cpu['cpu cores'] ?? '';
      if (hw.isNotEmpty) parts.add('CPU: $hw cores=$cores');
    }
    if (gpu != null && gpu.isNotEmpty) {
      parts.add('GPU: ${gpu.entries.first.value.toString().split('\n').first}');
    }
    if (mem != null) {
      parts.add('MemTotal=${mem['MemTotal']}');
    }
    return parts.join(' | ');
  }

  String _formatCodecInfo(Map info) {
    final decoders = info['videoDecoders'] as List?;
    if (decoders == null) return info.toString();
    final parts = <String>[];
    parts.add('共${info['totalDecoderCount']}个视频解码器');
    for (final d in decoders) {
      final codec = d as Map;
      final name = codec['name'];
      final isHw = codec['isHardwareAccelerated'];
      final isVendor = codec['isVendor'];
      final caps = codec['capabilities'] as List?;
      if (caps == null) continue;
      for (final c in caps) {
        final cap = c as Map;
        final mimeType = cap['mimeType'];
        final maxW = cap['maxWidth'];
        final maxH = cap['maxHeight'];
        final maxFps = cap['maxFrameRate'];
        final testResults = cap['testResults'] as List?;
        final profileLevels = cap['profileLevels'] as List?;
        final buf = StringBuffer();
        buf.write('$name [$mimeType] hw=$isHw vendor=$isVendor max=${maxW}x$maxH@${maxFps}fps');
        if (profileLevels != null && profileLevels.isNotEmpty) {
          buf.write(' profiles=${profileLevels.take(5).join(',')}');
        }
        if (testResults != null) {
          for (final tr in testResults) {
            final test = tr as Map;
            final supported = test['supported'];
            final tampered = test['tampered'];
            final res = test['resolution'];
            if (tampered == true) {
              buf.write(' [$res: TAMPERED(says $supported)]');
            } else {
              buf.write(' [$res: $supported]');
            }
          }
        }
        parts.add(buf.toString());
      }
    }
    return parts.join('\n  ');
  }

  ExoPlayerPlayer(this._config);

  Future<void> _ensureCreated() async {
    if (_created) return;
    final result = await _methodChannel.invokeMethod<Map>('create');
    _textureId = result?['textureId'] as int?;
    _created = true;
    if (_textureId != null) {
      _textureReadyController.add(_textureId!);
    }
    _eventSubscription = _eventChannel
        .receiveBroadcastStream()
        .listen(_onEvent, onError: _onEventError);
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['event'] as String?;
    switch (type) {
      case 'playing':
        _playingController.add(event['value'] as bool? ?? false);
        break;
      case 'buffering':
        _bufferingController.add(event['value'] as bool? ?? false);
        break;
      case 'videoSize':
        final w = event['width'] as int?;
        final h = event['height'] as int?;
        if (w != null) _widthController.add(w);
        if (h != null) _heightController.add(h);
        break;
      case 'completed':
        _completedController.add(true);
        break;
      case 'error':
        final msg = event['message'] as String? ?? 'ExoPlayer error';
        final code = event['errorCode'];
        _errorController.add('$msg (code: $code)');
        _logController.add(PlayerLogEntry(
          prefix: 'exoplayer',
          level: PlayerLogLevel.error,
          text: '$msg (code: $code)',
        ));
        break;
    }
  }

  void _onEventError(Object error) {
    _errorController.add('Event channel error: $error');
  }

  @override
  PlayerState get state {
    // ExoPlayer 状态由事件流驱动，这里返回空快照
    return const PlayerState();
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
    await _ensureCreated();
    await _methodChannel.invokeMethod('open', {
      'url': url,
      'headers': headers ?? <String, String>{},
    });
  }

  @override
  Future<void> stop() async {
    if (!_created) return;
    await _methodChannel.invokeMethod('stop');
    _playingController.add(false);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _eventSubscription?.cancel();
    if (_created) {
      await _methodChannel.invokeMethod('dispose');
    }
    _created = false;
    _textureId = null;
    await _playingController.close();
    await _bufferingController.close();
    await _widthController.close();
    await _heightController.close();
    await _errorController.close();
    await _completedController.close();
    await _logController.close();
    await _textureReadyController.close();
    await _recreateController.close();
  }

  @override
  Future<void> recreate() async {
    if (_disposed) return;
    _eventSubscription?.cancel();
    if (_created) {
      await _methodChannel.invokeMethod('dispose');
    }
    _created = false;
    _textureId = null;
    _recreateController.add(null);
  }

  @override
  Future<void> setProperty(String key, String value) async {
    // 不支持运行时属性设置
  }

  @override
  Future<String?> getProperty(String key) async {
    if (key == 'videoInfo' && _created) {
      final info = await _methodChannel.invokeMethod<Map>('getVideoInfo');
      return info?.toString();
    }
    return null;
  }

  @override
  Future<void> applyVideoRenderConfig(VideoRenderConfig config) async {
    // ExoPlayer 自动管理渲染配置
  }
}
