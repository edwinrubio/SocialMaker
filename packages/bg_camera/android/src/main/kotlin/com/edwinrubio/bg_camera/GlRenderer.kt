package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.core.SurfaceRequest
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/**
 * Owns the GL thread. The camera streams into an external texture; each new
 * frame is composited over the background with the latest person mask and drawn
 * into the Flutter preview surface and, while recording, the encoder surface.
 */
class GlRenderer(
    private val context: Context,
    private val resolution: OutputResolution,
) {
    private val width = resolution.width
    private val height = resolution.height

    // The on-screen preview never needs more than 1080p, even when recording 4K.
    private val previewScale = minOf(1f, MAX_PREVIEW_HEIGHT.toFloat() / height)
    val previewWidth = (width * previewScale).roundToInt()
    val previewHeight = (height * previewScale).roundToInt()

    private val thread = HandlerThread("bg_camera.gl").apply { start() }
    private val handler = Handler(thread.looper)
    private val glExecutor = Executor { handler.post(it) }
    private val released = AtomicBoolean(false)

    private lateinit var egl: EglCore
    private lateinit var programs: Programs
    private val quad: FloatBuffer =
        ByteBuffer
            .allocateDirect(QUAD.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(QUAD)
            .apply { position(0) }

    private var cameraTexture = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null
    private var cameraBufferSize = Size(width, height)
    private var cameraRotation = 0
    private var cameraMirror = false
    private val surfaceTextureMatrix = FloatArray(16)
    private val uprightMatrix = FloatArray(16)
    private val scratchMatrix = FloatArray(16)
    private val cameraMatrix = FloatArray(16)

    private var maskTexture = 0
    private val maskLock = Any()
    private var pendingMask: ByteBuffer? = null
    private var pendingMaskSize = 0 to 0
    private var pendingMaskDirty = false
    private var hasMask = false

    private var background: Background? = null
    private var backgroundTexture = 0
    private var backgroundImageSize = 0 to 0
    private var videoBackground: VideoBackground? = null
    private val videoTransform = FloatArray(16)
    private val backgroundMatrix = FloatArray(16)
    private var blurTargets: Array<RenderTarget>? = null

    private var previewSurface: EGLSurface? = null
    private var recorder: SegmentRecorder? = null
    private var recorderSurface: EGLSurface? = null

    // Creating encoders takes from 0.5 s to seconds, so the next recorder is
    // prepared ahead of time and pressing record only has to start it.
    private val prepareExecutor = Executors.newSingleThreadExecutor()
    private var preparedRecorder: Future<SegmentRecorder>? = null

    init {
        runOnGl {
            egl = EglCore()
            programs = Programs()
            cameraTexture = createTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
            maskTexture = createTexture(GLES20.GL_TEXTURE_2D)
            prepareNextRecorder()
        }
    }

    /** Blocks until the GL thread stops using the previous surface. */
    fun setPreviewSurface(surface: Surface?) =
        runOnGl {
            previewSurface?.let { egl.releaseSurface(it) }
            previewSurface = surface?.takeIf { it.isValid }?.let { egl.createWindowSurface(it) }
        }

    /** Hands CameraX a surface backed by the camera texture. Called for every (re)bind. */
    fun provideCameraSurface(
        request: SurfaceRequest,
        mirror: Boolean,
    ) = handler.post {
        if (released.get()) {
            request.willNotProvideSurface()
            return@post
        }
        val surfaceTexture =
            cameraSurfaceTexture ?: SurfaceTexture(cameraTexture).also {
                it.setOnFrameAvailableListener({ onCameraFrame() }, handler)
                cameraSurfaceTexture = it
            }
        surfaceTexture.setDefaultBufferSize(request.resolution.width, request.resolution.height)
        cameraBufferSize = request.resolution
        cameraMirror = mirror
        request.setTransformationInfoListener(glExecutor) { info ->
            // With a camera transform the SurfaceTexture matrix already rotates
            // the buffer upright; only rotate ourselves when it doesn't.
            cameraRotation = if (info.hasCameraTransform()) 0 else info.rotationDegrees
        }
        val surface = Surface(surfaceTexture)
        request.provideSurface(surface, glExecutor) { surface.release() }
    }

    /** Called on the analysis thread; the mask is copied, so the caller may reuse it. */
    fun submitMask(mask: Mask) =
        synchronized(maskLock) {
            val size = mask.width * mask.height
            val buffer =
                pendingMask?.takeIf { it.capacity() == size }
                    ?: ByteBuffer.allocateDirect(size).also { pendingMask = it }
            buffer.clear()
            mask.bytes.rewind()
            buffer.put(mask.bytes)
            buffer.flip()
            pendingMaskSize = mask.width to mask.height
            pendingMaskDirty = true
        }

    fun setBackground(background: Background?) =
        handler.post {
            // Only the blur strength changed: the current mask still applies.
            val sameMask = this.background is Background.Blur && background is Background.Blur
            releaseBackground()
            this.background = background
            if (!sameMask) hasMask = false
            when (background) {
                is Background.Image -> {
                    backgroundTexture = createTexture(GLES20.GL_TEXTURE_2D)
                    GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, background.bitmap, 0)
                    backgroundImageSize = background.bitmap.width to background.bitmap.height
                    background.bitmap.recycle()
                }
                is Background.Video -> {
                    backgroundTexture = createTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
                    videoBackground = VideoBackground(context, background.uri, backgroundTexture)
                }
                is Background.Blur, null -> Unit
            }
        }

    /** [callback] runs on the GL thread once the encoder is ready, or with the failure. */
    fun startRecording(callback: (kotlin.Result<Unit>) -> Unit) =
        handler.post {
            callback(
                runCatching {
                    check(recorder == null) { "A segment is already being recorded" }
                    val prepared =
                        runCatching { preparedRecorder?.get() }
                            .onFailure { Log.w(TAG, "Prepared recorder failed, creating a new one", it) }
                            .getOrNull()
                    val newRecorder = prepared ?: createRecorder()
                    preparedRecorder = null
                    recorderSurface = egl.createWindowSurface(newRecorder.inputSurface)
                    newRecorder.begin()
                    recorder = newRecorder
                    prepareNextRecorder()
                },
            )
        }

    fun stopRecording(callback: (kotlin.Result<RecordedSegment>) -> Unit) =
        handler.post {
            val current = recorder
            if (current == null) {
                callback(kotlin.Result.failure(IllegalStateException("No segment is being recorded")))
                return@post
            }
            recorderSurface?.let { egl.releaseSurface(it) }
            recorderSurface = null
            recorder = null
            // Draining the encoders takes a moment; keep the preview running meanwhile.
            Thread({ callback(runCatching { current.finish() }) }, "bg_camera.finish").start()
        }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        runOnGl {
            recorderSurface?.let { egl.releaseSurface(it) }
            recorder?.cancel()
            preparedRecorder?.let { prepared -> runCatching { prepared.get().cancel() } }
            prepareExecutor.shutdown()
            previewSurface?.let { egl.releaseSurface(it) }
            cameraSurfaceTexture?.release()
            releaseBackground()
            egl.release()
        }
        thread.quitSafely()
    }

    private fun onCameraFrame() {
        if (released.get()) return
        val surfaceTexture = cameraSurfaceTexture ?: return
        try {
            egl.makePbufferCurrent()
            surfaceTexture.updateTexImage()
            surfaceTexture.getTransformMatrix(surfaceTextureMatrix)
            val start = System.nanoTime()
            draw(start)
            drawNanos += System.nanoTime() - start
        } catch (e: Exception) {
            // A surface can vanish mid-frame (app backgrounded); skip the frame.
            Log.w(TAG, "Frame dropped", e)
            egl.makePbufferCurrent()
        }
    }

    private fun draw(timestampNanos: Long) {
        // Buffers are landscape; with the camera transform (rotation 0 here) the
        // matrix turns them portrait, so the aspect follows the output's.
        val sideways = cameraRotation % 180 != 0 || cameraBufferSize.width > cameraBufferSize.height
        val cameraScale =
            if (sideways) {
                fillScale(cameraBufferSize.height, cameraBufferSize.width)
            } else {
                fillScale(cameraBufferSize.width, cameraBufferSize.height)
            }
        // Upright coords → sensor coords → SurfaceTexture coords (bottom-left origin).
        uprightToSensor(cameraRotation, cameraMirror, uprightMatrix)
        Matrix.multiplyMM(scratchMatrix, 0, surfaceTextureMatrix, 0, FLIP_Y, 0)
        Matrix.multiplyMM(cameraMatrix, 0, scratchMatrix, 0, uprightMatrix, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexture)
        val program = selectProgram(cameraScale)

        previewSurface?.let { surface ->
            egl.makeCurrent(surface)
            drawQuad(program, cameraScale, previewWidth, previewHeight)
            // Finish on this thread so Flutter's consumer never waits on the
            // buffer's GPU fence on the platform thread (seconds on some GPUs).
            GLES20.glFinish()
            egl.swapBuffers(surface)
        }
        val recorder = recorder
        val recorderSurface = recorderSurface
        if (recorder != null && recorderSurface != null) {
            egl.makeCurrent(recorderSurface)
            drawQuad(program, cameraScale, width, height)
            egl.setPresentationTime(recorderSurface, recorder.presentationNanos(timestampNanos))
            egl.swapBuffers(recorderSurface)
            recorder.onFrameRendered()
        }
        egl.makePbufferCurrent()
        logFrameRate(timestampNanos)
    }

    /** Uploads the mask and background for this frame and picks the matching shader. */
    private fun selectProgram(cameraScale: FloatArray): Programs.Program {
        val background = background ?: return programs.passthrough
        uploadPendingMask()
        if (!hasMask) return programs.passthrough

        when (background) {
            is Background.Video -> {
                val video = videoBackground ?: return programs.passthrough
                GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, backgroundTexture)
                if (!video.updateFrame(videoTransform)) return programs.passthrough
                // Texture coordinates are top-left based; the SurfaceTexture matrix expects bottom-left.
                Matrix.multiplyMM(backgroundMatrix, 0, videoTransform, 0, FLIP_Y, 0)
                programs.compositeVideo.backgroundScale = fillScale(video.width, video.height)
                return programs.compositeVideo
            }
            is Background.Image -> {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backgroundTexture)
                Matrix.setIdentityM(backgroundMatrix, 0)
                programs.compositeImage.backgroundScale =
                    fillScale(backgroundImageSize.first, backgroundImageSize.second)
                return programs.compositeImage
            }
            is Background.Blur -> {
                val blurred = renderBlurredCamera(cameraScale, background.strength)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, blurred)
                // The blurred frame is already upright and covers the output.
                System.arraycopy(FLIP_Y, 0, backgroundMatrix, 0, 16)
                programs.compositeImage.backgroundScale = ONE
                return programs.compositeImage
            }
        }
    }

    private fun uploadPendingMask() =
        synchronized(maskLock) {
            val mask = pendingMask
            if (!pendingMaskDirty || mask == null) return@synchronized
            GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexture)
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, pendingMaskSize.first, pendingMaskSize.second, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, mask,
            )
            pendingMaskDirty = false
            hasMask = true
        }

    /**
     * Draws the upright camera frame small and blurs it in each direction;
     * returns the texture holding the result.
     */
    private fun renderBlurredCamera(
        cameraScale: FloatArray,
        strength: Float,
    ): Int {
        val (a, b) = blurTargets ?: arrayOf(RenderTarget(BLUR_WIDTH, BLUR_HEIGHT), RenderTarget(BLUR_WIDTH, BLUR_HEIGHT))
            .also { blurTargets = it }

        a.bind()
        programs.passthrough.use(quad, cameraScale, cameraMatrix, IDENTITY)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        val blur = programs.blur
        // A second pass only for strong blur: wide spacing alone would band.
        val spread = BLUR_MIN_SPREAD + strength * BLUR_SPREAD_RANGE
        repeat(if (strength > 0.6f) 2 else 1) {
            for ((source, target, step) in listOf(
                Triple(a, b, floatArrayOf(spread / BLUR_WIDTH, 0f)),
                Triple(b, a, floatArrayOf(0f, spread / BLUR_HEIGHT)),
            )) {
                target.bind()
                GLES20.glActiveTexture(GLES20.GL_TEXTURE3)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, source.texture)
                blur.texelStep = step
                blur.use(quad, ONE, IDENTITY, IDENTITY)
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            }
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexture)
        return a.texture
    }

    private fun drawQuad(
        program: Programs.Program,
        cameraScale: FloatArray,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        GLES20.glViewport(0, 0, viewportWidth, viewportHeight)
        program.use(quad, cameraScale, cameraMatrix, backgroundMatrix)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    /** UV scale that makes a `w`×`h` source cover the output (aspect fill). */
    private fun fillScale(
        w: Int,
        h: Int,
    ): FloatArray {
        val source = w.toFloat() / h
        val target = width.toFloat() / height
        return if (source > target) floatArrayOf(target / source, 1f) else floatArrayOf(1f, source / target)
    }

    private fun createRecorder() =
        SegmentRecorder(width, height, resolution.bitRate, Recordings.newFile(context, "segment"))

    private fun prepareNextRecorder() {
        preparedRecorder = prepareExecutor.submit<SegmentRecorder> { createRecorder() }
    }

    private fun releaseBackground() {
        videoBackground?.release()
        videoBackground = null
        if (backgroundTexture != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(backgroundTexture), 0)
            backgroundTexture = 0
        }
        blurTargets?.forEach { it.release() }
        blurTargets = null
    }

    private var frameCount = 0
    private var drawNanos = 0L
    private var frameWindowStart = 0L

    private fun logFrameRate(nowNanos: Long) {
        frameCount++
        val elapsed = nowNanos - frameWindowStart
        if (elapsed >= 2_000_000_000L) {
            if (frameWindowStart != 0L) {
                Log.d(TAG, "preview fps: ${frameCount * 1_000_000_000L / elapsed}, draw ${drawNanos / frameCount / 1000} us")
            }
            frameCount = 0
            drawNanos = 0
            frameWindowStart = nowNanos
        }
    }

    private fun runOnGl(block: () -> Unit) {
        if (Thread.currentThread() == thread) {
            block()
            return
        }
        var error: Throwable? = null
        val done = CountDownLatch(1)
        handler.post {
            try {
                block()
            } catch (e: Throwable) {
                error = e
            } finally {
                done.countDown()
            }
        }
        done.await()
        error?.let { throw it }
    }

    /** Offscreen color texture + framebuffer. */
    private class RenderTarget(
        private val width: Int,
        private val height: Int,
    ) {
        val texture = createTexture(GLES20.GL_TEXTURE_2D)
        private val framebuffer: Int

        init {
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
            )
            val ids = IntArray(1)
            GLES20.glGenFramebuffers(1, ids, 0)
            framebuffer = ids[0]
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
            GLES20.glFramebufferTexture2D(
                GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, texture, 0,
            )
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        }

        fun bind() {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
            GLES20.glViewport(0, 0, width, height)
        }

        fun release() {
            GLES20.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
            GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
        }
    }

    private companion object {
        const val TAG = "bg_camera"
        const val MAX_PREVIEW_HEIGHT = 1920

        // The blurred background is drawn tiny; its size doesn't depend on the output.
        const val BLUR_WIDTH = 180
        const val BLUR_HEIGHT = 320
        // Sample spacing in texels (wider blurs more in one pass): 0.5 at
        // strength 0, 2 at the default 0.5, 3.5 at 1.
        const val BLUR_MIN_SPREAD = 0.5f
        const val BLUR_SPREAD_RANGE = 3f

        val ONE = floatArrayOf(1f, 1f)
        val IDENTITY = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

        fun createTexture(target: Int): Int {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            GLES20.glBindTexture(target, ids[0])
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            return ids[0]
        }

        /**
         * Fills [out] with the column-major affine map from upright texture
         * coordinates (u, v) to sensor coordinates (x, y): CameraX rotates the
         * sensor image clockwise by [rotationDegrees] and the selfie view is
         * mirrored afterwards, so this undoes the mirror and then the rotation.
         */
        fun uprightToSensor(
            rotationDegrees: Int,
            mirror: Boolean,
            out: FloatArray,
        ) {
            // u' = mirror ? 1 - u : u  ==  mu * u + mc
            val mu = if (mirror) -1f else 1f
            val mc = if (mirror) 1f else 0f
            // x = a*u + b*v + c, y = d*u + e*v + f
            val (a, b, c, d, e, f) =
                when (((rotationDegrees % 360) + 360) % 360) {
                    90 -> Affine(0f, 1f, 0f, -mu, 0f, 1f - mc)
                    180 -> Affine(-mu, 0f, 1f - mc, 0f, -1f, 1f)
                    270 -> Affine(0f, -1f, 1f, mu, 0f, mc)
                    else -> Affine(mu, 0f, mc, 0f, 1f, 0f)
                }
            out.fill(0f)
            out[0] = a
            out[1] = d
            out[4] = b
            out[5] = e
            out[10] = 1f
            out[12] = c
            out[13] = f
            out[15] = 1f
        }

        data class Affine(
            val a: Float,
            val b: Float,
            val c: Float,
            val d: Float,
            val e: Float,
            val f: Float,
        )

        // x, y, u, v — triangle strip covering the viewport; uv origin is the image's top-left.
        val QUAD =
            floatArrayOf(
                -1f, -1f, 0f, 1f,
                1f, -1f, 1f, 1f,
                -1f, 1f, 0f, 0f,
                1f, 1f, 1f, 0f,
            )
        val FLIP_Y =
            floatArrayOf(
                1f, 0f, 0f, 0f,
                0f, -1f, 0f, 0f,
                0f, 0f, 1f, 0f,
                0f, 1f, 0f, 1f,
            )
    }
}
