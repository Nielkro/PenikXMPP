package eu.siacs.conversations.ui.util

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Fast hardware-accelerated transcoder for Penik Video Notes ("Кружочки").
 *
 * 1. Corrects camera sensor rotation (upright 0°).
 * 2. Crops center into a circle (radius 1.0).
 * 3. Fills everything outside the circle with SOLID BLACK (guaranteed zero privacy leaks).
 * 4. Places the stylish "Penik" brand badge in the bottom-right corner on the black background.
 * 5. Copies original AAC audio losslessly.
 */
object PenikVideoNoteTranscoder {

    private const val TAG = "PenikVideoTranscoder"
    private const val OUTPUT_SIZE = 480
    private const val BIT_RATE = 2_200_000
    private const val FRAME_RATE = 30
    private const val I_FRAME_INTERVAL = 1
    private const val TIMEOUT_USEC = 10_000L

    fun transcode(inputFile: File, outputFile: File): File {
        if (!inputFile.exists() || inputFile.length() == 0L) {
            return inputFile
        }
        var extractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var eglHelper: EglHelper? = null

        try {
            extractor = MediaExtractor().apply { setDataSource(inputFile.absolutePath) }

            var videoTrackIndex = -1
            var audioTrackIndex = -1
            var inputVideoFormat: MediaFormat? = null
            var inputAudioFormat: MediaFormat? = null

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/") && videoTrackIndex < 0) {
                    videoTrackIndex = i
                    inputVideoFormat = format
                } else if (mime.startsWith("audio/") && audioTrackIndex < 0) {
                    audioTrackIndex = i
                    inputAudioFormat = format
                }
            }

            if (videoTrackIndex < 0 || inputVideoFormat == null) {
                Log.w(TAG, "No video track found in input file, returning original")
                return inputFile
            }

            // Extract metadata: rotation and dimensions
            var rotation = 0
            var rawWidth = 640
            var rawHeight = 480
            try {
                val retriever = MediaMetadataRetriever().apply { setDataSource(inputFile.absolutePath) }
                rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                rawWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 640
                rawHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 480
                retriever.release()
            } catch (e: Exception) {
                Log.w(TAG, "Could not extract video metadata", e)
            }

