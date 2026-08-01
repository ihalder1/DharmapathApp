import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // FCM / Firebase: place `google-services.json` from Firebase Console at android/app/google-services.json
    id("com.google.gms.google-services")
}

val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()

if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use(keyProperties::load)
}

val requiredSigningProperties =
    listOf("storePassword", "keyPassword", "keyAlias", "storeFile")
val missingSigningProperties = requiredSigningProperties.filter {
    keyProperties.getProperty(it).isNullOrBlank()
}
val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    val taskName = it.substringAfterLast(':').lowercase()
    taskName.contains("release") || taskName in setOf("build", "assemble", "bundle")
}

if (isReleaseBuildRequested && (!keyPropertiesFile.exists() || missingSigningProperties.isNotEmpty())) {
    val problem = if (!keyPropertiesFile.exists()) {
        "android/key.properties is missing"
    } else {
        "android/key.properties is incomplete; missing: ${missingSigningProperties.joinToString()}"
    }
    throw GradleException(
        "$problem. Add storePassword, keyPassword, keyAlias, and storeFile before building a release."
    )
}

android {
    namespace = "com.example.colab_app_ui"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "com.example.colab_app_ui"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyPropertiesFile.exists() && missingSigningProperties.isEmpty()) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (isReleaseBuildRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("com.google.android.material:material:1.13.0")
}
