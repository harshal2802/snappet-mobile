package com.snappet.mobile.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Process-wide pending navigation, set from a launch [android.content.Intent] (a `snappet://` deep
 * link, a launcher shortcut, or a widget tap) and consumed once by the shell. Mirrors the iOS
 * `SuiteRouter`. Owned on [AppContainer] so it survives recomposition; the shell observes
 * [pendingRoute] and clears it after honoring it.
 *
 * Routes (issues #91, #99):
 * - [Route.Module] — open a module by id (launcher shortcuts, widget taps, Home cards).
 * - [Route.KilterClimb] — open a specific Kilter climb at an angle (`snappet://kilter/climb/...`).
 */
class SuiteRouter {

    sealed interface Route {
        data class Module(val moduleId: String) : Route
        data class KilterClimb(val uuid: String, val angle: Int?) : Route
        /** Open Kilter directly on its plan-home (the Home "Resume climbing session" card). */
        data object KilterPlan : Route
    }

    var pendingRoute by mutableStateOf<Route?>(null)
        private set

    fun request(route: Route) { pendingRoute = route }

    /** Open a module by id (shortcut / widget / Home card). No-op for an unknown id. */
    fun openModule(moduleId: String) {
        if (ModuleRegistry.byId(moduleId) != null) pendingRoute = Route.Module(moduleId)
    }

    /** Parse + queue a `snappet://` link; returns true if it was a recognized route. */
    fun handleUri(uri: String?): Boolean {
        if (uri == null) return false
        // snappet://module/<id> — used by static launcher shortcuts to open a module/editor (issue #99).
        moduleIdFromUri(uri)?.let { id ->
            if (ModuleRegistry.byId(id) != null) { pendingRoute = Route.Module(id); return true }
        }
        // snappet://kilter/climb/<uuid>?angle=<n> — a shared climb (issue #91).
        val link = com.snappet.mobile.feature.kilter.share.KilterDeepLink.parse(uri) ?: return false
        pendingRoute = Route.KilterClimb(link.uuid, link.angle)
        return true
    }

    private fun moduleIdFromUri(uri: String): String? {
        val s = uri.trim()
        val prefix = "snappet://module/"
        if (!s.startsWith(prefix, ignoreCase = true)) return null
        val id = s.removePrefix(prefix).substringBefore('?').trim('/')
        return id.ifEmpty { null }
    }

    /** Called by the shell once it has consumed the route. */
    fun consume() { pendingRoute = null }
}
