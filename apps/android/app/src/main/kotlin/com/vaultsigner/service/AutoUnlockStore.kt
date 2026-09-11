package com.vaultsigner.service

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * "Auto-unlock on startup" (spec §8): stores a compartment's master
 * passphrase so [VaultSignerService] can unlock it automatically after a
 * boot, without the disclosed risk of a plaintext copy. Mirrors macOS's
 * Keychain-backed `AutoUnlockStore`/Windows's DPAPI-backed
 * `DpapiAutoUnlockStore`, but using Android Keystore's hardware-backed
 * AES key — per spec §8, "Android Keystore can scope decryption to the
 * requesting app/process ... additionally offers hardware-backing," a
 * real protection against adversary #2 (a malicious co-resident app),
 * matching the stronger disclosure macOS/Android get in the spec (as
 * opposed to Windows's plain-DPAPI caveat).
 *
 * Off by default (spec §8), and this class only ever stores what
 * [com.vaultsigner.service.ManagementHandlers] explicitly asks it to
 * after the UI's own confirmation screen has already verified the
 * passphrase against the real vault — this class performs no such
 * verification itself.
 */
class AutoUnlockStore(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("auto_unlock_store", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    fun isEnabled(compartmentId: String): Boolean = prefs.contains(prefKey(compartmentId))

    fun store(compartmentId: String, passphrase: String) {
        val secretKey = getOrCreateKey(compartmentId)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey)
        val ciphertext = cipher.doFinal(passphrase.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        val combined = Base64.encodeToString(iv + ciphertext, Base64.NO_WRAP)
        prefs.edit().putString(prefKey(compartmentId), combined).apply()
    }

    fun retrieve(compartmentId: String): String? {
        val combined = prefs.getString(prefKey(compartmentId), null) ?: return null
        val bytes = Base64.decode(combined, Base64.NO_WRAP)
        val iv = bytes.copyOfRange(0, GCM_IV_LENGTH)
        val ciphertext = bytes.copyOfRange(GCM_IV_LENGTH, bytes.size)
        val secretKey = keyStore.getKey(keyAlias(compartmentId), null) as? SecretKey ?: return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    fun remove(compartmentId: String) {
        prefs.edit().remove(prefKey(compartmentId)).apply()
        try {
            keyStore.deleteEntry(keyAlias(compartmentId))
        } catch (_: Exception) {
            // Nothing to clean up if the key never existed.
        }
    }

    /** Every compartment ID this store currently holds a secret for. */
    fun enabledCompartmentIds(): List<String> =
        prefs.all.keys.filter { it.startsWith(PREF_PREFIX) }.map { it.removePrefix(PREF_PREFIX) }

    private fun getOrCreateKey(compartmentId: String): SecretKey {
        val alias = keyAlias(compartmentId)
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build()
        )
        return generator.generateKey()
    }

    private fun keyAlias(compartmentId: String) = "vaultsigner_auto_unlock_$compartmentId"
    private fun prefKey(compartmentId: String) = "$PREF_PREFIX$compartmentId"

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH = 12
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val PREF_PREFIX = "compartment_"
    }
}
