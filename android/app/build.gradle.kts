plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "br.com.medeirostec.aerovolt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Reverse DNS of medeirostec.com.br. Set before any Play upload
        // exists, because the first upload freezes it permanently.
        applicationId = "br.com.medeirostec.aerovolt"
        // A floor, not a preference. Three independent sources require 24:
        // Flutter 3.47 itself (gradle_utils.dart minSdkVersionInt = 24, and
        // flutter install refuses anything older), permission_handler_android
        // 14.1.0, and shared_preferences_android 2.4.28.
        // flutter_blue_plus_android needs only 21 — BLE is not the
        // constraint. This rules out Android 6 hardware: a Galaxy S5 tops
        // out at API 23, one level short.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
