package com.edwinrubio.bg_camera

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.util.UUID

/** Concatenates recorded segments, in order, into one .mp4 with Media3 Transformer. */
object SegmentMerger {
    /** [callback] runs on the main thread. */
    fun merge(
        context: Context,
        paths: List<String>,
        callback: (kotlin.Result<String>) -> Unit,
    ) {
        if (paths.isEmpty()) {
            callback(kotlin.Result.failure(IllegalArgumentException("There are no segments to merge")))
            return
        }
        val output = File(context.cacheDir, "socialmaker_${UUID.randomUUID()}.mp4")
        val items = paths.map { EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(it)))).build() }
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(items).build()).build()

        // Transformer must be created and driven from a Looper thread.
        Handler(Looper.getMainLooper()).post {
            Transformer
                .Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(
                    object : Transformer.Listener {
                        override fun onCompleted(
                            composition: Composition,
                            exportResult: ExportResult,
                        ) = callback(kotlin.Result.success(output.path))

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            output.delete()
                            callback(kotlin.Result.failure(exportException))
                        }
                    },
                ).build()
                .start(composition, output.path)
        }
    }
}
