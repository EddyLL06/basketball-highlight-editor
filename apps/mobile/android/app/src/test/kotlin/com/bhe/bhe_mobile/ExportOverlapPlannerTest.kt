package com.bhe.bhe_mobile

import org.junit.Assert.*
import org.junit.Test

class ExportOverlapPlannerTest {
    private fun interval(start: Long, end: Long) = ExportInterval(start, end)
    @Test fun overlappingTouchingContainedAndChainedRangesAreMerged() {
        val input = listOf(interval(7000, 8000), interval(2000, 5000), interval(0, 2000), interval(1000, 4000), interval(8000, 9000))
        val original = input.toList()
        val plan = ExportOverlapPlanner.plan(input)
        assertEquals(listOf(interval(0, 5000), interval(7000, 9000)), plan.intervals)
        assertEquals(3, plan.mergedOverlapCount)
        assertEquals(original, input)
    }
    @Test fun separateIntervalsAndSingleIntervalKeepChronologicalOrder() {
        val plan = ExportOverlapPlanner.plan(listOf(interval(5000, 6000), interval(0, 1000)))
        assertEquals(listOf(interval(0, 1000), interval(5000, 6000)), plan.intervals)
        assertEquals(0, plan.mergedOverlapCount)
        assertEquals(0, ExportOverlapPlanner.plan(listOf(interval(0, 10))).mergedOverlapCount)
    }
    @Test fun duplicateIntervalsCountAsOneRemoved() {
        assertEquals(1, ExportOverlapPlanner.plan(listOf(interval(0, 10), interval(0, 10))).mergedOverlapCount)
    }
    @Test fun invalidInputFailsBeforePlanning() {
        for (input in listOf(emptyList(), listOf(interval(-1, 5)), listOf(interval(5, 5)), listOf(interval(5, 4)), listOf(interval(0, Long.MAX_VALUE)))) {
            assertThrows(IllegalArgumentException::class.java) { ExportOverlapPlanner.plan(input) }
        }
    }
}
