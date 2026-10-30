package eu.siacs.conversations.stickers

import android.util.Log
import eu.siacs.conversations.Config
import eu.siacs.conversations.entities.Account
import im.conversations.android.xmpp.model.stanza.Iq
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.ConcurrentHashMap
import java.util.function.Consumer
import kotlin.coroutines.resume

/**
 * Fetches and caches Bearer tokens for the Penik microservice (stickers and
 * phone directory) from the XMPP server via the `penik:stickers:auth:0` IQ
 * protocol (see server/Modules/mod_stickers_auth.lua).
 *
 * The client never sees the shared secret: the server issues a token bound to
 * the authenticated account JID with an expiry timestamp, and the microservice
 * validates it on each request. Tokens are cached per account and refreshed
 * once they come within [EXPIRY_SAFETY_MARGIN_SECONDS] of expiring.
 */
object PenikServiceTokenProvider {

    private const val NAMESPACE = "penik:stickers:auth:0"
    private const val CHILD_NAME = "stickers-auth"
    private const val EXPIRY_SAFETY_MARGIN_SECONDS = 300L
    private const val FALLBACK_TTL_SECONDS = 3600L

    private data class CachedToken(val token: String, val expiresAtSeconds: Long)

    private val cache = ConcurrentHashMap<String, CachedToken>()

    @JvmStatic
    fun getCachedToken(account: Account): String? {
        val cached = cache[account.jid.asBareJid().toString()] ?: return null
        val nowSeconds = System.currentTimeMillis() / 1000
        return if (cached.expiresAtSeconds - EXPIRY_SAFETY_MARGIN_SECONDS > nowSeconds) {
            cached.token
        } else {
            null
        }
    }

    suspend fun getToken(account: Account): String? {
        getCachedToken(account)?.let { return it }
        return suspendCancellableCoroutine { continuation ->
            fetchTokenAsync(account) { token ->
                if (continuation.isActive) {
                    continuation.resume(token)
                }
            }
        }
    }

    @JvmStatic
    fun fetchTokenAsync(account: Account, callback: Consumer<String?>) {
        getCachedToken(account)?.let {
            callback.accept(it)
            return
        }
        val connection = account.xmppConnection
        if (connection == null) {
            Log.d(Config.LOGTAG, "PenikServiceTokenProvider: no connection for ${account.jid}")
            callback.accept(null)
            return
        }
        val iq = Iq(Iq.Type.GET)
        iq.setTo(account.jid.asBareJid())
        iq.addChild(CHILD_NAME, NAMESPACE)
        connection.sendIqPacket(
            iq,
            { response -> callback.accept(parseAndCache(account, response)) },
            false
        )
    }

    @JvmStatic
    fun invalidate(account: Account) {
        cache.remove(account.jid.asBareJid().toString())
    }

    private fun parseAndCache(account: Account, response: Iq): String? {
        if (response.type != Iq.Type.RESULT) {
            Log.d(Config.LOGTAG, "PenikServiceTokenProvider: token request failed (${response.type})")
            return null
        }
        val element = response.findChild(CHILD_NAME, NAMESPACE)
        val token = element?.getAttribute("token")?.takeIf { it.isNotBlank() }
        if (element == null || token == null) {
            Log.w(Config.LOGTAG, "PenikServiceTokenProvider: malformed token response")
            return null
        }
        val expiresAtSeconds = element.getAttribute("expires")?.toLongOrNull()
            ?: (System.currentTimeMillis() / 1000 + FALLBACK_TTL_SECONDS)
        cache[account.jid.asBareJid().toString()] = CachedToken(token, expiresAtSeconds)
        return token
    }
}
