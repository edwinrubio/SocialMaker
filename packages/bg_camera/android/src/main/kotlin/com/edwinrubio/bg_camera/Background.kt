package com.edwinrubio.bg_camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import java.io.File

/** What is drawn behind the person. */
sealed interface Background {
    class Image(
        val bitmap: Bitmap,
    ) : Background

    class Video(
        val uri: Uri,
    ) : Background

    /** The camera frame itself, blurred; [strength] from 0 (subtle) to 1 (strong). */
    class Blur(
        val strength: Float,
    ) : Background
}

/**
 * Plays a muted, looping video into an OES texture owned by the GL thread.
 * The player lives on the main thread; [updateFrame] runs on the GL thread.
 */
class VideoBackground(
    context: Context,
    uri: Uri,
    textureId: Int,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val surfaceTexture = SurfaceTexture(textureId)
    private val surface = Surface(surfaceTexture)
    private var player: ExoPlayer? = null

    @Volatile private var frameAvailable = false

    @Volatile var width = 0
        private set

    @Volatile var height = 0
        private set

    init {
        surfaceTexture.setOnFrameAvailableListener { frameAvailable = true }
        mainHandler.post {
            player =
                ExoPlayer.Builder(context).build().apply {
                    setVideoSurface(surface)
                    volume = 0f
                    repeatMode = Player.REPEAT_MODE_ALL
                    addListener(
                        object : Player.Listener {
                            override fun onVideoSizeChanged(videoSize: VideoSize) {
                                width = videoSize.width
                                height = videoSize.height
                            }
                        },
                    )
                    setMediaItem(MediaItem.fromUri(uri))
                    prepare()
                    play()
                }
        }
    }

    /** Latches the newest decoded frame; fills [transform] with its texture matrix. */
    fun updateFrame(transform: FloatArray): Boolean {
        if (frameAvailable) {
            frameAvailable = false
            surfaceTexture.updateTexImage()
        }
        surfaceTexture.getTransformMatrix(transform)
        return width > 0 && height > 0
    }

    fun release() {
        mainHandler.post {
            player?.release()
            player = null
            surface.release()
            surfaceTexture.release()
        }
    }
}

object BitmapLoader {
    /** Decodes an image downsampled to at most [maxSide] and rotated per its EXIF tag. */
    fun load(
        file: File,
        maxSide: Int,
    ): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val bitmap =
            BitmapFactory.decodeFile(
                file.path,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            ) ?: return null

        val degrees = ExifInterface(file.path).rotationDegrees
        if (degrees == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        bitmap.recycle()
        return rotated
    }
}
