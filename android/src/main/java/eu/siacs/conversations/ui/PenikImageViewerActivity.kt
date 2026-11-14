package eu.siacs.conversations.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import eu.siacs.conversations.ui.compose.PenikImageViewer
import java.io.File

class PenikImageViewerActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filePath = intent.getStringExtra(EXTRA_FILE_PATH)
        val uriStr = intent.getStringExtra(EXTRA_URI)
        val displayName = intent.getStringExtra(EXTRA_DISPLAY_NAME)

        val model: Any? = when {
            filePath != null -> File(filePath)
            uriStr != null -> Uri.parse(uriStr)
            intent.data != null -> intent.data
            else -> null
        }

        if (model == null) {
            finish()
            return
        }

        setContent {
            PenikImageViewer(
                model = model,
                message = null,
                listener = null,
                onDismiss = { finish() }
            )
        }
    }

    companion object {
        const val EXTRA_FILE_PATH = "extra_file_path"
        const val EXTRA_URI = "extra_uri"
        const val EXTRA_DISPLAY_NAME = "extra_display_name"

        @JvmStatic
        fun launch(context: Context, file: File, displayName: String? = null) {
            val intent = Intent(context, PenikImageViewerActivity::class.java).apply {
                putExtra(EXTRA_FILE_PATH, file.absolutePath)
                if (displayName != null) {
                    putExtra(EXTRA_DISPLAY_NAME, displayName)
                }
            }
            context.startActivity(intent)
        }

        @JvmStatic
        fun launch(context: Context, uri: Uri, displayName: String? = null) {
            val intent = Intent(context, PenikImageViewerActivity::class.java).apply {
                putExtra(EXTRA_URI, uri.toString())
                if (displayName != null) {
                    putExtra(EXTRA_DISPLAY_NAME, displayName)
                }
            }
            context.startActivity(intent)
        }
    }
}
