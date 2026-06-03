package com.snappet.mobile.feature.kilter

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.ArrayDeque
import java.util.UUID

/**
 * Drives the physical Kilter board over Bluetooth LE: scan → connect → write the illumination
 * packets built by [KilterProtocol]. On-device only (local radio; no network). Mirrors the iOS
 * `KilterBoardController`.
 *
 * ⚠️ Device-unverified. The GATT UUIDs and packet format follow the community Aurora reverse
 * engineering and have **not** been confirmed on hardware — must not be reported as working until
 * validated. Inert until the user taps Connect; Phase 1 never touches it. Callers must hold the
 * BLUETOOTH_SCAN / BLUETOOTH_CONNECT runtime permissions (the UI requests them first).
 */
class KilterBoardController(context: Context) {

    enum class State { UNSUPPORTED, BLUETOOTH_OFF, IDLE, SCANNING, CONNECTING, CONNECTED, FAILED }

    var state by mutableStateOf(State.IDLE)
        private set
    /** Human-readable reason shown when [state] is [State.FAILED]. */
    var failureMessage by mutableStateOf<String?>(null)
        private set
    val isConnected: Boolean get() = state == State.CONNECTED
    /** Notified when the connection comes up / goes down, so the module can open/close a session. */
    var onConnectionChange: ((Boolean) -> Unit)? = null

    private val appContext = context.applicationContext
    private val adapter = (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var pending: List<KilterHold>? = null
    /** Sequential write queue — BLE allows one outstanding write at a time. */
    private val writeQueue = ArrayDeque<ByteArray>()
    private val main = Handler(Looper.getMainLooper())
    /** Watchdog that fails the attempt if scan/connect/discovery stalls (BLE never times out itself). */
    private var timeout: Runnable? = null

    @SuppressLint("MissingPermission")
    fun connect() {
        // Order matters: a disabled adapter returns a null `bluetoothLeScanner`, so check "off"
        // (recoverable — the user can toggle Bluetooth) before "unsupported" (no radio at all).
        if (adapter == null) { state = State.UNSUPPORTED; return }
        if (!adapter.isEnabled) { state = State.BLUETOOTH_OFF; return }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) { state = State.UNSUPPORTED; return }
        fail(null)   // clear any prior failure
        state = State.SCANNING
        // No service filter: Aurora boards advertise by name, not service UUID (see [isLikelyBoard]),
        // so the old service-UUID ScanFilter never discovered them — the "stuck searching" bug.
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(null, settings, scanCallback)
        startTimeout(SCAN_TIMEOUT_MS, "No board found nearby. Make sure it's powered on and within range.")
    }

    /** Cancel an in-flight scan/connect and return to idle (the user backing out of a stuck attempt). */
    @SuppressLint("MissingPermission")
    fun cancel() {
        clearTimeout()
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        gatt?.disconnect(); gatt?.close(); gatt = null
        writeChar = null
        writeQueue.clear()
        if (state == State.SCANNING || state == State.CONNECTING || state == State.FAILED) state = State.IDLE
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        clearTimeout()
        // `gatt.close()` unregisters the callback, so `onConnectionStateChange(DISCONNECTED)` won't
        // fire for a user-initiated disconnect — close the session here instead.
        val wasConnected = isConnected
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        writeChar = null
        writeQueue.clear()
        state = State.IDLE
        if (wasConnected) onConnectionChange?.invoke(false)
    }

    /** Light the given holds (no-op unless connected). Stores them if not yet ready to flush. */
    fun illuminate(holds: List<KilterHold>) {
        val characteristic = writeChar
        if (!isConnected || gatt == null || characteristic == null) {
            pending = holds
            return
        }
        send(holds, characteristic)
    }

