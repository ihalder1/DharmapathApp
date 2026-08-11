package com.idsai.mantrasutra

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var billingBridge: GooglePlayBillingBridge? = null

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
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        billingBridge?.dispose()
        billingBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
