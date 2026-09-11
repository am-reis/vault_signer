import org.jetbrains.kotlin.gradle.tasks.KotlinCompile
import java.io.ByteArrayOutputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    // The Kotlin package tree is "com.vaultsigner" (not "com.vaultsigner.app")
    // — this is what generates R/BuildConfig into that package and
    // resolves the manifest's relative component names (".ui.MainActivity"
    // etc). applicationId below is independently "com.vaultsigner.app" —
    // the two are allowed to differ and commonly do.
    namespace = "com.vaultsigner"
    // compileSdk 36 (not 34) purely to satisfy several androidx libraries'
    // own compile-against requirements — this project's real floor is
    // still API 34 (minSdk/targetSdk below, spec §12 item 0.2's Android
    // 14+ assumption). compileSdk is independent of that: it only picks
    // which API surface this module compiles against.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.vaultsigner.app"
        // Spec §12/§6.3: Android 14+/API 34+ only, matching the credential-
        // provider role this app must play — no fallback path for older APIs.
        minSdk = 34
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    // vaultcore's cdylib is cross-compiled per-ABI by `cargo ndk` (see
    // Scripts/build-vaultcore.sh) into jniLibs/<abi>/libvaultcore.so —
    // this is a plain jniLibs pickup, not a Gradle-driven NDK build,
    // since vaultcore is a shared, platform-agnostic Rust crate (spec
    // §2) that every platform cross-compiles with its own toolchain, not
    // something this app module owns the build of.
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    packaging {
        // The generated UniFFI Kotlin bindings call into JNA, which
        // bundles its own native dispatch library per ABI inside the AAR
        // (net.java.dev.jna:jna:$version, `@aar` artifact) — nothing to
        // exclude for our own libvaultcore.so, but JNA's metadata files
        // collide across dependencies without this.
        resources.excludes.add("META-INF/*.md")
        resources.excludes.add("META-INF/LICENSE*")
    }
}

dependencies {
    // Deliberately not the latest-latest patch of each of these — the
    // newest androidx releases (core-ktx 1.19, lifecycle 2.11,
    // activity-compose 1.13) require compileSdk 37 / AGP 9.1+, which
    // itself needs a newer JDK than this VM's deliberately-provisioned
    // JDK 17 (see CLAUDE.md's environment notes) — these versions are
    // the newest ones still compatible with compileSdk 36 / AGP 8.x.
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.navigation:navigation-compose:2.8.4")

    // Credential Manager provider-side API (spec §6.3) — the provider
    // classes (CredentialProviderService, BeginGetCredentialRequest, ...)
    // live in this same artifact, not a separate `credentials-provider`
    // one (verified against Google's real group index, not assumed).
    implementation("androidx.credentials:credentials:1.5.0")

    // The UniFFI-generated Kotlin bindings for vaultcore call into JNA
    // directly (see vaultcore/uniffi-verify/kotlin/Main.kt) — the `@aar`
    // classifier bundles JNA's own native dispatch library per Android
    // ABI so it resolves at runtime with no manual JNI wiring.
    implementation("net.java.dev.jna:jna:5.19.1") { artifact { type = "aar" } }

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}

// ---- vaultcore UniFFI Kotlin bindings: generated, never checked in ----
//
// Mirrors the project-wide convention already established for the Swift/
// Kotlin verification harnesses (vaultcore/uniffi-verify/*): generated
// bindings are regenerated from the real compiled library at build time,
// not committed. `generateUniffiBindings` regenerates
// uniffi/vaultcore/vaultcore.kt from whichever per-ABI .so this run's
// Scripts/build-vaultcore.sh most recently produced (they're all built
// from the same vaultcore source, so any one of them describes the same
// API) and adds it to the app's Kotlin source set.
val uniffiBindingsDir = layout.buildDirectory.dir("generated/uniffi/kotlin")

val generateUniffiBindings = tasks.register("generateUniffiBindings") {
    val vaultcoreDir = rootProject.projectDir.resolve("../../vaultcore")
    val libForBindgen = vaultcoreDir.resolve("../target/x86_64-linux-android/release/libvaultcore.so")
    inputs.file(libForBindgen)
    val outDir = uniffiBindingsDir.get().asFile
    outputs.dir(outDir)
    doLast {
        if (!libForBindgen.exists()) {
            throw GradleException(
                "libvaultcore.so not found at $libForBindgen — run " +
                    "apps/android/Scripts/build-vaultcore.sh first to cross-compile vaultcore."
            )
        }
        outDir.deleteRecursively()
        outDir.mkdirs()
        val result = ByteArrayOutputStream()
        val execResult = exec {
            workingDir = vaultcoreDir
            commandLine(
                "cargo", "run", "--release", "--features", "uniffi", "--bin", "uniffi-bindgen", "--",
                "generate", "--library", libForBindgen.absolutePath,
                "--language", "kotlin", "--out-dir", outDir.absolutePath
            )
            standardOutput = result
            errorOutput = result
            isIgnoreExitValue = true
        }
        if (execResult.exitValue != 0) {
            throw GradleException("uniffi-bindgen failed:\n${result.toString(Charsets.UTF_8)}")
        }
    }
}

android {
    sourceSets {
        getByName("main") {
            kotlin.srcDir(uniffiBindingsDir)
        }
    }
}

tasks.withType<KotlinCompile>().configureEach {
    dependsOn(generateUniffiBindings)
}
