// Standalone verification harness for the UniFFI Kotlin bindings (spec
// §12 item 1.11), mirroring `uniffi-verify/swift/main.swift`: exercises
// Vault create/createKey/sign, the custom-protocol handler with a real
// foreign-implemented PassphrasePrompter, and a §5.3 import merge, all
// from real compiled Kotlin linked against the actual Rust cdylib — not
// just "bindings generated," but "bindings verified callable." Requires
// JNA on the classpath (the generated bindings call into it directly).
// Build/run (from `vaultcore/`, with `kotlinc`/JNA available):
//
//   cargo build --release --features uniffi
//   cargo run --release --features uniffi --bin uniffi-bindgen -- \
//       generate --library ../target/release/libvaultcore.dylib \
//       --language kotlin --out-dir /tmp/vaultcore-kotlin-bindings
//   curl -fsSL -o /tmp/jna.jar \
//       https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.14.0/jna-5.14.0.jar
//   kotlinc -cp /tmp/jna.jar \
//       /tmp/vaultcore-kotlin-bindings/uniffi/vaultcore/vaultcore.kt \
//       uniffi-verify/kotlin/Main.kt \
//       -include-runtime -d /tmp/vault_kotlin_harness.jar
//   java -cp /tmp/vault_kotlin_harness.jar:/tmp/jna.jar \
//       -Djna.library.path=../target/release MainKt
//
// Expect: "PASS: Vault create/createKey/sign/handleProtocolRequest/merge
// all verified from Kotlin". `bindings/` itself is never checked in
// (regenerate it — see `src/bin/uniffi_bindgen.rs`).

import uniffi.vaultcore.*
import java.util.Base64
import java.util.UUID

class FixedPrompter(private var passphrase: String?) : PassphrasePrompter {
    override fun prompt(callerIdentity: String, keyId: String): String? {
        val value = passphrase
        passphrase = null
        return value
    }
}

fun fail(message: String): Nothing {
    println("FAIL: $message")
    kotlin.system.exitProcess(1)
}

fun main() {
    val tmpDir = kotlin.io.path.createTempDirectory("vaultsigner-kotlin-harness")
    val vaultPath = tmpDir.resolve("test.vlt").toString()

    // 1. Create a vault (open vault).
    val vault = Vault.create(vaultPath, "Personal", "master pw", FacadeDeviceProfile.DESKTOP)
    val compartments = vault.listCompartments()
    if (compartments.size != 1) fail("expected 1 compartment, got ${compartments.size}")
    val compartmentId = compartments[0].compartmentId

    // 2. Create key.
    val key = vault.createKey(
        compartmentId, FacadeKeyType.ED25519, FacadePurpose.CUSTOM_SIGNING,
        "Deploy key", "", "example.com", listOf("work"), "key pw", null, null
    )
    if (key.publicKeyHex.isEmpty()) fail("expected a public key")

    val keys = vault.listKeys(compartmentId)
    if (keys.size != 1) fail("expected 1 key, got ${keys.size}")

    // 3. Sign, directly.
    vault.unlockKey(compartmentId, key.keyId, "key pw", 30u)
    val signature = vault.sign(key.keyId, "hello world".toByteArray())
    if (signature.size != 64) fail("expected a 64-byte ed25519 signature, got ${signature.size}")

    // 4. Sign, via the custom-protocol JSON-RPC handler + a foreign prompter callback.
    vault.lockKey(key.keyId)
    val messageB64 = Base64.getEncoder().encodeToString("hello".toByteArray())
    val requestJson = """{"method":"vaultsigner.sign","params":{"key_id":"${key.keyId}","message_b64":"$messageB64","algorithm":"ed25519"},"id":1}"""
    val responseBytes = vault.handleProtocolRequest("Kotlin harness", requestJson.toByteArray(), FixedPrompter("key pw"))
    val responseText = String(responseBytes)
    if (!responseText.contains("\"result\"")) fail("expected a signed result, got $responseText")

    // 5. Import packet (merge, spec §5.3 option 1).
    val incomingKeyId = UUID.randomUUID().toString().lowercase()
    val incomingManifestJson = """
        {"manifest_version":1,"vault_id":"${UUID.randomUUID()}","created_at":"2024-01-01T00:00:00Z","keys":[
          {"key_id":"$incomingKeyId","label":"Imported key","key_type":"ed25519","purpose":"custom-signing",
           "created_at":"2024-01-01T00:00:00Z","blob_file":"key_blobs/$incomingKeyId.kblob",
           "blob_sha256":"${"a".repeat(64)}","public_key_hex":"${"bb".repeat(32)}"}
        ]}
    """.trimIndent()
    val mergeOutcome = vault.mergeReencryptDiscardIncoming(
        compartmentId, incomingManifestJson,
        listOf(IncomingKeyBlob(incomingKeyId, "fake-blob-bytes".toByteArray()))
    )
    if (mergeOutcome.warnings.isNotEmpty()) fail("expected no duplicate warnings, got ${mergeOutcome.warnings}")
    val keysAfterMerge = vault.listKeys(compartmentId)
    if (keysAfterMerge.size != 2) fail("expected 2 keys after import, got ${keysAfterMerge.size}")

    println("PASS: Vault create/createKey/sign/handleProtocolRequest/merge all verified from Kotlin")
}
