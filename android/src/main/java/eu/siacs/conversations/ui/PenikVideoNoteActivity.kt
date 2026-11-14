package eu.siacs.conversations.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color as AndroidColor
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import eu.siacs.conversations.R
import eu.siacs.conversations.ui.util.PenikVideoNoteTranscoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

class PenikVideoNoteActivity : ComponentActivity() {

    companion object {
        const val EXTRA_VIDEO_URI = "extra_video_uri"
        const val MAX_RECORD_SECONDS = 60
        private const val TAG = "PenikVideoNoteActivity"
    }

    private var cameraProvider: ProcessCameraProvider? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var isFrontCamera by mutableStateOf(true)

    private val permissionLauncher = registerForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        val cameraGranted = perms[Manifest.permission.CAMERA] == true
        val audioGranted = perms[Manifest.permission.RECORD_AUDIO] == true
        if (!cameraGranted || !audioGranted) {
            Toast.makeText(this, "Необходимы разрешения камеры и микрофона", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Check permissions
        val hasCamera = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val hasAudio = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (!hasCamera || !hasAudio) {
            permissionLauncher.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
        }

        setContent {
            PenikVideoNoteScreen(
                    onClose = { finish() },
                    onFlipCamera = { flipCamera() },
                    onStartRecording = { onRecordStart() },
                    onStopRecording = { onRecordStop() },
                    onSend = { recordedFile -> processAndSend(recordedFile) },
                    bindCamera = { previewView -> bindCameraUseCases(previewView) }
            )
        }
    }

    private fun flipCamera() {
        isFrontCamera = !isFrontCamera
        // Camera will rebind in LaunchedEffect(isFrontCamera)
    }

    private fun bindCameraUseCases(previewView: PreviewView) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            val cameraSelector = if (isFrontCamera) {
                CameraSelector.DEFAULT_FRONT_CAMERA
            } else {
                CameraSelector.DEFAULT_BACK_CAMERA
            }

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val recorder = Recorder.Builder()
                    .setQualitySelector(QualitySelector.from(Quality.SD))
                    .build()
            videoCapture = VideoCapture.withOutput(recorder)

            try {
                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(this, cameraSelector, preview, videoCapture)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to bind camera use cases", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private var currentRecordedFile: File? = null
    private var onRecordCompleteCallback: ((File) -> Unit)? = null

    private fun onRecordStart() {
        val vc = videoCapture ?: return
        val rawFile = File(cacheDir, "raw_video_note_${System.currentTimeMillis()}.mp4")
        currentRecordedFile = rawFile

        val outputOptions = FileOutputOptions.Builder(rawFile).build()

        try {
            activeRecording = vc.output
                    .prepareRecording(this, outputOptions)
                    .apply {
                        if (ContextCompat.checkSelfPermission(this@PenikVideoNoteActivity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                            withAudioEnabled()
                        }
                    }
                    .start(ContextCompat.getMainExecutor(this)) { event ->
                        when (event) {
                            is VideoRecordEvent.Finalize -> {
                                if (!event.hasError()) {
                                    onRecordCompleteCallback?.invoke(rawFile)
                                } else {
                                    Log.e(TAG, "Recording error: ${event.error}")
                                    Toast.makeText(this, "Ошибка записи видео", Toast.LENGTH_SHORT).show()
                                }
                            }
                        }
                    }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording", e)
        }
    }

    private fun onRecordStop() {
        activeRecording?.stop()
        activeRecording = null
    }

    private fun processAndSend(file: File) {
        // Transcode to 480x480 square with Penik watermark in corner
        val outputFile = File(cacheDir, "penik_video_note_${System.currentTimeMillis()}.mp4")
        val finalFile = PenikVideoNoteTranscoder.transcode(file, outputFile)

        val intent = Intent().apply {
            data = Uri.fromFile(finalFile)
            putExtra(EXTRA_VIDEO_URI, Uri.fromFile(finalFile).toString())
        }
        setResult(Activity.RESULT_OK, intent)
        finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        activeRecording?.stop()
        cameraProvider?.unbindAll()
    }

    @Composable
    private fun PenikVideoNoteScreen(
            onClose: () -> Unit,
            onFlipCamera: () -> Unit,
            onStartRecording: () -> Unit,
            onStopRecording: () -> Unit,
            onSend: (File) -> Unit,
            bindCamera: (PreviewView) -> Unit
    ) {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()

        var isRecording by remember { mutableStateOf(false) }
        var recordedDurationSec by remember { mutableStateOf(0f) }
        var recordedFile by remember { mutableStateOf<File?>(null) }
        var isProcessing by remember { mutableStateOf(false) }

        // Live preview view reference
        var previewViewRef by remember { mutableStateOf<PreviewView?>(null) }

        LaunchedEffect(previewViewRef, isFrontCamera) {
            previewViewRef?.let { bindCamera(it) }
        }

        // Timer effect during recording
        LaunchedEffect(isRecording) {
            if (isRecording) {
                recordedDurationSec = 0f
                val start = System.currentTimeMillis()
                while (isRecording && recordedDurationSec < MAX_RECORD_SECONDS) {
                    kotlinx.coroutines.delay(100)
                    recordedDurationSec = (System.currentTimeMillis() - start) / 1000f
                    if (recordedDurationSec >= MAX_RECORD_SECONDS) {
                        isRecording = false
                        onStopRecording()
                    }
                }
            }
        }

        onRecordCompleteCallback = { file ->
            recordedFile = file
        }

        Box(
                modifier = Modifier
                        .fillMaxSize()
                        .background(Color(0xFF0C1017))
        ) {
            // Top Bar
            Row(
                    modifier = Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                        onClick = onClose,
                        modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.12f))
                ) {
                    Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Закрыть",
                            tint = Color.White
                    )
                }

                // Flip camera button (only visible when not reviewing or recording)
                if (recordedFile == null && !isRecording) {
                    IconButton(
                            onClick = onFlipCamera,
                            modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                                    .background(Color.White.copy(alpha = 0.12f))
                    ) {
                        Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "Сменить камеру",
                                tint = Color.White
                        )
                    }
                }
            }

