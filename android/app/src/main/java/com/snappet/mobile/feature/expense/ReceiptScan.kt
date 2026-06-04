package com.snappet.mobile.feature.expense

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume

/**
 * On-device receipt OCR for Android — the mirror of the iOS `ReceiptScanner` /
 * `ReceiptDocumentScanner`. The camera capture + ML Kit text recognition is the thin platform
 * edge; the recognized text is handed to the pure, unit-tested [ReceiptParser]. Device-only
 * (needs a camera and the bundled ML Kit model), so it isn't exercised in the JVM unit suite.
 */
object ReceiptTextRecognizer {
    /** Recognize the text in the image at [uri]. Returns "" on failure (caller treats as a no-op). */
    suspend fun recognize(context: Context, uri: Uri): String =
        suspendCancellableCoroutine { cont ->
            val image = try {
                InputImage.fromFilePath(context, uri)
            } catch (e: Exception) {
                cont.resume("")
                return@suspendCancellableCoroutine
            }
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            recognizer.process(image)
                .addOnSuccessListener { result -> cont.resume(result.text) }
                .addOnFailureListener { cont.resume("") }
        }
}

/**
 * Returns a launch lambda that opens the system camera to photograph a receipt, then OCRs it and
 * calls [onText] with the recognized text. Uses ACTION_IMAGE_CAPTURE via a FileProvider temp file,
 * so no CAMERA permission is required. The text flows into [ReceiptParser] at the call site.
 */
@Composable
fun rememberReceiptScanner(onText: (String) -> Unit): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingUri by remember { mutableStateOf<Uri?>(null) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        val uri = pendingUri
        if (success && uri != null) {
            scope.launch { onText(ReceiptTextRecognizer.recognize(context, uri)) }
        }
    }

    return {
        val file = File.createTempFile("receipt_", ".jpg", context.cacheDir)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        pendingUri = uri
        launcher.launch(uri)
    }
}
