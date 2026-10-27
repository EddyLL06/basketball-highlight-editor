package com.bhe.bhe_mobile.diagnostics

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import org.json.JSONObject
import java.io.File
import java.util.Locale

/** Application-scoped owner. Native tasks do not require an attached Flutter engine. */
object AppDiagnostics {
    private val queue = DiagnosticQueue()
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var context: Context? = null
    private var store: RotatingLogStore? = null
    private var appVersion = "unknown"
    private var language = Locale.getDefault().toLanguageTag()

    @Synchronized fun configure(appContext: Context) {
        if (context != null) return
        context = appContext.applicationContext
        queue.submit {
            store = RotatingLogStore(File(appContext.filesDir, "logs"))
            store?.startup(JSONObject(environment()).toString())
        }
        queue.tick {
            val dropped = queue.takeDropped()
            if (dropped > 0) store?.record("diagnostics events omitted: $dropped")
            store?.flushExpired()
        }
    }

    fun initialize(version: String, locale: String, done: () -> Unit) {
        if (!queue.submit {
            appVersion = version.take(120).replace(Regex("[\\r\\n]"), " ")
            language = locale.take(40).replace(Regex("[\\r\\n]"), " ")
            try { store?.startup(JSONObject(environment()).toString()) }
            finally { main.post { done() } }
        }) main.post { done() }
    }

    fun append(message: String, key: String? = null) {
        queue.submit { store?.record(message, key) }
    }

    fun event(event: String, fields: Map<String, Any?> = emptyMap(), error: Throwable? = null) {
        try {
            val safe = NativeDiagnosticEvent.format(event, fields, error)
            append(if (event == "app.error.native") "app error: $safe" else safe, if (error == null) null else "native:${safe.hashCode()}")
        } catch (_: Exception) { }
    }

    fun snapshot(done: (Map<String, Any?>) -> Unit) {
        if (!queue.submit {
            val result = try {
                val lines = store?.tail() ?: emptyList()
                mapOf("environment" to environment(), "lines" to lines, "available" to (store?.available == true))
            } catch (_: Exception) {
                mapOf("environment" to emptyMap<String, Any>(), "lines" to emptyList<String>(), "available" to false)
            }
            main.post { done(result) }
        }) main.post { done(mapOf("environment" to emptyMap<String, Any>(), "lines" to emptyList<String>(), "available" to false)) }
    }

    private fun environment(): Map<String, Any?> {
        val ctx = context ?: return mapOf("app_version" to appVersion, "language" to language)
        val result = linkedMapOf<String, Any?>(
            "app_version" to appVersion, "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT, "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL, "abi" to Build.SUPPORTED_ABIS.joinToString(","),
            "language" to language,
        )
        fun field(name: String, read: () -> Any?) {
            result[name] = try { read() ?: "unknown" } catch (_: Exception) { "unknown" }
        }
        field("native_package_version") { ctx.packageManager.getPackageInfo(ctx.packageName, 0)?.versionName }
        val memory = try {
            ActivityManager.MemoryInfo().also { (ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it) }
        } catch (_: Exception) { null }
        result["memory_total"] = memory?.totalMem ?: "unknown"
        result["memory_available"] = memory?.availMem ?: "unknown"
        field("storage_available") { StatFs(ctx.filesDir.path).availableBytes }
        field("screen") { ctx.resources.displayMetrics.let { "${it.widthPixels}x${it.heightPixels} @${it.density}" } }
        return result
    }
}
