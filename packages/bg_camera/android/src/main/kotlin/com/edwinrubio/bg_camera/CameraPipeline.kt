package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/** Person mask, one byte per pixel (255 = person), same orientation as the camera frame. */
class Mask(val bytes: ByteBuffer, val width: Int, val height: Int)

/**
 * Camera frames → (MediaPipe segmentation) → [GlRenderer], which composites them
 * over the background into the Flutter texture and, while recording, the encoder.
 *
 * Public methods are called on the main thread.
 */
class CameraPipeline(
    private val context: Context,
    textures: TextureRegistry,
) : LifecycleOwner {
    companion object {
        const val OUTPUT_WIDTH = 720
        const val OUTPUT_HEIGHT = 1280
        private const val MODEL_ASSET = "selfie_segmenter.tflite"
    }

    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private val producer = textures.createSurfaceProducer()
    val textureId: Long get() = producer.id()

    private val renderer = GlRenderer(context, OUTPUT_WIDTH, OUTPUT_HEIGHT)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var front = true

    @Volatile private var segmentationEnabled = false
    private var segmenter: ImageSegmenter? = null
    private var lastSegmentationMs = 0L

    fun start(front: Boolean, callback: (Exception?) -> Unit) {
        this.front = front
        producer.setSize(OUTPUT_WIDTH, OUTPUT_HEIGHT)
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

    fun switchCamera() {
        front = !front
        bindCamera()
    }

    fun setBackground(background: Background?) {
        segmentationEnabled = background != null
        renderer.setBackground(background)
    }

    fun startSegment() = renderer.startRecording()

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
        val analysis =
            ImageAnalysis
                .Builder()
                .setResolutionSelector(
                    ResolutionSelector
                        .Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(OUTPUT_HEIGHT, OUTPUT_WIDTH),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            ),
                        ).build(),
                ).setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
        analysis.setAnalyzer(analysisExecutor, ::analyze)

        val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        provider.unbindAll()
        provider.bindToLifecycle(this, selector, analysis)
    }

    private fun analyze(image: ImageProxy) {
        val frame =
            image.use {
                upright(it.toBitmap(), it.imageInfo.rotationDegrees, mirror = front)
            }
        val mask = if (segmentationEnabled) segment(frame) else null
        renderer.submitFrame(frame, mask)
    }

    /** Rotates the sensor frame to portrait and mirrors the selfie camera. */
    private fun upright(
        source: Bitmap,
        rotationDegrees: Int,
        mirror: Boolean,
    ): Bitmap {
        if (rotationDegrees == 0 && !mirror) return source
        val matrix =
            Matrix().apply {
                postRotate(rotationDegrees.toFloat())
                if (mirror) postScale(-1f, 1f)
            }
        val rotated = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, false)
        source.recycle()
        return rotated
    }

    private fun segment(frame: Bitmap): Mask? {
        val segmenter = segmenter ?: createSegmenter().also { segmenter = it }
        // VIDEO mode requires strictly increasing timestamps.
        val timestampMs = maxOf(SystemClock.uptimeMillis(), lastSegmentationMs + 1)
        lastSegmentationMs = timestampMs
        val result = segmenter.segmentForVideo(BitmapImageBuilder(frame).build(), timestampMs)
        // The selfie model's last confidence mask is "person".
        val confidence = result.confidenceMasks().orElse(null)?.lastOrNull() ?: return null
        val floats = ByteBufferExtractor.extract(confidence).order(ByteOrder.nativeOrder()).asFloatBuffer()
        val bytes = ByteBuffer.allocateDirect(confidence.width * confidence.height)
        while (floats.hasRemaining()) {
            bytes.put((floats.get().coerceIn(0f, 1f) * 255f).roundToInt().toByte())
        }
        bytes.flip()
        return Mask(bytes, confidence.width, confidence.height)
    }

    private fun createSegmenter(): ImageSegmenter =
        ImageSegmenter.createFromOptions(
            context,
            ImageSegmenter.ImageSegmenterOptions
                .builder()
                .setBaseOptions(BaseOptions.builder().setModelAssetPath(MODEL_ASSET).build())
                .setRunningMode(RunningMode.VIDEO)
                .setOutputCategoryMask(false)
                .setOutputConfidenceMasks(true)
                .build(),
        )
}
