package com.snappet.mobile.core

/**
 * Test-only switches read at activity startup. The Android analogue of the iOS
 * `-uiTestFreshStore` launch argument: a UI test sets [freshInMemoryStore] before launching
 * the activity so the suite comes up against an empty, isolated in-memory store.
 */
object TestHooks {
    @Volatile var freshInMemoryStore: Boolean = false
}
