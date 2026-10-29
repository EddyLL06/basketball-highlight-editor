package com.bhe.bhe_mobile.diagnostics
import org.junit.Assert.*
import org.junit.Test
class NativeFailureDetailsTest {
    @Test fun reasonsAreStructuredWithoutLeakingPaths() {
        assertEquals(28, NativeFailureDetails.from(java.io.IOException("ENOSPC /private/video.mp4"))["errno"])
        assertEquals(13, NativeFailureDetails.from(SecurityException("/private/video.mp4"))["errno"])
        val codec = NativeFailureDetails.from(IllegalArgumentException("muxer rejects audio/apac at /private/video.mp4"))
        assertEquals("unsupported", codec["kind"]); assertEquals("audio/apac", codec["mime"])
        assertFalse(codec.toString().contains("/private"))
        assertEquals("unknown", NativeFailureDetails.from(IllegalStateException("null"))["kind"])
    }
}
