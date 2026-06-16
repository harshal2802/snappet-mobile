package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.hr.BleHeartRateSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the fix for issue #90: the first-log auto-session calls BleHeartRateSource.start() without
 * having gone through the board-connect permission flow. On API 31+ scanning without
 * BLUETOOTH_SCAN/_CONNECT throws SecurityException; the pure [hasScanPermissions] gate must default-deny
 * so start() can early-return (skip HR capture) instead of crashing "log an ascent".
 */
class BleHrPermissionGuardTest {

    private val S = android.os.Build.VERSION_CODES.S // API 31

    @Test fun preApi31_alwaysAllowed_regardlessOfGrants() {
        // Below 31 the bluetooth perms are install-time, so the scan path is always allowed.
        assertTrue(BleHeartRateSource.hasScanPermissions(S - 1, scanGranted = false, connectGranted = false))
        assertTrue(BleHeartRateSource.hasScanPermissions(S - 1, scanGranted = true, connectGranted = true))
    }

    @Test fun api31Plus_deniesWhenScanPermissionMissing() {
        assertFalse(BleHeartRateSource.hasScanPermissions(S, scanGranted = false, connectGranted = true))
    }

    @Test fun api31Plus_deniesWhenConnectPermissionMissing() {
        assertFalse(BleHeartRateSource.hasScanPermissions(S, scanGranted = true, connectGranted = false))
    }

    @Test fun api31Plus_deniesWhenBothMissing() {
        assertFalse(BleHeartRateSource.hasScanPermissions(S, scanGranted = false, connectGranted = false))
        assertFalse(BleHeartRateSource.hasScanPermissions(S + 3, scanGranted = false, connectGranted = false))
    }

    @Test fun api31Plus_allowsWhenBothGranted() {
        assertTrue(BleHeartRateSource.hasScanPermissions(S, scanGranted = true, connectGranted = true))
        assertTrue(BleHeartRateSource.hasScanPermissions(S + 3, scanGranted = true, connectGranted = true))
    }
}
