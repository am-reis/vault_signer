// Standalone verification harness for the UniFFI Swift bindings (spec §12
// item 1.11): exercises Vault create/createKey/sign, the custom-protocol
// handler with a real foreign-implemented PassphrasePrompter, and a §5.3
// import merge, all from real compiled Swift linked against the actual
// Rust cdylib — not just "bindings generated," but "bindings verified
// callable." Must be named `main.swift` (Swift only allows top-level
// executable statements in a file with that exact name) and compiled
// together with the generated `vaultcore.swift` as one module, e.g.
// (from `vaultcore/`, macOS with Xcode/Swift installed):
//
//   cargo build --release --features uniffi
//   cargo run --release --features uniffi --bin uniffi-bindgen -- \
//       generate --library ../target/release/libvaultcore.dylib \
//       --language swift --out-dir /tmp/vaultcore-swift-bindings
//   cp uniffi-verify/swift/main.swift /tmp/vaultcore-swift-bindings/
//   swiftc -I /tmp/vaultcore-swift-bindings \
//       -Xcc -fmodule-map-file=/tmp/vaultcore-swift-bindings/vaultcoreFFI.modulemap \
//       -L ../target/release -lvaultcore \
//       /tmp/vaultcore-swift-bindings/vaultcore.swift \
//       /tmp/vaultcore-swift-bindings/main.swift \
//       -o /tmp/vault_swift_harness
//   DYLD_LIBRARY_PATH=../target/release /tmp/vault_swift_harness
//
// Expect: "PASS: Vault create/createKey/sign/handleProtocolRequest/merge
// all verified from Swift". `bindings/` itself is never checked in
// (regenerate it — see `src/bin/uniffi_bindgen.rs`).

import Foundation

final class FixedPrompter: PassphrasePrompter {
    let passphrase: String?
    init(_ passphrase: String?) { self.passphrase = passphrase }
    func prompt(callerIdentity: String, keyId: String) -> String? { passphrase }
}

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("vaultsigner-swift-harness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let vaultPath = tmpDir.appendingPathComponent("test.vlt").path

// 1. Create a vault (open vault).
let vault = try! Vault.create(path: vaultPath, compartmentLabel: "Personal", masterPassphrase: "master pw", profile: .desktop)
let compartments = vault.listCompartments()
guard compartments.count == 1 else { fail("expected 1 compartment, got \(compartments.count)") }
let compartmentId = compartments[0].compartmentId

// 2. Create key.
let key = try! vault.createKey(
    compartmentId: compartmentId, keyType: .ed25519, purpose: .customSigning,
    label: "Deploy key", description: "", resource: "example.com", tags: ["work"],
    keyPassphrase: "key pw", fido2RpId: nil, fido2UserHandleB64: nil
)
guard !key.publicKeyHex.isEmpty else { fail("expected a public key") }

let keys = try! vault.listKeys(compartmentId: compartmentId)
guard keys.count == 1 else { fail("expected 1 key, got \(keys.count)") }

// 3. Sign, directly.
try! vault.unlockKey(compartmentId: compartmentId, keyId: key.keyId, passphrase: "key pw", retentionSecs: 30)
let signature = try! vault.sign(keyId: key.keyId, message: "hello world".data(using: .utf8)!)
guard signature.count == 64 else { fail("expected a 64-byte ed25519 signature, got \(signature.count)") }

// 4. Sign, via the custom-protocol JSON-RPC handler + a foreign prompter callback.
vault.lockKey(keyId: key.keyId)
let requestJson = """
{"method":"vaultsigner.sign","params":{"key_id":"\(key.keyId)","message_b64":"aGVsbG8=","algorithm":"ed25519"},"id":1}
"""
let responseData = vault.handleProtocolRequest(
    callerIdentity: "Swift harness", rawJson: requestJson.data(using: .utf8)!,
    prompter: FixedPrompter("key pw")
)
let response = try! JSONSerialization.jsonObject(with: responseData) as! [String: Any]
guard response["result"] != nil else { fail("expected a signed result, got \(response)") }

// 5. Import packet (merge, spec §5.3 option 1).
let incomingKeyId = UUID().uuidString.lowercased()
let incomingManifestJson = """
{"manifest_version":1,"vault_id":"\(UUID().uuidString.lowercased())","created_at":"2024-01-01T00:00:00Z","keys":[
  {"key_id":"\(incomingKeyId)","label":"Imported key","key_type":"ed25519","purpose":"custom-signing",
   "created_at":"2024-01-01T00:00:00Z","blob_file":"key_blobs/\(incomingKeyId).kblob",
   "blob_sha256":"\(String(repeating: "a", count: 64))","public_key_hex":"\(String(repeating: "bb", count: 32))"}
]}
"""
let mergeOutcome = try! vault.mergeReencryptDiscardIncoming(
    targetCompartmentId: compartmentId, incomingManifestJson: incomingManifestJson,
    incomingKeyBlobs: [IncomingKeyBlob(keyId: incomingKeyId, blobBytes: Data("fake-blob-bytes".utf8))]
)
guard mergeOutcome.warnings.isEmpty else { fail("expected no duplicate warnings, got \(mergeOutcome.warnings)") }
let keysAfterMerge = try! vault.listKeys(compartmentId: compartmentId)
guard keysAfterMerge.count == 2 else { fail("expected 2 keys after import, got \(keysAfterMerge.count)") }

// 6. Export/import packet (spec §5.2/§5.3) across two separate vaults.
let destPath = tmpDir.appendingPathComponent("dest.vlt").path
let destVault = try! Vault.create(path: destPath, compartmentLabel: "Personal", masterPassphrase: "dest master pw", profile: .desktop)
let destCompartmentId = destVault.listCompartments()[0].compartmentId

let packetBytes = try! vault.exportPacket(
    compartmentId: compartmentId, keyIds: [key.keyId], includeMasterKey: false, encryption: .asIs
)
let imported = try! destVault.importPacket(packetBytes: packetBytes, transferPassword: nil)
guard imported.embeddedMasterCompartmentId == nil else { fail("expected no embedded master key") }
guard imported.keyBlobs.count == 1 else { fail("expected 1 key blob in the imported packet") }
let importMergeOutcome = try! destVault.mergeReencryptDiscardIncoming(
    targetCompartmentId: destCompartmentId, incomingManifestJson: imported.manifestJson, incomingKeyBlobs: imported.keyBlobs
)
guard importMergeOutcome.warnings.isEmpty else { fail("expected no duplicate warnings on packet import") }
// The imported key's own passphrase must survive the cross-vault trip unchanged.
try! destVault.unlockKey(compartmentId: destCompartmentId, keyId: key.keyId, passphrase: "key pw", retentionSecs: 30)
let importedKeySignature = try! destVault.sign(keyId: key.keyId, message: "cross-vault packet import works".data(using: .utf8)!)
guard importedKeySignature.count == 64 else { fail("expected a 64-byte signature from the imported key") }

// 7. Transfer-password-wrapped packet (spec §5.2.2 option 3) must require the password on import.
let wrappedPacket = try! vault.exportPacket(
    compartmentId: compartmentId, keyIds: [key.keyId], includeMasterKey: false,
    encryption: .oneTimeTransferPassword(password: "one-time secret")
)
do {
    _ = try destVault.importPacket(packetBytes: wrappedPacket, transferPassword: nil)
    fail("expected import without a transfer password to fail")
} catch {}
_ = try! destVault.importPacket(packetBytes: wrappedPacket, transferPassword: "one-time secret")

print("PASS: Vault create/createKey/sign/handleProtocolRequest/merge/exportPacket/importPacket all verified from Swift")
