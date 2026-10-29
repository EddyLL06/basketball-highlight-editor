package com.bhe.bhe_mobile.diagnostics

import org.junit.Assert.*
import org.junit.Test

class NativeDiagnosticEventTest {
    @Test fun onlySafeStructuredFieldsAndThirtyCodeFramesAreRecorded() {
        val error = IllegalArgumentException("open /storage/emulated/0/private/video.mp4 failed")
        error.stackTrace = (1..60).map { StackTraceElement("com.bhe.Test", "run", "/private/source/Test.kt", it) }.toTypedArray()
        val text = NativeDiagnosticEvent.format("export.audio.skipped", mapOf(
            "mime" to "audio/apac", "track" to 1, "videoPath" to "/sdcard/personal/video.mp4", "projectName" to "alice"), error)
        assertTrue(text.contains("audio/apac")); assertTrue(text.contains("IllegalArgumentException"))
        assertFalse(text.contains("/storage")); assertFalse(text.contains("/private")); assertFalse(text.contains("alice"))
        assertEquals(30, text.lineSequence().count { it.contains(" at ") })
        assertTrue(text.contains("Test.kt:30")); assertFalse(text.contains("Test.kt:31"))
    }
    @Test fun nativeUncaughtHandlerDelegatesEvenWhenItsLoggerFails() {
        var original = 0; val failure = IllegalStateException("test")
        val handler = LoggingUncaughtHandler({ throw IllegalStateException("logger unavailable") },
            Thread.UncaughtExceptionHandler { _, error -> assertSame(failure, error); original++ })
        handler.uncaughtException(Thread.currentThread(), failure); assertEquals(1, original)
    }
}
