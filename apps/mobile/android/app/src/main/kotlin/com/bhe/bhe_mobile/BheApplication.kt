package com.bhe.bhe_mobile

import android.app.Application
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import com.bhe.bhe_mobile.diagnostics.LoggingUncaughtHandler

class BheApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppDiagnostics.configure(this)
        Thread.getDefaultUncaughtExceptionHandler()?.let { previous ->
            Thread.setDefaultUncaughtExceptionHandler(LoggingUncaughtHandler(
                { error -> AppDiagnostics.event("app.error.native", error = error) }, previous,
            ))
        }
    }
}
