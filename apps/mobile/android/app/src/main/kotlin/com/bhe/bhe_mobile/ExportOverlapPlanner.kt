package com.bhe.bhe_mobile

internal data class ExportInterval(val startMs: Long, val endMs: Long)
internal data class ExportOverlapPlan(val intervals: List<ExportInterval>, val mergedOverlapCount: Int)

/** Keeps the existing chronological output order, coalescing touching intervals. */
internal object ExportOverlapPlanner {
    fun plan(input: List<ExportInterval>): ExportOverlapPlan {
        require(input.isNotEmpty()) { "No export intervals" }
        require(input.all { it.startMs >= 0 && it.endMs > it.startMs && it.endMs <= Long.MAX_VALUE / 1000 }) {
            "Invalid export interval"
        }
        val result = mutableListOf<ExportInterval>()
        for (clip in input.sortedBy { it.startMs }) {
            val previous = result.lastOrNull()
            if (previous != null && clip.startMs <= previous.endMs) {
                result[result.lastIndex] = ExportInterval(previous.startMs, maxOf(previous.endMs, clip.endMs))
            } else {
                result.add(clip)
            }
        }
        return ExportOverlapPlan(result, input.size - result.size)
    }
}
