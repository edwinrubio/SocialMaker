package com.edwinrubio.bg_camera

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer

class RecordedSegment(
    val path: String,
    val durationMs: Long,
)

/**
 * Encodes one fragment: H.264 from [inputSurface] (fed by the GL thread) plus
 * AAC from the microphone on its own thread, muxed into an .mp4.
 *
 * [onFrameRendered] and [finish] must be called on the GL thread.
 */
@SuppressLint("MissingPermission") // RECORD_AUDIO is requested by the app before initialize.
class SegmentRecorder(
    width: Int,
    height: Int,
    private val output: File,
) {
    private val videoEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val audioRecord: AudioRecord
    private val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val startNanos = System.nanoTime()
    val inputSurface: Surface

    private val muxerLock = Any()
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxerStarted = false
    private val pendingSamples = mutableListOf<PendingSample>()
    private var firstVideoUs = -1L
    private var lastVideoUs = -1L

    @Volatile private var capturingAudio = true
    private val audioThread: Thread

    init {
        val videoFormat =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
        videoEncoder.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = videoEncoder.createInputSurface()
        videoEncoder.start()

        val audioFormat =
            MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 96_000)
            }
        audioEncoder.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        audioEncoder.start()

        val minBuffer =
            AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        audioRecord =
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuffer * 4,
            )
        audioThread = Thread(::captureAudio, "bg_camera.audio").apply { start() }
    }

    /** Presentation time for a frame, on the same clock as the audio samples. */
    fun presentationNanos(timestampNanos: Long) = timestampNanos - startNanos

    fun onFrameRendered() = drain(videoEncoder, isVideo = true, endOfStream = false)

    fun finish(): RecordedSegment {
        try {
            capturingAudio = false
            videoEncoder.signalEndOfInputStream()
            drain(videoEncoder, isVideo = true, endOfStream = true)
            audioThread.join()
            synchronized(muxerLock) {
                check(muxerStarted && lastVideoUs >= 0) { "Segment too short" }
                muxer.stop()
            }
            return RecordedSegment(output.path, (lastVideoUs - firstVideoUs) / 1000)
        } catch (e: Exception) {
            output.delete()
            throw e
        } finally {
            release()
        }
    }

    fun cancel() {
        capturingAudio = false
        audioThread.join()
        release()
        output.delete()
    }

    private fun captureAudio() {
        audioRecord.startRecording()
        val chunk = ByteArray(2048)
        while (capturingAudio) {
            val read = audioRecord.read(chunk, 0, chunk.size)
            if (read <= 0) continue
            val ptsUs = relativeUs(System.nanoTime()) - read / 2 * 1_000_000L / SAMPLE_RATE
            queueAudio(chunk, read, ptsUs.coerceAtLeast(0), flags = 0)
            drain(audioEncoder, isVideo = false, endOfStream = false)
        }
        audioRecord.stop()
        queueAudio(chunk, 0, relativeUs(System.nanoTime()), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(audioEncoder, isVideo = false, endOfStream = true)
    }

    private fun queueAudio(
        data: ByteArray,
        size: Int,
        ptsUs: Long,
        flags: Int,
    ) {
        var index: Int
        do {
            index = audioEncoder.dequeueInputBuffer(TIMEOUT_US)
        } while (index < 0 && (capturingAudio || flags != 0))
        if (index < 0) return
        audioEncoder.getInputBuffer(index)!!.apply {
            clear()
            put(data, 0, size)
        }
        audioEncoder.queueInputBuffer(index, 0, size, ptsUs, flags)
    }

    /** Moves encoded samples to the muxer; with [endOfStream], waits for the codec's EOS. */
    private fun drain(
        codec: MediaCodec,
        isVideo: Boolean,
        endOfStream: Boolean,
    ) {
        val info = MediaCodec.BufferInfo()
        var idleRounds = 0
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) TIMEOUT_US else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream || ++idleRounds > MAX_IDLE_ROUNDS) return
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(isVideo, codec.outputFormat)
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)!!
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!isConfig && info.size > 0) writeSample(isVideo, buffer, info)
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private fun addTrack(
        isVideo: Boolean,
        format: MediaFormat,
    ) = synchronized(muxerLock) {
        if (isVideo) videoTrack = muxer.addTrack(format) else audioTrack = muxer.addTrack(format)
        if (videoTrack >= 0 && audioTrack >= 0) {
            muxer.start()
            muxerStarted = true
            pendingSamples.forEach { muxer.writeSampleData(trackFor(it.isVideo), it.data, it.info) }
            pendingSamples.clear()
        }
    }

    private fun writeSample(
        isVideo: Boolean,
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
    ) = synchronized(muxerLock) {
        if (isVideo) {
            if (firstVideoUs < 0) firstVideoUs = info.presentationTimeUs
            lastVideoUs = info.presentationTimeUs
        }
        if (muxerStarted) {
            muxer.writeSampleData(trackFor(isVideo), buffer, info)
        } else {
            // Both tracks must be added before the muxer starts; keep early samples.
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            val copy = ByteBuffer.allocate(info.size)
            copy.put(buffer)
            copy.flip()
            val copiedInfo =
                MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) }
            pendingSamples += PendingSample(isVideo, copy, copiedInfo)
        }
    }

    private fun trackFor(isVideo: Boolean) = if (isVideo) videoTrack else audioTrack

    private fun relativeUs(nanos: Long) = (nanos - startNanos) / 1000

    private fun release() {
        runCatching { videoEncoder.stop() }
        runCatching { audioEncoder.stop() }
        videoEncoder.release()
        audioEncoder.release()
        audioRecord.release()
        inputSurface.release()
        runCatching { muxer.release() }
    }

    private class PendingSample(
        val isVideo: Boolean,
        val data: ByteBuffer,
        val info: MediaCodec.BufferInfo,
    )

    private companion object {
        const val SAMPLE_RATE = 44_100
        const val TIMEOUT_US = 10_000L
        const val MAX_IDLE_ROUNDS = 100
    }
}
