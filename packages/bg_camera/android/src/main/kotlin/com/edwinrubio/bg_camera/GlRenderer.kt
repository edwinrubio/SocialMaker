package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.Bitmap
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

/** A camera frame in sensor orientation; [rotationDegrees] and [mirror] make it upright. */
class CameraFrame(
    val bitmap: Bitmap,
    val rotationDegrees: Int,
    val mirror: Boolean,
)

/**
 * Owns the GL thread. Draws each camera frame — composited over the background
 * when a mask is given — into the Flutter preview surface and, while recording,
 * into the [SegmentRecorder]'s encoder surface.
 */
class GlRenderer(
    private val context: Context,
    private val width: Int,
    private val height: Int,
) {
    private val thread = HandlerThread("bg_camera.gl").apply { start() }
    private val handler = Handler(thread.looper)
    private val framePending = AtomicBoolean(false)
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
    private var cameraTextureSize = 0 to 0
    private val cameraMatrix = FloatArray(16)
    private var maskTexture = 0
    private var backgroundTexture = 0
    private var backgroundImageSize = 0 to 0
    private var videoBackground: VideoBackground? = null
    private val videoTransform = FloatArray(16)
    private val backgroundMatrix = FloatArray(16)

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
            cameraTexture = createTexture(GLES20.GL_TEXTURE_2D)
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

    fun setBackground(background: Background?) =
        handler.post {
            releaseBackground()
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
                null -> Unit
            }
        }

    /**
     * Reserves the renderer for one frame; false while the previous frame is
     * still being drawn. The caller must then call [submitFrame] or [cancelFrame].
     */
    fun tryAcquireFrame() = !released.get() && framePending.compareAndSet(false, true)

    fun cancelFrame() = framePending.set(false)

    /** The frame's bitmap stays in use until the next [tryAcquireFrame] succeeds. */
    fun submitFrame(
        frame: CameraFrame,
        mask: Mask?,
    ) {
        handler.post {
            try {
                val start = System.nanoTime()
                draw(frame, mask, start)
                drawNanos += System.nanoTime() - start
            } catch (e: Exception) {
                // A surface can vanish mid-frame (app backgrounded); skip the frame.
                Log.w(TAG, "Frame dropped", e)
                egl.makePbufferCurrent()
            } finally {
                framePending.set(false)
            }
        }
    }

    /** [callback] runs on the GL thread once the encoder is ready, or with the failure. */
    fun startRecording(callback: (kotlin.Result<Unit>) -> Unit) =
        handler.post {
            callback(
                runCatching {
                    check(recorder == null) { "A segment is already being recorded" }
                    val waitStart = System.nanoTime()
                    val prepared =
                        runCatching { preparedRecorder?.get() }
                            .onFailure { Log.w(TAG, "Prepared recorder failed, creating a new one", it) }
                            .getOrNull()
                    val newRecorder = prepared ?: createRecorder()
                    Log.d(TAG, "recording started after ${(System.nanoTime() - waitStart) / 1_000_000} ms")
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
            releaseBackground()
            egl.release()
        }
        thread.quitSafely()
    }

    private fun draw(
        frame: CameraFrame,
        mask: Mask?,
        timestampNanos: Long,
    ) {
        if (released.get()) return
        val bitmap = frame.bitmap
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, cameraTexture)
        if (cameraTextureSize == bitmap.width to bitmap.height) {
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        } else {
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            cameraTextureSize = bitmap.width to bitmap.height
        }

        val program = selectProgram(mask)
        val sideways = frame.rotationDegrees % 180 != 0
        val cameraScale =
            if (sideways) fillScale(bitmap.height, bitmap.width) else fillScale(bitmap.width, bitmap.height)
        uprightToSensor(frame.rotationDegrees, frame.mirror, cameraMatrix)

        previewSurface?.let { surface ->
            egl.makeCurrent(surface)
            drawQuad(program, cameraScale)
            // Finish on this thread so Flutter's consumer never waits on the
            // buffer's GPU fence on the platform thread (seconds on some GPUs).
            GLES20.glFinish()
            egl.swapBuffers(surface)
        }
        val recorder = recorder
        val recorderSurface = recorderSurface
        if (recorder != null && recorderSurface != null) {
            egl.makeCurrent(recorderSurface)
            drawQuad(program, cameraScale)
            egl.setPresentationTime(recorderSurface, recorder.presentationNanos(timestampNanos))
            egl.swapBuffers(recorderSurface)
            recorder.onFrameRendered()
        }
        egl.makePbufferCurrent()
        logFrameRate(timestampNanos)
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

    /** Uploads the mask and background for this frame and picks the matching shader. */
    private fun selectProgram(mask: Mask?): Programs.Program {
        if (mask == null || backgroundTexture == 0) return programs.passthrough

        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexture)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, mask.width, mask.height, 0,
            GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, mask.bytes,
        )

        GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
        val video = videoBackground
        if (video != null) {
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, backgroundTexture)
            if (!video.updateFrame(videoTransform)) return programs.passthrough
            // Texture coordinates are top-left based; the SurfaceTexture matrix expects bottom-left.
            Matrix.multiplyMM(backgroundMatrix, 0, videoTransform, 0, FLIP_Y, 0)
            programs.compositeVideo.backgroundScale = fillScale(video.width, video.height)
            return programs.compositeVideo
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backgroundTexture)
        Matrix.setIdentityM(backgroundMatrix, 0)
        programs.compositeImage.backgroundScale =
            fillScale(backgroundImageSize.first, backgroundImageSize.second)
        return programs.compositeImage
    }

    private fun drawQuad(
        program: Programs.Program,
        cameraScale: FloatArray,
    ) {
        GLES20.glViewport(0, 0, width, height)
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
        SegmentRecorder(width, height, Recordings.newFile(context, "segment"))

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
    }

    private fun createTexture(target: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(target, ids[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
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

    private companion object {
        const val TAG = "bg_camera"

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