            // Center Viewfinder Area
            Column(
                    modifier = Modifier
                            .align(Alignment.Center)
                            .padding(bottom = 60.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Circular viewfinder
                Box(
                        modifier = Modifier.size(280.dp),
                        contentAlignment = Alignment.Center
                ) {
                    val fileToPreview = recordedFile
                    if (fileToPreview != null) {
                        // Review playback in circle
                        ReviewPlayer(file = fileToPreview)
                    } else {
                        // Live CameraX preview in circle
                        AndroidView(
                                factory = { ctx ->
                                    PreviewView(ctx).apply {
                                        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                                        scaleType = PreviewView.ScaleType.FILL_CENTER
                                        previewViewRef = this
                                    }
                                },
                                modifier = Modifier
                                        .size(268.dp)
                                        .clip(CircleShape)
                        )
                    }

                    // Circular Progress Ring during recording
                    if (isRecording) {
                        Canvas(modifier = Modifier.size(280.dp)) {
                            val strokeWidth = 4.dp.toPx()
                            val sweepAngle = (recordedDurationSec / MAX_RECORD_SECONDS.toFloat()) * 360f

                            // Track
                            drawCircle(
                                    color = Color.White.copy(alpha = 0.2f),
                                    style = Stroke(width = strokeWidth)
                            )
                            // Progress Arc
                            drawArc(
                                    color = Color(0xFFE53935),
                                    startAngle = -90f,
                                    sweepAngle = sweepAngle,
                                    useCenter = false,
                                    style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                            )
                        }
                    } else if (recordedFile == null) {
                        // Subtle decorative ring when idle
                        Box(
                                modifier = Modifier
                                        .size(276.dp)
                                        .clip(CircleShape)
                                        .border(2.dp, Color.White.copy(alpha = 0.25f), CircleShape)
                        )
                    }
                }

                Spacer(modifier = Modifier.height(18.dp))

                // Timer pill
                if (isRecording) {
                    val minutes = (recordedDurationSec / 60).toInt()
                    val seconds = (recordedDurationSec % 60).toInt()
                    val timeStr = String.format(Locale.ENGLISH, "%02d:%02d / 01:00", minutes, seconds)

                    Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.Black.copy(alpha = 0.6f))
                                    .padding(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Box(
                                modifier = Modifier
                                        .size(8.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFFE53935))
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                                text = timeStr,
                                color = Color.White,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold
                        )
                    }
                } else if (recordedFile == null) {
                    Text(
                            text = "Нажмите для записи кружочка",
                            color = Color.White.copy(alpha = 0.6f),
                            fontSize = 13.sp
                    )
                }
            }

            // Bottom Controls Area
            Box(
                    modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(bottom = 32.dp),
                    contentAlignment = Alignment.Center
            ) {
                val file = recordedFile
                if (isProcessing) {
                    Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(Color.Black.copy(alpha = 0.7f))
                                    .padding(horizontal = 20.dp, vertical = 12.dp)
                    ) {
                        CircularProgressIndicator(
                                modifier = Modifier.size(24.dp),
                                color = Color(0xFF3390EC),
                                strokeWidth = 2.5.dp
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                                text = "Обработка кружочка...",
                                color = Color.White,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium
                        )
                    }
                } else if (file != null) {
                    // Review controls: Retake / Send
                    Row(
                            horizontalArrangement = Arrangement.spacedBy(48.dp),
                            verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Retake
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            IconButton(
                                    onClick = {
                                        try { file.delete() } catch (ignored: Exception) {}
                                        recordedFile = null
                                    },
                                    modifier = Modifier
                                            .size(56.dp)
                                            .clip(CircleShape)
                                            .background(Color.White.copy(alpha = 0.15f))
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Delete,
                                        contentDescription = "Перезаписать",
                                        tint = Color.White,
                                        modifier = Modifier.size(26.dp)
                                )
                            }
                            Spacer(modifier = Modifier.height(4.dp))
                            Text("Сброс", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
                        }

                        // Send
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            IconButton(
                                    onClick = {
                                        isProcessing = true
                                        scope.launch(Dispatchers.IO) {
                                            onSend(file)
                                        }
                                    },
                                    modifier = Modifier
                                            .size(56.dp)
                                            .clip(CircleShape)
                                            .background(Color(0xFF3390EC))
                            ) {
                                Icon(
                                        imageVector = Icons.Default.Send,
                                        contentDescription = "Отправить",
                                        tint = Color.White,
                                        modifier = Modifier.size(26.dp)
                                )
                            }
                            Spacer(modifier = Modifier.height(4.dp))
                            Text("Отправить", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                } else {
                    // Record button (idle or recording)
                    Box(
                            modifier = Modifier
                                    .size(76.dp)
                                    .clip(CircleShape)
                                    .border(3.dp, Color.White, CircleShape)
                                    .clickable {
                                        if (!isRecording) {
                                            isRecording = true
                                            onStartRecording()
                                        } else {
                                            isRecording = false
                                            onStopRecording()
                                        }
                                    },
                            contentAlignment = Alignment.Center
                    ) {
                        if (isRecording) {
                            // Red square (Stop)
                            Box(
                                    modifier = Modifier
                                            .size(26.dp)
                                            .clip(RoundedCornerShape(6.dp))
                                            .background(Color(0xFFE53935))
                            )
                        } else {
                            // Red circle (Record)
                            Box(
                                    modifier = Modifier
                                            .size(56.dp)
                                            .clip(CircleShape)
                                            .background(Color(0xFFE53935))
                            )
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun ReviewPlayer(file: File) {
        val context = LocalContext.current
        var mediaPlayer by remember { mutableStateOf<MediaPlayer?>(null) }

        DisposableEffect(file) {
            val player = MediaPlayer().apply {
                setDataSource(file.absolutePath)
                isLooping = true
            }
            mediaPlayer = player

            onDispose {
                try {
                    player.stop()
                    player.release()
                } catch (ignored: Exception) {}
            }
        }

        AndroidView(
                factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(surface: android.graphics.SurfaceTexture, width: Int, height: Int) {
                                val s = Surface(surface)
                                mediaPlayer?.setSurface(s)
                                mediaPlayer?.prepareAsync()
                                mediaPlayer?.setOnPreparedListener { mp ->
                                    mp.start()
                                }
                            }

                            override fun onSurfaceTextureSizeChanged(surface: android.graphics.SurfaceTexture, width: Int, height: Int) {}
                            override fun onSurfaceTextureDestroyed(surface: android.graphics.SurfaceTexture): Boolean {
                                mediaPlayer?.setSurface(null)
                                return true
                            }
                            override fun onSurfaceTextureUpdated(surface: android.graphics.SurfaceTexture) {}
                        }
                    }
                },
                modifier = Modifier
                        .size(268.dp)
                        .clip(CircleShape)
        )
    }
}
