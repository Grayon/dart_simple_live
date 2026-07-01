import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 取当前策略与用户设置的缓冲区上限中的较大值（策略兜底，用户想调大就放开）
  static int _effectiveBufferSizeMb() {
    final user = AppSettingsController.instance.playerBufferSize.value;
    final recommend = AppSettingsController
        .instance.playerLiveBufferMode.value.recommendBufferSizeMb;
    return user < recommend ? recommend : user;
  }

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "Simple Live Player",
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.error,
      // 缓冲区上限（MB），由用户设置和策略预设共同决定
      bufferSize: _effectiveBufferSizeMb() * 1024 * 1024,
    ),
  );

  bool _playerInitialized = false;

  /// 初始化播放器并设置性能相关参数（Android 直播高码率/电视盒子场景优化）
  Future<void> initializePlayer() async {
    if (_playerInitialized) return;
    _playerInitialized = true;

    var pp = player.platform as NativePlayer;

    // 自定义音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value &&
        AppSettingsController.instance.audioOutputDriver.value.isNotEmpty) {
      await pp.setProperty(
        'ao',
        AppSettingsController.instance.audioOutputDriver.value,
      );
    }

    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }

    // 直播缓冲策略 preset（全平台应用，桌面端跳过 swapchain-depth）
    final preset =
        AppSettingsController.instance.playerLiveBufferMode.value.mpvPreset;
    for (final entry in preset.entries) {
      if (!Platform.isAndroid && entry.key == 'swapchain-depth') continue;
      await pp.setProperty(entry.key, entry.value);
    }

    // Android：解码器优化，防止高帧率直播源（60fps 游戏直播等）喂爆 MediaCodec
    if (Platform.isAndroid) {
      // vd-lavc 线程自动探测（CPU 核数）+ 快速模式（跳过部分参考帧检查）
      await pp.setProperty('vd-lavc-o', 'threads=0;fast=1;drdd=1;');
      // MediaCodec 用 gralloc allocator，零拷贝直送 Surface（部分盒子不支持时 mpv 会自动 fallback）
      await pp.setProperty('mediacodec-allocator', 'gralloc');
      // 解码器输出队列上限，防止高帧率源堆积帧阻塞 SurfaceFlinger
      await pp.setProperty('vd-queue-max-bytes', '67108864'); // 64MB
      await pp.setProperty('vd-queue-max-samples', '4');
      // HDR：自动检测峰值亮度，传递色彩空间给 Surface（Android TV 普遍支持 HDR10/HLG）
      await pp.setProperty('hdr-compute-peak', 'auto');
      await pp.setProperty('target-colorspace-hint', 'yes');
      // 音频声道自动检测（接功放/回音壁时正确输出多声道）
      await pp.setProperty('audio-channels', 'auto');
    }

    // 避免 mpv 在音视频不同步时丢音频样本触发反复缓冲
    await pp.setProperty('audio-stream-silence', 'yes');
  }

  /// 视频控制器
  /// - 高帧率兼容模式：强制软解（hwdec=no），防止60fps等直播源喂爆MediaCodec卡死系统
  /// - 自定义输出驱动模式：用户自选 vo/hwdec
  /// - 兼容模式：Android 强制 mediacodec_embed/mediacodec，其他平台 null
  /// - 正常模式：Android 用 mediacodec_embed，hwdec 跟随硬件解码开关；其他平台不指定
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.highFpsCompat.value
        ? VideoControllerConfiguration(
            enableHardwareAcceleration: false,
            vo: Platform.isAndroid ? 'mediacodec_embed' : null,
            hwdec: Platform.isAndroid ? 'no' : null,
            androidAttachSurfaceAfterVideoParameters: false,
          )
        : AppSettingsController.instance.customPlayerOutput.value
            ? VideoControllerConfiguration(
                vo: AppSettingsController.instance.videoOutputDriver.value
                        .isNotEmpty
                    ? AppSettingsController.instance.videoOutputDriver.value
                    : null,
                hwdec: AppSettingsController
                            .instance.videoHardwareDecoder.value
                            .isNotEmpty
                        ? AppSettingsController
                            .instance.videoHardwareDecoder.value
                        : null,
                androidAttachSurfaceAfterVideoParameters: false,
              )
            : AppSettingsController.instance.playerCompatMode.value
                ? VideoControllerConfiguration(
                    vo: Platform.isAndroid ? 'mediacodec_embed' : null,
                    hwdec: Platform.isAndroid ? 'mediacodec' : null,
                    androidAttachSurfaceAfterVideoParameters: false,
                  )
                : VideoControllerConfiguration(
                    enableHardwareAcceleration:
                        AppSettingsController.instance.hardwareDecode.value,
                    vo: Platform.isAndroid ? 'mediacodec_embed' : null,
                    hwdec: Platform.isAndroid
                        ? (AppSettingsController.instance.hardwareDecode.value
                            ? 'mediacodec'
                            : 'no')
                        : null,
                    androidAttachSurfaceAfterVideoParameters: false,
                  ),
  );
}
mixin PlayerStateMixin on PlayerMixin {
  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器
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

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
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
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  /// 待发送弹幕队列（每帧合并提交，避免高密度弹幕时一帧几十次 repaint 抖动）
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

  /// 初始化一些系统状态
  void initSystem() async {
    // 屏幕常亮
    WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    await WakelockPlus.disable();
  }

  /// 是否是IOS16以下
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
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      Log.d("播放器错误：$event");
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    _logSubscription = player.stream.log.listen((event) {
      Log.d("播放器日志：$event");
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.w(
          'width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      width.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.w(
          'height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      height.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
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
