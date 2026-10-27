package com.bhe.bhe_mobile.diagnostics

/** Interpret known causes; arbitrary exception text never becomes a UI message. */
object NativeFailureDetails {
    fun from(error: Throwable): Map<String, Any> {
        val text = (error.message ?: "").lowercase()
        val result = linkedMapOf<String, Any>()
        when {
            "enospc" in text || "no space left" in text -> { result["kind"] = "storage"; result["errno"] = 28 }
            error is SecurityException || "permission denied" in text || "eacces" in text -> { result["kind"] = "permission"; result["errno"] = 13 }
            "muxer" in text || "codec" in text || "decoder" in text || "unsupported" in text -> result["kind"] = "unsupported"
            else -> result["kind"] = "unknown"
        }
        Regex("(?:audio|video)/[a-z0-9._+-]+").find(text)?.value?.let { result["mime"] = it }
        return result
    }
}
