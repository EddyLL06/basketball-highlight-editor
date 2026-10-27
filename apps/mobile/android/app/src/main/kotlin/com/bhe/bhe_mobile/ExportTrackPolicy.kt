package com.bhe.bhe_mobile

internal data class ExportSourceTrack(val index: Int, val mime: String)
internal data class ExportTrackSelection(
    val trackMap: Map<Int, Int>,
    val skippedAudio: List<ExportSourceTrack>,
)

/** Container policy is independent of Android codecs so error paths are unit-testable. */
internal object ExportTrackPolicy {
    fun select(
        tracks: List<ExportSourceTrack>,
        addTrack: (Int) -> Int,
        onSkipped: (ExportSourceTrack, Exception) -> Unit = { _, _ -> },
    ): ExportTrackSelection {
        val selected = mutableMapOf<Int, Int>()
        val skipped = mutableListOf<ExportSourceTrack>()
        var videos = 0
        for (track in tracks) {
            val isVideo = track.mime.startsWith("video/")
            if (!isVideo && !track.mime.startsWith("audio/")) continue
            try {
                selected[track.index] = addTrack(track.index)
                if (isVideo) videos++
            } catch (error: Exception) {
                if (isVideo) throw IllegalStateException("视频轨道格式（${track.mime}）无法导出", error)
                skipped.add(track)
                onSkipped(track, error)
            }
        }
        check(videos > 0) { "视频没有可导出的音视频轨道" }
        return ExportTrackSelection(selected, skipped)
    }

    fun orientation(degrees: Int): Int {
        val normalized = ((degrees % 360) + 360) % 360
        require(normalized in listOf(0, 90, 180, 270)) { "Invalid video orientation" }
        return normalized
    }
}
