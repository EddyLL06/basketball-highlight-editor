package com.bhe.bhe_mobile

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** The replacement function must atomically rename on the same filesystem. */
internal class MergeOutputTransaction(
    val temporary: File,
    private val destination: File,
    private val cancelled: AtomicBoolean,
    private val replace: (File, File) -> Unit,
) {
    private var committed = false

    @Synchronized fun cancel(): Boolean {
        if (committed) return false
        cancelled.set(true)
        return true
    }

    fun publish(validate: (File) -> Unit) {
        if (cancelled.get()) throw InterruptedException("合并导出已取消")
        check(temporary.isFile && temporary.length() > 0) { "合并导出文件为空" }
        validate(temporary)
        synchronized(this) {
            if (cancelled.get()) throw InterruptedException("合并导出已取消")
            replace(temporary, destination)
            committed = true
        }
    }

    fun cleanup() {
        if (temporary.exists() && !temporary.delete()) {
            throw IllegalStateException("无法清理合并导出临时文件")
        }
    }
}
