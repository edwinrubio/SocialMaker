package com.edwinrubio.bg_camera

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Person mask, one byte per pixel (255 = person), in upright orientation. */
class Mask(val bytes: ByteBuffer, val width: Int, val height: Int)

/** Recorded video size (portrait) and H.264 bit rate. Names match the Dart enum. */
enum class OutputResolution(
    val width: Int,
    val height: Int,
    val bitRate: Int,
) {
    p720(720, 1280, 6_000_000),
    p1080(1080, 1920, 12_000_000),
    p2160(2160, 3840, 40_000_000),
    ;

    companion object {
        /** Sizes both the front camera and an H.264 encoder can handle. */
        fun supported(context: Context): List<OutputResolution> {
            val encoders =
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
                    info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
                }
            val cameraSizes = frontCameraSizes(context)
            val supported =
                entries.filter { resolution ->
                    val encoderOk =
                        encoders.any {
                            it
                                .getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                                .videoCapabilities
                                .isSizeSupported(resolution.width, resolution.height)
                        }
                    // Camera sizes are landscape.
                    val cameraOk =
                        cameraSizes.any {
                            maxOf(it.width, it.height) >= resolution.height &&
                                minOf(it.width, it.height) >= resolution.width
                        }
                    encoderOk && cameraOk
                }
            return supported.ifEmpty { listOf(p720) }
        }

        private fun frontCameraSizes(context: Context): List<Size> {
            val manager = context.getSystemService(CameraManager::class.java) ?: return emptyList()
            return manager.cameraIdList
                .map(manager::getCameraCharacteristics)
                .filter { it.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT }
                .flatMap {
                    it
                        .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                        ?.getOutputSizes(SurfaceTexture::class.java)
                        ?.toList()
                        .orEmpty()
                }
        }
    }
}

/**
 * The camera streams into [GlRenderer]'s GPU texture; a small analysis stream
 * feeds the person segmentation only while a background is active.
 *
 * In dual mode both cameras run at once (CameraX concurrent cameras, only on
 * devices that support it); [front] then says which one fills the frame.
 *
 * Public methods are called on the main thread.
 */
