package com.vaultsigner.ipc

import android.content.Context
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import com.vaultsigner.service.VaultSignerService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicInteger

/**
 * The management UI process's sole means of touching vault state — mirrors
 * `ManagementClient.swift`/`ManagementClient.cs`: every operation (create/
 * open vault, list/create/discard keys, export/import/merge, settings)
 * is one `internal.*` call to [VaultSignerService], which is the only
 * process that ever holds a `Vault`. This process (the default, UI
 * process) holds no `Vault` of its own — spec §8's single-owner
 * invariant, same as the reference platforms.
 *
 * Connects over [VaultSignerService.SOCKET_NAME], a device-local abstract
 * Unix domain socket (spec §7: "Unix domain socket ... never accept
 * non-loopback connections" — Android is grouped with desktop for
 * transport, not the iOS exception, per spec §7.1). One connection per
 * call, matching `PROTOCOL-SPEC.md` §3's "a client is not required to
 * reconnect between calls" (permitted, not mandated) — simpler than
 * managing a long-lived socket across this process's activity lifecycle.
 */
object ManagementClient {
    private const val TAG = "ManagementClient"
    private const val CONNECT_RETRY_ATTEMPTS = 30
    private const val CONNECT_RETRY_DELAY_MS = 100L

    private val nextId = AtomicInteger(1)

    fun ensureAgentRunning(context: Context) {
        val intent = Intent(context, VaultSignerService::class.java)
        context.startForegroundService(intent)
    }

    suspend fun call(method: String, params: JSONObject = JSONObject()): JSONObject =
        withContext(Dispatchers.IO) {
            val socket = connectWithRetry()
            try {
                val id = nextId.getAndIncrement()
                val request = buildRpcRequest(method, params, id)
                writeLine(socket.outputStream, request)
                val responseLine = BufferedReader(InputStreamReader(socket.inputStream)).readLine()
                    ?: throw RpcException("connection_closed", "agent closed the connection with no response")
                when (val outcome = parseRpcResponse(responseLine)) {
                    is RpcOutcome.Success -> outcome.result
                    is RpcOutcome.Failure -> throw RpcException(outcome.code, outcome.message)
                }
            } finally {
                socket.close()
            }
        }

    private fun connectWithRetry(): LocalSocket {
        var lastError: Exception? = null
        repeat(CONNECT_RETRY_ATTEMPTS) { attempt ->
            try {
                val socket = LocalSocket()
                socket.connect(LocalSocketAddress(VaultSignerService.SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
                return socket
            } catch (e: Exception) {
                lastError = e
                if (attempt < CONNECT_RETRY_ATTEMPTS - 1) Thread.sleep(CONNECT_RETRY_DELAY_MS)
            }
        }
        Log.w(TAG, "could not connect to agent after $CONNECT_RETRY_ATTEMPTS attempts", lastError)
        throw RpcException("agent_unreachable", "could not reach VaultSignerService: ${lastError?.message}")
    }

    private fun writeLine(out: OutputStream, line: String) {
        out.write((line + "\n").toByteArray(Charsets.UTF_8))
        out.flush()
    }
}
