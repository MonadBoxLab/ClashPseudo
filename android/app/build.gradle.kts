import groovy.json.JsonSlurper
import com.android.build.api.artifact.ScopedArtifact
import com.android.build.api.variant.ScopedArtifacts
import org.gradle.testing.jacoco.plugins.JacocoPluginExtension
import org.gradle.testing.jacoco.tasks.JacocoReport
import java.util.Base64
import java.util.Properties
import java.nio.file.Files
import java.nio.file.FileSystems
import java.nio.file.attribute.PosixFilePermissions

plugins {
    id("com.android.application")
    // Apply the Flutter plugin after the Android plugin.
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
val mihomoVersion = providers.exec {
    environment("GOTOOLCHAIN", "local")
    commandLine("go", "-C", rootProject.projectDir.resolve("../native/mihomo"),
        "list", "-mod=readonly", "-m", "-f", "{{.Version}}", "github.com/metacubex/mihomo")
}.standardOutput.asText.map { it.trim() }

android {
    buildToolsVersion = "37.0.0"
    namespace = "io.github.monadboxlab.clashpseudo"
    compileSdk = 36
    ndkVersion = "30.0.16248370"

    buildFeatures {
        aidl = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.monadboxlab.clashpseudo"
        minSdk = 24
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            if (!providers.gradleProperty("split-per-abi").map(String::toBoolean).getOrElse(false)) {
                abiFilters.clear()
                abiFilters += nativeAbis
            }
        }
        // Use the version from Flutter build metadata.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "MIHOMO_VERSION", "\"${mihomoVersion.get()}\"")
        buildConfigField("boolean", "VALIDATION_NATIVE_COVERAGE", "false")
    }

    splits {
        abi {
            isUniversalApk = true
        }
    }

    testCoverage {
        jacocoVersion = "0.8.14"
    }

    val signingNames = listOf(
        "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64", "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD",
        "CLASH_PSEUDO_ANDROID_KEY_ALIAS", "CLASH_PSEUDO_ANDROID_KEY_PASSWORD",
    )
    val environmentSigning = signingNames.map { providers.environmentVariable(it) }
    val hasEnvironmentSigning = environmentSigning.any { it.isPresent }
    require(!hasEnvironmentSigning || environmentSigning.all { !it.orNull.isNullOrEmpty() }) {
        "Signing requires all four CLASH_PSEUDO_ANDROID environment variables"
    }
    require(!hasEnvironmentSigning || environmentSigning.all { '\u0000' !in it.get() }) {
        "Signing environment values must not contain NUL"
    }
    require(providers.environmentVariable("CLASH_REQUIRE_DISTRIBUTION_SIGNING").orNull != "true" ||
        hasEnvironmentSigning) { "Distribution builds require the four signing environment variables" }
    val localSigningFile = rootProject.file("key.properties")
    val localSigning = Properties()
    if (localSigningFile.exists()) {
        localSigningFile.reader(Charsets.UTF_8).use(localSigning::load)
        require(listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .all { !localSigning.getProperty(it).isNullOrEmpty() }) { "Incomplete android/key.properties" }
        require(listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .all { '\u0000' !in localSigning.getProperty(it) }) { "android/key.properties values must not contain NUL" }
        val key = localSigningFile.parentFile.resolve(localSigning.getProperty("storeFile"))
        require(key.isFile) { "Debug signing keystore does not exist" }
        signingConfigs.getByName("debug") {
            storeFile = key
            storePassword = localSigning.getProperty("storePassword")
            keyAlias = localSigning.getProperty("keyAlias")
            keyPassword = localSigning.getProperty("keyPassword")
        }
    }
    if (hasEnvironmentSigning) {
        val key = run {
            val bytes = Base64.getDecoder().decode(environmentSigning[0].get())
            try {
                require(bytes.isNotEmpty()) { "Signing keystore is empty" }
                // Explicitly use mode 0600 on POSIX; elsewhere, use the JVM's restricted temporary-file defaults.
                val permissions = if (FileSystems.getDefault().supportedFileAttributeViews().contains("posix")) {
                    arrayOf(PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
                } else emptyArray()
                val temporary = Files.createTempFile("clash-pseudo-signing-", ".jks", *permissions)
                try {
                    temporary.toFile().deleteOnExit()
                    gradle.buildFinished {
                        val buildFailure = failure
                        try {
                            Files.deleteIfExists(temporary)
                        } catch (cleanup: Throwable) {
                            if (buildFailure == null) throw cleanup
                            buildFailure.addSuppressed(cleanup)
                        }
                    }
                    Files.write(temporary, bytes)
                    temporary.toFile()
                } catch (failure: Throwable) {
                    try {
                        Files.deleteIfExists(temporary)
                    } catch (cleanup: Throwable) {
                        failure.addSuppressed(cleanup)
                    }
                    throw failure
                }
            } finally {
                // Erase decoded material even if permission attributes or temporary-file creation fail.
                bytes.fill(0)
            }
        }
        require(key.isFile) { "Signing keystore does not exist" }
        signingConfigs.create("distribution") {
            storeFile = key
            storePassword = environmentSigning[1].get()
            keyAlias = environmentSigning[2].get()
            keyPassword = environmentSigning[3].get()
        }
    }
    gradle.taskGraph.whenReady {
        require(hasEnvironmentSigning || allTasks.none { it.project == project && it.name.contains("Release") }) {
            "Release builds require the four signing environment variables"
        }
    }

    buildTypes {
        debug {
            enableUnitTestCoverage = validationCoverage
            enableAndroidTestCoverage = validationCoverage
            buildConfigField("boolean", "VALIDATION_NATIVE_COVERAGE", validationNativeCoverage.toString())
        }
        release {
            signingConfig = if (hasEnvironmentSigning) signingConfigs.getByName("distribution") else null
        }
    }
    sourceSets.maybeCreate("profile").java.srcDir("src/release/kotlin")
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
val toolEntry = rootProject.projectDir.resolve("../tool/main.py")
val toolSources = fileTree(rootProject.projectDir.resolve("../tool")) { include("**/*.py") }
val nativeOutput = layout.buildDirectory.dir(
    if (validationNativeCoverage) "generated/mihomo-coverage/jniLibs" else "generated/mihomo/jniLibs")
val ndkPath = androidComponents.sdkComponents.sdkDirectory.get().asFile
    .resolve("ndk/${android.ndkVersion}")
val buildNativeCore by tasks.registering(Exec::class) {
    inputs.files(fileTree(nativeSource) { include("**/*.go", "**/*.c", "**/*.h", "go.mod", "go.sum") })
    inputs.files(toolSources)
    inputs.file(rootProject.projectDir.resolve("../contracts/application.json"))
    inputs.file(rootProject.projectDir.resolve("../lib/src/model/application_contract.dart"))
    inputs.file("src/main/kotlin/io/github/monadboxlab/clashpseudo/app/ApplicationContract.kt")
    for (name in listOf("CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS",
        "GOFLAGS", "GOEXPERIMENT", "GOAMD64", "GOARM64")) {
        inputs.property("environment.$name", providers.environmentVariable(name).orElse(""))
    }
    inputs.property("nativeCoverage", validationNativeCoverage)
    if (validationNativeCoverage) {
        inputs.file("src/androidTest/cpp/coverage_probe.c")
    }
    inputs.file(ndkPath.resolve("source.properties"))
    inputs.property("api", 24)
    inputs.property("abis", nativeAbis.joinToString(","))
    inputs.property("goVersion", providers.exec {
        environment("GOTOOLCHAIN", "local")
        commandLine("go", "version")
    }.standardOutput.asText)
    outputs.dir(nativeOutput)
    commandLine("python3", "-I", "-B", toolEntry, "android", "build-core",
        "--project", rootProject.projectDir.resolve(".."), "--ndk", ndkPath, "--api", 24,
        "--output", nativeOutput.get().asFile, "--abis", nativeAbis.joinToString(","))
    if (validationNativeCoverage) args("--coverage")
}
android.sourceSets.getByName("main").jniLibs.srcDir(nativeOutput.get().asFile)

val bundledOutput = rootProject.projectDir.resolve("../build/generated/bundled")
val prepareBundledLegalAssets by tasks.registering(Exec::class) {
    val sourceRoot = rootProject.projectDir.resolve("..")
    inputs.file(sourceRoot.resolve("third_party/data/resources.json"))
    inputs.files(toolSources)
    inputs.files(fileTree(sourceRoot.resolve("third_party/data/certificates")) { include("MPL-2.0.txt") })
    inputs.files(fileTree(sourceRoot.resolve("third_party/data/geodata")) { include("*.txt"); exclude("NOTICE.txt") })
    outputs.dir(bundledOutput)
    commandLine("python3", "-I", "-B", toolEntry, "dependencies", "prepare-build",
        "--project", sourceRoot)
}
// Exclude legacy payloads in source directories; all variants use the same release record.
android.sourceSets.getByName("main").assets.setSrcDirs(listOf(bundledOutput.resolve("assets")))
android.sourceSets.getByName("main").java.srcDir(bundledOutput.resolve("kotlin"))
tasks.configureEach {
    if (name.startsWith("compileFlutterBuild") || name.startsWith("compile") && name.endsWith("Kotlin")) {
        dependsOn(prepareBundledLegalAssets)
    }
}
tasks.named("preBuild") { dependsOn(buildNativeCore, prepareBundledLegalAssets) }
tasks.withType<Test>().configureEach {
    dependsOn(prepareBundledLegalAssets)
    inputs.file(rootProject.projectDir.resolve("../third_party/data/resources.json"))
    doFirst {
        val record = JsonSlurper().parse(rootProject.projectDir.resolve("../third_party/data/resources.json")) as Map<*, *>
        val resources = record["resources"] as Map<*, *>
        systemProperty("certificates.assets", bundledOutput.resolve("assets").absolutePath)
        systemProperty("geodata.assets", bundledOutput.resolve("assets/geodata").absolutePath)
        for (kind in listOf("geoip", "geosite", "mmdb", "asn")) {
            val spec = resources[kind] as Map<*, *>
            for (field in listOf("storedBytes", "storedSha256", "installedBytes", "installedSha256")) {
                systemProperty("geodata.$kind.$field", requireNotNull(spec[field]).toString())
            }
        }
    }
}

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
            // Use the application main sources selected below as the coverage denominator.
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
    androidTestImplementation("androidx.test:runner:1.8.0-alpha03")
}
