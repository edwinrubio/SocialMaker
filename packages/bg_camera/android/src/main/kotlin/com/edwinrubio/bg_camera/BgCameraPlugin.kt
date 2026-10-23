package com.edwinrubio.bg_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executors

/** BgCameraPlugin */
class BgCameraPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pipeline: CameraPipeline? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: Result? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        textures = flutterPluginBinding.textureRegistry
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "bg_camera")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "requestPermissions" -> requestPermissions(result)
            "supportedResolutions" -> result.success(OutputResolution.supported(context).map { it.name })
            "initialize" -> {
                val resolution =
                    OutputResolution.entries.firstOrNull { it.name == call.argument<String>("resolution") }
                        ?: OutputResolution.p1080
                initialize(call.argument<String>("lens") != "back", resolution, result)
            }
            "setZoom" -> withPipeline(result) {
                it.setZoom(call.argument<Double>("fraction")?.toFloat() ?: 0f)
                result.success(null)
            }
            "subtitlesSupported" -> result.success(false)
            "shareToApp" -> shareToApp(call.argument("path"), call.argument("app"), result)
            "setBackground" ->
                setBackground(
                    call.argument("type"),
                    call.argument("path"),
                    call.argument<Double>("blurStrength") ?: 0.5,
                    result,
                )
            "switchCamera" -> withPipeline(result) {
                it.switchCamera()
                result.success(null)
            }
            "startSegment" -> withPipeline(result) {
                it.startSegment { outcome ->
                    mainHandler.post {
                        outcome.fold(
                            { result.success(null) },
                            { error -> result.error("record_failed", error.message, null) },
                        )
                    }
                }
            }
            "stopSegment" -> withPipeline(result) {
                it.stopSegment { outcome ->
                    mainHandler.post {
                        outcome.fold(
                            { segment ->
                                result.success(
                                    mapOf(
                                        "path" to segment.path,
                                        "durationMs" to segment.durationMs,
                                        "thumbnailPath" to segment.thumbnailPath,
                                    ),
                                )
                            },
                            { error -> result.error("record_failed", error.message, null) },
                        )
                    }
                }
            }
            "mergeSegments" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                SegmentMerger.merge(context, paths) { outcome ->
                    outcome.fold(
                        { path -> result.success(path) },
                        { error -> result.error("merge_failed", error.message, null) },
                    )
                }
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        dispose()
        worker.shutdown()
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSIONS_REQUEST_CODE) return false
        pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pendingPermissionResult = null
        return true
    }

    private fun requestPermissions(result: Result) {
        val missing = PERMISSIONS.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        val activity: Activity? = activityBinding?.activity
        when {
            missing.isEmpty() -> result.success(true)
            activity == null -> result.error("no_activity", "Permissions need a foreground activity", null)
            pendingPermissionResult != null -> result.error("busy", "A permission request is already running", null)
            else -> {
                pendingPermissionResult = result
                activity.requestPermissions(missing.toTypedArray(), PERMISSIONS_REQUEST_CODE)
            }
        }
    }

    private fun initialize(
        front: Boolean,
        resolution: OutputResolution,
        result: Result,
    ) {
        dispose()
        Recordings.clear(context)
        val pipeline = CameraPipeline(context, textures, resolution)
        this.pipeline = pipeline
        pipeline.start(front) { error ->
            if (error != null) {
                dispose()
                result.error("camera_unavailable", error.message, null)
            } else {
                result.success(
                    mapOf(
                        "textureId" to pipeline.textureId,
                        "width" to resolution.width,
                        "height" to resolution.height,
                    ),
                )
            }
        }
    }

    private fun setBackground(
        type: String?,
        path: String?,
        blurStrength: Double,
        result: Result,
    ) = withPipeline(result) { pipeline ->
        when {
            type == "image" && path != null -> worker.execute {
                val bitmap = BitmapLoader.load(File(path), maxSide = 1920)
                mainHandler.post {
                    if (bitmap == null) {
                        result.error("bad_background", "Cannot read image $path", null)
                    } else {
                        pipeline.setBackground(Background.Image(bitmap))
                        result.success(null)
                    }
                }
            }
            type == "blur" -> {
                pipeline.setBackground(Background.Blur(blurStrength.toFloat()))
                result.success(null)
            }
            type == "video" && path != null -> {
                pipeline.setBackground(Background.Video(Uri.fromFile(File(path))))
                result.success(null)
            }
            else -> {
                pipeline.setBackground(null)
                result.success(null)
            }
        }
    }

    /** Sends the video to TikTok, Instagram or YouTube; the chooser if not installed. */
    private fun shareToApp(
        path: String?,
        app: String?,
        result: Result,
    ) {
        val activity = activityBinding?.activity
        if (path == null || activity == null) {
            result.error("share_failed", "Nothing to share", null)
            return
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.bg_camera.files", File(path))
        val send =
            Intent(Intent.ACTION_SEND).apply {
                type = "video/mp4"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        val installed =
            SHARE_PACKAGES[app].orEmpty().firstOrNull { pkg ->
                runCatching { context.packageManager.getPackageInfo(pkg, 0) }.isSuccess
            }
        val intent =
            if (installed != null) {
                send.setPackage(installed)
            } else {
                Intent.createChooser(send, null)
            }
        try {
            activity.startActivity(intent)
            result.success(installed != null || app == null)
        } catch (e: Exception) {
            result.error("share_failed", e.message, null)
        }
    }

    private fun withPipeline(result: Result, body: (CameraPipeline) -> Unit) {
        val pipeline = pipeline
        if (pipeline == null) {
            result.error("not_initialized", "Call initialize first", null)
        } else {
            body(pipeline)
        }
    }

    private fun dispose() {
        pipeline?.release()
        pipeline = null
    }

    private companion object {
        const val PERMISSIONS_REQUEST_CODE = 0x6263
        val PERMISSIONS = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        val SHARE_PACKAGES =
            mapOf(
                "tiktok" to listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill"),
                "instagram" to listOf("com.instagram.android"),
                "youtube" to listOf("com.google.android.youtube"),
            )
    }
}
