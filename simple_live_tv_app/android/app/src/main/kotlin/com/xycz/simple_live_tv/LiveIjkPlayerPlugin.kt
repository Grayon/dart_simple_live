package com.xycz.simple_live_tv

import android.content.Context
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import tv.danmaku.ijk.media.player.IjkMediaPlayer
import tv.danmaku.ijk.media.player.IMediaPlayer
import java.io.File

/** 自定义 IJKPlayer 插件，基于 FFmpeg，格式兼容性好 */
class LiveIjkPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var appContext: Context

    private var player: IjkMediaPlayer? = null
    private var textureEntry: TextureRegistry.SurfaceProducer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var currentUrl: String? = null

    // 播放统计
    private var totalDroppedFrames: Int = 0
    // 缓存大小（create 时保存，open reset 后重新应用选项时使用）
    private var bufferSizeBytes: Int = 32 * 1024 * 1024

    private val playerListener = object : IMediaPlayer.OnPreparedListener,
        IMediaPlayer.OnCompletionListener,
        IMediaPlayer.OnErrorListener,
        IMediaPlayer.OnVideoSizeChangedListener,
        IMediaPlayer.OnBufferingUpdateListener,
        IMediaPlayer.OnInfoListener {

        override fun onPrepared(mp: IMediaPlayer?) {
            eventSink?.success(mapOf("event" to "buffering", "value" to false))
            eventSink?.success(mapOf("event" to "playing", "value" to true))
            val w = mp?.videoWidth ?: 0
            val h = mp?.videoHeight ?: 0
            if (w > 0 && h > 0) {
                eventSink?.success(
                    mapOf(
                        "event" to "videoSize",
                        "width" to w,
                        "height" to h
                    )
                )
            }
        }

        override fun onCompletion(mp: IMediaPlayer?) {
            eventSink?.success(mapOf("event" to "completed"))
        }

        override fun onError(mp: IMediaPlayer?, what: Int, extra: Int): Boolean {
            val msg = "IJKPlayer error (what=$what, extra=$extra)"
            Log.e("LiveIjkPlayer", msg)
            eventSink?.success(
                mapOf(
                    "event" to "error",
                    "message" to msg,
                    "errorCode" to what
                )
            )
            return true
        }

        override fun onVideoSizeChanged(
            mp: IMediaPlayer?,
            width: Int,
            height: Int,
            sarNum: Int,
            sarDen: Int
        ) {
            if (width > 0 && height > 0) {
                eventSink?.success(
                    mapOf(
                        "event" to "videoSize",
                        "width" to width,
                        "height" to height
                    )
                )
            }
        }

        override fun onBufferingUpdate(mp: IMediaPlayer?, percent: Int) {
            // IJK 的 buffering 回调不需要推送状态，播放状态由 onPrepared/onError 驱动
        }

        override fun onInfo(mp: IMediaPlayer?, what: Int, extra: Int): Boolean {
            when (what) {
                IMediaPlayer.MEDIA_INFO_BUFFERING_START -> {
                    eventSink?.success(mapOf("event" to "buffering", "value" to true))
                }
                IMediaPlayer.MEDIA_INFO_BUFFERING_END -> {
                    eventSink?.success(mapOf("event" to "buffering", "value" to false))
                }
                IMediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START -> {
                    eventSink?.success(mapOf("event" to "playing", "value" to true))
                }
            }
            return true
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry

        // 加载 native 库
        try {
            IjkMediaPlayer.loadLibrariesOnce(null)
            IjkMediaPlayer.native_profileBegin("libijkplayer.so")
        } catch (e: Exception) {
            Log.e("LiveIjkPlayer", "Failed to load IJK libraries", e)
        }

        channel = MethodChannel(binding.binaryMessenger, "com.xycz.simple_live_tv/ijk_player")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.xycz.simple_live_tv/ijk_player_events")
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val logLevel = call.argument<Int>("logLevel") ?: 5
                val bufferSize = call.argument<Int>("bufferSize") ?: (32 * 1024 * 1024)
                val textureId = createPlayer(logLevel, bufferSize)
                result.success(mapOf("textureId" to textureId))
            }
            "open" -> {
                val url = call.argument<String>("url") ?: return result.error("NO_URL", "No URL", null)
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                open(url, headers)
                result.success(null)
            }
            "stop" -> {
                player?.reset()
                eventSink?.success(mapOf("event" to "playing", "value" to false))
                result.success(null)
            }
            "dispose" -> {
                releasePlayer()
                result.success(null)
            }
            "setProperty" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                setProperty(key, value)
                result.success(null)
            }
            "getVideoInfo" -> {
                val p = player
                if (p == null) {
                    result.success(null)
                } else {
                    result.success(
                        mapOf(
                            "width" to p.videoWidth,
                            "height" to p.videoHeight,
                            "frameRate" to p.videoOutputFramesPerSecond,
                            "codec" to decoderName(p.videoDecoder),
                            "bitrate" to p.bitRate,
                            "audioCodec" to "",
                            "audioBitrate" to 0,
                            "audioSampleRate" to 0,
                            "audioChannels" to 0,
                            "droppedFrames" to totalDroppedFrames,
                            "isPlaying" to p.isPlaying,
                            "bufferedPosition" to 0,
                            "currentPosition" to p.currentPosition,
                            "contentDuration" to p.duration,
                            "playbackSpeed" to p.getSpeed(0f),
                            "hwDecoder" to if (p.videoDecoder == IjkMediaPlayer.FFP_PROPV_DECODER_MEDIACODEC) "mediacodec" else "ffmpeg",
                        )
                    )
                }
            }
            "getCodecInfo" -> {
                result.success(dumpCodecInfo())
            }
            "getDeviceHwInfo" -> {
                result.success(dumpDeviceHwInfo())
            }
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(logLevel: Int, bufferSize: Int): Long {
        releasePlayer()

        // 创建 Flutter Texture 入口
        val entry = textureRegistry.createSurfaceProducer()
        textureEntry = entry

        val p = IjkMediaPlayer()

        // 日志级别
        val ijkLogLevel = when (logLevel) {
            0 -> IjkMediaPlayer.IJK_LOG_SILENT
            1 -> IjkMediaPlayer.IJK_LOG_ERROR
            2 -> IjkMediaPlayer.IJK_LOG_ERROR
            3 -> IjkMediaPlayer.IJK_LOG_WARN
            4 -> IjkMediaPlayer.IJK_LOG_INFO
            5 -> IjkMediaPlayer.IJK_LOG_DEBUG
            6 -> IjkMediaPlayer.IJK_LOG_VERBOSE
            else -> IjkMediaPlayer.IJK_LOG_INFO
        }
        IjkMediaPlayer.native_setLogLevel(ijkLogLevel)

        bufferSizeBytes = bufferSize
        applyPlayerOptions(p, bufferSize)

        // 绑定监听器
        p.setOnPreparedListener(playerListener)
        p.setOnCompletionListener(playerListener)
        p.setOnErrorListener(playerListener)
        p.setOnVideoSizeChangedListener(playerListener)
        p.setOnBufferingUpdateListener(playerListener)
        p.setOnInfoListener(playerListener)

        player = p

        // 绑定 Surface
        entry.surface?.let { surface ->
            p.setSurface(surface)
        }

        // Surface 重建时重新绑定
        entry.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceCreated() {
                    entry.surface?.let { surface ->
                        player?.setSurface(surface)
                    }
                }

                override fun onSurfaceDestroyed() {
                    player?.setSurface(null)
                }
            }
        )

        return entry.id()
    }

    /**
     * 配置播放器选项（缓冲、硬解等）。
     *
     * 必须在 createPlayer 和每次 open(reset 后) 都重新调用，因为
     * IjkMediaPlayer.reset() 会调用 native ffp_reset_internal，
     * 清除 player_opts 字典并将所有 mediacodec 字段重置为 0，
     * 导致切源后硬解失效回退到 FFmpeg 软解。
     */
    private fun applyPlayerOptions(p: IjkMediaPlayer, bufferSize: Int) {
        // 缓冲参数
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "probsize", bufferSize.toLong())
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 2L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-fps", 60L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // 直播流优化：不自动暂停、不缓存到本地
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "nobuffer")
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "flags", "low_delay")
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")

        // 硬件解码（MediaCodec）
        // 注意：debugly/ijkplayer 的 "mediacodec" 选项仅启用 H264 (mediacodec_avc)，
        // HEVC/AV1 等其他编码格式不会走硬解。需要用 "mediacodec-all-videos"
        // 覆盖所有视频格式，或单独启用 mediacodec-hevc 等。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 0L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
    }

    private fun open(url: String, headers: Map<String, String>) {
        val p = player ?: return
        currentUrl = url
        p.reset()

        // reset() 会清除 native 层的 surface 绑定和所有 player 选项，
        // 必须重新绑定 Surface 并重新应用选项（否则硬解失效、无视频画面）
        textureEntry?.surface?.let { surface ->
            p.setSurface(surface)
        }
        applyPlayerOptions(p, bufferSizeBytes)

        // 设置 HTTP 请求头
        if (headers.isNotEmpty()) {
            val sb = StringBuilder()
            for ((key, value) in headers) {
                sb.append("$key: $value\r\n")
            }
            p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "headers", sb.toString())
        }

        try {
            p.setDataSource(appContext, Uri.parse(url))
            p.prepareAsync()
        } catch (e: Exception) {
            Log.e("LiveIjkPlayer", "Failed to open URL: $url", e)
            eventSink?.success(
                mapOf(
                    "event" to "error",
                    "message" to "Failed to open: ${e.message}",
                    "errorCode" to -1
                )
            )
        }
    }

    private fun setProperty(key: String, value: String) {
        val p = player ?: return
        when (key) {
            "volume" -> {
                val v = value.toFloatOrNull() ?: 1.0f
                p.setVolume(v, v)
            }
            "playback-speed" -> {
                val speed = value.toFloatOrNull() ?: 1.0f
                p.setSpeed(speed)
            }
        }
    }

    private fun dumpCodecInfo(): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        val codecsList = mutableListOf<Map<String, Any>>()
        try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            val videoDecoders = codecList.codecInfos.filter { info ->
                !info.isEncoder && info.supportedTypes.any { it.startsWith("video/") }
            }.sortedBy { it.name }
            for (info in videoDecoders) {
                codecsList.add(
                    mapOf(
                        "name" to info.name,
                        "isHardwareAccelerated" to info.isHardwareAccelerated,
                        "supportedTypes" to info.supportedTypes.toList(),
                    )
                )
            }
            result["videoDecoders"] = codecsList
            result["totalDecoderCount"] = codecsList.size
        } catch (e: Exception) {
            result["error"] = (e.message ?: "Unknown error")
        }
        return result
    }

    private fun dumpDeviceHwInfo(): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
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
        result["buildInfo"] = mapOf(
            "MANUFACTURER" to Build.MANUFACTURER,
            "MODEL" to Build.MODEL,
            "SDK_INT" to Build.VERSION.SDK_INT,
            "RELEASE" to Build.VERSION.RELEASE,
            "SUPPORTED_ABIS" to Build.SUPPORTED_ABIS.toList(),
        )
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
        return result
    }

    private fun decoderName(decoder: Int): String {
        return when (decoder) {
            IjkMediaPlayer.FFP_PROPV_DECODER_MEDIACODEC -> "mediacodec"
            IjkMediaPlayer.FFP_PROPV_DECODER_AVCODEC -> "ffmpeg"
            IjkMediaPlayer.FFP_PROPV_DECODER_VIDEOTOOLBOX -> "videotoolbox"
            else -> ""
        }
    }

    private fun releasePlayer() {
        player?.let {
            it.setOnPreparedListener(null)
            it.setOnCompletionListener(null)
            it.setOnErrorListener(null)
            it.setOnVideoSizeChangedListener(null)
            it.setOnInfoListener(null)
            it.reset()
            it.release()
        }
        player = null
        textureEntry?.release()
        textureEntry = null
        currentUrl = null
    }
}
