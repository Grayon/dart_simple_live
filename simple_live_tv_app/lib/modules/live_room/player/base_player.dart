import 'dart:async';

import 'package:flutter/material.dart';

/// 播放器状态快照
class PlayerState {
  final bool playing;
  final bool buffering;
  final int? width;
  final int? height;

  const PlayerState({
    this.playing = false,
    this.buffering = false,
    this.width,
    this.height,
  });
}

/// 播放器日志级别
enum PlayerLogLevel {
  none,
  fatal,
  error,
  warn,
  info,
  debug,
  verbose,
}

/// 播放器日志条目
class PlayerLogEntry {
  final String prefix;
  final PlayerLogLevel level;
  final String text;

  const PlayerLogEntry({
    required this.prefix,
    required this.level,
    required this.text,
  });
}

/// 视频渲染配置
class VideoRenderConfig {
  final bool enableHardwareAcceleration;
  final String? vo;
  final String? hwdec;
  final bool androidAttachSurfaceAfterVideoParameters;

  const VideoRenderConfig({
    this.enableHardwareAcceleration = true,
    this.vo,
    this.hwdec,
    this.androidAttachSurfaceAfterVideoParameters = true,
  });
}

/// 播放器配置
class PlayerConfig {
  final String title;
  final PlayerLogLevel logLevel;
  final int bufferSizeBytes;

  const PlayerConfig({
    this.title = "Simple Live Player",
    this.logLevel = PlayerLogLevel.error,
    this.bufferSizeBytes = 32 * 1024 * 1024,
  });
}

/// 播放器抽象接口
///
/// 所有播放器实现（media_kit、ExoPlayer等）必须实现此接口。
/// 上层业务代码只依赖此接口，不直接依赖具体播放器库。
abstract class BasePlayer {
  /// 当前状态
  PlayerState get state;

  /// 状态流
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<int?> get widthStream;
  Stream<int?> get heightStream;
  Stream<String> get errorStream;
  Stream<bool> get completedStream;
  Stream<PlayerLogEntry> get logStream;

  /// 播放器重建通知（PlayerVideo 监听此流重建渲染器）
  Stream<void> get recreateStream;

  /// 打开媒体源
  Future<void> open(String url, {Map<String, String>? headers});

  /// 停止播放（释放解码器，保留播放器实例）
  Future<void> stop();

  /// 释放播放器（不可再使用）
  Future<void> dispose();

  /// 完全重建播放器（用于 VO/解码器崩溃后恢复）
  ///
  /// 当 vo/libmpv 报 "No render context set" 或 MediaCodec 状态机崩溃时，
  /// 仅 stop()+open() 无法恢复，必须完全销毁并重建底层播放器和渲染器。
  Future<void> recreate();

  /// 设置播放器属性（如 mpv 的 setProperty）
  Future<void> setProperty(String key, String value);

  /// 获取播放器属性（如 mpv 的 getProperty）
  Future<String?> getProperty(String key);

  /// 应用视频渲染配置（vo/hwdec等）
  Future<void> applyVideoRenderConfig(VideoRenderConfig config);
}
