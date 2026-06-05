package com.snappet.mobile.core

/**
 * Test-only switches read at activity startup. The Android analogue of the iOS
 * `-uiTestFreshStore` launch argument: a UI test sets [freshInMemoryStore] before launching
 * the activity so the suite comes up against an empty, isolated in-memory store.
 */
object TestHooks {
    @Volatile var freshInMemoryStore: Boolean = false

    /**
     * When set, [com.snappet.mobile.MainActivity] installs the synthetic Kilter catalog fixture (zero
     * Aurora data) before the UI comes up, so the Kilter browse instrumented tests have data. The app
     * ships no catalog (issue #42); leaving this false brings the module up in its opt-in import state.
     */
    @Volatile var installKilterCatalogFixture: Boolean = false
}