    @SuppressLint("MissingPermission")
    private fun send(holds: List<KilterHold>, characteristic: BluetoothGattCharacteristic) {
        val payload = holds.mapNotNull { h -> h.ledPosition?.let { it to h.colorHex } }
        writeQueue.clear()
        writeQueue.addAll(KilterProtocol.messages(payload))
        dequeueWrite(characteristic)
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun dequeueWrite(characteristic: BluetoothGattCharacteristic) {
        val next = writeQueue.poll() ?: return
        val g = gatt ?: return
        characteristic.value = next
        g.writeCharacteristic(characteristic)
    }

    // MARK: - timeout watchdog

    private fun startTimeout(millis: Long, message: String) {
        clearTimeout()
        val task = Runnable { onTimeout(message) }
        timeout = task
        main.postDelayed(task, millis)
    }

    private fun clearTimeout() {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
    }

    @SuppressLint("MissingPermission")
    private fun onTimeout(message: String) {
        if (state != State.SCANNING && state != State.CONNECTING) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        gatt?.disconnect(); gatt?.close(); gatt = null
        writeChar = null
        fail(message)
    }

    private fun fail(message: String?) {
        clearTimeout()
        failureMessage = message
        if (message != null) state = State.FAILED
    }

    @SuppressLint("MissingPermission")
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName ?: runCatching { result.device.name }.getOrNull()
            val services = result.scanRecord?.serviceUuids?.map { it.uuid }
            if (!isLikelyBoard(name, services) || state != State.SCANNING) return
            adapter?.bluetoothLeScanner?.stopScan(this)
            state = State.CONNECTING
            startTimeout(CONNECT_TIMEOUT_MS, "Couldn't reach the board. Move closer and try again.")
            gatt = result.device.connectGatt(appContext, false, gattCallback)
        }

        override fun onScanFailed(errorCode: Int) {
            fail("Couldn't start scanning for a board (error $errorCode).")
        }
    }

    @SuppressLint("MissingPermission")
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                // Keep the watchdog running across discovery — a board with an unexpected GATT
                // layout would otherwise hang here silently.
                startTimeout(CONNECT_TIMEOUT_MS, "Connected, but the board didn't respond. Try again.")
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val wasConnected = isConnected
                clearTimeout()
                g.close()
                gatt = null
                writeChar = null
                writeQueue.clear()
                if (wasConnected) {
                    onConnectionChange?.invoke(false)
                    state = State.IDLE
                } else if (state == State.CONNECTING) {
                    fail("Couldn't connect to the board.")
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val characteristic = g.getService(SERVICE_UUID)?.getCharacteristic(WRITE_UUID)
            if (characteristic == null) {
                gatt?.disconnect()
                fail("This board didn't expose the expected controls.")
                return
            }
            clearTimeout()
            writeChar = characteristic
            failureMessage = null
            state = State.CONNECTED
            onConnectionChange?.invoke(true)
            pending?.let { holds -> pending = null; send(holds, characteristic) }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            dequeueWrite(characteristic)   // flush the next queued packet
        }
    }

    companion object {
        // Aurora/Kilter board GATT (community-sourced — verify against hardware).
        private val SERVICE_UUID: UUID = UUID.fromString("4488b571-7806-4df6-bcff-a2897e4953ff")
        private val WRITE_UUID: UUID = UUID.fromString("4488b572-7806-4df6-bcff-a2897e4953ff")
        private const val SCAN_TIMEOUT_MS = 12_000L
        private const val CONNECT_TIMEOUT_MS = 12_000L

        /**
         * Whether an advertising peripheral looks like an Aurora-family board (Kilter/Tension/etc).
         * Pure so it can be unit-tested off-device. Aurora boards generally do **not** advertise their
         * primary service UUID, only a local name — so name matching is the primary signal.
         */
        fun isLikelyBoard(name: String?, serviceUuids: List<UUID>?): Boolean {
            if (serviceUuids?.contains(SERVICE_UUID) == true) return true
            val lower = name?.lowercase() ?: return false
            return listOf("kilter", "aurora", "tension", "grasshopper", "decoy", "soill").any { lower.contains(it) }
        }
    }
}
