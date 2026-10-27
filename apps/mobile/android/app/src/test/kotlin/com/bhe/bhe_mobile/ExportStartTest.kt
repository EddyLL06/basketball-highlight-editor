package com.bhe.bhe_mobile

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class ExportStartTest {
    @Test fun duplicateIdKeepsExistingCancellationFlag() {
        val flags = ConcurrentHashMap<String, AtomicBoolean>()
        val existing = ExportStart.claimFlag(flags, "same")!!
        assertNull(ExportStart.claimFlag(flags, "same"))
        assertSame(existing, flags["same"])
        existing.set(true)
        assertTrue(flags["same"]!!.get())
    }

    @Test fun failureAfterReservationRollsBackOnlyOwned() {
        var rolledBack = 0
        assertFalse(ExportStart.acquire({ false }, { true }, { rolledBack++ }))
        assertEquals(0, rolledBack)
        assertFalse(ExportStart.acquire({ true }, { false }, { rolledBack++ }))
        assertEquals(1, rolledBack)
        try {
            ExportStart.acquire({ true }, { throw IllegalStateException("canonical path") }, { rolledBack++ })
            fail("expected exception")
        } catch (_: IllegalStateException) { }
        assertEquals(2, rolledBack)
    }

    @Test fun threadStartFailureReleasesReservation() {
        var rolledBack = 0
        try {
            ExportStart.launch({ throw IllegalThreadStateException() }, { rolledBack++ })
            fail("expected exception")
        } catch (_: IllegalThreadStateException) { }
        assertEquals(1, rolledBack)
    }
}
