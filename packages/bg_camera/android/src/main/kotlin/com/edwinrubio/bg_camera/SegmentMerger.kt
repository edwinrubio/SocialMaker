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

/** Part of a recorded segment to keep: [endUs] null means up to the end. */
data class SegmentPiece(
    val path: String,
    val startUs: Long,
    val endUs: Long?,
)

/**
 * Concatenates recorded segments, in order, into one .mp4 without re-encoding:
 * every fragment comes from the same encoder settings, so their samples can be
 * copied back to back with shifted timestamps. A trimmed start snaps back to
 * the previous video key frame, since frames before it can't be decoded.
 */
object SegmentMerger {
    /** [callback] runs on the main thread. */
    fun merge(
        context: Context,
        pieces: List<SegmentPiece>,
        callback: (kotlin.Result<String>) -> Unit,
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        Thread({
            val output = Recordings.newFile(context, "socialmaker")
            val result =
                runCatching {
                    require(pieces.isNotEmpty()) { "There are no segments to merge" }
                    concatenate(pieces, output)
                    output.path
                }.onFailure { output.delete() }
            mainHandler.post { callback(result) }
        }, "bg_camera.merge").start()
    }

    private fun concatenate(
        pieces: List<SegmentPiece>,
        output: File,
    ) {
        val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            // Output tracks come from the first fragment: one video, one audio.
            val muxerTracks = mutableMapOf<String, Int>()
            withExtractor(File(pieces.first().path)) { extractor ->
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
            for (piece in pieces) {
                withExtractor(File(piece.path)) { extractor ->
                    val trackKinds = mutableMapOf<Int, String>()
                    var durationUs = 0L
                    for (i in 0 until extractor.trackCount) {
                        val format = extractor.getTrackFormat(i)
                        val kind = kindOf(format) ?: continue
                        if (kind !in muxerTracks || kind in trackKinds.values) continue
                        trackKinds[i] = kind
                        if (format.containsKey(MediaFormat.KEY_DURATION)) {
                            durationUs = maxOf(durationUs, format.getLong(MediaFormat.KEY_DURATION))
                        }
                    }
                    val startUs = keyFrameAtOrBefore(extractor, trackKinds, piece.startUs)
                    val endUs = piece.endUs ?: Long.MAX_VALUE
                    trackKinds.keys.forEach(extractor::selectTrack)
                    extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    var lastSampleUs = startUs
                    while (true) {
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        val sampleUs = extractor.sampleTime
                        if (sampleUs in startUs until endUs) {
                            val kind = trackKinds.getValue(extractor.sampleTrackIndex)
                            lastSampleUs = maxOf(lastSampleUs, sampleUs)
                            info.set(0, size, offsetUs + sampleUs - startUs, sampleFlags(extractor))
                            muxer.writeSampleData(muxerTracks.getValue(kind), buffer, info)
                        }
                        extractor.advance()
                    }
                    offsetUs += minOf(maxOf(durationUs, lastSampleUs), endUs) - startUs
                }
            }
            muxer.stop()
        } finally {
            muxer.release()
        }
    }

    /** Time of the last video key frame at or before [timeUs]. */
    private fun keyFrameAtOrBefore(
        extractor: MediaExtractor,
        trackKinds: Map<Int, String>,
        timeUs: Long,
    ): Long {
        if (timeUs <= 0) return 0
        val video = trackKinds.entries.firstOrNull { it.value == VIDEO }?.key ?: return timeUs
        extractor.selectTrack(video)
        extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val keyFrameUs = extractor.sampleTime.coerceAtLeast(0)
        extractor.unselectTrack(video)
        return keyFrameUs
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
