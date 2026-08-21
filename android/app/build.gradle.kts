plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")
    testImplementation("junit:junit:4.13.2")
    // 本地单元测试需要真实的 org.json 实现；android.jar 中的桩会抛 “not mocked”。
    testImplementation("org.json:json:20240303")
    // 在 JVM 上执行 Android Bitmap/Canvas 真实绘制，防止水印文字裁切回归。
    testImplementation("org.robolectric:robolectric:4.16.1")
}

val releaseStorePath = System.getenv("PACKING_PROOF_KEYSTORE_PATH")?.trim().orEmpty()
val releaseKeyAlias = System.getenv("PACKING_PROOF_KEY_ALIAS")?.trim().orEmpty()
val releaseStorePassword = System.getenv("PACKING_PROOF_STORE_PASSWORD").orEmpty()
val releaseKeyPassword = System.getenv("PACKING_PROOF_KEY_PASSWORD").orEmpty()
val releaseSigningRequired =
    System.getenv("PACKING_PROOF_REQUIRE_RELEASE_SIGNING")?.equals("true", ignoreCase = true) == true
val releaseSigningConfigured = listOf(
    releaseStorePath,
    releaseKeyAlias,
    releaseStorePassword,
    releaseKeyPassword,
).all { it.isNotEmpty() }

if (releaseSigningRequired && !releaseSigningConfigured) {
    throw GradleException("正式 Release 构建缺少 PackingProof 签名配置")
}

android {
    namespace = "app.packingproof.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.packingproof.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
        manifestPlaceholders["buildRevision"] =
            System.getenv("PACKING_PROOF_BUILD_REVISION") ?: "development"
        manifestPlaceholders["buildTimestamp"] =
            System.getenv("PACKING_PROOF_BUILD_TIMESTAMP") ?: "development"
    }

    packaging {
        jniLibs {
            excludes += setOf("**/armeabi-v7a/**", "**/x86/**", "**/x86_64/**")
        }
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("packingProofRelease") {
                storeFile = file(releaseStorePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigningConfigured) {
                signingConfigs.getByName("packingProofRelease")
            } else {
                // Local development remains installable without access to the
                // private release key. The release script can require signing.
                signingConfigs.getByName("debug")
            }
            // ML Kit's byte-image converter fails after shrinking on some devices.
            // Reliability is more important than APK size for the first release.
            isMinifyEnabled = false
            isShrinkResources = false
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
