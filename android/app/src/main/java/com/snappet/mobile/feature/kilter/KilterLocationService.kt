package com.snappet.mobile.feature.kilter

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.Granularity
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * A thin, when-in-use [com.google.android.gms.location.FusedLocationProviderClient] wrapper that
 * publishes the device's **current coarse place** for the pre-connect arrival suggestion (Flow 1,
 * Option B) — the Android port of the iOS `KilterLocationService`. It is deliberately minimal: a single
 * coarse fix ([Granularity.GRANULARITY_COARSE] / [Priority.PRIORITY_BALANCED_POWER_ACCURACY]), bucketed
 * immediately into a [CoarsePlace], and **never reverse-geocoded, never networked** — the coarse value
 * stays on the device.
 *
 * Authorization is requested **lazily** (only when the feature is actually used, via the caller's
 * permission launcher) and every denied / unavailable path degrades to a `null` place so the module falls
 * back to BLE-only with no crash and no prompt loop. Compose-observable like [KilterBoardController] so the
 * root/Settings recompose when the place or authorization changes.
 *
 * ⚠️ The live FusedLocation fix is device/emulator-pending (like iOS); the pure place bucketing
 * ([CoarsePlace]) + place match ([KilterBoardMemoryRules.suggestion]) are what the unit tests exercise.
 */
class KilterLocationService(context: Context) {

    /** Authorization state, mapped to a small enum the UI can switch on without importing the framework. */
    enum class Authorization { NOT_DETERMINED, DENIED, AUTHORIZED }

    /** The most recent coarse place, or `null` when location is unavailable / not yet resolved. Bucketed
     *  (≈110 m) the instant a fix arrives; the precise coordinate is dropped immediately. */
    var currentPlace by mutableStateOf<CoarsePlace?>(null)
        private set

    var authorization by mutableStateOf(Authorization.NOT_DETERMINED)
        private set

    /** Whether the feature is usable — derived from the current authorization (the UI hides the feature
     *  entirely when denied, rather than show a dead toggle). */
    val isSupported: Boolean get() = authorization != Authorization.DENIED

    private val appContext = context.applicationContext
    private val client = LocationServices.getFusedLocationProviderClient(appContext)
    /** Guards the single one-shot retry per request so a failing fix can't trigger a storm. */
    private var didRetryThisRequest = false

    init {
        authorization = if (hasCoarsePermission()) Authorization.AUTHORIZED else Authorization.NOT_DETERMINED
    }

    /** Whether the COARSE (or finer) location permission is currently granted. */
    private fun hasCoarsePermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Re-read the live permission state and, when authorized, grab one fresh coarse fix. Call this on entry
     * (after the optional runtime request resolves) so the suggestion can appear without another tap. The
     * runtime *prompt* itself is the caller's responsibility (Compose's permission launcher); this never
     * prompts, so it's a safe no-op once denied — no prompt loop.
     */
    fun refresh() {
        authorization = if (hasCoarsePermission()) Authorization.AUTHORIZED else
            // Distinguish "never asked" from "said no": only the caller's launcher result flips DENIED, so
            // before any ask we stay NOT_DETERMINED; after a denied ask the caller calls [onPermissionResult].
            if (authorization == Authorization.DENIED) Authorization.DENIED else Authorization.NOT_DETERMINED
        if (authorization == Authorization.AUTHORIZED) requestFix()
    }

    /**
     * Fold a runtime-permission launcher result into the authorization state (the caller drives the actual
     * `ActivityResultContracts.RequestPermission` prompt). Granted → grab the first coarse fix so the
     * suggestion can appear without another tap; denied → BLE-only, place cleared, no further prompts.
     */
    fun onPermissionResult(granted: Boolean) {
        if (granted) {
            authorization = Authorization.AUTHORIZED
            requestFix()
        } else {
            authorization = Authorization.DENIED
            currentPlace = null
        }
    }

    /** Start a one-shot coarse fix, resetting the per-request retry guard. No-op unless authorized. */
    @SuppressLint("MissingPermission")
    private fun requestFix() {
        if (!hasCoarsePermission()) return
        didRetryThisRequest = false
        val request = CurrentLocationRequest.Builder()
            // Coarse by design: never ask for precise location for a gym-bucket match.
            .setGranularity(Granularity.GRANULARITY_COARSE)
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .build()
        client.getCurrentLocation(request, null)
            .addOnSuccessListener { location ->
                if (location == null) { retryOnce(); return@addOnSuccessListener }
                // Bucket immediately and drop the precise coordinate — only the coarse square is ever kept.
                currentPlace = CoarsePlace.bucket(location.latitude, location.longitude)
                didRetryThisRequest = false
            }
            .addOnFailureListener {
                // A failed fix is not fatal — keep the last known place (if any) and stay BLE-capable.
                retryOnce()
            }
    }

    /** Allow exactly one bounded retry per request (a first failure is often a transient indoor miss). */
    @SuppressLint("MissingPermission")
    private fun retryOnce() {
        if (didRetryThisRequest || !hasCoarsePermission()) return
        didRetryThisRequest = true
        val request = CurrentLocationRequest.Builder()
            .setGranularity(Granularity.GRANULARITY_COARSE)
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .build()
        client.getCurrentLocation(request, null).addOnSuccessListener { location ->
            if (location != null) currentPlace = CoarsePlace.bucket(location.latitude, location.longitude)
        }
    }

    companion object {
        /** The runtime permission the caller's launcher requests for the arrival suggestion. */
        const val PERMISSION = Manifest.permission.ACCESS_COARSE_LOCATION
    }
}
