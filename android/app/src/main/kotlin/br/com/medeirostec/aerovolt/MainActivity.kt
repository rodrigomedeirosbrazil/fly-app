package br.com.medeirostec.aerovolt

import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The permission policy branches on this and nothing else.
                    // device_info_plus would be a fifth dependency, on every
                    // platform, to read this one integer.
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    // permission_handler opens the app's own settings page; a
                    // location service switched off needs the system one, and
                    // below API 31 a BLE scan cannot return anything without
                    // it.
                    "openLocationSettings" -> {
                        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "br.com.medeirostec.aerovolt/host"
    }
}
