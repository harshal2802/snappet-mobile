package com.snappet.mobile.feature.kilter

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
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

    enum class State { UNSUPPORTED, IDLE, SCANNING, CONNECTING, CONNECTED, FAILED }

    var state by mutableStateOf(State.IDLE)
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

    @SuppressLint("MissingPermission")
    fun connect() {
        val scanner = adapter?.bluetoothLeScanner
        if (adapter == null || !adapter.isEnabled || scanner == null) {
            state = State.UNSUPPORTED
            return
        }
        state = State.SCANNING
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        writeChar = null
        writeQueue.clear()
        state = State.IDLE
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

    @SuppressLint("MissingPermission")
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            adapter?.bluetoothLeScanner?.stopScan(this)
            state = State.CONNECTING
            gatt = result.device.connectGatt(appContext, false, gattCallback)
        }

        override fun onScanFailed(errorCode: Int) {
            state = State.FAILED
        }
    }

    @SuppressLint("MissingPermission")
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                g.close()
                gatt = null
                writeChar = null
                state = State.IDLE
                onConnectionChange?.invoke(false)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val characteristic = g.getService(SERVICE_UUID)?.getCharacteristic(WRITE_UUID)
            if (characteristic == null) {
                state = State.FAILED
                return
            }
            writeChar = characteristic
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
    }
}
