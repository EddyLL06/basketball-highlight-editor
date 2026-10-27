package com.bhe.bhe_mobile.diagnostics

import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** File operations belong to the one diagnostics worker, never the UI thread. */
class RotatingLogStore(
    private val directory: File,
    private val maxBytes: Int = 2 * 1024 * 1024,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val current get() = File(directory, "app.log")
    private val old get() = File(directory, "app.log.1")
    private var startup: String? = null
    var available: Boolean = true
        private set
    private val dates = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    private data class Repeated(val since: Long, var count: Int = 0)
    private val repeated = linkedMapOf<String, Repeated>()

    fun startup(environment: String): Boolean {
        startup = line("startup environment: $environment")
        return safe { write(startup!!) }
    }

    fun record(message: String, errorKey: String? = null): Boolean = safe {
        flushExpired()
        if (errorKey == null) {
            write(line(message))
        } else {
            val key = errorKey.take(128)
            val pending = repeated[key]
            if (pending != null) {
                pending.count++
            } else {
                if (repeated.size >= 64) flushKey(repeated.keys.first())
                write(line(message))
                repeated[key] = Repeated(clock())
            }
        }
    }

    fun flushExpired(force: Boolean = false) {
        val now = clock()
        repeated.keys.toList().forEach { key ->
            if (force || now - repeated.getValue(key).since >= 1000) flushKey(key)
        }
    }

    private fun flushKey(key: String) {
        val pending = repeated.remove(key) ?: return
        if (pending.count > 0) safe {
            write(line("app error: repeated ${pending.count} additional times (key=$key)"))
        }
    }

    /** Exactly the real tail; no startup synthesis or sidecar snapshot. */
    fun tail(lines: Int = 300): List<String> {
        var result = emptyList<String>()
        safe {
            if (!directory.isDirectory) throw IOException("Diagnostics directory unavailable")
            flushExpired(force = true)
            result = listOf(old, current).flatMap { if (it.isFile) it.readLines(Charsets.UTF_8) else emptyList() }
                .takeLast(lines.coerceIn(0, 300))
        }
        return result
    }

    private fun line(message: String): String =
        bounded("${dates.format(Date(clock()))} $message", minOf(32 * 1024, maxBytes / 2) - 1) + "\n"

    private fun write(record: String) {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Diagnostics directory unavailable")
        val bytes = record.toByteArray(Charsets.UTF_8)
        if (current.isFile && current.length() + bytes.size > maxBytes) {
            if (old.exists() && !old.delete()) throw IOException("Diagnostics rotation unavailable")
            if (!current.renameTo(old)) throw IOException("Diagnostics rotation unavailable")
            // A real retained startup line is part of the new log, not appended by the reader.
            startup?.let { current.writeText(it, Charsets.UTF_8) }
        }
        current.appendBytes(bytes)
    }

    private fun safe(action: () -> Unit): Boolean = try {
        action(); available = true; true
    } catch (_: Exception) {
        available = false; false
    }

    companion object {
        fun bounded(value: String, maxBytes: Int): String {
            if (value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value
            val suffix = " [truncated]"
            val limit = (maxBytes - suffix.length).coerceAtLeast(0)
            val output = StringBuilder()
            var bytes = 0
            var index = 0
            while (index < value.length) {
                val code = value.codePointAt(index)
                val next = String(Character.toChars(code))
                val length = next.toByteArray(Charsets.UTF_8).size
                if (bytes + length > limit) break
                output.append(next); bytes += length; index += Character.charCount(code)
            }
            return output.toString() + suffix.take(maxBytes.coerceAtLeast(0))
        }
    }
}
