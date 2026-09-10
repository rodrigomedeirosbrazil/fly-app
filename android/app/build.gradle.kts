import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, kept out of the repo. Absent on a machine that has only
// ever built debug, so the config is only wired up when the file exists.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
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

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug keys when key.properties is absent, so a
            // fresh clone still builds. A debug-signed release cannot be
            // updated in place later, which is the whole point of the key:
            // an APK handed to a pilot must install over the one they have.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
