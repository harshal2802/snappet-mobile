package com.snappet.mobile.feature.journal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure tests for the staged-delete set algebra (issue #89, review fix). The bug being guarded:
 * `SnackbarController.showUndo` dismisses the current snackbar before showing the next, which fires
 * the previous one's `commit`. With a single `pendingDeleteId` that commit cleared the *new* still-
 * pending id too, un-hiding a row mid-delete. As a `Set`, each commit/undo removes only its own id.
 */
class PendingDeletesTest {

    @Test fun stage_hidesId() {
        val s = PendingDeletes.stage(emptySet(), 7L)
        assertTrue(7L in s)
    }

    @Test fun unstage_revealsOnlyThatId() {
        val s = PendingDeletes.stage(PendingDeletes.stage(emptySet(), 1L), 2L)
        val after = PendingDeletes.unstage(s, 1L)
        assertFalse(1L in after)
        assertTrue("undoing 1 must not reveal 2", 2L in after)
    }

    @Test fun commitFirst_keepsSecondPending() {
        // Delete 1, then delete 2 (which dismisses 1's snackbar -> fires 1's commit). The second
        // row must STAY hidden — this is the exact clobber the single-id version had.
        var pending: Set<Long> = emptySet()
        pending = PendingDeletes.stage(pending, 1L)
        pending = PendingDeletes.stage(pending, 2L)
        // 1's commit fires as 2 is staged:
        pending = PendingDeletes.commit(pending, 1L)
        assertEquals(setOf(2L), pending)
        assertTrue("the second pending row must remain hidden", 2L in pending)
    }

    @Test fun committingMissingId_isNoOp() {
        val s = PendingDeletes.stage(emptySet(), 5L)
        assertEquals(setOf(5L), PendingDeletes.commit(s, 99L))
    }

    @Test fun fullLifecycle_independentPerId() {
        var p: Set<Long> = emptySet()
        p = PendingDeletes.stage(p, 10L)
        p = PendingDeletes.stage(p, 20L)
        p = PendingDeletes.unstage(p, 10L)   // user undoes 10
        p = PendingDeletes.commit(p, 20L)    // 20's snackbar times out, real delete fires
        assertTrue("undone id reappears", 10L !in p)
        assertTrue("committed id gone", 20L !in p)
        assertTrue(p.isEmpty())
    }
}
