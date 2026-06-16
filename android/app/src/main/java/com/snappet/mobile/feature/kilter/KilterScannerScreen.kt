package com.snappet.mobile.feature.kilter

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.snappet.mobile.feature.kilter.share.KilterDeepLink
import com.snappet.mobile.ui.LocalAppContainer
import com.snappet.mobile.ui.ModuleScaffold
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

/**
 * On-device QR scanner (issue #91) using CameraX + ML Kit barcode. Decoded text is parsed by the pure
 * [KilterDeepLink]; a valid `snappet://kilter/climb/<uuid>` resolves to a catalog or created climb and
 * opens its detail (the encoded angle is persisted so detail opens there). A QR for a climb not in the
 * user's catalog shows the "not in your catalog" fallback rather than a blank screen.
 *
 * The parse + resolve are pure/tested; the live camera scan is **device-pending** (no emulator camera).
 * Persisting the encoded angle reuses [KilterSettings] so the resolved climb opens at the shared angle.
 */
@Composable
fun KilterScannerScreen(
    onResolved: (uuid: String) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var status by remember { mutableStateOf<String?>(null) }
    var handled by remember { mutableStateOf(false) }
    var hasCamera by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> hasCamera = granted }
    LaunchedEffect(Unit) { if (!hasCamera) permissionLauncher.launch(Manifest.permission.CAMERA) }

    // Resolve a scanned link: parse → persist angle → verify the climb exists → open or report.
    suspend fun resolve(rawText: String) {
        if (handled) return
        val link = KilterDeepLink.parse(rawText) ?: run {
            status = "That QR isn't a Snappet climb."
            return
        }
        handled = true
        link.angle?.let { KilterSettings.setAngle(context, it) }
        val dao = container.database.kilterDao()
        // The catalog lookup mirrors the detail screen's resolve order (catalog → created).
        val catalog = KilterCatalog.get(context)
        val inCatalog = catalog.climb(link.uuid) != null
        val created = dao.createdByUuid(link.uuid) != null
        if (inCatalog || created) {
            onResolved(link.uuid)
        } else {
            handled = false
            status = "That climb isn't in your catalog yet. Ask the sender for its hold string to re-create it."
        }
    }

    ModuleScaffold(title = "Scan a climb", onExit = onExit) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            if (!hasCamera) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(32.dp).testTag("kilter.scan.noCamera"),
                ) {
                    Text("Camera access needed", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Snappet uses the camera only to read a shared climb's QR code — nothing is saved or sent.",
                        style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                        Text("Allow camera")
                    }
                }
            } else {
                CameraScanner(onText = { text -> scope.launch { resolve(text) } })
                status?.let { msg ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                        Text(
                            msg, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(24.dp).testTag("kilter.scan.status"),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CameraScanner(onText: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val scanner = remember { BarcodeScanning.getClient() }
    // Hold the bound provider so onDispose can unbind it when the scanner leaves composition.
    val providerRef = remember { java.util.concurrent.atomic.AtomicReference<ProcessCameraProvider?>(null) }

    // Free the analysis thread + native ML Kit client (and unbind the camera) on teardown so the
    // single-thread executor and BarcodeScanner don't leak each time the scanner is shown.
    DisposableEffect(Unit) {
        onDispose {
            runCatching { providerRef.getAndSet(null)?.unbindAll() }
            runCatching { analysisExecutor.shutdown() }
            runCatching { scanner.close() }
        }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize().testTag("kilter.scan.preview"),
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val provider = providerFuture.get()
                providerRef.set(provider)
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                val analysis = ImageAnalysis.Builder()
                    .setTargetResolution(Size(1280, 720))
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { proxy ->
                    @Suppress("UnsafeOptInUsageError")
                    val media = proxy.image
                    if (media == null) { proxy.close(); return@setAnalyzer }
                    val image = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
                    scanner.process(image)
                        .addOnSuccessListener { barcodes ->
                            barcodes.firstOrNull { it.valueType == Barcode.TYPE_TEXT || it.rawValue != null }
                                ?.rawValue?.let(onText)
                        }
                        .addOnCompleteListener { proxy.close() }
                }
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
    )
}
