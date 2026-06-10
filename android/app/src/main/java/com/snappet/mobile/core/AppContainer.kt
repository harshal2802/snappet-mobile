package com.snappet.mobile.core

import android.content.Context

/**
 * Process-wide dependency holder — the one place the Room store and [SnappetCore] are wired,
 * mirroring the iOS `AppModel`. No DI framework; a single lazily-built instance injected via
 * a Compose `CompositionLocal` ([com.snappet.mobile.LocalAppContainer]).
 */
class AppContainer private constructor(val database: SnappetDatabase) {
    val core: SnappetCore by lazy { SnappetCore(database.usageDao()) }
    /** Export/import of the whole store as one SAF file (issue #84). */
    val backup: SnappetBackupManager by lazy { SnappetBackupManager(database) }

    companion object {
        @Volatile private var instance: AppContainer? = null

        /**
         * Returns the shared container, building the store on first use. When [freshInMemory]
         * is set (UI tests), it always rebuilds against a throwaway in-memory database so each
         * test run starts from an empty, isolated store — the Android analogue of the iOS
         * `-uiTestFreshStore` launch argument.
         */
        fun get(context: Context, freshInMemory: Boolean = false): AppContainer {
            if (freshInMemory) {
                val fresh = AppContainer(SnappetDatabase.buildInMemory(context.applicationContext))
                instance = fresh
                return fresh
            }
            return instance ?: synchronized(this) {
                instance ?: AppContainer(SnappetDatabase.build(context.applicationContext)).also { instance = it }
            }
        }
    }
}
