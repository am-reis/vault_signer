package com.vaultsigner.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.vaultsigner.R
import com.vaultsigner.ipc.InternalErrorCodes
import com.vaultsigner.ipc.InternalMethods
import com.vaultsigner.ipc.buildRpcError
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.Executors

/**
 * The background service (spec §8): "a genuine OS-level background
 * service/daemon" — Android's answer among the platform list is
 * explicitly "a foreground/bound service." Owns [AgentState.vault] (the
 * single `Vault` instance system-wide), the custom-protocol/internal
 * socket listener (spec §7), and — via `vaultcore`'s own retention cache,
 * reached only through that one `Vault` — the in-memory key cache.
 *
 * Runs in the `:agent` process (see `AndroidManifest.xml`), a different
 * OS process from the management UI's default process, so the two
 * communicate over [SOCKET_NAME] exactly like a third-party app would —
 * `internal.*` is just a same-app-UID-authenticated slice of the same
 * transport (see [PeerAuthentication]), matching spec §8's "both
 * communicate over the same local-IPC mechanism as Section 7."
 */
class VaultSignerService : Service() {
    private lateinit var managementHandlers: ManagementHandlers
    private var serverSocket: LocalServerSocket? = null
    private val connectionExecutor = Executors.newCachedThreadPool()
    private val acceptExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        managementHandlers = ManagementHandlers(applicationContext)
        startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        // Must finish before the socket starts accepting connections below
        // — otherwise a client's very first `internal.status` could race
        // ahead of AgentState.vault being set and see `vault_open: false`
        // for a vault that is, moments later, actually open.
        reopenLastVaultIfAny()
        startSocketServer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Idempotent: onCreate already did everything needed. A second
        // startForegroundService() call (e.g. from BootCompletedReceiver
        // racing ManagementClient.ensureAgentRunning()) just re-delivers
        // here without restarting the socket server.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serverSocket?.close()
        acceptExecutor.shutdownNow()
        connectionExecutor.shutdownNow()
        AgentState.vault?.lockAll()
        super.onDestroy()
    }

    /** Reopens whichever vault [ManagementHandlers] last recorded via
     * [VaultConfig], every time this process (re)starts — for whatever
     * reason it started (a boot-triggered autostart, or the UI calling
     * [ManagementClient.ensureAgentRunning] on demand). "Start VaultSigner
     * at login" (spec §8) gates whether [BootCompletedReceiver] starts
     * this process at all, not what this process does once running —
     * once started, it always tries to pick back up where it left off,
     * mirroring macOS's `main.swift`. */
    private fun reopenLastVaultIfAny() {
        if (AgentState.vault != null) return
        val path = VaultConfig.loadVaultPath(applicationContext) ?: return
        try {
            val vault = uniffi.vaultcore.Vault.open(path)
            AgentState.vault = vault
            AgentState.vaultPath = path
            managementHandlers.autoUnlockCompartments(vault)
        } catch (e: Exception) {
            Log.w(TAG, "could not reopen last vault at $path on agent startup", e)
        }
    }

    private fun startSocketServer() {
        acceptExecutor.execute {
            try {
                val server = LocalServerSocket(SOCKET_NAME)
                serverSocket = server
                while (!Thread.currentThread().isInterrupted) {
                    val socket = try {
                        server.accept()
                    } catch (e: Exception) {
                        break // socket closed, e.g. during onDestroy
                    }
                    connectionExecutor.execute { handleConnection(socket) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "socket server failed to start", e)
            }
        }
    }

    private fun handleConnection(socket: LocalSocket) {
        socket.use {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream))
                val isSelf = PeerAuthentication.isSelf(socket)
                val callerIdentity = PeerAuthentication.callerIdentity(applicationContext, socket)
                var line = reader.readLine()
                while (line != null) {
                    val responseLine = handleRequestLine(line, isSelf, callerIdentity)
                    socket.outputStream.write((responseLine + "\n").toByteArray(Charsets.UTF_8))
                    socket.outputStream.flush()
                    line = reader.readLine()
                }
            } catch (e: Exception) {
                Log.w(TAG, "connection handling failed", e)
            }
        }
    }

    private fun handleRequestLine(line: String, isSelf: Boolean, callerIdentity: String): String {
        val method = try {
            JSONObject(line).optString("method", "")
        } catch (e: Exception) {
            return buildRpcError(null, "parse_error", "invalid JSON")
        }
        return when {
            method.startsWith("internal.") && !isSelf ->
                buildRpcError(requestId(line), InternalErrorCodes.UNAUTHORIZED_CALLER, "internal.* is reserved for VaultSigner's own app")
            method.startsWith("internal.") -> {
                val id = requestId(line)
                val params = try {
                    JSONObject(line).optJSONObject("params") ?: JSONObject()
                } catch (e: Exception) {
                    return buildRpcError(id, "parse_error", "invalid JSON")
                }
                managementHandlers.handle(method, id, params)
            }
            method.startsWith("vaultsigner.") -> {
                val vault = AgentState.vault
                    ?: return buildRpcError(requestId(line), InternalErrorCodes.NO_VAULT_OPEN, "no vault is open")
                val prompter = AndroidPassphrasePrompter(applicationContext)
                val responseBytes = vault.handleProtocolRequest(callerIdentity, line.toByteArray(Charsets.UTF_8), prompter)
                String(responseBytes, Charsets.UTF_8)
            }
            else -> buildRpcError(requestId(line), "method_not_found", "unknown method: $method")
        }
    }

    private fun requestId(line: String): Any? =
        try {
            val obj = JSONObject(line)
            if (obj.has("id") && !obj.isNull("id")) obj.get("id") else null
        } catch (e: Exception) {
            null
        }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, getString(R.string.android_agent_notification_channel_name), NotificationManager.IMPORTANCE_MIN)
            manager.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.android_agent_notification_title))
            .setContentText(getString(R.string.android_agent_notification_text))
            .setSmallIcon(R.drawable.ic_vault_notification)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
    }

    companion object {
        private const val TAG = "VaultSignerService"
        private const val CHANNEL_ID = "vaultsigner_agent"
        private const val NOTIFICATION_ID = 1

        /** Abstract-namespace Unix domain socket name (spec §7) — see
         * `apps/android/docs/protocol-integration.md` for the transport
         * discussion, including the real, verified cross-app reachability
         * caveat this name's namespace choice carries on Android. */
        const val SOCKET_NAME = "com.vaultsigner.app.agent"
    }
}
