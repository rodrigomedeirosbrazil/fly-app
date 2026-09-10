allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Compile every module against API 37.0, spelled as major + minor.
//
// permission_handler_android 14.1.0 needs compileSdk 37 — it references
// VERSION_CODES.CINNAMON_BUN and Manifest.permission.ACCESS_LOCAL_NETWORK,
// so 36 fails to compile outright. But Google now publishes that platform as
// `platforms;android-37.0` under a minor-versioned name, and a bare
// `compileSdk = 37` makes AGP look up the hash `android-37`, which does not
// exist: "Failed to find target with hash string 'android-37'" on an SDK that
// is perfectly healthy.
//
// compileSdkMinor is the supported way to name the platform, so this is the
// fix rather than a workaround. It is set here for every module so there is
// one compile target across the app and its plugins instead of two.
// minSdk stays 24 and targetSdk stays 36; only what we compile against moves.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android")
        if (android is com.android.build.api.dsl.CommonExtension) {
            android.compileSdk = 37
            android.compileSdkMinor = 0
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