class CameraPipeline(
    private val context: Context,
    textures: TextureRegistry,
    val resolution: OutputResolution,
) : LifecycleOwner {
    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private val producer = textures.createSurfaceProducer()
    val textureId: Long get() = producer.id()

    private val renderer = GlRenderer(context, resolution)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var front = true
    private var dual = false
    private var dualCameras: Map<Boolean, Camera> = emptyMap()

    @Volatile private var segmentationEnabled = false
    private var segmenter: PersonSegmenter? = null
    private var segmenterUnavailable = false
    private var analysisBitmap: Bitmap? = null

    fun start(
        front: Boolean,
        callback: (Exception?) -> Unit,
    ) {
        this.front = front
        producer.setSize(renderer.previewWidth, renderer.previewHeight)
        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() = renderer.setPreviewSurface(producer.surface)

                override fun onSurfaceCleanup() = renderer.setPreviewSurface(null)
            },
        )
        renderer.setPreviewSurface(producer.surface)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED

        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                cameraProvider = future.get()
                bindCamera()
                callback(null)
            } catch (e: Exception) {
                callback(e)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Works while recording; in dual mode it swaps the two cameras. */
    fun switchCamera() {
        front = !front
        if (dual) {
            camera = dualCameras[front]
            renderer.setLayout(true, slotOf(front))
        } else {
            bindCamera()
        }
    }

    /** Binds one or both cameras; on failure goes back to one and reports it. Not while recording. */
    fun setDual(
        enabled: Boolean,
        callback: (Exception?) -> Unit,
    ) {
        if (enabled == dual) return callback(null)
        dual = enabled
        try {
            bindCamera()
            callback(null)
        } catch (e: Exception) {
            Log.w(TAG, "Dual camera failed", e)
            dual = false
            bindCamera()
            callback(e)
        }
    }

    /** Fractions of the frame, top-left origin. */
    fun setPictureInPicture(
        left: Float,
        top: Float,
        width: Float,
        height: Float,
    ) = renderer.setPictureInPicture(left, top, width, height)

    /** [fraction] 0..1 across the camera's zoom range. */
    fun setZoom(fraction: Float) {
        camera?.cameraControl?.setLinearZoom(fraction.coerceIn(0f, 1f))
    }

    fun setBackground(background: Background?) {
        segmentationEnabled = background != null
        renderer.setBackground(background)
    }

    fun startSegment(callback: (kotlin.Result<Unit>) -> Unit) = renderer.startRecording(callback)

    fun stopSegment(callback: (kotlin.Result<RecordedSegment>) -> Unit) = renderer.stopRecording(callback)

    fun release() {
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        cameraProvider?.unbindAll()
        analysisExecutor.execute {
            segmenter?.close()
            segmenter = null
        }
        analysisExecutor.shutdown()
        renderer.release()
        producer.release()
    }

    private fun bindCamera() {
        val provider = cameraProvider ?: return
        if (dual) return bindBothCameras(provider)
        dualCameras = emptyMap()
        renderer.setLayout(false, 0)
        val preview =
            Preview
                .Builder()
                .setResolutionSelector(
                    ResolutionSelector
                        .Builder()
                        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(resolution.height, resolution.width),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                            ),
                        ).build(),
                ).build()
        val mirror = front
        preview.setSurfaceProvider(ContextCompat.getMainExecutor(context)) { request ->
            renderer.provideCameraSurface(request, mirror)
        }

        val analysis =
            ImageAnalysis
                .Builder()
                .setResolutionSelector(
                    ResolutionSelector
                        .Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                ANALYSIS_SIZE,
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            ),
                        ).build(),
                ).setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
        analysis.setAnalyzer(analysisExecutor) { analyze(it, mirror) }

        val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        provider.unbindAll()
        camera = provider.bindToLifecycle(this, selector, preview, analysis)
    }

    /**
     * Back camera into slot 0, front into slot 1. Segmentation streams are
     * added when the device allows them with two cameras; otherwise only the
     * previews run (and backgrounds don't apply).
     */
    private fun bindBothCameras(provider: ProcessCameraProvider) {
        val pair =
            provider.availableConcurrentCameraInfos.firstOrNull { infos ->
                infos.any { it.lensFacing == CameraSelector.LENS_FACING_FRONT } &&
                    infos.any { it.lensFacing == CameraSelector.LENS_FACING_BACK }
            } ?: throw IllegalStateException(
                "No front + back concurrent cameras in " +
                    provider.availableConcurrentCameraInfos.map { infos -> infos.map { it.lensFacing } },
            )

        fun config(
            lensFront: Boolean,
            withAnalysis: Boolean,
        ): ConcurrentCamera.SingleCameraConfig {
            val facing = if (lensFront) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
            val selector = pair.first { it.lensFacing == facing }.cameraSelector
            val preview =
                Preview
                    .Builder()
                    .setResolutionSelector(
                        ResolutionSelector
                            .Builder()
                            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    DUAL_PREVIEW_SIZE,
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                ),
                            ).build(),
                    ).build()
            preview.setSurfaceProvider(ContextCompat.getMainExecutor(context)) { request ->
                renderer.provideCameraSurface(request, lensFront, slotOf(lensFront))
            }
            val group = UseCaseGroup.Builder().addUseCase(preview)
            if (withAnalysis) {
                val analysis =
                    ImageAnalysis
                        .Builder()
                        .setResolutionSelector(
                            ResolutionSelector
                                .Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        ANALYSIS_SIZE,
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                    ),
                                ).build(),
                        ).setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                // Only the camera that fills the frame is segmented.
                analysis.setAnalyzer(analysisExecutor) { image ->
                    if (lensFront == front) analyze(image, lensFront) else image.close()
                }
                group.addUseCase(analysis)
            }
            return ConcurrentCamera.SingleCameraConfig(selector, group.build(), this)
        }

        renderer.setLayout(true, slotOf(front))
        val bound =
            listOf(true, false).firstNotNullOfOrNull { withAnalysis ->
                provider.unbindAll()
                try {
                    provider.bindToLifecycle(listOf(config(false, withAnalysis), config(true, withAnalysis)))
                } catch (e: Exception) {
                    Log.w(TAG, "Concurrent cameras (analysis=$withAnalysis) failed", e)
                    null
                }
            } ?: throw IllegalStateException("Cannot bind both cameras")
        // Same order as the configs: back, then front.
        dualCameras = mapOf(false to bound.cameras[0], true to bound.cameras[1])
        camera = dualCameras[front]
    }

    private fun analyze(
        image: ImageProxy,
        mirror: Boolean,
    ) = image.use {
            if (!segmentationEnabled) return@use
            try {
                val bitmap = copyToBitmap(it)
                val mask = segment(bitmap, it.imageInfo.rotationDegrees, mirror) ?: return@use
                renderer.submitMask(mask)
            } catch (e: Exception) {
                Log.w(TAG, "Analysis failed", e)
            }
        }

    /** Copies the RGBA frame into a reused bitmap, in sensor orientation. */
    private fun copyToBitmap(image: ImageProxy): Bitmap {
        val plane = image.planes[0]
        if (plane.pixelStride != 4 || plane.rowStride != image.width * 4) {
            return image.toBitmap()
        }
        val bitmap =
            analysisBitmap?.takeIf { it.width == image.width && it.height == image.height }
                ?: Bitmap
                    .createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
                    .also { analysisBitmap = it }
        plane.buffer.rewind()
        bitmap.copyPixelsFromBuffer(plane.buffer)
        return bitmap
    }

    private fun segment(
        frame: Bitmap,
        rotationDegrees: Int,
        mirror: Boolean,
    ): Mask? {
        if (segmenterUnavailable) return null
        val segmenter =
            segmenter ?: try {
                PersonSegmenter(context).also { segmenter = it }
            } catch (e: Exception) {
                // Keep the camera running without background replacement.
                Log.e(TAG, "Segmentation unavailable", e)
                segmenterUnavailable = true
                return null
            }
        return segmenter.segment(frame, rotationDegrees, mirror)
    }

    companion object {
        private const val TAG = "bg_camera"

        // The model works at 256 px; a small stream keeps segmentation cheap.
        private val ANALYSIS_SIZE = Size(640, 480)

        // Concurrent cameras are limited to about 1080p per stream.
        private val DUAL_PREVIEW_SIZE = Size(1920, 1080)

        private fun slotOf(front: Boolean) = if (front) 1 else 0

        /**
         * Whether the device can stream a front and a back camera at once. The
         * system feature alone isn't enough (the emulator declares it without
         * any usable pair), so the camera service is asked for one.
         */
        fun dualSupported(context: Context): Boolean {
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return false
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)) return false
            val manager = context.getSystemService(CameraManager::class.java) ?: return false
            return runCatching {
                manager.concurrentCameraIds.any { ids ->
                    val facings = ids.map { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) }
                    CameraCharacteristics.LENS_FACING_FRONT in facings && CameraCharacteristics.LENS_FACING_BACK in facings
                }
            }.getOrDefault(false)
        }
    }
}
