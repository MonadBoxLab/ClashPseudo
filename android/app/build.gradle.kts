plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.monadboxlab.clashpseudo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.monadboxlab.clashpseudo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
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

val nativeSource = rootProject.projectDir.resolve("../native/mihomo")
val nativeScript = rootProject.projectDir.resolve("../tool/build_android_core.sh")
val nativeOutput = layout.buildDirectory.dir("generated/mihomo/jniLibs")
val ndkPath = androidComponents.sdkComponents.sdkDirectory.get().asFile
    .resolve("ndk/${android.ndkVersion}")
val buildNativeCore by tasks.registering(Exec::class) {
    inputs.files(fileTree(nativeSource) { include("**/*.go", "**/*.c", "**/*.h", "go.mod", "go.sum") })
    inputs.file(nativeScript)
    inputs.file(ndkPath.resolve("source.properties"))
    inputs.property("api", flutter.minSdkVersion)
    inputs.property("abis", "arm64-v8a,x86_64")
    inputs.property("goVersion", providers.exec {
        environment("GOTOOLCHAIN", "local")
        commandLine("go", "version")
    }.standardOutput.asText)
    outputs.dir(nativeOutput)
    commandLine("bash", nativeScript, ndkPath, flutter.minSdkVersion,
        nativeOutput.get().asFile, "arm64-v8a,x86_64")
}
android.sourceSets.getByName("main").jniLibs.srcDir(nativeOutput.get().asFile)
tasks.named("preBuild") { dependsOn(buildNativeCore) }

dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
}
