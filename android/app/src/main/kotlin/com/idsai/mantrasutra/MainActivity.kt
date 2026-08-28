package com.idsai.mantrasutra

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var billingBridge: GooglePlayBillingBridge? = null
    private var songExportBridge: GeneratedSongExportBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        billingBridge = GooglePlayBillingBridge(this).also { bridge ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.idsai.mantrasutra/play_billing",
            ).setMethodCallHandler(bridge)
            EventChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.idsai.mantrasutra/play_billing_events",
            ).setStreamHandler(bridge)
        }
        songExportBridge = GeneratedSongExportBridge(this).also { bridge ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.idsai.mantrasutra/generated_song_export",
            ).setMethodCallHandler(bridge)
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (songExportBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        billingBridge?.dispose()
        billingBridge = null
        songExportBridge?.let { bridge ->
            bridge.dispose()
        }
        songExportBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
