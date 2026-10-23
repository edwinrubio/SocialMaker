package com.edwinrubio.bg_camera

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import java.io.File
import java.nio.ByteBuffer

/**
 * Concatenates recorded segments, in order, into one .mp4 without re-encoding:
 * every fragment comes from the same encoder settings, so their samples can be
 * copied back to back with shifted timestamps.
 */
object SegmentMerger {
    /** [callback] runs on the main thread. */
    fun merge(
        context: Context,
        paths: List<String>,
        callback: (kotlin.Result<String>) -> Unit,
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        Thread({
            val output = Recordings.newFile(context, "socialmaker")
            val result =
                runCatching {
                    require(paths.isNotEmpty()) { "There are no segments to merge" }
                    concatenate(paths.map(::File), output)
                    output.path
                }.onFailure { output.delete() }
            mainHandler.post { callback(result) }
        }, "bg_camera.merge").start()
    }

    private fun concatenate(
        inputs: List<File>,
        output: File,
    ) {
        val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            // Output tracks come from the first fragment: one video, one audio.
            val muxerTracks = mutableMapOf<String, Int>()
            withExtractor(inputs.first()) { extractor ->
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    val kind = kindOf(format) ?: continue
                    if (kind !in muxerTracks) muxerTracks[kind] = muxer.addTrack(format)
                }
            }
            check(VIDEO in muxerTracks) { "First segment has no video" }
            muxer.start()

            val buffer = ByteBuffer.allocate(BUFFER_SIZE)
            val info = MediaCodec.BufferInfo()
            var offsetUs = 0L
            for (input in inputs) {
                withExtractor(input) { extractor ->
                    val trackKinds = mutableMapOf<Int, String>()
                    var durationUs = 0L
                    for (i in 0 until extractor.trackCount) {
                        val format = extractor.getTrackFormat(i)
                        val kind = kindOf(format) ?: continue
                        if (kind !in muxerTracks || kind in trackKinds.values) continue
                        extractor.selectTrack(i)
                        trackKinds[i] = kind
                        if (format.containsKey(MediaFormat.KEY_DURATION)) {
                            durationUs = maxOf(durationUs, format.getLong(MediaFormat.KEY_DURATION))
                        }
                    }
                    var lastSampleUs = 0L
                    while (true) {
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        val kind = trackKinds.getValue(extractor.sampleTrackIndex)
                        lastSampleUs = maxOf(lastSampleUs, extractor.sampleTime)
                        info.set(0, size, offsetUs + extractor.sampleTime, sampleFlags(extractor))
                        muxer.writeSampleData(muxerTracks.getValue(kind), buffer, info)
                        extractor.advance()
                    }
                    offsetUs += maxOf(durationUs, lastSampleUs)
                }
            }
            muxer.stop()
        } finally {
            muxer.release()
        }
    }

    private fun sampleFlags(extractor: MediaExtractor) =
        if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0

    private fun kindOf(format: MediaFormat): String? {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
        return when {
            mime.startsWith("video/") -> VIDEO
            mime.startsWith("audio/") -> AUDIO
            else -> null
        }
    }

    private inline fun withExtractor(
        file: File,
        block: (MediaExtractor) -> Unit,
    ) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.path)
            block(extractor)
        } finally {
            extractor.release()
        }
    }

    private const val VIDEO = "video"
    private const val AUDIO = "audio"
    private const val BUFFER_SIZE = 4 * 1024 * 1024
}
