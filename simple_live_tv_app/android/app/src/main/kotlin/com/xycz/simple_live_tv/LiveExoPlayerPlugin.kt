package com.xycz.simple_live_tv

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.util.Log
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
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
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/** 自定义 ExoPlayer 插件，针对直播流优化 */
class LiveExoPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var textureRegistry: TextureRegistry
  private lateinit var appContext: Context

  private var player: ExoPlayer? = null
  private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
  private var videoSurface: Surface? = null
  private var eventSink: EventChannel.EventSink? = null
  private var currentUrl: String? = null

  // 播放统计
  private var totalDroppedFrames: Int = 0

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
          // 输出选中的轨道和解码器信息，方便诊断解码器选择问题
          val tracks = player?.currentTracks
          tracks?.groups?.forEach { group ->
            if (group.isSelected) {
              val trackType = group.type
              for (i in 0 until group.length) {
                if (group.isTrackSelected(i)) {
                  val fmt = group.getTrackFormat(i)
                  Log.d("LiveExoPlayer", "Selected track: type=$trackType codec=${fmt.codecs} ${fmt.width}x${fmt.height}")
                }
              }
            }
          }
        }
        Player.STATE_ENDED -> {
          eventSink?.success(mapOf("event" to "completed"))
        }
      }
    }

    override fun onPlayerError(error: PlaybackException) {
      val detail = buildString {
        append(error.message ?: "Unknown ExoPlayer error")
        // 输出错误链
        var cause: Throwable? = error.cause
        while (cause != null) {
          append(" → ${cause.javaClass.simpleName}: ${cause.message}")
          cause = cause.cause
        }
        // 如果是 MediaCodec 错误，输出当前视频格式信息
        val fmt = player?.videoFormat
        if (fmt != null) {
          append(" | format=${fmt.codecs} ${fmt.width}x${fmt.height}@${fmt.frameRate}fps")
        }
      }
      Log.e("LiveExoPlayer", "Player error: $detail", error)
      eventSink?.success(
        mapOf(
          "event" to "error",
          "message" to detail,
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
          val vFormat = p.videoFormat
          val aFormat = p.audioFormat
          result.success(
            mapOf(
              "width" to (vFormat?.width ?: 0),
              "height" to (vFormat?.height ?: 0),
              "frameRate" to (vFormat?.frameRate ?: 0f),
              "codec" to (vFormat?.codecs ?: ""),
              "bitrate" to (vFormat?.bitrate ?: 0),
              "audioCodec" to (aFormat?.codecs ?: ""),
              "audioBitrate" to (aFormat?.bitrate ?: 0),
              "audioSampleRate" to (aFormat?.sampleRate ?: 0),
              "audioChannels" to (aFormat?.channelCount ?: 0),
              "droppedFrames" to totalDroppedFrames,
              "isPlaying" to p.isPlaying,
              "bufferedPosition" to p.bufferedPosition,
              "currentPosition" to p.currentPosition,
              "contentDuration" to p.duration,
              "playbackState" to p.playbackState,
              "playbackSpeed" to p.playbackParameters.speed,
            )
          )
        }
      }
      "getCodecInfo" -> {
        result.success(dumpAllCodecInfo())
      }
      "getDeviceHwInfo" -> {
        result.success(dumpDeviceHwInfo())
      }
      else -> result.notImplemented()
    }
  }

  @OptIn(UnstableApi::class)
  private fun createPlayer(): Long {
    releasePlayer()

    // 创建 Flutter Texture 入口。
    // 用旧版 SurfaceTexture 路径（与 pure_live 的 better_player/fijk 一致）：
    // 新版 createSurfaceProducer()(ImageReader/HardwareBuffer) 在部分 Android TV +
    // Impeller 下，解码帧约 1 秒填满 Surface 缓冲队列后消费端不再取帧，表现为“画面
    // 卡死但音频继续播放”；SurfaceTexture 走成熟的 GLES 外部纹理桥，无此问题。
    val entry = textureRegistry.createSurfaceTexture()
    textureEntry = entry
    val surface = Surface(entry.surfaceTexture())
    videoSurface = surface

    // 解码器工厂：启用 fallback，解码器选择完全使用 media3 默认策略。
    // 对齐 pure_live(better_player)：DefaultRenderersFactory 默认就硬件解码器优先，
    // 并内置各厂商 SoC 的 workaround 表，首选解码器初始化失败时按链回退。
    // 不再自定义 MediaCodecSelector 按名字前缀强制置顶——旧实现会绕过 media3 的
    // 设备 workaround，可能钉死在“标称支持 2K、实际有 bug”的 vendor 解码器上，
    // 而这种运行期静默卡死不在 enableDecoderFallback 的覆盖范围内。
    val renderersFactory = DefaultRenderersFactory(appContext)
      .setEnableDecoderFallback(true)

    // 缓冲控制：对齐 pure_live better_player 的 BetterPlayerBufferingConfiguration
    // 默认值（实测 2K 高码率直播流畅）。
    // 旧值 1000/5000/500/1000 垫子太薄，2K(8-20Mbps) 叠加 CDN 抖动必被打穿，
    // 反复 underrun→rebuffer。大水位让加载器持续攒出数十秒缓冲吸收抖动。
    // targetBufferBytes 保持默认 C.LENGTH_UNSET(-1，按分辨率/码率自适应封顶)，
    // 因此实际内存不会随 maxBufferMs=109分钟 真的膨胀，时长水位只是“尽量不停传”。
    val loadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        25000,    // minBufferMs
        6553600,  // maxBufferMs（better_player 默认 ~109 分钟）
        3000,     // bufferForPlaybackMs
        6000      // bufferForPlaybackAfterRebufferMs
      )
      .build()

    val trackSelector = DefaultTrackSelector(appContext)

    player = ExoPlayer.Builder(appContext, renderersFactory)
      .setTrackSelector(trackSelector)
      .setLoadControl(loadControl)
      .build()
      .also { it.addListener(playerListener) }

    // SurfaceTexture 生命周期稳定（不会中途销毁重建），创建后一次性绑定即可，
    // 无需 SurfaceProducer 那套 onSurfaceCreated/onSurfaceDestroyed 回调。
    player?.setVideoSurface(surface)

    return entry.id()
  }

  @OptIn(UnstableApi::class)
  private fun open(url: String, headers: Map<String, String>) {
    val p = player ?: return
    currentUrl = url

    // HTTP 数据源：用 OkHttp 替代 DefaultHttpDataSource
    // DefaultHttpDataSource 基于 HttpURLConnection，对 FLV 直播流的 chunked 长连接
    // 处理有 bug（EOFException: \n not found: size=0 content=）
    // OkHttp 对长连接和流式响应兼容性更好
    //
    // 超时必须是有限值（不能为 0=无限等待）：直播连接中途静默假死/CDN 长尾不发数据时，
    // 无限 readTimeout 会让加载线程永久阻塞，Exo 既收不到数据也收不到异常，5s 缓冲耗尽后
    // 画面永久冻结且无法触发上层重试。8s 无数据即抛错，进入现有的同 URL 重试/换线路逻辑。
    // （对齐 pure_live DefaultHttpDataSource 的 8s/8s，但保留 OkHttp 规避 FLV EOF。）
    val okHttpClient = OkHttpClient.Builder()
      .connectTimeout(8, TimeUnit.SECONDS)
      .readTimeout(8, TimeUnit.SECONDS)
      .writeTimeout(8, TimeUnit.SECONDS)
      .retryOnConnectionFailure(true)
      .build()

    val dataSourceFactory = OkHttpDataSource.Factory(okHttpClient)
      .setDefaultRequestProperties(
        HashMap<String, String>(headers).apply {
          // 确保有合理的 User-Agent，部分 CDN 会拦截默认 Android 代理
          if (!containsKey("User-Agent")) {
            put("User-Agent", "Mozilla/5.0 (Linux; Android 14; TV) AppleWebKit/537.36")
          }
        }
      )

    val mediaSourceFactory = DefaultMediaSourceFactory(appContext)
      .setDataSourceFactory(dataSourceFactory)

    // 统一用裸 MediaItem，媒体类型交给 DefaultMediaSourceFactory 自动分派
    // （.m3u8→HlsMediaSource，.flv/其它→ProgressiveMediaSource+FlvExtractor）。
    // 对齐 pure_live(better_player)：不设置任何 LiveConfiguration / targetOffset /
    // 播放速度微调。旧实现对非 FLV 强制 targetOffset=2s + 0.96~1.04 变速，在本就很薄的
    // 缓冲上进一步压缩抗抖动空间并周期性变速追赶，反而加剧卡顿。
    // 直播延迟由前面的大缓冲水位平滑吸收，不靠压直播边或变速实现。
    val mediaItem = MediaItem.fromUri(Uri.parse(url))

    val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
    p.setMediaSource(mediaSource)
    p.prepare()
    p.playWhenReady = true
  }

  /**
   * 输出设备所有 MediaCodec 解码器的详细能力信息。
   * 用于诊断 TCL 等设备 MediaCodec capability 查询不准确的问题。
   */
  private fun dumpAllCodecInfo(): Map<String, Any> {
    val result = mutableMapOf<String, Any>()
    val codecsList = mutableListOf<Map<String, Any>>()

    try {
      val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
      val allCodecs = codecList.codecInfos

      // 只关注视频解码器
      val videoDecoders = allCodecs.filter { info ->
        !info.isEncoder && info.supportedTypes.any { it.startsWith("video/") }
      }.sortedBy { it.name }

      for (info in videoDecoders) {
        val codecInfo = mutableMapOf<String, Any>()
        codecInfo["name"] = info.name
        codecInfo["isHardwareAccelerated"] = info.isHardwareAccelerated
        codecInfo["isSoftwareOnly"] = info.isSoftwareOnly
        codecInfo["isVendor"] = info.isVendor
        codecInfo["supportedTypes"] = info.supportedTypes.toList()

        val capabilitiesList = mutableListOf<Map<String, Any>>()
        for (mimeType in info.supportedTypes) {
          if (!mimeType.startsWith("video/")) continue
          try {
            val caps = info.getCapabilitiesForType(mimeType)
            val capMap = mutableMapOf<String, Any>()
            capMap["mimeType"] = mimeType

            // 最大分辨率
            val vcaps = caps.videoCapabilities
            if (vcaps != null) {
              capMap["maxWidth"] = vcaps.supportedWidths.upper
              capMap["maxHeight"] = vcaps.supportedHeights.upper
              capMap["maxFrameRate"] = vcaps.supportedFrameRates.upper
              capMap["maxInstanceCount"] = caps.maxSupportedInstances

              // 测试常见分辨率的 capability
              val testResolutions = listOf(
                Triple(1920, 1080, 30),
                Triple(1920, 1080, 60),
                Triple(2560, 1440, 30),
                Triple(2560, 1440, 60),
                Triple(3840, 2160, 30),
                Triple(3840, 2160, 60),
              )
              val results = mutableListOf<Map<String, Any>>()
              for ((w, h, fps) in testResolutions) {
                val supported = try {
                  vcaps.areSizeAndRateSupported(w, h, fps.toDouble())
                } catch (_: Exception) {
                  false
                }
                results.add(mapOf(
                  "resolution" to "${w}x${h}@${fps}",
                  "supported" to supported,
                  "tampered" to false,
                ))
              }
              capMap["testResults"] = results

              // 支持的 color formats
              capMap["colorFormats"] = caps.colorFormats.toList()

              // 支持的 profile/level
              val profileLevels = caps.profileLevels
              if (profileLevels != null) {
                capMap["profileLevels"] = profileLevels.map { pl ->
                  val profileName = when (mimeType) {
                    MediaFormat.MIMETYPE_VIDEO_AVC -> when (pl.profile) {
                      MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline -> "Baseline"
                      MediaCodecInfo.CodecProfileLevel.AVCProfileMain -> "Main"
                      MediaCodecInfo.CodecProfileLevel.AVCProfileHigh -> "High"
                      MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10 -> "High10"
                      else -> "0x${Integer.toHexString(pl.profile)}"
                    }
                    else -> "0x${Integer.toHexString(pl.profile)}"
                  }
                  val levelName = when (mimeType) {
                    MediaFormat.MIMETYPE_VIDEO_AVC -> when (pl.level) {
                      MediaCodecInfo.CodecProfileLevel.AVCLevel3 -> "3"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel31 -> "3.1"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel4 -> "4"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel41 -> "4.1"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel42 -> "4.2"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel5 -> "5"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel51 -> "5.1"
                      MediaCodecInfo.CodecProfileLevel.AVCLevel52 -> "5.2"
                      else -> "0x${Integer.toHexString(pl.level)}"
                    }
                    else -> "0x${Integer.toHexString(pl.level)}"
                  }
                  "$profileName@$levelName"
                }
              }
            }
            capabilitiesList.add(capMap)
          } catch (e: Exception) {
            capabilitiesList.add(mapOf(
              "mimeType" to mimeType,
              "error" to (e.message ?: "Unknown error")
            ))
          }
        }
        codecInfo["capabilities"] = capabilitiesList
        codecsList.add(codecInfo)
      }

      result["videoDecoders"] = codecsList
      result["totalDecoderCount"] = codecsList.size
      result["totalCodecCount"] = allCodecs.size
      result["sdkInt"] = Build.VERSION.SDK_INT
      result["manufacturer"] = Build.MANUFACTURER
      result["model"] = Build.MODEL
      result["hardware"] = Build.HARDWARE
      result["device"] = Build.DEVICE
      result["board"] = Build.BOARD

      // 同时打印到 logcat 方便调试
      for (codec in codecsList) {
        val name = codec["name"]
        val types = codec["supportedTypes"]
        Log.d("LiveExoCodec", "Codec: $name, types=$types, hw=${codec["isHardwareAccelerated"]}")
        val caps = codec["capabilities"] as? List<Map<String, Any>>
        caps?.forEach { cap ->
          val mimeType = cap["mimeType"]
          val testResults = cap["testResults"] as? List<Map<String, Any>>
          testResults?.forEach { tr ->
            Log.d("LiveExoCodec", "  $mimeType ${tr["resolution"]}: supported=${tr["supported"]}, tampered=${tr["tampered"]}")
          }
        }
      }

    } catch (e: Exception) {
      result["error"] = (e.message ?: "Unknown error")
      Log.e("LiveExoCodec", "dumpAllCodecInfo failed", e)
    }

    return result
  }

  /**
   * 输出 CPU/GPU/VPU 硬件信息，从 /proc 和 /sys 读取。
   */
  private fun dumpDeviceHwInfo(): Map<String, Any> {
    val result = mutableMapOf<String, Any>()

    // CPU info from /proc/cpuinfo
    try {
      val cpuInfo = File("/proc/cpuinfo").readText()
      val cpuMap = mutableMapOf<String, String>()
      cpuInfo.lines().forEach { line ->
        val idx = line.indexOf(':')
        if (idx > 0) {
          val key = line.substring(0, idx).trim()
          val value = line.substring(idx + 1).trim()
          if (key.isNotEmpty()) cpuMap[key] = value
        }
      }
      result["cpuInfo"] = cpuMap
    } catch (e: Exception) {
      result["cpuInfoError"] = (e.message ?: "Unknown")
    }

    // CPU 频率
    try {
      val cpuFreqDir = File("/sys/devices/system/cpu/cpu0/cpufreq")
      if (cpuFreqDir.exists()) {
        val freqInfo = mutableMapOf<String, String>()
        listOf("cpuinfo_max_freq", "cpuinfo_min_freq", "scaling_cur_freq", "scaling_governor").forEach { fname ->
          val f = File(cpuFreqDir, fname)
          if (f.exists()) freqInfo[fname] = f.readText().trim()
        }
        result["cpuFreq"] = freqInfo
      }
    } catch (_: Exception) {}

    // GPU info from various paths
    try {
      val gpuInfo = mutableMapOf<String, String>()
      // Mali GPU
      val maliPaths = listOf(
        "/sys/class/misc/mali0/device/gpuinfo",
        "/sys/devices/platform/soc/1c00000.gpu/misc/mali0/device/gpuinfo",
        "/proc/mali"
      )
      for (path in maliPaths) {
        val f = File(path)
        if (f.exists()) {
          gpuInfo[path] = f.readText().trim().take(2000)
        }
      }
      // GPU frequency
      val gpuFreqDirs = listOf(
        "/sys/class/misc/mali0/device/devfreq/mali0",
        "/sys/devices/platform/soc/1c00000.gpu/devfreq/mali0"
      )
      for (dirPath in gpuFreqDirs) {
        val dir = File(dirPath)
        if (dir.exists()) {
          listOf("max_freq", "min_freq", "cur_freq").forEach { fname ->
            val f = File(dir, fname)
            if (f.exists()) gpuInfo["gpu_$fname"] = f.readText().trim()
          }
        }
      }
      if (gpuInfo.isNotEmpty()) result["gpuInfo"] = gpuInfo
    } catch (_: Exception) {}

    // VPU / Video decoder info
    try {
      val vpuInfo = mutableMapOf<String, String>()
      // MTK VPU
      val mtkVpuPaths = listOf(
        "/sys/class/misc/mtk-vpu",
        "/proc/mtk-vpu"
      )
      for (path in mtkVpuPaths) {
        val f = File(path)
        if (f.exists()) vpuInfo[path] = f.readText().trim().take(1000)
      }
      // Video codec info from sysfs
      val codecPaths = listOf(
        "/sys/class/vcodec",
        "/sys/devices/virtual/vcodec",
        "/proc/avcodec"
      )
      for (path in codecPaths) {
        val dir = File(path)
        if (dir.exists() && dir.isDirectory) {
          dir.listFiles()?.forEach { file ->
            if (file.isFile) {
              vpuInfo["${path}/${file.name}"] = file.readText().trim().take(500)
            }
          }
        }
      }
      if (vpuInfo.isNotEmpty()) result["vpuInfo"] = vpuInfo
    } catch (_: Exception) {}

    // Memory info
    try {
      val memInfo = File("/proc/meminfo").readText()
      val memMap = mutableMapOf<String, String>()
      memInfo.lines().forEach { line ->
        val idx = line.indexOf(':')
        if (idx > 0) {
          memMap[line.substring(0, idx).trim()] = line.substring(idx + 1).trim()
        }
      }
      result["memInfo"] = memMap
    } catch (_: Exception) {}

    // Build info
    result["buildInfo"] = mapOf(
      "MANUFACTURER" to Build.MANUFACTURER,
      "BRAND" to Build.BRAND,
      "MODEL" to Build.MODEL,
      "DEVICE" to Build.DEVICE,
      "HARDWARE" to Build.HARDWARE,
      "BOARD" to Build.BOARD,
      "PRODUCT" to Build.PRODUCT,
      "DISPLAY" to Build.DISPLAY,
      "FINGERPRINT" to Build.FINGERPRINT,
      "SDK_INT" to Build.VERSION.SDK_INT,
      "RELEASE" to Build.VERSION.RELEASE,
      "CODENAME" to Build.VERSION.CODENAME,
      "SUPPORTED_ABIS" to Build.SUPPORTED_ABIS.toList(),
      "SUPPORTED_32_BIT_ABIS" to Build.SUPPORTED_32_BIT_ABIS.toList(),
      "SUPPORTED_64_BIT_ABIS" to Build.SUPPORTED_64_BIT_ABIS.toList(),
    )

    // 同时打印到 logcat
    Log.d("LiveExoHw", "Device HW Info: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.HARDWARE})")
    Log.d("LiveExoHw", "SDK: ${Build.VERSION.SDK_INT}, ABIs: ${Build.SUPPORTED_ABIS.toList()}")
    (result["cpuInfo"] as? Map<String, String>)?.let { cpu ->
      Log.d("LiveExoHw", "CPU: ${cpu["Hardware"] ?: cpu["model name"] ?: "unknown"}, cores: ${cpu["cpu cores"] ?: "?"}")
    }
    (result["gpuInfo"] as? Map<String, String>)?.let { gpu ->
      gpu.forEach { (k, v) -> Log.d("LiveExoHw", "GPU $k: $v") }
    }

    return result
  }

  private fun releasePlayer() {
    player?.let {
      it.removeListener(playerListener)
      it.stop()
      it.release()
    }
    player = null
    videoSurface?.release()
    videoSurface = null
    textureEntry?.release()
    textureEntry = null
    currentUrl = null
  }
}
