package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import org.tensorflow.lite.Interpreter
import java.io.Closeable
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.roundToInt

/**
 * Runs the MediaPipe selfie segmentation model directly with LiteRT on the CPU.
 * (MediaPipe Tasks post-processes with OpenGL, which fails on some GPUs and on
 * emulators.)
 *
 * Not thread-safe: use from the analysis thread only.
 */
class PersonSegmenter(
    context: Context,
) : Closeable {
    private val interpreter: Interpreter
    private val inputWidth: Int
    private val inputHeight: Int
    private val outputChannels: Int
    private val input: ByteBuffer
    private val output: ByteBuffer
    private val pixels: IntArray
    private val modelBitmap: Bitmap
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    // Reused across frames; the renderer is done with it before the next frame.
    private val maskBytes: ByteBuffer

    init {
        val model =
            context.assets.openFd(MODEL_ASSET).use { fd ->
                FileInputStream(fd.fileDescriptor).channel.use {
                    it.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
                }
            }
        interpreter = Interpreter(model, Interpreter.Options().setNumThreads(2))
        // Input [1, height, width, 3] in 0..1; output [1, height, width, channels]
        // whose last channel is the person confidence.
        val inputShape = interpreter.getInputTensor(0).shape()
        inputHeight = inputShape[1]
        inputWidth = inputShape[2]
        outputChannels = interpreter.getOutputTensor(0).shape().last()

        input = ByteBuffer.allocateDirect(inputWidth * inputHeight * 3 * 4).order(ByteOrder.nativeOrder())
        output =
            ByteBuffer.allocateDirect(inputWidth * inputHeight * outputChannels * 4).order(ByteOrder.nativeOrder())
        pixels = IntArray(inputWidth * inputHeight)
        modelBitmap = Bitmap.createBitmap(inputWidth, inputHeight, Bitmap.Config.ARGB_8888)
        maskBytes = ByteBuffer.allocateDirect(inputWidth * inputHeight)
    }

    /**
     * Segments [frame] (sensor orientation) and returns the person mask in
     * upright orientation, stretched over the whole frame.
     */
    fun segment(
        frame: Bitmap,
        rotationDegrees: Int,
        mirror: Boolean,
    ): Mask {
        val sideways = rotationDegrees % 180 != 0
        val uprightWidth = if (sideways) frame.height else frame.width
        val uprightHeight = if (sideways) frame.width else frame.height
        val matrix =
            Matrix().apply {
                postTranslate(-frame.width / 2f, -frame.height / 2f)
                postRotate(rotationDegrees.toFloat())
                if (mirror) postScale(-1f, 1f)
                postScale(inputWidth.toFloat() / uprightWidth, inputHeight.toFloat() / uprightHeight)
                postTranslate(inputWidth / 2f, inputHeight / 2f)
            }
        Canvas(modelBitmap).drawBitmap(frame, matrix, paint)

        modelBitmap.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)
        input.rewind()
        for (pixel in pixels) {
            input.putFloat((pixel shr 16 and 0xFF) / 255f)
            input.putFloat((pixel shr 8 and 0xFF) / 255f)
            input.putFloat((pixel and 0xFF) / 255f)
        }
        input.rewind()
        output.rewind()
        interpreter.run(input, output)

        output.rewind()
        val confidence = output.asFloatBuffer()
        maskBytes.clear()
        for (i in 0 until inputWidth * inputHeight) {
            val person = confidence.get(i * outputChannels + outputChannels - 1)
            maskBytes.put((person.coerceIn(0f, 1f) * 255f).roundToInt().toByte())
        }
        maskBytes.flip()
        return Mask(maskBytes, inputWidth, inputHeight)
    }

    override fun close() = interpreter.close()

    private companion object {
        const val MODEL_ASSET = "selfie_segmenter.tflite"
    }
}
