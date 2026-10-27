package com.bhe.bhe_mobile.diagnostics

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object DiagnosticsChannel {
    fun register(engine: FlutterEngine, context: Context) {
        AppDiagnostics.configure(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.bhe.bhe/diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> AppDiagnostics.initialize(
                        call.argument<String>("version") ?: "unknown",
                        call.argument<String>("language") ?: "unknown",
                    ) { result.success(null) }
                    "append" -> {
                        val message = call.argument<String>("message")
                        if (message == null || message.length > 65536) {
                            result.error("DIAGNOSTICS_INVALID", "Invalid log record", null)
                        } else {
                            AppDiagnostics.append(message, call.argument<String>("key"))
                            result.success(null)
                        }
                    }
                    "snapshot" -> AppDiagnostics.snapshot { result.success(it) }
                    else -> result.notImplemented()
                }
            }
    }
}
