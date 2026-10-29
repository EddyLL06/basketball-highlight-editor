package com.bhe.bhe_mobile.diagnostics

import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Bounded, non-blocking submission. The worker owns all I/O and flush timers. */
class DiagnosticQueue(private val capacity: Int = 256) : AutoCloseable {
    private val pending = AtomicInteger()
    private val dropped = AtomicInteger()
    private val executor = ScheduledThreadPoolExecutor(1) { task ->
        Thread(task, "BHE-Diagnostics").apply { isDaemon = true }
    }

    fun submit(action: () -> Unit): Boolean {
        if (pending.incrementAndGet() > capacity) {
            pending.decrementAndGet(); dropped.incrementAndGet(); return false
        }
        return try {
            executor.execute {
                try { action() } catch (_: Exception) { /* Logging must not break callers. */ }
                finally { pending.decrementAndGet() }
            }
            true
        } catch (_: Exception) {
            pending.decrementAndGet(); false
        }
    }

    fun tick(action: () -> Unit) {
        executor.scheduleWithFixedDelay({ try { action() } catch (_: Exception) {} }, 1, 1, TimeUnit.SECONDS)
    }
    fun takeDropped(): Int = dropped.getAndSet(0)
    override fun close() { executor.shutdown(); executor.awaitTermination(2, TimeUnit.SECONDS) }
}
