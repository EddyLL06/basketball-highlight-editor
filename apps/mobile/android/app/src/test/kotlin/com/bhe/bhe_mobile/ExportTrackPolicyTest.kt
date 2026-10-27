package com.bhe.bhe_mobile

import org.junit.Assert.*
import org.junit.Test

class ExportTrackPolicyTest {
    private val video = ExportSourceTrack(0, "video/hevc")
    private val spatial = ExportSourceTrack(1, "audio/apac")
    private val aac = ExportSourceTrack(2, "audio/mp4a-latm")

    @Test fun rejectedAudioPreservesVideoAndOriginalTrackMapping() {
        val selection = ExportTrackPolicy.select(listOf(video, spatial, aac), addTrack = { index ->
            if (index == 1) throw IllegalArgumentException("unsupported audio")
            if (index == 0) 4 else 7
        })
        assertEquals(mapOf(0 to 4, 2 to 7), selection.trackMap)
        assertEquals(listOf(spatial), selection.skippedAudio)
    }
    @Test fun rejectedVideoFailsInsteadOfReportingSuccess() {
        assertThrows(IllegalStateException::class.java) {
            ExportTrackPolicy.select(listOf(video, aac), addTrack = { throw IllegalArgumentException("unsupported") })
        }
    }
    @Test fun audioOnlyInputCannotBecomeASuccessfulVideoExport() {
        assertThrows(IllegalStateException::class.java) {
            ExportTrackPolicy.select(listOf(aac), addTrack = { 0 })
        }
    }
    @Test fun acceptedAudioHasNoWarningAndMetadataIsNotSelected() {
        val selection = ExportTrackPolicy.select(listOf(video, aac, ExportSourceTrack(3, "application/meta")), addTrack = { it })
        assertEquals(mapOf(0 to 0, 2 to 2), selection.trackMap)
        assertTrue(selection.skippedAudio.isEmpty())
    }
    @Test fun orientationPreservesAllQuarterTurnsAndNormalizesNegativeAngles() {
        for (degrees in listOf(0, 90, 180, 270)) assertEquals(degrees, ExportTrackPolicy.orientation(degrees))
        assertEquals(270, ExportTrackPolicy.orientation(-90))
        assertEquals(0, ExportTrackPolicy.orientation(360))
        assertThrows(IllegalArgumentException::class.java) { ExportTrackPolicy.orientation(45) }
    }
}
