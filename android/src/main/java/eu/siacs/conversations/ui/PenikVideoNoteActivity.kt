package eu.siacs.conversations.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.util.Log
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
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import java.io.File
import java.util.Locale

/**
 * Telegram-style Video Note ("Кружочки") recording overlay.
 * Opens transparently over the chat, immediately begins recording,
 * and exits instantly when tapping Send or Cancel.
 */
class PenikVideoNoteActivity : ComponentActivity() {

    companion object {
        const val EXTRA_RAW_VIDEO_PATH = "extra_raw_video_path"
        const val MAX_RECORD_SECONDS = 60
        private const val TAG = "PenikVideoNoteActivity"
    }

    private var cameraProvider: ProcessCameraProvider? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var isFrontCamera by mutableStateOf(true)
    private var currentRecordedFile: File? = null
    private var isRecordingStarted = false

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

        val hasCamera = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val hasAudio = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (!hasCamera || !hasAudio) {
            permissionLauncher.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
        }

        setContent {
            PenikVideoNoteOverlayScreen(
                    onCancel = { cancelAndExit() },
                    onFlipCamera = { flipCamera() },
                    onSend = { finishAndSend() },
                    bindCamera = { previewView -> bindCameraUseCases(previewView) }
            )
        }
    }

    private fun flipCamera() {
        // If recording, we can stop and flip or flip between takes
        isFrontCamera = !isFrontCamera
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
                // Start recording automatically as soon as camera is bound!
                if (!isRecordingStarted) {
                    startRecordingInternal()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to bind camera", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun startRecordingInternal() {
        val vc = videoCapture ?: return
        val rawFile = File(cacheDir, "raw_video_note_${System.currentTimeMillis()}.mp4")
        currentRecordedFile = rawFile

        val outputOptions = FileOutputOptions.Builder(rawFile).build()

        try {
            isRecordingStarted = true
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
                                if (event.hasError()) {
                                    Log.e(TAG, "Recording finalized with error: ${event.error}")
                                }
                            }
                        }
                    }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording", e)
        }
    }

    private fun cancelAndExit() {
        try {
            activeRecording?.stop()
            activeRecording = null
            currentRecordedFile?.delete()
        } catch (ignored: Exception) {}
        setResult(Activity.RESULT_CANCELED)
        finish()
        overridePendingTransition(0, 0)
    }

    private fun finishAndSend() {
        try {
            activeRecording?.stop()
            activeRecording = null
        } catch (ignored: Exception) {}

        val file = currentRecordedFile
        if (file != null && file.exists()) {
            val intent = Intent().apply {
                putExtra(EXTRA_RAW_VIDEO_PATH, file.absolutePath)
                data = Uri.fromFile(file)
            }
            setResult(Activity.RESULT_OK, intent)
        } else {
            setResult(Activity.RESULT_CANCELED)
        }
        finish()
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        super.onDestroy()
        activeRecording?.stop()
        cameraProvider?.unbindAll()
    }

    @Composable
    private fun PenikVideoNoteOverlayScreen(
            onCancel: () -> Unit,
            onFlipCamera: () -> Unit,
            onSend: () -> Unit,
            bindCamera: (PreviewView) -> Unit
    ) {
        var recordedDurationSec by remember { mutableStateOf(0f) }
        var previewViewRef by remember { mutableStateOf<PreviewView?>(null) }

        LaunchedEffect(previewViewRef, isFrontCamera) {
            previewViewRef?.let { bindCamera(it) }
        }

        // Live timer loop up to MAX_RECORD_SECONDS
        LaunchedEffect(Unit) {
            val start = System.currentTimeMillis()
            while (recordedDurationSec < MAX_RECORD_SECONDS) {
                kotlinx.coroutines.delay(100)
                recordedDurationSec = (System.currentTimeMillis() - start) / 1000f
                if (recordedDurationSec >= MAX_RECORD_SECONDS) {
                    onSend()
                    break
                }
            }
        }

        // Semi-transparent darkened chat background
        Box(
                modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.65f))
                        .clickable(enabled = false) {}
        ) {
            // Center Circular Camera Viewfinder
            Column(
                    modifier = Modifier
                            .align(Alignment.Center)
                            .padding(bottom = 80.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                        modifier = Modifier.size(280.dp),
                        contentAlignment = Alignment.Center
                ) {
                    // Live camera preview
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

                    // Circular Progress Arc (white, like Telegram)
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
                                color = Color.White,
                                startAngle = -90f,
                                sweepAngle = sweepAngle,
                                useCenter = false,
                                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                        )
                    }
                }
            }

            // Bottom Bar: Flip, Timer, "ОТМЕНА", Send (Exact layout from Image 2!)
            Box(
                    modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 20.dp, vertical = 24.dp)
            ) {
                Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    // Left: Flip camera button
                    IconButton(
                            onClick = onFlipCamera,
                            modifier = Modifier
                                    .size(44.dp)
                                    .clip(CircleShape)
                                    .background(Color.White.copy(alpha = 0.15f))
                    ) {
                        Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "Сменить камеру",
                                tint = Color.White,
                                modifier = Modifier.size(24.dp)
                        )
                    }

                    // Center-left: Red dot + live timer
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                                modifier = Modifier
                                        .size(9.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFFE53935))
                        )
                        Spacer(modifier = Modifier.width(7.dp))
                        val minutes = (recordedDurationSec / 60).toInt()
                        val seconds = (recordedDurationSec % 60).toInt()
                        val tenths = ((recordedDurationSec * 10).toInt() % 10)
                        val timeStr = String.format(Locale.ENGLISH, "%d:%02d,%d", minutes, seconds, tenths)
                        Text(
                                text = timeStr,
                                color = Color.White,
                                fontSize = 16.sp,
                                fontWeight = FontWeight.Bold,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                        )
                    }

                    // Center: "ОТМЕНА" button
                    Box(
                            modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable { onCancel() }
                                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Text(
                                text = "ОТМЕНА",
                                color = Color.White,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.5.sp
                        )
                    }

                    // Right: Send button (Telegram accent blue circle with send arrow)
                    IconButton(
                            onClick = onSend,
                            modifier = Modifier
                                    .size(54.dp)
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
                }
            }
        }
    }
}
