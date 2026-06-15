package com.snappet.mobile.feature.kilter.hr

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID

/**
 * Live heart-rate capture over the standard BLE **Heart Rate Profile** (`0x180D` / `0x2A37`),
 * mirroring the iOS `BLEHeartRateMetricsSource`. This is the **thin platform edge**: scan → connect →
 * subscribe → hand each packet to the pure [HRMeasurementParser] / [ingest] logic (which is what the
 * unit tests cover). Live capture from a real strap is device-pending; the parse + ingest + RR-trust
 * decisions are pure and tested.
 *
 * Reuses [com.snappet.mobile.feature.kilter.KilterBoardController]'s permission/scan patterns. The
 * caller is responsible for requesting `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` first (same as the board).
 */
class BleHeartRateSource(context: Context) {

    enum class State { UNSUPPORTED, IDLE, SCANNING, CONNECTING, STREAMING, FAILED }

    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = manager?.adapter
    private val handler = Handler(Looper.getMainLooper())

    var state by mutableStateOf(if (adapter == null) State.UNSUPPORTED else State.IDLE)
        private set

    /** Latest bpm, or null before the first sample. Drives the live pill. */
    var latestBpm by mutableStateOf<Int?>(null)
        private set

    /** True when the strap reports lost skin contact (orange "adjust strap" hint). */
    var isContactLost by mutableStateOf(false)
        private set

    private var gatt: BluetoothGatt? = null
    private var scanner = adapter?.bluetoothLeScanner
    private var sessionStartMillis: Long? = null
    private var deviceName: String = ""
    private var modelNumber: String = ""

    /** The accumulating series (session-relative seconds). Read at session end for the summary. */
    private val samples = ArrayList<HRSample>()
    fun snapshotSeries(): List<HRSample> = synchronized(samples) { ArrayList(samples) }

    val isStreaming: Boolean get() = state == State.STREAMING

    /** Begin scanning for a strap. [startMillis] anchors sample offsets to the session start. */
    @SuppressLint("MissingPermission")
    fun start(startMillis: Long) {
        if (adapter == null) { state = State.UNSUPPORTED; return }
        if (!adapter.isEnabled) { state = State.FAILED; return }
        sessionStartMillis = startMillis
        synchronized(samples) { samples.clear() }
        scanner = adapter.bluetoothLeScanner
        state = State.SCANNING
        val filter = ScanFilter.Builder()
            .setServiceUuid(android.os.ParcelUuid(HR_SERVICE)).build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner?.startScan(listOf(filter), settings, scanCallback)
        // Watchdog: stop scanning if nothing turns up (mirrors the board controller's timeout).
        handler.postDelayed({ if (state == State.SCANNING) { stopScan(); state = State.FAILED } }, SCAN_TIMEOUT_MS)
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        stopScan()
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        if (state != State.UNSUPPORTED) state = State.IDLE
        latestBpm = null
        isContactLost = false
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        runCatching { scanner?.stopScan(scanCallback) }
        handler.removeCallbacksAndMessages(null)
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (state != State.SCANNING) return
            stopScan()
            deviceName = result.device.name ?: ""
            connect(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            if (state == State.SCANNING) state = State.FAILED
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(device: BluetoothDevice) {
        state = State.CONNECTING
        gatt = device.connectGatt(appContext, false, gattCallback)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (state == State.STREAMING || state == State.CONNECTING) state = State.IDLE
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            // Read the model number (device-info service) so RR can be trust-gated by hardware.
            g.getService(DEVICE_INFO_SERVICE)?.getCharacteristic(MODEL_NUMBER_CHAR)?.let {
                runCatching { g.readCharacteristic(it) }
            }
            val hrChar = g.getService(HR_SERVICE)?.getCharacteristic(HR_MEASUREMENT_CHAR)
            if (hrChar == null) { state = State.FAILED; return }
            g.setCharacteristicNotification(hrChar, true)
            hrChar.getDescriptor(CCCD)?.let { desc ->
                desc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                runCatching { g.writeDescriptor(desc) }
            }
            state = State.STREAMING
        }

        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (ch.uuid == MODEL_NUMBER_CHAR) {
                modelNumber = runCatching { ch.getStringValue(0) }.getOrNull()?.trim() ?: ""
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid != HR_MEASUREMENT_CHAR) return
            val raw = ch.value ?: return
            handleMeasurement(raw)
        }
    }

    /** Decode + ingest one raw `0x2A37` packet. Split out so the ingest path is unit-testable. */
    private fun handleMeasurement(raw: ByteArray) {
        val m = HRMeasurementParser.parse(raw) ?: return
        ingest(m, System.currentTimeMillis())
    }

    /**
     * Pure-ish ingest: applies contact-lost dropping, RR trust gating, and session-relative offset.
     * Exposed `internal` so tests can drive it without a GATT.
     */
    @Synchronized
    internal fun ingest(m: HRMeasurementParser.Measurement, receivedAtMillis: Long) {
        when (m.contact) {
            false -> { isContactLost = true; return }   // contact lost → drop, surface the hint
            true -> isContactLost = false
            null -> Unit                                 // band can't report → ingest normally
        }
        latestBpm = m.bpm
        val start = sessionStartMillis ?: receivedAtMillis
        val offset = ((receivedAtMillis - start).coerceAtLeast(0L)) / 1000.0
        val trustedRr = if (rrTrusted(modelNumber, deviceName)) m.rrIntervalsMs else null
        synchronized(samples) { samples.add(HRSample(t = offset, bpm = m.bpm, rrIntervalsMs = trustedRr)) }
    }

    companion object {
        private val HR_SERVICE = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        private val HR_MEASUREMENT_CHAR = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val DEVICE_INFO_SERVICE = UUID.fromString("0000180a-0000-1000-8000-00805f9b34fb")
        private val MODEL_NUMBER_CHAR = UUID.fromString("00002a24-0000-1000-8000-00805f9b34fb")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val SCAN_TIMEOUT_MS = 15_000L

        /**
         * Default-deny RR trust: RR/HRV is only believable from a real chest strap (optical wrist/ring
         * sensors emit derived, unreliable RR). Ported from the iOS `rrTrusted`. The optical blacklist
         * is checked FIRST so "TICKR FIT" (optical) is rejected before the "tickr" whitelist match.
         */
        fun rrTrusted(modelNumber: String, deviceName: String): Boolean {
            val id = "$modelNumber $deviceName".lowercase().trim()
            if (id.isEmpty()) return false
            val opticalBlacklist = listOf(
                "fit", "oh1", "verity", "scosche", "rhythm", "fitbit", "whoop",
                "apple watch", "wrist", "armband", "ring",
            )
            if (opticalBlacklist.any { id.contains(it) }) return false
            val chestWhitelist = listOf(
                "polar h", "hrm", "tickr", "movesense", "frontier", "wahoo",
                "garmin", "coospo h", "magene h", "decathlon dual", "chest",
            )
            return chestWhitelist.any { id.contains(it) }
        }
    }
}
