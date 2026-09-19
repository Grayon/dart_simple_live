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

    // 播放统计
    private var totalDroppedFrames: Int = 0

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
                val textureId = createPlayer(logLevel)
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

    private fun createPlayer(logLevel: Int): Long {
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

        applyPlayerOptions(p)

        // 绑定监听器
        p.setOnPreparedListener(playerListener)
        p.setOnCompletionListener(playerListener)
        p.setOnErrorListener(playerListener)
        p.setOnVideoSizeChangedListener(playerListener)
        p.setOnBufferingUpdateListener(playerListener)
        p.setOnInfoListener(playerListener)
        // 注意：不要调用 setOnMediaCodecSelectListener。
        // 保持该字段为 null，native 才会启用 AAR 内置的
        // IjkMediaPlayer$DefaultMediaCodecSelector（旧 API、按流的真实
        // mime/profile/level 排序，AVC/HEVC 与新老盒子都能选到硬解）。

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
     * 配置播放器选项（硬解、网络等）。
     *
     * 必须在 createPlayer 和每次 open(reset 后) 都重新调用，因为
     * IjkMediaPlayer.reset() 会调用 native ffp_reset_internal，
     * 清除 player_opts 字典并将所有 mediacodec 字段重置为 0。
     *
     * 配置对齐 pure_live 的 fijk 内核（实测 2K 高码率直播流畅，而本项目旧配置卡死）：
     * 只开 MediaCodec 硬解（AVC/HEVC）+ 断线重连，缓冲/时间戳选项全部交给 ijk 出厂默认
     * （http-flv 走 15MB 有界包队列 + packet-buffering 冻帧重缓冲）。
     *
     * 关键：绝不设置 async-init-decoder / video-mime-type / mediacodec-default-name，
     * 也不注册 OnMediaCodecSelectListener。
     *  - 异步三件套会把流按写死的 video/avc 建解码器，HEVC 2K 流 mime 不匹配 →
     *    configure 失败 → 静默回退 FFmpeg 软解 → 2K 幻灯片/卡死；
     *  - 自注册 listener 用 API29+ 的 isHardwareAccelerated，老盒子(API26-28)恒抛
     *    异常返回 null，且返回 null 不会回落内置选择器 → 同样软解。
     *  已用 AAR 字节码验证 onSelectCodec：listener 字段为 null 时取
     *  DefaultMediaCodecSelector.sInstance（旧 API + 真实 mime + profile/level 排序）。
     */
    private fun applyPlayerOptions(p: IjkMediaPlayer) {
        // 播放控制：准备好即起播
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // 网络：断线重连 + 30 秒超时（对齐 fijk_helper.dart）
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", 30_000_000L)

        // FLV 直播流协议白名单：ijklivehook/ijklongurl 等是 IJK 处理 FLV 直播的
        // 专用协议钩子，部分超长/特殊直播 URL 缺了会打不开，保留这层兜底。
        p.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "async,cache,crypto,file,http,https,ijkhttphook,ijkinject,ijklivehook,ijklongurl,ijksegment,ijktcphook,pipe,rtp,tcp,tls,udp,ijkurlhook,data"
        )
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "allowed_extensions", "ALL")

        // 对齐 fijk：只用 fastseek（直播不可 seek，实际无作用，仅保持配置一致）。
        // 不设 genpts/igndts/discardcorrupt，避免扰动 FLV 正常时间戳与音画同步；
        // 不设 infbuf（保留出厂 15MB 有界背压，防止高码率下包队列无限膨胀）。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek")

        // 硬件解码（MediaCodec）：具体解码器交给内置 DefaultMediaCodecSelector
        // 按流的真实 mime（AVC/HEVC 一视同仁）自动选择，这里只负责开启能力。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
    }

    private fun open(url: String, headers: Map<String, String>) {
        val p = player ?: return
        currentUrl = url
        p.reset()

        // reset() 会清除 native 层的 surface 绑定和所有 player 选项，
        // 必须重新绑定 Surface、重新应用选项（否则硬解失效、无视频画面）。
        textureEntry?.surface?.let { surface ->
            p.setSurface(surface)
        }
        applyPlayerOptions(p)

        // 设置 HTTP 请求头
        if (headers.isNotEmpty()) {
            val sb = StringBuilder()
            for ((key, value) in headers) {
                sb.append("$key: $value\r\n")
            }
            p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "headers", sb.toString())
        }

        try {
            // 用纯字符串 setDataSource(url) 而非 setDataSource(context, uri)，
            // 避免 ContentResolver 对 HTTP FLV 直播流的额外开销和处理不当。
            // 参考 blbl (cat3399/blbl) 对直播流的做法。
            p.setDataSource(url)
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
