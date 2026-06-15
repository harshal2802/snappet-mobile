package com.snappet.mobile.feature.expense

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
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
/**
 * The outcome of an OCR pass (issue #89). Distinguishes a genuine read [Success] from a recognition
 * [Failure] (couldn't open/process the image) and an [Empty] photo (processed fine but no text) so
 * the caller can show an actionable error instead of silently doing nothing.
 */
sealed interface ReceiptScanResult {
    data class Success(val text: String) : ReceiptScanResult
    /** Processed, but no usable text found (e.g. a blank/blurry photo). */
    object Empty : ReceiptScanResult
    /** The recognizer or image load failed outright. */
    object Failure : ReceiptScanResult
}

object ReceiptTextRecognizer {
    /** Recognize the text in the image at [uri], reporting failure / empty distinctly (issue #89). */
    suspend fun recognize(context: Context, uri: Uri): ReceiptScanResult =
        suspendCancellableCoroutine { cont ->
            val image = try {
                InputImage.fromFilePath(context, uri)
            } catch (e: Exception) {
                cont.resume(ReceiptScanResult.Failure)
                return@suspendCancellableCoroutine
            }
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            recognizer.process(image)
                .addOnSuccessListener { result ->
                    cont.resume(
                        if (result.text.isBlank()) ReceiptScanResult.Empty
                        else ReceiptScanResult.Success(result.text),
                    )
                }
                .addOnFailureListener { cont.resume(ReceiptScanResult.Failure) }
        }
}

/**
 * Returns a launch lambda that opens the system camera to photograph a receipt, then OCRs it and
 * reports the [ReceiptScanResult] via [onResult]. Uses ACTION_IMAGE_CAPTURE via a FileProvider temp
 * file, so no CAMERA permission is required. The text flows into [ReceiptParser] at the call site;
 * failure/empty outcomes let the caller surface an actionable error (issue #89).
 */
@Composable
fun rememberReceiptScanner(onResult: (ReceiptScanResult) -> Unit): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // rememberSaveable (Uri is Parcelable) so the pending capture survives a config change or
    // process death while the camera activity is foregrounded — otherwise the returned photo would
    // come back with a null Uri and be silently dropped.
    var pendingUri by rememberSaveable { mutableStateOf<Uri?>(null) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        val uri = pendingUri
        if (success && uri != null) {
            scope.launch { onResult(ReceiptTextRecognizer.recognize(context, uri)) }
        }
    }

    return {
        val file = File.createTempFile("receipt_", ".jpg", context.cacheDir)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        pendingUri = uri
        launcher.launch(uri)
    }
}
