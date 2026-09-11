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
        // minSdk is per-flavor (below) — Credential Manager's provider
        // role (spec §6.3) genuinely needs API 34, but that floor doesn't
        // apply to the rest of the app (vault/key management, the custom
        // protocol, i18n), so it isn't a project-wide constant anymore.
        // targetSdk stays a single, un-flavored value: it's what the app
        // *behaves as* at runtime on a device that has it, independent of
        // the oldest device either flavor can install on.
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Wipe app data between every test method, not just once per
        // gradle invocation — see testOptions.execution below for why
        // this matters together with that setting.
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    // Without Test Orchestrator, every test CLASS in one
    // connectedAndroidTest invocation shares the same long-lived app
    // process (and its :agent child process/open vault) — `am instrument`
    // only restarts the process if it crashes. That let one test's
    // leftover open vault bleed into the next test's initial state, and
    // repeated Activity-recreation cycles against the same never-restarted
    // :agent process eventually made the whole suite intermittently hang
    // (see apps/android/docs/android-dev-journal.md). Orchestrator runs
    // each test in its own fresh Instrumentation instance instead, and
    // clearPackageData above wipes storage between them too — the real
    // fix, not just working around it from the test side.
    testOptions {
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    // Two flavors of the *same app*, from the same commit, same version
    // number (see docs/release-process.md and CLAUDE.md's Release
    // artifacts section) — not two products, not two versioning lines.
    // "full" keeps spec §12's original API-34+ scope (FIDO2/
    // CredentialProviderService included); "lite" drops just that one
    // capability to reach the other ~44 points of device-share API 34
    // alone doesn't cover (54.5% cumulative at API 34 vs. 98.0% at API 23,
    // per apilevels.com's April 2026 Statcounter-sourced figures — see
    // docs/release-process.md for the full reasoning behind landing on
    // API 23 specifically, not just "lower").
    flavorDimensions += "tier"
    productFlavors {
        create("full") {
            dimension = "tier"
            minSdk = 34
        }
        create("lite") {
            dimension = "tier"
            // 23, not lower: AndroidX itself has required minSdk 23+
            // since mid-2025, so this is the actual practical floor for
            // an app built on Compose/AndroidX regardless of product
            // choice — going lower isn't an option this dependency stack
            // has, and 23 already covers ~98% of active devices (vs.
            // ~96.6% at 24), so there is no real coverage left on the
            // table between them.
            minSdk = 23
            // Deliberately no versionNameSuffix/applicationIdSuffix here:
            // both flavors carry the identical version number from the
            // identical commit (see docs/release-process.md) — "full" vs.
            // "lite" is an artifact-filename distinction, not a version
            // or app-identity one.
        }
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
    // "full"-only: this is the one dependency the FIDO2 code path needs
    // that the rest of the app doesn't — declaring it as fullImplementation
    // rather than implementation means "lite" never even links it, not
    // just "doesn't call it."
    "fullImplementation"("androidx.credentials:credentials:1.5.0")

    // The UniFFI-generated Kotlin bindings for vaultcore call into JNA
    // directly (see vaultcore/uniffi-verify/kotlin/Main.kt) — the `@aar`
    // classifier bundles JNA's own native dispatch library per Android
    // ABI so it resolves at runtime with no manual JNI wiring.
    implementation("net.java.dev.jna:jna:5.19.1") { artifact { type = "aar" } }

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")

    // Instrumented tests (spec item 4.8's Android-specific test coverage
    // gap): real Compose semantics-tree interaction against the actual
    // MainActivity, running on a real device/emulator — not adb/
    // uiautomator pixel-coordinate taps, which this project's own
    // PROGRESS.md records losing real time to (a field's on-screen
    // position shifting once the keyboard covers part of the layout).
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.12.01"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Export/Import both hand off to a real system document picker
    // (ActivityResultContracts.CreateDocument/OpenDocument) — Espresso-
    // Intents lets a test stub that picker's result with a real local
    // file instead of needing a human to drive Android's actual file-
    // picker UI, so the export→import round trip stays a real,
    // automated test rather than something only ever driven manually.
    androidTestImplementation("androidx.test.espresso:espresso-intents:3.7.0")

    // Runs each test in its own fresh process/Instrumentation instance —
    // see testOptions.execution above for why this suite needs it.
    androidTestUtil("androidx.test:orchestrator:1.5.1")
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
