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

// The Rust core: .so files + generated Kotlin bindings, both build outputs.
val rustOut = layout.projectDirectory.dir("build/rust") // == the source dirs below
val mobileDir = rootProject.layout.projectDirectory.dir("..")

android {
    namespace = "org.simpleagentmanager.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.simpleagentmanager.app"
        minSdk = 26
        targetSdk = 36
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildFeatures {
        compose = true
    }

    buildTypes {
        getByName("release") {
            // R8 off: it would need keep rules for JNA + the generated bindings.
            isMinifyEnabled = false
        }
    }

    sourceSets["main"].kotlin.directories += "build/rust/kotlin"
    sourceSets["main"].jniLibs.directories += "build/rust/jniLibs"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

val buildRustCore = tasks.register<Exec>("buildRustCore") {
    description = "cargo ndk build of apps/mobile/core + UniFFI Kotlin bindings (scripts/build-android.sh)"
    inputs.dir(mobileDir.dir("core/src"))
    inputs.files(mobileDir.file("core/Cargo.toml"), mobileDir.file("core/Cargo.lock"), mobileDir.file("core/uniffi.toml"))
    inputs.file(mobileDir.file("scripts/build-android.sh"))
    outputs.dir(rustOut)
    environment("ANDROID_HOME", androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath)
    commandLine(mobileDir.file("scripts/build-android.sh").asFile.absolutePath, rustOut.asFile.absolutePath)
}
tasks.named("preBuild") { dependsOn(buildRustCore) }

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.coroutines.android)
    implementation(libs.browser)
    implementation("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")
}
