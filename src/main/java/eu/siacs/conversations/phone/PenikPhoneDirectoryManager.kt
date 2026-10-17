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
import java.util.concurrent.TimeUnit

data class DirectoryEntry(
    val jid: String,
    val phone: String,
    val updatedAt: Long
)

data class MatchedPhoneContact(
    val jid: String,
    val localName: String,
    val rawPhoneNumber: String
)

object PenikPhoneDirectoryManager {

    private const val TAG = "PenikPhoneDir"

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    fun normalizePhoneNumber(phone: String): String {
        val digits = phone.replace(Regex("[^0-9]"), "")
        if (digits.length == 11 && (digits.startsWith("7") || digits.startsWith("8"))) {
            return "+7" + digits.substring(1)
        }
        return if (phone.startsWith("+")) "+$digits" else digits
    }

    fun uploadPhoneAsync(jid: String, phoneNumber: String, authToken: String? = null) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
                val normalized = normalizePhoneNumber(phoneNumber)
                val json = JSONObject().apply {
                    put("jid", jid)
                    put("phone", normalized)
                }.toString()

                val requestBuilder = Request.Builder()
                    .url("$cleanBase/api/v1/phone-directory")
                    .post(json.toRequestBody("application/json".toMediaType()))

                if (!authToken.isNullOrBlank()) {
                    requestBuilder.addHeader("Authorization", "Bearer $authToken")
                }

                httpClient.newCall(requestBuilder.build()).execute().use { response ->
                    if (response.isSuccessful) {
                        Log.d(TAG, "Uploaded phone for $jid successfully")
                    } else {
                        Log.w(TAG, "Failed to upload phone: HTTP ${response.code}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error uploading phone for $jid", e)
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
                    val phone = item.optString("phone").ifEmpty { item.optString("phone_hash") }
                    list.add(
                        DirectoryEntry(
                            jid = item.getString("jid"),
                            phone = phone,
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

        // Map normalized phone (and last 10 digits) -> jid
        val phoneMap = mutableMapOf<String, String>()
        for (entry in directory) {
            val norm = normalizePhoneNumber(entry.phone)
            phoneMap[norm] = entry.jid
            val digits = norm.replace(Regex("[^0-9]"), "")
            if (digits.length >= 10) {
                phoneMap[digits.takeLast(10)] = entry.jid
            }
        }

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
                        val norm = normalizePhoneNumber(number)
                        val digits = norm.replace(Regex("[^0-9]"), "")
                        val jid = phoneMap[norm] ?: if (digits.length >= 10) phoneMap[digits.takeLast(10)] else null
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
