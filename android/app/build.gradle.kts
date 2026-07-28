plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

// Release signing: android/key.properties + storeFile (gitignored).
// Release artifacts fail closed when it is absent; a debug-signed package must
// never enter the GitHub / OTA upgrade chain.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasReleaseKeystore =
    keystorePropertiesFile.exists() &&
        keystoreProperties["storeFile"] != null &&
        keystoreProperties["keyAlias"] != null &&
        keystoreProperties["storePassword"] != null &&
        keystoreProperties["keyPassword"] != null

android {
    namespace = "com.wweiyi.expert_chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (and other modern AndroidX libs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.wweiyi.expert_chat"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    lint {
        // Release artifacts should pass Android lint just like debug builds.
        // Do not hide platform/API regressions until after distribution.
        checkReleaseBuilds = true
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Keep ordinary debug configuration usable, but stop every task that can emit
// a release package before it produces an unsigned/debug-signed artifact.
tasks.configureEach {
    val emitsReleaseArtifact =
        name.contains("Release", ignoreCase = true) &&
            (name.startsWith("assemble", ignoreCase = true) ||
                name.startsWith("bundle", ignoreCase = true) ||
                name.startsWith("package", ignoreCase = true))
    if (emitsReleaseArtifact) {
        doFirst {
            if (!hasReleaseKeystore) {
                throw GradleException(
                    "Release signing is not configured. Copy android/key.properties.example " +
                        "to android/key.properties and provide the upload keystore.",
                )
            }
        }
    }
}
