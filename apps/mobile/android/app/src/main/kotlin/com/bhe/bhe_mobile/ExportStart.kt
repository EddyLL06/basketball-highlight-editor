package com.bhe.bhe_mobile

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Only roll back a reservation that this invocation actually acquired. */
internal object ExportStart {
    fun claimFlag(flags: ConcurrentHashMap<String, AtomicBoolean>, id: String): AtomicBoolean? {
        val flag = AtomicBoolean(false)
        return if (flags.putIfAbsent(id, flag) == null) flag else null
    }

    fun acquire(reserve: () -> Boolean, start: () -> Boolean, rollback: () -> Unit): Boolean {
        if (!reserve()) return false
        try {
            if (start()) return true
        } catch (error: Throwable) {
            rollback()
            throw error
        }
        rollback()
        return false
    }

    fun launch(startThread: () -> Unit, rollback: () -> Unit) {
        try { startThread() } catch (error: Throwable) { rollback(); throw error }
    }
}
