package com.bhe.bhe_mobile

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class MergeOutputTransactionTest {
    private fun atomicReplace(from: File, to: File) {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    @Test fun successReplacesPreviousAndCancellationAfterCommitLoses() {
        val dir = Files.createTempDirectory("merge-tx").toFile()
        try {
            val target = File(dir, "merged.mp4").apply { writeText("old") }
            val temp = File(dir, "temp.mp4").apply { writeText("new") }
            val tx = MergeOutputTransaction(temp, target, AtomicBoolean(false), ::atomicReplace)
            tx.publish { }
            assertFalse(tx.cancel())
            tx.cleanup()
            assertEquals("new", target.readText())
            assertFalse(temp.exists())
        } finally { dir.deleteRecursively() }
    }

    @Test fun cancellationAndReplacementFailureKeepPreviousAndCleanOnlyOwnTemp() {
        for (cancel in listOf(true, false)) {
            val dir = Files.createTempDirectory("merge-tx").toFile()
            try {
                val target = File(dir, "merged.mp4").apply { writeText("old") }
                val temp = File(dir, "temp.mp4").apply { writeText("new") }
                val other = File(dir, "other.mp4").apply { writeText("other") }
                val tx = MergeOutputTransaction(temp, target, AtomicBoolean(false)) { _, _ -> throw IOException("injected rename failure") }
                if (cancel) assertTrue(tx.cancel())
                assertThrows(if (cancel) InterruptedException::class.java else IOException::class.java) { tx.publish { } }
                tx.cleanup()
                assertEquals("old", target.readText())
                assertEquals("other", other.readText())
                assertFalse(temp.exists())
            } finally { dir.deleteRecursively() }
        }
    }

    @Test fun emptyTemporaryCannotReplacePrevious() {
        val dir = Files.createTempDirectory("merge-tx").toFile()
        try {
            val target = File(dir, "merged.mp4").apply { writeText("old") }
            val temp = File(dir, "temp.mp4").apply { createNewFile() }
            val tx = MergeOutputTransaction(temp, target, AtomicBoolean(false), ::atomicReplace)
            assertThrows(IllegalStateException::class.java) { tx.publish { } }
            tx.cleanup()
            assertEquals("old", target.readText())
        } finally { dir.deleteRecursively() }
    }

    @Test fun concurrentCancelWaitsForInProgressAtomicPublication() {
        val dir = Files.createTempDirectory("merge-tx").toFile()
        try {
            val target = File(dir, "merged.mp4").apply { writeText("old") }
            val temp = File(dir, "temp.mp4").apply { writeText("new") }
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val tx = MergeOutputTransaction(temp, target, AtomicBoolean(false)) { from, to ->
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                atomicReplace(from, to)
            }
            val published = Thread { tx.publish { } }.apply { start() }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            var cancelled: Boolean? = null
            val cancelling = Thread { cancelled = tx.cancel() }.apply { start() }
            release.countDown()
            published.join(5000); cancelling.join(5000)
            assertEquals(false, cancelled)
            assertEquals("new", target.readText())
            tx.cleanup()
        } finally { dir.deleteRecursively() }
    }
}
