import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    // AGP 9 has built-in Kotlin support, so no kotlin.android plugin is applied.
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeCompiler)
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_11
    }
}

// Brand and identity, from the environment so white-label builds need no code changes
// (same names as the iOS build, see apps/native/ios/Config/Brand.xcconfig).
fun brand(name: String, default: String) = System.getenv(name)?.takeIf { it.isNotBlank() } ?: default

// The Rust core: .so files + generated Kotlin bindings, both build outputs.
val rustOut = layout.projectDirectory.dir("build/rust") // == the source dirs below
val nativeDir = rootProject.layout.projectDirectory.dir("..")

android {
    namespace = "org.simpleagentmanager.app"
    compileSdk = 36

    defaultConfig {
        applicationId = brand("SAM_BUNDLE_ID", "org.simpleagentmanager.app")
        minSdk = 26
        targetSdk = 36
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        resValue("string", "app_name", brand("SAM_APP_NAME", "SAM"))
        // The platform's BASE_DOMAIN to suggest; the app talks to api.<BASE_DOMAIN>.
        buildConfigField("String", "BASE_DOMAIN", "\"${brand("BASE_DOMAIN", "simple-agent-manager.org")}\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }

    buildTypes {
        getByName("release") {
            // R8 off: it would need keep rules for JNA + the generated bindings.
            isMinifyEnabled = false
        }
    }

    sourceSets["main"].kotlin.directories += "build/rust/kotlin"
    sourceSets["main"].jniLibs.directories += "build/rust/jniLibs"

    testOptions { unitTests.isIncludeAndroidResources = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

val buildRustCore = tasks.register<Exec>("buildRustCore") {
    description = "cargo ndk build of apps/native/core + UniFFI Kotlin bindings (scripts/build-android.sh)"
    inputs.dir(nativeDir.dir("core/src"))
    inputs.files(nativeDir.file("core/Cargo.toml"), nativeDir.file("core/Cargo.lock"), nativeDir.file("core/uniffi.toml"))
    inputs.file(nativeDir.file("scripts/build-android.sh"))
    outputs.dir(rustOut)
    environment("ANDROID_HOME", androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath)
    commandLine(nativeDir.file("scripts/build-android.sh").asFile.absolutePath, rustOut.asFile.absolutePath)
}
tasks.named("preBuild") { dependsOn(buildRustCore) }

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.coroutines.android)
    implementation(libs.browser)
    implementation("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")
}
