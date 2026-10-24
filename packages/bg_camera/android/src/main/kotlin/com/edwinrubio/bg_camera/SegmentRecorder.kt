package com.edwinrubio.bg_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Fragments and merged videos. Not in cacheDir: Android purges it when storage
 * runs low, which can delete fragments mid-session.
 */
object Recordings {
    fun dir(context: Context) = File(context.filesDir, "recordings").apply { mkdirs() }

    fun newFile(
        context: Context,
        prefix: String,
    ) = File(dir(context), "${prefix}_${UUID.randomUUID()}.mp4")

    /** Fragments don't outlive the session, so leftovers from a killed app are dropped. */
    fun clear(context: Context) {
        dir(context).listFiles()?.forEach { it.delete() }
    }
}

class RecordedSegment(
    val path: String,
    val durationMs: Long,
    val thumbnailPath: String?,
)

/**
 * Encodes one fragment: H.264 from [inputSurface] (fed by the GL thread) plus
 * AAC from the microphone on its own thread, muxed into an .mp4.
 *
 * Construction sets up the codecs (slow) and [begin] starts capturing (fast).
 * [onFrameRendered] is called on the GL thread.
 */
@SuppressLint("MissingPermission") // RECORD_AUDIO is requested by the app before initialize.
class SegmentRecorder(
    width: Int,
    height: Int,
    private val bitRate: Int,
    private val frameRate: Int,
    private val output: File,
) {
    private val videoEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private lateinit var audioRecord: AudioRecord
    private val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var startNanos = 0L
    lateinit var inputSurface: Surface
        private set

    private val muxerLock = Any()
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxerStarted = false
    private val pendingSamples = mutableListOf<PendingSample>()
    private var firstVideoUs = -1L
    private var lastVideoUs = -1L

    @Volatile private var capturingAudio = false
    private var audioThread: Thread? = null

    init {
        try {
            configure(width, height)
        } catch (e: Exception) {
            // Emulators in particular can fail here; don't leak the codecs.
            release()
            output.delete()
            throw e
        }
    }

    private fun configure(
        width: Int,
        height: Int,
    ) {
        val videoFormat =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
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
    }

    fun begin() {
        startNanos = System.nanoTime()
        capturingAudio = true
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
            audioThread?.join(AUDIO_JOIN_TIMEOUT_MS)
            check(audioThread?.isAlive != true) { "Audio encoder did not finish" }
            synchronized(muxerLock) {
                Log.d(TAG, "finish: muxerStarted=$muxerStarted video=$firstVideoUs..$lastVideoUs")
                check(muxerStarted && lastVideoUs >= 0) { "Segment too short" }
                muxer.stop()
            }
            return RecordedSegment(output.path, (lastVideoUs - firstVideoUs) / 1000, writeThumbnail())
        } catch (e: Exception) {
            output.delete()
            throw e
        } finally {
            release()
        }
    }

    fun cancel() {
        capturingAudio = false
        audioThread?.join(AUDIO_JOIN_TIMEOUT_MS)
        release()
        output.delete()
    }

    /** Saves the first frame next to the video as a small JPEG. */
    private fun writeThumbnail(): String? =
        runCatching {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(output.path)
                val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
                val scale = THUMBNAIL_SIZE.toFloat() / maxOf(frame.width, frame.height)
                val small =
                    Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true)
                val file = File(output.path.removeSuffix(".mp4") + ".jpg")
                file.outputStream().use { small.compress(Bitmap.CompressFormat.JPEG, 80, it) }
                file.path
            } finally {
                retriever.release()
            }
        }.getOrElse {
            Log.w(TAG, "Thumbnail failed", it)
            null
        }

    private fun captureAudio() {
        try {
            audioRecord.startRecording()
            val chunk = ByteArray(2048)
            var samplesQueued = 0L
            var samplesDropped = 0L
            while (capturingAudio) {
                val read = audioRecord.read(chunk, 0, chunk.size)
                if (read <= 0) continue
                // Some sources (emulators, some HALs) return audio faster than
                // real time; anything beyond the elapsed time would stretch the
                // fragment, so it is dropped. Timestamps follow the sample count.
                val elapsedSamples = (System.nanoTime() - startNanos) * SAMPLE_RATE / 1_000_000_000L
                if (samplesQueued > elapsedSamples + SAMPLE_RATE / 10) {
                    samplesDropped += read / 2
                    continue
                }
                val ptsUs = samplesQueued * 1_000_000L / SAMPLE_RATE
                queueAudio(chunk, read, ptsUs, flags = 0)
                samplesQueued += read / 2
                drain(audioEncoder, isVideo = false, endOfStream = false)
            }
            Log.d(TAG, "audio: queued ${samplesQueued * 1000 / SAMPLE_RATE} ms, dropped ${samplesDropped * 1000 / SAMPLE_RATE} ms")
            audioRecord.stop()
            queueAudio(chunk, 0, samplesQueued * 1_000_000L / SAMPLE_RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drain(audioEncoder, isVideo = false, endOfStream = true)
        } catch (e: Exception) {
            Log.e(TAG, "Audio capture failed", e)
        }
    }

    private fun queueAudio(
        data: ByteArray,
        size: Int,
        ptsUs: Long,
        flags: Int,
    ) {
        // Free input buffers by draining output, or the codec can stall here.
        var index = audioEncoder.dequeueInputBuffer(TIMEOUT_US)
        var attempts = 0
        while (index < 0 && ++attempts < MAX_IDLE_ROUNDS) {
            drain(audioEncoder, isVideo = false, endOfStream = false)
            index = audioEncoder.dequeueInputBuffer(TIMEOUT_US)
        }
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


    private fun release() {
        runCatching { videoEncoder.stop() }
        runCatching { audioEncoder.stop() }
        videoEncoder.release()
        audioEncoder.release()
        if (::audioRecord.isInitialized) audioRecord.release()
        if (::inputSurface.isInitialized) inputSurface.release()
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
        const val AUDIO_JOIN_TIMEOUT_MS = 2_000L
        const val THUMBNAIL_SIZE = 240
        const val TAG = "bg_camera"
    }
}
