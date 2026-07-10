import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'base_player.dart';
import 'exoplayer_player.dart';
import 'mediakit_player.dart';
import 'player_video.dart';

mixin PlayerMixin {
  GlobalKey<PlayerVideoState> globalPlayerVideoKey = GlobalKey<PlayerVideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  static int _effectiveBufferSizeMb() {
    final user = AppSettingsController.instance.playerBufferSize.value;
    final recommend = AppSettingsController
        .instance.playerLiveBufferMode.value.recommendBufferSizeMb;
    return user < recommend ? recommend : user;
  }

  /// 播放器实例（通过抽象层访问）
  BasePlayer _player = _createPlayerStatic();
  BasePlayer get player => _player;

  static BasePlayer _createPlayerStatic() {
    final config = PlayerConfig(
      title: "Simple Live Player",
      logLevel: AppSettingsController.instance.logEnable.value
          ? PlayerLogLevel.info
          : PlayerLogLevel.error,
      bufferSizeBytes: _effectiveBufferSizeMbStatic() * 1024 * 1024,
    );
    switch (AppSettingsController.instance.playerEngine.value) {
      case PlayerEngine.exoPlayer:
        return ExoPlayerPlayer(config);
      case PlayerEngine.mpv:
        return MediaKitPlayer(config);
    }
  }

  static int _effectiveBufferSizeMbStatic() {
    final user = AppSettingsController.instance.playerBufferSize.value;
    final recommend = AppSettingsController
        .instance.playerLiveBufferMode.value.recommendBufferSizeMb;
    return user < recommend ? recommend : user;
  }

  /// 切换播放器引擎（销毁旧实例，创建新实例）
  Future<void> switchPlayerEngine(PlayerEngine engine) async {
    if (engine == AppSettingsController.instance.playerEngine.value &&
        _playerInitialized) {
      return;
    }
    final oldPlayer = _player;
    final config = PlayerConfig(
      title: "Simple Live Player",
      logLevel: AppSettingsController.instance.logEnable.value
          ? PlayerLogLevel.info
          : PlayerLogLevel.error,
      bufferSizeBytes: _effectiveBufferSizeMbStatic() * 1024 * 1024,
    );
    switch (engine) {
      case PlayerEngine.exoPlayer:
        _player = ExoPlayerPlayer(config);
        break;
      case PlayerEngine.mpv:
        _player = MediaKitPlayer(config);
        break;
    }
    _playerInitialized = false;
    hwdecRetried = false;
    await oldPlayer.dispose();
  }

  bool _playerInitialized = false;

  /// 硬解零拷贝失败后的重试标记（recreate 后重试 mediacodec，不再降级到 copy）
  bool hwdecRetried = false;

  void resetHwdecFallback() {
    hwdecRetried = false;
    _hwFormatFallbackDone = false;
  }

  VideoRenderConfig _buildVideoRenderConfig() {
    final c = AppSettingsController.instance;
    if (c.customPlayerOutput.value) {
      return VideoRenderConfig(
        vo: c.videoOutputDriver.value.isNotEmpty
            ? c.videoOutputDriver.value
            : null,
        hwdec: c.videoHardwareDecoder.value.isNotEmpty
            ? c.videoHardwareDecoder.value
            : null,
        androidAttachSurfaceAfterVideoParameters: true,
      );
    }
    if (c.playerCompatMode.value) {
      return VideoRenderConfig(
        vo: Platform.isAndroid ? 'mediacodec_embed' : null,
        hwdec: Platform.isAndroid ? 'mediacodec' : null,
        androidAttachSurfaceAfterVideoParameters: true,
      );
    }
    // 默认 vo=gpu + hwdec=mediacodec（mediacodec-copy 路径）
    // mediacodec_embed 是 Surface 直出零拷贝，高分辨率/部分芯片兼容性差
    // gpu VO 走 OpenGL 渲染，兼容性好，2K/4K 硬解也能正常工作
    final hwdec = c.hardwareDecode.value ? 'mediacodec' : 'no';
    final vo = c.hardwareDecode.value ? 'gpu' : 'gpu';
    return VideoRenderConfig(
      enableHardwareAcceleration: c.hardwareDecode.value,
      vo: Platform.isAndroid ? vo : null,
      hwdec: Platform.isAndroid ? hwdec : null,
      androidAttachSurfaceAfterVideoParameters: true,
    );
  }

  /// 完全重建播放器（VO/解码器崩溃后恢复）
  Future<void> recreatePlayer() async {
    await player.recreate();
    _playerInitialized = false;
  }

  /// 初始化播放器并设置性能相关参数
  Future<void> initializePlayer() async {
    final p = player;

    if (p is MediaKitPlayer) {
      if (!_playerInitialized) {
        _playerInitialized = true;
        p.initVideoController(_buildVideoRenderConfig());
      }

      // 自定义音频输出驱动
      if (AppSettingsController.instance.customPlayerOutput.value &&
          AppSettingsController.instance.audioOutputDriver.value.isNotEmpty) {
        await p.setProperty(
          'ao',
          AppSettingsController.instance.audioOutputDriver.value,
        );
      }

      if (Platform.isAndroid) {
        await p.setProperty('force-seekable', 'yes');
      }

      // 直播缓冲策略 preset（仅 mpv）
      final preset =
          AppSettingsController.instance.playerLiveBufferMode.value.mpvPreset;
      for (final entry in preset.entries) {
        if (!Platform.isAndroid && entry.key == 'swapchain-depth') continue;
        await p.setProperty(entry.key, entry.value);
      }

      if (Platform.isAndroid) {
        await p.setProperty('vd-lavc-o', 'threads=0');
        await p.setProperty('hdr-compute-peak', 'auto');
        await p.setProperty('target-colorspace-hint', 'yes');
        await p.setProperty('audio-channels', 'auto');
      }

      await p.setProperty('audio-stream-silence', 'yes');
    } else if (p is ExoPlayerPlayer) {
      if (!_playerInitialized) {
        _playerInitialized = true;
        // 提前创建原生播放器和 Texture，确保 open 前 Surface 已就绪
        await p.ensureCreatedForRender();
      }
    }
  }
}

