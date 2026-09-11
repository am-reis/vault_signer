package com.vaultsigner.service

import android.content.Context
import android.content.pm.PackageManager
import android.net.LocalSocket
import android.os.Process

/**
 * Resolves and authenticates the identity of a process connected to
 * [VaultSignerService]'s socket, via OS-level peer credentials only —
 * spec §7: "never trust a self-reported name ... for this purpose",
 * spec §8: "verify the connecting process's identity via an OS-level,
 * code-identity mechanism ... not a self-reported name or the mere fact
 * of a successful connection."
 *
 * Android's per-app UID sandboxing makes the `internal.*` half of this
 * simpler and strictly stronger than the code-signing check macOS/Windows
 * need: every process of this exact app (the default process and every
 * `android:process=":..."` one) shares one Linux UID, and no other app on
 * the device can share it. So "the peer's UID equals our own UID" is a
 * complete, OS-enforced answer to "is this really VaultSigner's own
 * management UI" — there is no equivalent to a same-user-but-different-
 * app confusion the way a Unix domain socket's owner-only file
 * permissions alone would allow on desktop (spec §8's own caveat about
 * that).
 */
object PeerAuthentication {
    /** `internal.*` gate: the peer must be this exact app (any of its own processes). */
    fun isSelf(socket: LocalSocket): Boolean {
        val creds = socket.peerCredentials ?: return false
        return creds.uid == Process.myUid()
    }

    /**
     * Caller identity for the `vaultsigner.sign` consent prompt (spec
     * §7): resolved from the peer's UID via [PackageManager], the
     * Android equivalent of macOS's `proc_pidpath`/Windows's named-pipe
     * client process lookup — never anything the caller's own JSON
     * payload could claim to be.
     */
    fun callerIdentity(context: Context, socket: LocalSocket): String {
        val creds = socket.peerCredentials ?: return "unknown caller"
        val packages = context.packageManager.getPackagesForUid(creds.uid) ?: return "uid ${creds.uid}"
        val packageName = packages.firstOrNull() ?: return "uid ${creds.uid}"
        return try {
            val appInfo = context.packageManager.getApplicationInfo(packageName, 0)
            context.packageManager.getApplicationLabel(appInfo).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            packageName
        }
    }
}
