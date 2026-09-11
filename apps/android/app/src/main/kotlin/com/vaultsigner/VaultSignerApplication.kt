package com.vaultsigner

import android.app.Application

/**
 * Instantiated once per OS process — both the default (UI) process and
 * the `:agent` process (`AndroidManifest.xml`) get their own separate
 * instance of this same class, with independent static state. Nothing
 * process-wide needs initializing here yet: [com.vaultsigner.service.AgentState]
 * (a plain Kotlin `object`) is already a natural process-local singleton
 * without any explicit setup.
 */
class VaultSignerApplication : Application()
