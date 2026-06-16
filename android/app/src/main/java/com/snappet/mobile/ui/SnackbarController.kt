package com.snappet.mobile.ui

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * App-level snackbar surface (issue #89). A single [SnackbarHostState] is hosted once at the suite
 * shell ([RootShell]) and exposed through [LocalSnackbarController] so any mini-app can show commit
 * confirmations, error notices, and — the headline use — **undoable** actions, without each module
 * standing up its own `Scaffold`/`SnackbarHost`.
 *
 * The undo pattern is deliberately built in here so future delete flows reuse it: [showUndo] runs
 * the destructive work only after the snackbar times out *without* the user tapping Undo. The
 * data is Flow-driven, so deferring the DAO call keeps the row on screen until it's truly gone and
 * an Undo tap is a pure no-op (nothing was deleted yet).
 */
class SnackbarController(
    private val hostState: SnackbarHostState,
    private val scope: CoroutineScope,
) {
    /** Show a simple confirmation/error message. Replaces any visible snackbar. */
    fun show(message: String) {
        hostState.currentSnackbarData?.dismiss()
        scope.launch { hostState.showSnackbar(message, duration = SnackbarDuration.Short) }
    }

    /**
     * Show "<message> — Undo". If the user taps Undo, [onUndo] runs and [commit] never does. If the
     * snackbar is dismissed/times out, [commit] runs (the deferred destructive action). Either
     * branch fires exactly once.
     */
    fun showUndo(
        message: String,
        actionLabel: String = "Undo",
        onUndo: () -> Unit = {},
        commit: () -> Unit,
    ) {
        hostState.currentSnackbarData?.dismiss()
        scope.launch {
            val result = hostState.showSnackbar(
                message = message,
                actionLabel = actionLabel,
                withDismissAction = false,
                duration = SnackbarDuration.Long,
            )
            when (result) {
                SnackbarResult.ActionPerformed -> onUndo()
                SnackbarResult.Dismissed -> commit()
            }
        }
    }
}

/** The process-wide snackbar controller; provided at [RootShell], read by any mini-app. */
val LocalSnackbarController = staticCompositionLocalOf<SnackbarController> {
    error("LocalSnackbarController not provided")
}
