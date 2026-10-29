package com.bhe.bhe_mobile

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class AnalysisWorkerLivenessTest {
    @Test fun cancelledWorkerRemainsActiveUntilItExits() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = Thread { entered.countDown(); release.await() }
        worker.start()
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        try {
            assertTrue(AnalysisWorkerLiveness.isRunning(worker, "cancelled"))
            assertTrue(AnalysisWorkerLiveness.isRunning(null, "running"))
        } finally {
            release.countDown()
            worker.join(5000)
        }
        assertFalse(worker.isAlive)
        assertFalse(AnalysisWorkerLiveness.isRunning(worker, "cancelled"))
    }
}
