package com.bhe.bhe_mobile

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ExportPathRegistryTest {
    @Test fun reservesCanonicalPathsBeforeStart() {
        val dir = Files.createTempDirectory("bhe-path-test").toFile()
        val path = File(dir, "out.mp4").path
        val alias = File(dir, "sub/../out.mp4").path
        try {
            assertTrue(ExportPathRegistry.reserve("test-a", path))
            assertFalse(ExportPathRegistry.reserve("test-b", alias))
            assertFalse(ExportPathRegistry.start("test-a", File(dir, "other.mp4").path))
            assertTrue(ExportPathRegistry.start("test-a", path))
            ExportPathRegistry.releaseIdle("test-a")
            assertFalse(ExportPathRegistry.reserve("test-b", path))
            ExportPathRegistry.finish("test-a")
            assertTrue(ExportPathRegistry.reserve("test-b", path))
            ExportPathRegistry.releaseIdle("test-b")
            assertTrue(ExportPathRegistry.reserve("test-c", path))
        } finally {
            listOf("test-a", "test-b", "test-c").forEach(ExportPathRegistry::finish)
            dir.deleteRecursively()
        }
    }

    @Test fun differentPathsCanReserveButSameIdCannot() {
        val dir = Files.createTempDirectory("bhe-path-test").toFile()
        try {
            assertTrue(ExportPathRegistry.reserve("test-x", File(dir, "a.mp4").path))
            assertFalse(ExportPathRegistry.reserve("test-x", File(dir, "b.mp4").path))
            assertTrue(ExportPathRegistry.reserve("test-y", File(dir, "b.mp4").path))
        } finally {
            ExportPathRegistry.finish("test-x")
            ExportPathRegistry.finish("test-y")
            dir.deleteRecursively()
        }
    }
}