mixin PlayerStateMixin on PlayerMixin {
  RxBool showDanmakuState = false.obs;
  RxBool showControlsState = false.obs;
  RxBool showSettingState = false.obs;
  RxBool showDanmakuSettingState = false.obs;
  RxBool lockControlsState = false.obs;
  RxBool fullScreenState = false.obs;
  RxBool showGestureTip = false.obs;
  RxString gestureTipText = "".obs;
  RxBool showBottomTip = false.obs;
  RxString bottomTipText = "".obs;

  Timer? hideControlsTimer;
  Timer? hideSeekTipTimer;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();
    hideControlsTimer = Timer(
      const Duration(seconds: 5),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    final s = player.state;
    if (s.width != null && s.height != null) {
      aspectRatio = s.width! / s.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerVideoKey.currentState?.updateVideoDisplay(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}

mixin PlayerDanmakuMixin on PlayerStateMixin {
  DanmakuController? danmakuController;

  final List<DanmakuContentItem> _pendingDanmaku = [];
  bool _danmakuFlushScheduled = false;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
    _pendingDanmaku.clear();
    _danmakuFlushScheduled = false;
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    _pendingDanmaku.addAll(items);
    if (!_danmakuFlushScheduled) {
      _danmakuFlushScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _danmakuFlushScheduled = false;
        if (_pendingDanmaku.isEmpty || danmakuController == null) {
          _pendingDanmaku.clear();
          return;
        }
        final list = List<DanmakuContentItem>.of(_pendingDanmaku);
        _pendingDanmaku.clear();
        for (final item in list) {
          danmakuController?.addDanmaku(item);
        }
      });
    }
  }
}

mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  void initSystem() async {
    WakelockPlus.enable();
    resetHideControlsTimer();
  }

  Future resetSystem() async {
    await WakelockPlus.disable();
  }

  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }
}

