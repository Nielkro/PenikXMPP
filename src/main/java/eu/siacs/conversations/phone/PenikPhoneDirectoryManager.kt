package eu.siacs.conversations.phone

import android.content.Context
import android.provider.ContactsContract
import android.util.Log
import eu.siacs.conversations.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

data class DirectoryEntry(
    val jid: String,
    val phoneHash: String,
    val updatedAt: Long
)

data class MatchedPhoneContact(
    val jid: String,
    val localName: String,
    val rawPhoneNumber: String
)

object PenikPhoneDirectoryManager {

    private const val TAG = "PenikPhoneDir"
    private const val SALT = "penik:"

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    fun normalizePhoneNumber(phone: String): String {
        return phone.replace(Regex("[^0-9+]"), "").lowercase()
    }

    fun hashPhoneNumber(phone: String): String {
        val normalized = normalizePhoneNumber(phone)
        val input = "$SALT$normalized"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun uploadPhoneHashAsync(jid: String, phoneNumber: String, authToken: String? = null) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
                val hash = hashPhoneNumber(phoneNumber)
                val json = JSONObject().apply {
                    put("jid", jid)
                    put("phone_hash", hash)
                }.toString()

                val requestBuilder = Request.Builder()
                    .url("$cleanBase/api/v1/phone-directory")
                    .post(json.toRequestBody("application/json".toMediaType()))

                if (!authToken.isNullOrBlank()) {
                    requestBuilder.addHeader("Authorization", "Bearer $authToken")
                }

                httpClient.newCall(requestBuilder.build()).execute().use { response ->
                    if (response.isSuccessful) {
                        Log.d(TAG, "Uploaded phone hash for $jid successfully")
                    } else {
                        Log.w(TAG, "Failed to upload phone hash: HTTP ${response.code}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error uploading phone hash for $jid", e)
            }
        }
    }

    suspend fun fetchPhoneDirectory(): Result<List<DirectoryEntry>> = withContext(Dispatchers.IO) {
        try {
            val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
            val request = Request.Builder()
                .url("$cleanBase/api/v1/phone-directory")
                .get()
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return@withContext Result.failure(Exception("HTTP ${response.code}"))
                }
                val bodyStr = response.body?.string() ?: ""
                val root = JSONObject(bodyStr)
                if (!root.optBoolean("ok", false)) {
                    val err = root.optString("error", "Unknown server error")
                    return@withContext Result.failure(Exception(err))
                }

                val dataArray = root.getJSONArray("data")
                val list = mutableListOf<DirectoryEntry>()
                for (i in 0 until dataArray.length()) {
                    val item = dataArray.getJSONObject(i)
                    list.add(
                        DirectoryEntry(
                            jid = item.getString("jid"),
                            phoneHash = item.getString("phone_hash"),
                            updatedAt = item.optLong("updated_at", 0L)
                        )
                    )
                }
                Result.success(list)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching phone directory", e)
            Result.failure(e)
        }
    }

    suspend fun matchLocalContacts(context: Context): List<MatchedPhoneContact> = withContext(Dispatchers.IO) {
        val directoryRes = fetchPhoneDirectory()
        if (directoryRes.isFailure) {
            return@withContext emptyList()
        }
        val directory = directoryRes.getOrNull() ?: return@withContext emptyList()
        if (directory.isEmpty()) {
            return@withContext emptyList()
        }

        // Map hash -> jid
        val hashMap = directory.associateBy({ it.phoneHash }, { it.jid })
        val matched = mutableListOf<MatchedPhoneContact>()

        try {
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            )
            val cursor = context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                projection,
                null,
                null,
                null
            )

            cursor?.use {
                val nameIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)

                while (it.moveToNext()) {
                    val name = if (nameIndex >= 0) it.getString(nameIndex) ?: "" else ""
                    val number = if (numberIndex >= 0) it.getString(numberIndex) ?: "" else ""
                    if (number.isNotBlank()) {
                        val computedHash = hashPhoneNumber(number)
                        val jid = hashMap[computedHash]
                        if (jid != null) {
                            matched.add(
                                MatchedPhoneContact(
                                    jid = jid,
                                    localName = name,
                                    rawPhoneNumber = number
                                )
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying ContactsContract", e)
        }

        matched.distinctBy { it.jid }
    }
}
