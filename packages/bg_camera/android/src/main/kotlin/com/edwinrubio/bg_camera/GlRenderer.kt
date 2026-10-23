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
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean

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
    private var maskTexture = 0
    private var backgroundTexture = 0
    private var backgroundImageSize = 0 to 0
    private var videoBackground: VideoBackground? = null
    private val videoTransform = FloatArray(16)
    private val backgroundMatrix = FloatArray(16)

    private var previewSurface: EGLSurface? = null
    private var recorder: SegmentRecorder? = null
    private var recorderSurface: EGLSurface? = null

    init {
        runOnGl {
            egl = EglCore()
            programs = Programs()
            cameraTexture = createTexture(GLES20.GL_TEXTURE_2D)
            maskTexture = createTexture(GLES20.GL_TEXTURE_2D)
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

    /** Takes ownership of [frame]. Drops it if the previous frame is still being drawn. */
    fun submitFrame(
        frame: Bitmap,
        mask: Mask?,
    ) {
        if (released.get() || !framePending.compareAndSet(false, true)) {
            frame.recycle()
            return
        }
        handler.post {
            try {
                draw(frame, mask, System.nanoTime())
            } catch (e: Exception) {
                // A surface can vanish mid-frame (app backgrounded); skip the frame.
                Log.w(TAG, "Frame dropped", e)
                egl.makePbufferCurrent()
            } finally {
                frame.recycle()
                framePending.set(false)
            }
        }
    }

    fun startRecording() =
        runOnGl {
            check(recorder == null) { "A segment is already being recorded" }
            val output = File(context.cacheDir, "segment_${UUID.randomUUID()}.mp4")
            val newRecorder = SegmentRecorder(width, height, output)
            recorder = newRecorder
            recorderSurface = egl.createWindowSurface(newRecorder.inputSurface)
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
            callback(runCatching { current.finish() })
        }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        runOnGl {
            recorderSurface?.let { egl.releaseSurface(it) }
            recorder?.cancel()
            previewSurface?.let { egl.releaseSurface(it) }
            releaseBackground()
            egl.release()
        }
        thread.quitSafely()
    }

    private fun draw(
        frame: Bitmap,
        mask: Mask?,
        timestampNanos: Long,
    ) {
        if (released.get()) return
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, cameraTexture)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, frame, 0)

        val program = selectProgram(mask)
        val cameraScale = fillScale(frame.width, frame.height)

        previewSurface?.let { surface ->
            egl.makeCurrent(surface)
            drawQuad(program, cameraScale)
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
        program.use(quad, cameraScale, backgroundMatrix)
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