class PlayerController extends BaseController
    with PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin, PlayerSystemMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    super.onInit();
  }

  var width = 0.obs;
  var height = 0.obs;

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;
  StreamSubscription<PlayerLogEntry>? _logSubscription;

  void initStream() {
    _errorSubscription = player.errorStream.listen((event) {
      Log.d("播放器错误：$event");
      if (event.contains('no sound.')) {
        return;
      }
      mediaError(event);
    });

    _completedSubscription = player.completedStream.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    _logSubscription = player.logStream.listen((event) {
      Log.d("播放器日志：PlayerLog(prefix: ${event.prefix}, level: ${event.level.name}, text: ${event.text})");
      // VO 子系统崩溃（fatal 级别），errorStream 不会收到，
      // 必须从日志流中检测并主动重建播放器
      if (event.level == PlayerLogLevel.fatal &&
          (event.text.contains('No render context set') ||
              event.text.contains('Error opening/initializing the selected video_out') ||
              event.text.contains('Could not initialize video chain') ||
              event.text.contains('Cannot convert decoder/filter output'))) {
        Log.e("检测到 VO 崩溃: ${event.text}", StackTrace.current);
        _handleVoFatal(event.text);
      }
      // mediacodec_embed 不支持软解帧上传，自动切 gpu VO 软解渲染
      if (event.text.contains('no support for this hw format') ||
          event.text.contains('hardware format not supported')) {
        _handleHwFormatUnsupported();
      }
    });
    _widthSubscription = player.widthStream.listen((event) {
      final s = player.state;
      Log.w('width:$event  W:${s.width}  H:${s.height}');
      width.value = event ?? 0;
    });
    _heightSubscription = player.heightStream.listen((event) {
      final s = player.state;
      Log.w('height:$event  W:${s.width}  H:${s.height}');
      height.value = event ?? 0;
    });
  }

  /// 切换引擎后重新绑定流到新 player 实例
  void rebindStreams() {
    disposeStream();
    initStream();
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
  }

  void mediaEnd() {}

  void mediaError(String error) {}

  /// VO 子系统崩溃时的恢复回调（由 LiveRoomController 实现）
  Future<void> onVoFatal() async {}

  bool _voFatalHandled = false;
  bool _hwFormatFallbackDone = false;
  String? _lastVoFatalError;

  void _handleHwFormatUnsupported() {
    if (_hwFormatFallbackDone) return;
    _hwFormatFallbackDone = true;
    final p = player;
    if (p is MediaKitPlayer) {
      Log.w("mediacodec_embed 不支持软解帧，切换 vo=gpu + hwdec=no");
      p.setProperty('vo', 'gpu');
      p.setProperty('hwdec', 'no');
    }
  }

  void _handleVoFatal(String errorText) async {
    if (_voFatalHandled) return;
    _voFatalHandled = true;
    _lastVoFatalError = errorText;
    hwdecRetried = true;

    // VO 驱动不存在（如 gpu-next），回退到安全 VO，防止无限崩溃循环
    if (errorText.contains('not found')) {
      final c = AppSettingsController.instance;
      if (c.customPlayerOutput.value &&
          c.videoOutputDriver.value.isNotEmpty) {
        Log.w("VO 驱动 ${c.videoOutputDriver.value} 不存在，回退到 mediacodec_embed");
        c.setVideoOutputDriver('mediacodec_embed');
      }
    }

    // 软解帧无法被 mediacodec_embed VO 渲染，切到 gpu VO 软解
    if (errorText.contains('Cannot convert decoder/filter output') ||
        errorText.contains('Could not initialize video chain')) {
      final c = AppSettingsController.instance;
      if (c.hardwareDecode.value) {
        Log.w("视频链初始化失败（软解帧不兼容），切换 vo=gpu 软解渲染");
        c.setHardwareDecode(false);
      }
    }

    await recreatePlayer();
    await onVoFatal();
    _voFatalHandled = false;
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    await player.dispose();
    super.onClose();
  }
}
