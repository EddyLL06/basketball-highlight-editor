package com.bhe.bhe_mobile

/** A cancelled state is not idle while its worker is still cleaning up. */
internal object AnalysisWorkerLiveness {
    fun isRunning(worker: Thread?, status: String): Boolean =
        worker?.isAlive == true || status == "running"
}
