package com.edwinrubio.bg_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
            "initialize" -> initialize(call.argument<String>("lens") != "back", result)
            "setBackground" -> setBackground(call.argument("type"), call.argument("path"), result)
            "switchCamera" -> withPipeline(result) {
                it.switchCamera()
                result.success(null)
            }
            "startSegment" -> withPipeline(result) {
                try {
                    it.startSegment()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("record_failed", e.message, null)
                }
            }
            "stopSegment" -> withPipeline(result) {
                it.stopSegment { outcome ->
                    mainHandler.post {
                        outcome.fold(
                            { segment -> result.success(mapOf("path" to segment.path, "durationMs" to segment.durationMs)) },
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

    private fun initialize(front: Boolean, result: Result) {
        dispose()
        val pipeline = CameraPipeline(context, textures)
        this.pipeline = pipeline
        pipeline.start(front) { error ->
            if (error != null) {
                dispose()
                result.error("camera_unavailable", error.message, null)
            } else {
                result.success(
                    mapOf(
                        "textureId" to pipeline.textureId,
                        "width" to CameraPipeline.OUTPUT_WIDTH,
                        "height" to CameraPipeline.OUTPUT_HEIGHT,
                    ),
                )
            }
        }
    }

    private fun setBackground(type: String?, path: String?, result: Result) = withPipeline(result) { pipeline ->
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
    }
}
