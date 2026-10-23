package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
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
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Person mask, one byte per pixel (255 = person), in upright orientation. */
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
        private const val TAG = "bg_camera"
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
    private var segmenter: PersonSegmenter? = null
    private var segmenterUnavailable = false
    // Two bitmaps used alternately: some GPU drivers (the emulator's among them)
    // read an uploaded bitmap after the upload call returns, so overwriting the
    // same one for the next frame tears the image.
    private val frameBitmaps = arrayOfNulls<Bitmap>(2)
    private var frameIndex = 0

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

    private var statsStart = 0L
    private var statsFrames = 0
    private var statsDropped = 0
    private var statsCopyNs = 0L
    private var statsSegmentNs = 0L

    private fun analyze(image: ImageProxy) =
        image.use {
            logStats()
            statsFrames++
            // Skip the frame while the renderer still draws the previous one: the
            // bitmaps below are reused and must not change under it.
            if (!renderer.tryAcquireFrame()) {
                statsDropped++
                return@use
            }
            try {
                val t0 = System.nanoTime()
                val bitmap = copyToBitmap(it)
                val t1 = System.nanoTime()
                val rotation = it.imageInfo.rotationDegrees
                val mask = if (segmentationEnabled) segment(bitmap, rotation, front) else null
                statsCopyNs += t1 - t0
                statsSegmentNs += System.nanoTime() - t1
                renderer.submitFrame(CameraFrame(bitmap, rotation, front), mask)
            } catch (e: Exception) {
                renderer.cancelFrame()
                Log.w(TAG, "Analysis failed", e)
            }
        }

    private fun logStats() {
        val now = System.nanoTime()
        if (now - statsStart < 2_000_000_000L) return
        if (statsStart != 0L && statsFrames > 0) {
            val drawn = (statsFrames - statsDropped).coerceAtLeast(1)
            Log.d(
                TAG,
                "camera fps ${statsFrames * 1_000_000_000L / (now - statsStart)}, dropped $statsDropped, " +
                    "copy ${statsCopyNs / drawn / 1000} us, segment ${statsSegmentNs / drawn / 1000} us",
            )
        }
        statsStart = now
        statsFrames = 0
        statsDropped = 0
        statsCopyNs = 0
        statsSegmentNs = 0
    }

    /** Copies the RGBA frame into a reused bitmap, in sensor orientation. */
    private fun copyToBitmap(image: ImageProxy): Bitmap {
        val plane = image.planes[0]
        frameIndex = 1 - frameIndex
        if (plane.pixelStride != 4 || plane.rowStride != image.width * 4) {
            return image.toBitmap().also { frameBitmaps[frameIndex] = it }
        }
        val bitmap =
            frameBitmaps[frameIndex]?.takeIf { it.width == image.width && it.height == image.height }
                ?: Bitmap
                    .createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
                    .also { frameBitmaps[frameIndex] = it }
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
}
