package com.xycz.simple_live_tv

import android.content.Context
import android.net.Uri
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** 自定义 ExoPlayer 插件，针对直播流优化 */
class LiveExoPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var textureRegistry: TextureRegistry
  private lateinit var appContext: Context

  private var player: ExoPlayer? = null
  private var textureEntry: TextureRegistry.SurfaceProducer? = null
  private var eventSink: EventChannel.EventSink? = null
  private var currentUrl: String? = null

  private val playerListener = object : Player.Listener {
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      eventSink?.success(mapOf("event" to "playing", "value" to isPlaying))
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
      when (playbackState) {
        Player.STATE_BUFFERING -> {
          eventSink?.success(mapOf("event" to "buffering", "value" to true))
        }
        Player.STATE_READY -> {
          eventSink?.success(mapOf("event" to "buffering", "value" to false))
          val format = player?.videoFormat
          if (format != null && format.width > 0 && format.height > 0) {
            eventSink?.success(
              mapOf(
                "event" to "videoSize",
                "width" to format.width,
                "height" to format.height
              )
            )
          }
        }
        Player.STATE_ENDED -> {
          eventSink?.success(mapOf("event" to "completed"))
        }
      }
    }

    override fun onPlayerError(error: PlaybackException) {
      eventSink?.success(
        mapOf(
          "event" to "error",
          "message" to (error.message ?: "Unknown ExoPlayer error"),
          "errorCode" to error.errorCode
        )
      )
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    textureRegistry = binding.textureRegistry

    channel = MethodChannel(binding.binaryMessenger, "com.xycz.simple_live_tv/exo_player")
    channel.setMethodCallHandler(this)

    eventChannel = EventChannel(binding.binaryMessenger, "com.xycz.simple_live_tv/exo_player_events")
    eventChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
          eventSink = sink
        }

        override fun onCancel(arguments: Any?) {
          eventSink = null
        }
      }
    )
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    releasePlayer()
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
  }

  @OptIn(UnstableApi::class)
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "create" -> {
        val textureId = createPlayer()
        result.success(mapOf("textureId" to textureId))
      }
      "open" -> {
        val url = call.argument<String>("url") ?: return result.error("NO_URL", "No URL", null)
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        open(url, headers)
        result.success(null)
      }
      "play" -> {
        player?.playWhenReady = true
        result.success(null)
      }
      "pause" -> {
        player?.playWhenReady = false
        result.success(null)
      }
      "stop" -> {
        player?.stop()
        result.success(null)
      }
      "dispose" -> {
        releasePlayer()
        result.success(null)
      }
      "setVolume" -> {
        val volume = call.argument<Double>("volume") ?: 1.0
        player?.volume = volume.toFloat()
        result.success(null)
      }
      "getVideoInfo" -> {
        val p = player
        if (p == null) {
          result.success(null)
        } else {
          val format = p.videoFormat
          result.success(
            mapOf(
              "width" to (format?.width ?: 0),
              "height" to (format?.height ?: 0),
              "frameRate" to (format?.frameRate ?: 0f),
              "codec" to (format?.codecs ?: ""),
              "bitrate" to (format?.bitrate ?: 0),
              "isPlaying" to p.isPlaying,
              "bufferedPosition" to p.bufferedPosition,
              "currentPosition" to p.currentPosition,
            )
          )
        }
      }
      else -> result.notImplemented()
    }
  }

  @OptIn(UnstableApi::class)
  private fun createPlayer(): Long {
    releasePlayer()

    // 创建 Flutter Texture 入口
    val entry = textureRegistry.createSurfaceProducer()
    textureEntry = entry

    // 解码器工厂：启用 fallback，codec 失败时尝试其他 decoder（包括软解）
    val renderersFactory = DefaultRenderersFactory(appContext)
      .setEnableDecoderFallback(true)

    // 缓冲控制：直播流小缓冲，低延迟
    val loadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        1000,   // minBufferMs: 最少缓冲1s
        5000,   // maxBufferMs: 最多5s
        500,    // bufferForPlaybackMs: 缓冲500ms就开始播放
        1000    // bufferForPlaybackAfterRebufferMs: rebuffer后1s恢复
      )
      .build()

    val trackSelector = DefaultTrackSelector(appContext)

    player = ExoPlayer.Builder(appContext, renderersFactory)
      .setTrackSelector(trackSelector)
      .setLoadControl(loadControl)
      .build()
      .also { it.addListener(playerListener) }

    // Surface 就绪时绑定到播放器
    entry.setCallback(
      object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceCreated() {
          entry.surface?.let { surface ->
            player?.setVideoSurface(surface)
          }
        }

        override fun onSurfaceDestroyed() {
          player?.clearVideoSurface()
        }
      }
    )

    return entry.id()
  }

  @OptIn(UnstableApi::class)
  private fun open(url: String, headers: Map<String, String>) {
    val p = player ?: return
    currentUrl = url

    // HTTP 数据源：合理超时 + 自定义 headers
    val dataSourceFactory = DefaultHttpDataSource.Factory()
      .setConnectTimeoutMs(5000)
      .setReadTimeoutMs(8000)
      .setAllowCrossProtocolRedirects(true)
      .setDefaultRequestProperties(headers)

    val mediaSourceFactory = DefaultMediaSourceFactory(appContext)
      .setDataSourceFactory(dataSourceFactory)

    // 直播配置：targetOffset 2s，允许小幅变速追赶
    val liveConfig = MediaItem.LiveConfiguration.Builder()
      .setTargetOffsetMs(2000)
      .setMaxPlaybackSpeed(1.04f)
      .setMinPlaybackSpeed(0.96f)
      .build()

    val mediaItem = MediaItem.Builder()
      .setUri(Uri.parse(url))
      .setLiveConfiguration(liveConfig)
      .build()

    val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
    p.setMediaSource(mediaSource)
    p.prepare()
    p.playWhenReady = true
  }

  private fun releasePlayer() {
    player?.let {
      it.removeListener(playerListener)
      it.stop()
      it.release()
    }
    player = null
    textureEntry?.release()
    textureEntry = null
    currentUrl = null
  }
}
