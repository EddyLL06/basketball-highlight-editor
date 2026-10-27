package com.bhe.bhe_mobile.diagnostics

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RotatingLogStoreTest {
    private fun withStore(action: (File) -> Unit) {
        val directory = Files.createTempDirectory("bhe-log-test").toFile()
        try { action(directory) } finally { directory.deleteRecursively() }
    }
    @Test fun writesAndReadsOnlyTheRealTail() = withStore { directory ->
        val log = RotatingLogStore(directory)
        log.startup("version=0.1.13+android.1")
        repeat(350) { assertTrue(log.record("event $it")) }
        val tail = log.tail()
        assertEquals(300, tail.size)
        assertTrue(tail.last().contains("event 349"))
        assertFalse(tail.any { it.contains("startup environment") })
        assertEquals(setOf("app.log"), directory.list()!!.toSet())
    }
    @Test fun rotationPinsTheLatestRealStartupAndKeepsOnlyOneOldFile() = withStore { directory ->
        val log = RotatingLogStore(directory, maxBytes = 512)
        log.startup("version=old"); log.startup("version=new")
        repeat(80) { log.record("event-$it " + "x".repeat(60)) }
        assertTrue(File(directory, "app.log").readLines().first().contains("version=new"))
        assertTrue(File(directory, "app.log.1").readLines().first().contains("version=new"))
        assertEquals(setOf("app.log", "app.log.1"), directory.list()!!.toSet())
        directory.listFiles()!!.forEach { assertTrue(it.length() <= 512) }
        assertTrue(log.tail().last().contains("event-79"))
    }
    @Test fun utf8AndHugeRecordsStayWithinTheByteBudget() = withStore { directory ->
        val log = RotatingLogStore(directory, maxBytes = 512)
        log.startup("中文😀")
        repeat(10) { log.record("中文😀".repeat(1000)) }
        directory.listFiles()!!.forEach { assertTrue(it.length() <= 512); assertFalse(it.readText().contains('\uFFFD')) }
        assertTrue(log.tail().any { it.contains("truncated") })
    }
    @Test fun fileErrorsNeverEscape() = withStore { directory ->
        val blocked = File(directory, "not-a-directory").apply { writeText("file") }
        val log = RotatingLogStore(blocked)
        assertFalse(log.record("error")); assertFalse(log.available)
        assertEquals(emptyList<String>(), log.tail()); assertEquals("file", blocked.readText())
    }
    @Test fun duplicateWindowsFoldCountsWithoutSleeping() = withStore { directory ->
        var now = 0L
        val log = RotatingLogStore(directory, clock = { now })
        log.record("app error: boom", "same"); now = 200
        repeat(3) { log.record("app error: boom", "same") }
        log.record("app error: different", "other"); now = 1001; log.flushExpired()
        log.record("app error: boom", "same")
        val text = log.tail().joinToString("\n")
        assertEquals(2, Regex("app error: boom").findAll(text).count())
        assertTrue(text.contains("repeated 3 additional times")); assertTrue(text.contains("different"))
    }
    @Test fun readingFlushesPendingDuplicatesButNeverSynthesizesStartup() = withStore { directory ->
        val log = RotatingLogStore(directory)
        repeat(2) { log.record("app error: boom", "same") }
        val tail = log.tail()
        assertTrue(tail.last().contains("repeated 1 additional times"))
        assertFalse(tail.any { it.contains("startup environment") })
    }
    @Test fun queueIsBoundedAndPreservesOrderOffTheCallerThread() {
        val queue = DiagnosticQueue(3)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val completed = CountDownLatch(2)
        val order = mutableListOf<Int>(); val caller = Thread.currentThread()
        try {
            assertTrue(queue.submit { entered.countDown(); release.await(3, TimeUnit.SECONDS) })
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            assertTrue(queue.submit { assertNotSame(caller, Thread.currentThread()); order.add(1); completed.countDown() })
            assertTrue(queue.submit { order.add(2); completed.countDown() })
            assertFalse(queue.submit { fail("Rejected task executed") }); assertEquals(1, queue.takeDropped())
            release.countDown(); assertTrue(completed.await(3, TimeUnit.SECONDS)); assertEquals(listOf(1, 2), order)
        } finally { release.countDown(); queue.close() }
        assertFalse(queue.submit { fail("Closed queue accepted task") })
    }
}
