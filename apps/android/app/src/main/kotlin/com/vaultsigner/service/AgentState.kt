package com.vaultsigner.service

import uniffi.vaultcore.Vault

/**
 * Process-local singleton, alive only inside the `:agent` process. Both
 * [VaultSignerService] (the socket server, spec §7/§8) and
 * [com.vaultsigner.credentialprovider.VaultSignerCredentialProviderService]
 * (spec §6.3) run in this same OS process (see `AndroidManifest.xml`'s
 * `android:process=":agent"` on both), so they share this exact object —
 * a plain Kotlin `object` is already a process-wide singleton, no IPC
 * needed between them. This is what keeps "the service must never hold
 * more than one instance of the vault's decrypted state at a time" (spec
 * §8) true by construction, including for the credential-provider path:
 * unlike macOS's extension (a genuinely separate OS process that could
 * only ever open its own separate `Vault`, flagged as a known deferred
 * gap in that platform's PROGRESS.md), Android's single-APK model lets
 * both FIDO2 and the custom protocol share one `Vault` reference from day
 * one.
 *
 * `vault` is `null` until `internal.create_vault`/`internal.open_vault`
 * is called — a fresh install has no vault yet, same as the other
 * platforms' agents.
 */
object AgentState {
    @Volatile
    var vault: Vault? = null

    @Volatile
    var vaultPath: String? = null
}
