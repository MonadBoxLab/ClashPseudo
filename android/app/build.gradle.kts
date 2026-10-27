import com.android.build.api.artifact.ScopedArtifact
import com.android.build.api.variant.ScopedArtifacts
import org.gradle.testing.jacoco.plugins.JacocoPluginExtension
import org.gradle.testing.jacoco.tasks.JacocoReport

plugins {
    id("com.android.application")
    // Flutter插件在Android插件之后接入。
    id("dev.flutter.flutter-gradle-plugin")
}

val validationCoverage = providers.gradleProperty("validationCoverage")
    .map(String::toBooleanStrict).getOrElse(false)
val validationNativeCoverage = providers.gradleProperty("validationNativeCoverage")
    .map(String::toBooleanStrict).getOrElse(false)
require(!validationNativeCoverage || validationCoverage) {
    "Native coverage requires the explicit validationCoverage test build"
}
if (validationNativeCoverage) {
    gradle.taskGraph.whenReady {
        require(allTasks.none { it.project == project && it.name.contains("Release") }) {
            "Native coverage must never be packaged in a release variant"
        }
    }
}

val nativePlatforms = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val nativeAbis = providers.gradleProperty("target-platform")
    .getOrElse(nativePlatforms.keys.joinToString(","))
    .split(",").map { platform ->
        requireNotNull(nativePlatforms[platform]) { "Unsupported target platform: $platform" }
    }.distinct()

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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            if (!providers.gradleProperty("split-per-abi").map(String::toBoolean).getOrElse(false)) {
                abiFilters += nativeAbis
            }
        }
        // 版本沿Flutter构建元数据。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    testCoverage {
        jacocoVersion = "0.8.14"
    }

    val distributionSigning = listOf(
        "CLASH_SIGNING_STORE_FILE", "CLASH_SIGNING_STORE_PASSWORD",
        "CLASH_SIGNING_KEY_ALIAS", "CLASH_SIGNING_KEY_PASSWORD",
    ).associateWith { providers.environmentVariable(it).orNull }
    require(distributionSigning.values.all { it.isNullOrEmpty() } ||
        distributionSigning.values.all { !it.isNullOrEmpty() }) {
        "Distribution signing requires all four CLASH_SIGNING environment variables"
    }
    val hasDistributionSigning = distributionSigning.values.all { !it.isNullOrEmpty() }
    require(providers.environmentVariable("CLASH_REQUIRE_DISTRIBUTION_SIGNING").orNull != "true" ||
        hasDistributionSigning) { "This build requires the configured distribution signing key" }
    if (hasDistributionSigning) {
        signingConfigs.create("distribution") {
            storeFile = file(distributionSigning.getValue("CLASH_SIGNING_STORE_FILE")!!)
            require(storeFile!!.isFile) { "Distribution keystore does not exist" }
            storePassword = distributionSigning.getValue("CLASH_SIGNING_STORE_PASSWORD")
            keyAlias = distributionSigning.getValue("CLASH_SIGNING_KEY_ALIAS")
            keyPassword = distributionSigning.getValue("CLASH_SIGNING_KEY_PASSWORD")
        }
    }

    buildTypes {
        debug {
            enableUnitTestCoverage = validationCoverage
            enableAndroidTestCoverage = validationCoverage
        }
        release {
            signingConfig = signingConfigs.getByName(if (hasDistributionSigning) "distribution" else "debug")
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
val nativeScript = rootProject.projectDir.resolve("../tool/android/build_core.sh")
val nativeOutput = layout.buildDirectory.dir(
    if (validationNativeCoverage) "generated/mihomo-coverage/jniLibs" else "generated/mihomo/jniLibs")
val ndkPath = androidComponents.sdkComponents.sdkDirectory.get().asFile
    .resolve("ndk/${android.ndkVersion}")
val buildNativeCore by tasks.registering(Exec::class) {
    inputs.files(fileTree(nativeSource) { include("**/*.go", "**/*.c", "**/*.h", "go.mod", "go.sum") })
    inputs.file(nativeScript)
    inputs.file(rootProject.projectDir.resolve("../contracts/application.json"))
    inputs.file(rootProject.projectDir.resolve("../tool/contracts/generate.py"))
    inputs.file("src/main/assets/geodata/manifest.json")
    inputs.file(rootProject.projectDir.resolve("../third_party/data/certificates/manifest.json"))
    for (name in listOf("CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS",
        "GOFLAGS", "GOEXPERIMENT", "GOAMD64", "GOARM64")) {
        inputs.property("environment.$name", providers.environmentVariable(name).orElse(""))
    }
    inputs.property("nativeCoverage", validationNativeCoverage)
    if (validationNativeCoverage) {
        inputs.file("src/androidTest/cpp/coverage_probe.c")
    }
    inputs.file(ndkPath.resolve("source.properties"))
    inputs.property("api", flutter.minSdkVersion)
    inputs.property("abis", nativeAbis.joinToString(","))
    inputs.property("goVersion", providers.exec {
        environment("GOTOOLCHAIN", "local")
        commandLine("go", "version")
    }.standardOutput.asText)
    outputs.dir(nativeOutput)
    commandLine("bash", nativeScript, ndkPath, flutter.minSdkVersion,
        nativeOutput.get().asFile, nativeAbis.joinToString(","))
    if (validationNativeCoverage) args("coverage")
}
android.sourceSets.getByName("main").jniLibs.srcDir(nativeOutput.get().asFile)

val bundledLegalOutput = layout.buildDirectory.dir("generated/bundledLegal/assets")
val prepareBundledLegalAssets by tasks.registering(Sync::class) {
    val source = rootProject.projectDir.resolve("../third_party/data/geodata")
    from(source.resolve("NOTICE.txt")) { into("geodata") }
    from(source) {
        include("*.txt")
        exclude("NOTICE.txt")
        into("geodata/licenses")
    }
    into(bundledLegalOutput)
}
android.sourceSets.getByName("main").assets.srcDir(bundledLegalOutput.get().asFile)
tasks.named("preBuild") { dependsOn(buildNativeCore, prepareBundledLegalAssets) }

if (validationCoverage) {
    apply(plugin = "jacoco")
    extensions.configure<JacocoPluginExtension> {
        toolVersion = "0.8.14"
    }
    androidComponents.onVariants(androidComponents.selector().withBuildType("debug")) { variant ->
        val jars = objects.listProperty<RegularFile>()
        val directories = objects.listProperty<Directory>()
        val deviceDirectory = providers.gradleProperty("validationCoverageDirectory")
        val unitData = layout.buildDirectory.file(
            "outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec")
        val classFiles = files(
            jars.map { files -> files.map { zipTree(it.asFile) } },
            directories.map { files -> files.map { fileTree(it.asFile) } })
        val report = tasks.register<JacocoReport>("validationDebugCoverageReport") {
            group = "verification"
            description = "Merge current debug JVM data and explicitly exported device coverage"
            dependsOn("testDebugUnitTest")
            sourceDirectories.from("src/main/kotlin")
            // 分母使用下方明确选择的应用主源码。
            classDirectories.from(classFiles.asFileTree.matching {
                include("io/github/monadboxlab/clashpseudo/**")
                exclude("**/R.class", "**/R$*.class", "**/BuildConfig.class", "**/debug/**")
            })
            executionData.from(unitData, deviceDirectory.map { directory ->
                fileTree(directory) { include("*.ec") }
            })
            reports {
                xml.required.set(true)
                html.required.set(true)
            }
            doFirst {
                require(deviceDirectory.isPresent && file(deviceDirectory.get()).isAbsolute) {
                    "validationCoverageDirectory must name this run's absolute device-data directory"
                }
                require(unitData.get().asFile.isFile &&
                    fileTree(deviceDirectory.get()) { include("*.ec") }.files.isNotEmpty()) {
                    "Both current JVM execution data and exported device .ec files are required"
                }
            }
        }
        variant.artifacts.forScope(ScopedArtifacts.Scope.PROJECT).use(report)
            .toGet(ScopedArtifact.CLASSES, { jars }, { directories })
        tasks.register<JacocoReport>("validationCoverageProbeReport") {
            group = "verification"
            description = "Check the known JaCoCo sample separately from application coverage"
            dependsOn(report)
            sourceDirectories.from("src/debug/java")
            classDirectories.from(classFiles.asFileTree.matching {
                include("io/github/monadboxlab/clashpseudo/debug/CoverageProbe.class")
            })
            executionData.from(unitData)
            reports {
                xml.required.set(true)
                html.required.set(true)
            }
        }
    }
}

dependencies {
    implementation("androidx.work:work-runtime:2.12.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
}
