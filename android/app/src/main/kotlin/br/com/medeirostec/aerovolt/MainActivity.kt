package br.com.medeirostec.aerovolt

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// No test reaches this file: every Dart test mocks the channel. A change here
// is verified by `flutter build apk --debug` and on a phone.
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
                    // The update notice compares this against the latest
                    // release tag. It is the `+N` of pubspec.yaml, YYYYMMDDNN.
                    // Same method name as iOS, so one Dart class serves both.
                    "buildNumber" -> {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                        result.success(code)
                    }
                    // The browser downloads the APK and the system installer
                    // checks the signature; url_launcher would be a dependency
                    // for this one Intent.
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("ARG", "url missing", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                result.success(null)
                            } catch (e: ActivityNotFoundException) {
                                result.error("NO_BROWSER", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "br.com.medeirostec.aerovolt/host"
    }
}
