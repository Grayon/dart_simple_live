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

    // logcat 捕获：将 native 层 IJK 日志（如 amc: video_mime_type error）
    // 转发到 Dart 层写入日志文件，方便诊断硬解问题
    private var logcatProcess: Process? = null
    private var logcatThread: Thread? = null

    // MediaCodec 解码器选择回调：native 层从流中解析出实际 mime type 后回调，
    // 返回硬件解码器名称强制硬解（返回 null 则 IJK 自动选择，会回退到 FFmpeg）。
    // 必须在 createPlayer 和每次 open(reset 后) 都重新注册，因为
    // IjkMediaPlayer.reset() 会调用 resetListeners() 清除所有监听器。
    private val mediaCodecSelectListener =
        IjkMediaPlayer.OnMediaCodecSelectListener { _, mimeType, profile, level ->
            val codecName = selectHardwareCodec(mimeType)
            eventSink?.success(
                mapOf(
                    "event" to "nativeLog",
                    "message" to "onMediaCodecSelect: mime=$mimeType profile=$profile level=$level -> $codecName"
                )
            )
            codecName
        }

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
                    // Dart 端订阅事件通道后 eventSink 才有效，
                    // 此时再启动 logcat 捕获，避免 native 日志被静默丢弃
                    startLogcatCapture()
                    eventSink?.success(
                        mapOf("event" to "nativeLog", "message" to "IJK_LOGCAT_CAPTURE_STARTED")
                    )
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    stopLogcatCapture()
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
        p.setOnMediaCodecSelectListener(mediaCodecSelectListener)

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
        // min-frames 从 5 提升到 10，给 2K 高码率流（~16Mbps）留更多缓冲余量，
        // 关键帧大、解码耗时长，缓冲太小容易耗尽导致画面卡住。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 10L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-fps", 60L)
        // framedrop=1：允许在解码/渲染管线落后时丢帧，避免高码率流（如 2K）
        // 因输出缓冲区占满导致解码器阻塞、画面冻住（音频走独立管线不受影响）。
        // 之前设为 0 导致 2K 流播放 2 秒后画面卡住。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // 直播流优化：不缓存到本地，但保留 ffmpeg 内部缓冲（不设 nobuffer）
        // 之前 fflags=nobuffer + flags=low_delay 过于激进，网络稍有抖动就
        // 缓冲耗尽导致画面卡住。移除 nobuffer 允许 ffmpeg 维持一定预缓冲。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "flags", "low_delay")
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")
        // 网络断线自动重连，避免直播流断开后卡死
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)

        // 硬件解码（MediaCodec）
        // 注意：debugly/ijkplayer 的 "mediacodec" 选项仅启用 H264 (mediacodec_avc)，
        // HEVC/AV1 等其他编码格式不会走硬解。需要用 "mediacodec-all-videos"
        // 覆盖所有视频格式，或单独启用 mediacodec-hevc 等。
        // 参考 blbl (cat3399/blbl) 的做法：显式设置 mediacodec-avc 和 mediacodec-auto-rotate。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)

        // async-init-decoder=1 + video-mime-type + mediacodec-default-name 走
        // ffpipeline_init_video_decoder 异步初始化路径，直接用 mediacodec-default-name
        // 通过 SDL_AMediaCodecJava_createByCodecName 创建硬件 MediaCodec，
        // 绕过同步路径的 mediacodec_select_callback（需 Java 层 onMediaCodecSelect
        // 返回非空，否则 amc: no suitable codec 回退 FFmpeg）。
        // 参考 ff_ffplay.c:3713 的异步初始化条件：必须同时设置 video_mime_type
        // 和 mediacodec_default_name（非空）才会进入该分支。
        // 注意：IJK 选项名用连字符（async-init-decoder），下划线会被静默忽略。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "async-init-decoder", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "video-mime-type", "video/avc")

        // mediacodec-default-name 直接指定硬件解码器名称，绕过 native 层的
        // video_mime_type strcmp 检查（该 fork 无 NULL 保护，不设或设错都会
        // 回退 FFmpeg）和 DefaultMediaCodecSelector 选择流程。
        // 动态查找设备的 H.264 硬件解码器，兼容不同设备（MTK/高通/海思等）。
        val hwCodecName = findHardwareCodecName("video/avc")
        if (hwCodecName != null) {
            Log.i("LiveIjkPlayer", "mediacodec-default-name = $hwCodecName")
            eventSink?.success(
                mapOf("event" to "nativeLog", "message" to "mediacodec-default-name = $hwCodecName")
            )
            p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-default-name", hwCodecName)
        } else {
            Log.w("LiveIjkPlayer", "未找到 video/avc 硬件解码器，将回退 FFmpeg 软解")
            eventSink?.success(
                mapOf("event" to "nativeLog", "message" to "未找到 video/avc 硬件解码器，将回退 FFmpeg 软解")
            )
        }
    }

    /** 查找设备上支持指定 mime type 的硬件解码器名称 */
    private fun findHardwareCodecName(mimeType: String): String? {
        return try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            codecList.codecInfos.firstOrNull { info ->
                !info.isEncoder &&
                    info.isHardwareAccelerated &&
                    info.supportedTypes.contains(mimeType)
            }?.name
        } catch (e: Exception) {
            null
        }
    }

    private fun open(url: String, headers: Map<String, String>) {
        val p = player ?: return
        currentUrl = url
        p.reset()

        // reset() 会清除 native 层的 surface 绑定、所有 player 选项和监听器，
        // 必须重新绑定 Surface、应用选项、注册 MediaCodec 选择回调
        // （否则硬解失效、无视频画面、onMediaCodecSelect 不触发）
        textureEntry?.surface?.let { surface ->
            p.setSurface(surface)
        }
        applyPlayerOptions(p, bufferSizeBytes)
        p.setOnMediaCodecSelectListener(mediaCodecSelectListener)

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

    /**
     * 根据 native 层回调的实际 mime type，查找设备上对应的硬件解码器名称并返回。
     * 返回 null 则 IJK 自动选择（通常会回退到 FFmpeg 软解）。
     *
     * 这样做绕过了 video-mime-type 选项的 strcmp 匹配逻辑（该 fork 无 NULL 保护，
     * 不设 video-mime-type 时必定失败回退），直接指定硬件解码器名称。
     */
    private fun selectHardwareCodec(mimeType: String?): String? {
        if (mimeType.isNullOrEmpty()) return null
        try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            // 优先选择硬件解码器（isHardwareAccelerated），且匹配 mime type
            val hwCodec = codecList.codecInfos.firstOrNull { info ->
                !info.isEncoder &&
                    info.isHardwareAccelerated &&
                    info.supportedTypes.contains(mimeType)
            }
            if (hwCodec != null) {
                return hwCodec.name
            }
            // 没有硬件解码器，返回 null 让 IJK 自行处理（会回退软解）
            return null
        } catch (e: Exception) {
            Log.e("LiveIjkPlayer", "selectHardwareCodec failed for $mimeType", e)
            return null
        }
    }

    private fun releasePlayer() {
        stopLogcatCapture()
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

    /**
     * 启动 logcat 捕获，将 native 层 IJK 日志（如 amc: video_mime_type error、
     * MediaCodec 初始化失败等）通过 EventChannel 转发到 Dart 层写入日志文件。
     *
     * 这些日志由 C 层直接输出到 Android logcat，不经过 Java/Kotlin 层，
     * 之前无法被 Dart 层的 Log 系统捕获，导致硬解失败时无法诊断。
     *
     * 注意：必须在 eventSink 就绪后调用（onListen 回调中），否则日志会被静默丢弃。
     */
    private fun startLogcatCapture() {
        stopLogcatCapture()
        try {
            // 清空 logcat 缓冲区，避免旧日志干扰
            val clearProcess = Runtime.getRuntime().exec(arrayOf("logcat", "-c"))
            clearProcess.waitFor()

            // 不过滤 tag，捕获所有日志后在 Kotlin 层过滤。
            // 原因：debugly/ijkplayer fork 的 native 日志 tag 不确定，
            // 之前用 -s IJKMEDIA IJK ijkplayer ffmpeg 过滤会漏掉关键日志。
            val logcatProcess = Runtime.getRuntime().exec(
                arrayOf("logcat", "-v", "brief")
            )
            this.logcatProcess = logcatProcess

            val thread = Thread {
                try {
                    logcatProcess.inputStream.bufferedReader().useLines { lines ->
                        for (line in lines) {
                            if (line.isBlank()) continue
                            val lower = line.lowercase()
                            // 只转发 IJK/MediaCodec/FFmpeg 相关日志，减少噪音
                            if (lower.contains("ijk") ||
                                lower.contains("mediacodec") ||
                                lower.contains("amc") ||
                                lower.contains("ffmpeg") ||
                                lower.contains("ffp") ||
                                lower.contains("videotoolbox") ||
                                lower.contains("sdl_") ||
                                lower.contains("libijksdl") ||
                                lower.contains("libijkplayer") ||
                                lower.contains("avcodec") ||
                                lower.contains("decoder") ||
                                lower.contains("codec_id") ||
                                lower.contains("video_mime_type") ||
                                lower.contains("h264") ||
                                lower.contains("hevc") ||
                                lower.contains("flv") ||
                                lower.contains("live") ||
                                lower.contains("stream_component_open")
                            ) {
                                eventSink?.success(
                                    mapOf(
                                        "event" to "nativeLog",
                                        "message" to line.trim()
                                    )
                                )
                            }
                        }
                    }
                } catch (_: Exception) {
                    // 进程被终止时正常退出
                }
            }
            thread.isDaemon = true
            thread.name = "IJKLogcatCapture"
            thread.start()
            this.logcatThread = thread
            Log.i("LiveIjkPlayer", "logcat capture started")
        } catch (e: Exception) {
            Log.e("LiveIjkPlayer", "Failed to start logcat capture", e)
        }
    }

    private fun stopLogcatCapture() {
        try {
            logcatProcess?.destroy()
        } catch (_: Exception) {
        }
        logcatProcess = null
        logcatThread = null
    }
}
