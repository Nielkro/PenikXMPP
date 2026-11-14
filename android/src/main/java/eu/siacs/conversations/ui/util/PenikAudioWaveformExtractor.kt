/*
 * Copyright (c) 2026, Penik Project.
 * All rights reserved.
 */

package eu.siacs.conversations.ui.util

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteOrder
import kotlin.math.abs

object PenikAudioWaveformExtractor {

    private val cache = LruCache<String, List<Float>>(200)

    fun getCached(key: String): List<Float>? = cache.get(key)

    suspend fun getWaveform(file: File, key: String, barCount: Int = 45): List<Float> {
        val cached = cache.get(key)
        if (cached != null) return cached

        return withContext(Dispatchers.IO) {
            val result = extractWaveform(file, barCount)
            if (result.isNotEmpty()) {
                cache.put(key, result)
            }
            result
        }
    }

    private fun extractWaveform(file: File, barCount: Int): List<Float> {
        if (!file.exists() || file.length() == 0L) return emptyList()

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)
            var audioTrackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    format = trackFormat
                    break
                }
            }

            if (audioTrackIndex < 0 || format == null) {
                return emptyList()
            }

            extractor.selectTrack(audioTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return emptyList()
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcmAmplitudes = ArrayList<Float>()
            val bufferInfo = MediaCodec.BufferInfo()
            var isEOS = false
            val timeoutUs = 5000L

            var framesProcessed = 0
            val maxFrames = 2000

            while (!isEOS && framesProcessed < maxFrames) {
                val inputBufferIndex = codec.dequeueInputBuffer(timeoutUs)
                if (inputBufferIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inputBufferIndex)
                    if (inputBuffer != null) {
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(inputBufferIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            isEOS = true
                        } else {
                            codec.queueInputBuffer(inputBufferIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                var outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                while (outputBufferIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        outputBuffer.order(ByteOrder.LITTLE_ENDIAN)

                        var maxAmp = 0
                        while (outputBuffer.remaining() >= 2) {
                            val sample = abs(outputBuffer.short.toInt())
                            if (sample > maxAmp) {
                                maxAmp = sample
                            }
                        }
                        pcmAmplitudes.add(maxAmp.toFloat())
                        framesProcessed++
                    }
                    codec.releaseOutputBuffer(outputBufferIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        isEOS = true
                        break
                    }
                    outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, 0L)
                }
            }

            if (pcmAmplitudes.isEmpty()) {
                return emptyList()
            }

            return downsample(pcmAmplitudes, barCount)
        } catch (e: Exception) {
            return emptyList()
        } finally {
            try {
                codec?.stop()
            } catch (ignored: Exception) {}
            try {
                codec?.release()
            } catch (ignored: Exception) {}
            try {
                extractor.release()
            } catch (ignored: Exception) {}
        }
    }

    private fun downsample(raw: List<Float>, barCount: Int): List<Float> {
        if (raw.isEmpty()) return emptyList()

        val maxVal = raw.maxOrNull() ?: 1f
        val normalizer = if (maxVal > 0f) maxVal else 32767f

        val result = ArrayList<Float>(barCount)
        val chunkSize = raw.size.toFloat() / barCount.toFloat()

        for (i in 0 until barCount) {
            val startIdx = (i * chunkSize).toInt().coerceIn(0, raw.size - 1)
            val endIdx = ((i + 1) * chunkSize).toInt().coerceIn(startIdx + 1, raw.size)

            var chunkMax = 0f
            for (j in startIdx until endIdx) {
                if (raw[j] > chunkMax) {
                    chunkMax = raw[j]
                }
            }
            val normalized = (chunkMax / normalizer).coerceIn(0f, 1f)
            val barHeight = 0.12f + (normalized * 0.88f)
            result.add(barHeight)
        }
        return result
    }
}