            // Setup encoder (H.264 / AVC 480x480)
            val outputFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, OUTPUT_SIZE, OUTPUT_SIZE).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
            }

            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val encoderSurface = encoder.createInputSurface()
            encoder.start()

            // Setup EGL & OpenGL
            eglHelper = EglHelper(encoderSurface, rotation, rawWidth, rawHeight)
            eglHelper.makeCurrent()

            // Setup decoder to output onto EGL surface texture
            val videoMime = inputVideoFormat.getString(MediaFormat.KEY_MIME) ?: MediaFormat.MIMETYPE_VIDEO_AVC
            decoder = MediaCodec.createDecoderByType(videoMime)
            val decoderSurface = Surface(eglHelper.surfaceTexture)
            decoder.configure(inputVideoFormat, decoderSurface, null, 0)
            decoder.start()

            // Setup muxer with orientation 0 (already rotated in OpenGL)
            muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer.setOrientationHint(0)

            var muxerVideoTrack = -1
            var muxerAudioTrack = -1
            var muxerStarted = false

            extractor.selectTrack(videoTrackIndex)

            // Buffers & state
            val bufferInfo = MediaCodec.BufferInfo()
            var isExtractorEOS = false
            var isDecoderEOS = false
            var isEncoderEOS = false

            val audioBuffer = ByteBuffer.allocateDirect(128 * 1024)
            val audioBufferInfo = MediaCodec.BufferInfo()

            fun drainEncoder(endOfStream: Boolean) {
                if (endOfStream) {
                    encoder.signalEndOfInputStream()
                }
                var tryCount = 0
                while (true) {
                    val encoderStatus = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC)
                    if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                        if (!endOfStream) {
                            break
                        } else {
                            tryCount++
                            if (tryCount > 25) break
                            continue
                        }
                    } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        if (muxerStarted) throw RuntimeException("Encoder format changed twice")
                        val newFormat = encoder.outputFormat
                        muxerVideoTrack = muxer.addTrack(newFormat)
                        if (audioTrackIndex >= 0 && inputAudioFormat != null) {
                            try {
                                muxerAudioTrack = muxer.addTrack(inputAudioFormat)
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to add audio track to muxer", e)
                                muxerAudioTrack = -1
                            }
                        }
                        muxer.start()
                        muxerStarted = true
                    } else if (encoderStatus >= 0) {
                        val encodedData = encoder.getOutputBuffer(encoderStatus)
                                ?: throw RuntimeException("encoderOutputBuffer was null")
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                            bufferInfo.size = 0
                        }
                        if (bufferInfo.size != 0 && muxerStarted) {
                            encodedData.position(bufferInfo.offset)
                            encodedData.limit(bufferInfo.offset + bufferInfo.size)
                            muxer.writeSampleData(muxerVideoTrack, encodedData, bufferInfo)
                        }
                        encoder.releaseOutputBuffer(encoderStatus, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            isEncoderEOS = true
                            break
                        }
                    }
                }
            }

            // Main processing loop
            while (!isEncoderEOS) {
                // Feed decoder
                if (!isExtractorEOS) {
                    val inIndex = decoder.dequeueInputBuffer(TIMEOUT_USEC)
                    if (inIndex >= 0) {
                        val inputBuf = decoder.getInputBuffer(inIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuf, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            isExtractorEOS = true
                        } else {
                            val pts = extractor.sampleTime
                            decoder.queueInputBuffer(inIndex, 0, sampleSize, pts, 0)
                            extractor.advance()
                        }
                    }
                }

                // Drain decoder -> render to OpenGL surface -> feed encoder
                if (!isDecoderEOS) {
                    val outIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC)
                    if (outIndex >= 0) {
                        val doRender = bufferInfo.size != 0
                        decoder.releaseOutputBuffer(outIndex, doRender)
                        if (doRender) {
                            eglHelper.awaitNewImage()
                            eglHelper.drawImage()
                            eglHelper.setPresentationTime(bufferInfo.presentationTimeUs * 1000)
                            eglHelper.swapBuffers()
                        }
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            isDecoderEOS = true
                            drainEncoder(true)
                        }
                    }
                }

                drainEncoder(false)
            }

            // Copy original audio track directly into muxer
            if (audioTrackIndex >= 0 && muxerAudioTrack >= 0 && muxerStarted) {
                extractor.unselectTrack(videoTrackIndex)
                extractor.selectTrack(audioTrackIndex)
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                while (true) {
                    val sampleSize = extractor.readSampleData(audioBuffer, 0)
                    if (sampleSize < 0) break
                    audioBufferInfo.offset = 0
                    audioBufferInfo.size = sampleSize
                    audioBufferInfo.presentationTimeUs = extractor.sampleTime
                    audioBufferInfo.flags = extractor.sampleFlags
                    muxer.writeSampleData(muxerAudioTrack, audioBuffer, audioBufferInfo)
                    extractor.advance()
                }
            }

            Log.i(TAG, "Video note transcode completed successfully: ${outputFile.length()} bytes")
            return outputFile
        } catch (e: Exception) {
            Log.e(TAG, "Transcode failed, falling back to original file", e)
            return inputFile
        } finally {
            try { decoder?.stop(); decoder?.release() } catch (ignored: Exception) {}
            try { encoder?.stop(); encoder?.release() } catch (ignored: Exception) {}
            try { muxer?.stop(); muxer?.release() } catch (ignored: Exception) {}
            try { extractor?.release() } catch (ignored: Exception) {}
            try { eglHelper?.release() } catch (ignored: Exception) {}
        }
    }

    private class EglHelper(
            surface: Surface,
            private val videoRotation: Int,
            private val rawWidth: Int,
            private val rawHeight: Int
    ) {
        private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

        val surfaceTexture: android.graphics.SurfaceTexture
        private var textureId: Int = -1
        private var watermarkTextureId: Int = -1

        private var program: Int = 0
        private var uSTMatrixHandle: Int = 0
        private var uRotationHandle: Int = 0
        private var uAspectScaleHandle: Int = 0
        private var aPositionHandle: Int = 0
        private var aTextureHandle: Int = 0

        private var watermarkProgram: Int = 0
        private var wmPositionHandle: Int = 0
        private var wmTextureHandle: Int = 0

        private val triangleVertices: FloatBuffer
        private val watermarkVertices: FloatBuffer
        private val stMatrix = FloatArray(16)

        @Volatile
        private var frameAvailable = false
        private val frameSyncObject = Object()

        init {
            // Full screen quad [-1, 1] x [-1, 1]
            val vertexData = floatArrayOf(
                    -1.0f, -1.0f, 0f, 0f, 0f,
                    1.0f, -1.0f, 0f, 1f, 0f,
                    -1.0f, 1.0f, 0f, 0f, 1f,
                    1.0f, 1.0f, 0f, 1f, 1f
            )
            triangleVertices = ByteBuffer.allocateDirect(vertexData.size * 4)
                    .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                        put(vertexData)
                        position(0)
                    }

            // Watermark quad in BOTTOM-RIGHT corner on the black background:
            // x: [0.50, 0.96], y: [-0.94, -0.74]
            // At (0.50, -0.74), distance^2 = 0.25 + 0.5476 = 0.7976 -> placed nicely in corner
            val wmVertexData = floatArrayOf(
                    0.50f, -0.94f, 0f, 0f, 1f,
                    0.96f, -0.94f, 0f, 1f, 1f,
                    0.50f, -0.74f, 0f, 0f, 0f,
                    0.96f, -0.74f, 0f, 1f, 0f
            )
            watermarkVertices = ByteBuffer.allocateDirect(wmVertexData.size * 4)
                    .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                        put(wmVertexData)
                        position(0)
                    }

            initEgl(surface)
            makeCurrent()

            textureId = createOesTexture()
            surfaceTexture = android.graphics.SurfaceTexture(textureId).apply {
                setDefaultBufferSize(OUTPUT_SIZE, OUTPUT_SIZE)
                setOnFrameAvailableListener({
                    synchronized(frameSyncObject) {
                        frameAvailable = true
                        frameSyncObject.notifyAll()
                    }
                }, android.os.Handler(android.os.Looper.getMainLooper()))
            }

            initShaders()
            watermarkTextureId = createWatermarkTexture()
        }

        private fun initEgl(surface: Surface) {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val version = IntArray(2)
            EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

            val attribList = intArrayOf(
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL_RECORDABLE_ANDROID, 1,
                    EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, configs.size, numConfigs, 0)

            val contextAttribs = intArrayOf(
                    EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
                    EGL14.EGL_NONE
            )
            eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

            val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
            eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], surface, surfaceAttribs, 0)
        }

        fun makeCurrent() {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        }

        fun awaitNewImage() {
            synchronized(frameSyncObject) {
                var waitAttempts = 0
                while (!frameAvailable && waitAttempts < 15) {
                    frameSyncObject.wait(15)
                    waitAttempts++
                }
                frameAvailable = false
            }
            try {
                surfaceTexture.updateTexImage()
                surfaceTexture.getTransformMatrix(stMatrix)
            } catch (e: Exception) {
                Log.w(TAG, "updateTexImage failed: ${e.message}")
            }
        }

        fun drawImage() {
            GLES20.glViewport(0, 0, OUTPUT_SIZE, OUTPUT_SIZE)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            GLES20.glUseProgram(program)

            // Pass ST matrix
            GLES20.glUniformMatrix4fv(uSTMatrixHandle, 1, false, stMatrix, 0)

            // Pass rotation (0, 90, 180, 270)
            GLES20.glUniform1i(uRotationHandle, videoRotation)

            // Aspect ratio scaling to center-crop raw sensor buffer into square
            val aspectScale = if (rawWidth > 0 && rawHeight > 0) {
                val maxDim = maxOf(rawWidth, rawHeight).toFloat()
                val minDim = minOf(rawWidth, rawHeight).toFloat()
                maxDim / minDim
            } else {
                1.333f
            }
            GLES20.glUniform1f(uAspectScaleHandle, aspectScale)

            triangleVertices.position(0)
            GLES20.glVertexAttribPointer(aPositionHandle, 3, GLES20.GL_FLOAT, false, 5 * 4, triangleVertices)
            GLES20.glEnableVertexAttribArray(aPositionHandle)

            triangleVertices.position(3)
            GLES20.glVertexAttribPointer(aTextureHandle, 2, GLES20.GL_FLOAT, false, 5 * 4, triangleVertices)
            GLES20.glEnableVertexAttribArray(aTextureHandle)

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            // Draw Penik watermark overlay in bottom-right corner on black background
            drawWatermark()
        }

        private fun drawWatermark() {
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

            GLES20.glUseProgram(watermarkProgram)

            watermarkVertices.position(0)
            GLES20.glVertexAttribPointer(wmPositionHandle, 3, GLES20.GL_FLOAT, false, 5 * 4, watermarkVertices)
            GLES20.glEnableVertexAttribArray(wmPositionHandle)

            watermarkVertices.position(3)
            GLES20.glVertexAttribPointer(wmTextureHandle, 2, GLES20.GL_FLOAT, false, 5 * 4, watermarkVertices)
            GLES20.glEnableVertexAttribArray(wmTextureHandle)

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTextureId)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            GLES20.glDisable(GLES20.GL_BLEND)
        }

        fun setPresentationTime(nsecs: Long) {
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, nsecs)
        }

        fun swapBuffers() {
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        }

        fun release() {
            surfaceTexture.release()
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }

        private fun createOesTexture(): Int {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            val id = textures[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, id)
            GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            return id
        }

        private fun createWatermarkTexture(): Int {
            val width = 150
            val height = 48
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)

            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xEE161A22.toInt()
                style = Paint.Style.FILL
            }
            val cornerRadius = height / 2f
            canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), cornerRadius, cornerRadius, bgPaint)

            val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFF3390EC.toInt() // Penik accent blue
                style = Paint.Style.FILL
            }
            canvas.drawCircle(20f, height / 2f, 6.5f, dotPaint)

            val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFFFFFFFF.toInt()
                textSize = 21f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            }
            canvas.drawText("Penik", 38f, height / 2f + 7.5f, textPaint)

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            val id = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
            GLES20.glTexParameterf(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameterf(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            bitmap.recycle()
            return id
        }

        private fun initShaders() {
            // Video shader: transforms coordinates to upright, crops center, masks to circle with black background
            val vertexShader = """
                uniform mat4 uSTMatrix;
                uniform int uRotation;
                uniform float uAspectScale;
                attribute vec4 aPosition;
                attribute vec4 aTextureCoord;
                varying vec2 vTextureCoord;
                varying vec2 vPos;
                void main() {
                    gl_Position = aPosition;
                    vPos = aPosition.xy;
                    
                    // Base coordinates centered at (0, 0)
                    vec2 coord = aPosition.xy;
                    
                    // Rotate according to camera sensor rotation
                    if (uRotation == 90) {
                        coord = vec2(-coord.y, coord.x);
                    } else if (uRotation == 180) {
                        coord = vec2(-coord.x, -coord.y);
                    } else if (uRotation == 270) {
                        coord = vec2(coord.y, -coord.x);
                    }
                    
                    // Center crop aspect ratio: scale longer axis so square fits central sensor area
                    coord.x = coord.x / uAspectScale;
                    
                    // Map from [-1, 1] back to [0, 1]
                    vec2 uv = coord * 0.5 + 0.5;
                    
                    // Apply SurfaceTexture matrix
                    vTextureCoord = (uSTMatrix * vec4(uv, 0.0, 1.0)).xy;
                }
            """.trimIndent()

            val fragmentShader = """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                varying vec2 vTextureCoord;
                varying vec2 vPos;
                uniform samplerExternalOES sTexture;
                void main() {
                    float dist = length(vPos);
                    if (dist > 1.0) {
                        // SOLID BLACK outside circle: zero privacy leak!
                        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
                    } else {
                        // Anti-aliased smooth circle edge
                        float alpha = smoothstep(1.0, 0.985, dist);
                        vec4 col = texture2D(sTexture, vTextureCoord);
                        gl_FragColor = mix(vec4(0.0, 0.0, 0.0, 1.0), col, alpha);
                    }
                }
            """.trimIndent()

            program = createProgram(vertexShader, fragmentShader)
            aPositionHandle = GLES20.glGetAttribLocation(program, "aPosition")
            aTextureHandle = GLES20.glGetAttribLocation(program, "aTextureCoord")
            uSTMatrixHandle = GLES20.glGetUniformLocation(program, "uSTMatrix")
            uRotationHandle = GLES20.glGetUniformLocation(program, "uRotation")
            uAspectScaleHandle = GLES20.glGetUniformLocation(program, "uAspectScale")

            // 2D Watermark shader
            val wmVertexShader = """
                attribute vec4 aPosition;
                attribute vec2 aTextureCoord;
                varying vec2 vTextureCoord;
                void main() {
                    gl_Position = aPosition;
                    vTextureCoord = aTextureCoord;
                }
            """.trimIndent()

            val wmFragmentShader = """
                precision mediump float;
                varying vec2 vTextureCoord;
                uniform sampler2D sTexture;
                void main() {
                    gl_FragColor = texture2D(sTexture, vTextureCoord);
                }
            """.trimIndent()

            watermarkProgram = createProgram(wmVertexShader, wmFragmentShader)
            wmPositionHandle = GLES20.glGetAttribLocation(watermarkProgram, "aPosition")
            wmTextureHandle = GLES20.glGetAttribLocation(watermarkProgram, "aTextureCoord")
        }

        private fun createProgram(vertexSource: String, fragmentSource: String): Int {
            val vShader = loadShader(GLES20.GL_VERTEX_SHADER, vertexSource)
            val fShader = loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, vShader)
            GLES20.glAttachShader(p, fShader)
            GLES20.glLinkProgram(p)
            val linkStatus = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, linkStatus, 0)
            if (linkStatus[0] != GLES20.GL_TRUE) {
                GLES20.glDeleteProgram(p)
                throw RuntimeException("Could not link program")
            }
            return p
        }

        private fun loadShader(shaderType: Int, source: String): Int {
            val shader = GLES20.glCreateShader(shaderType)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val compiled = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
            if (compiled[0] == 0) {
                val info = GLES20.glGetShaderInfoLog(shader)
                GLES20.glDeleteShader(shader)
                throw RuntimeException("Could not compile shader $shaderType: $info")
            }
            return shader
        }

        companion object {
            private const val EGL_RECORDABLE_ANDROID = 0x3142
        }
    }
}
