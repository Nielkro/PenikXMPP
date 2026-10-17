package eu.siacs.conversations.phone

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import eu.siacs.conversations.Config
import eu.siacs.conversations.android.PenikPhoneContact
import eu.siacs.conversations.entities.Contact
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.xmpp.Jid
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

fun interface PhoneLookupCallback {
    fun onResult(jid: String?)
}

object PenikPhoneDirectoryManager {

    private const val TAG = "PenikPhoneDir"

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    @Volatile
    private var cachedDirectory: List<DirectoryEntry>? = null

    @Volatile
    private var lastFetchTime = 0L

    @JvmStatic
    fun normalizePhoneNumber(phone: String): String {
        val digits = phone.replace(Regex("[^0-9]"), "")
        if (digits.length == 11 && (digits.startsWith("7") || digits.startsWith("8"))) {
            return "+7" + digits.substring(1)
        }
        return if (phone.startsWith("+")) "+$digits" else digits
    }

    @JvmStatic
    fun formatPhoneNumberHuman(phone: String): String {
        if (phone.isBlank()) return ""
        val digits = phone.replace(Regex("[^0-9]"), "")
        if (digits.length == 11 && (digits.startsWith("7") || digits.startsWith("8"))) {
            return "+7 ${digits.substring(1, 4)} ${digits.substring(4, 7)} ${digits.substring(7, 9)} ${digits.substring(9, 11)}"
        } else if (digits.length == 10) {
            return "+7 ${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6, 8)} ${digits.substring(8, 10)}"
        } else if (phone.startsWith("+")) {
            return when {
                digits.length == 12 && digits.startsWith("375") -> {
                    "+375 ${digits.substring(3, 5)} ${digits.substring(5, 8)} ${digits.substring(8, 10)} ${digits.substring(10, 12)}"
                }
                digits.length == 12 && digits.startsWith("380") -> {
                    "+380 ${digits.substring(3, 5)} ${digits.substring(5, 8)} ${digits.substring(8, 10)} ${digits.substring(10, 12)}"
                }
                digits.length == 11 && digits.startsWith("1") -> {
                    "+1 ${digits.substring(1, 4)} ${digits.substring(4, 7)} ${digits.substring(7, 11)}"
                }
                digits.length > 7 -> {
                    val ccLen = if (digits.length > 10) 2 else 1
                    "+${digits.substring(0, ccLen)} ${digits.substring(ccLen).chunked(3).joinToString(" ")}"
                }
                else -> phone
            }
        }
        return phone
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

    suspend fun fetchPhoneDirectory(forceRefresh: Boolean = false): Result<List<DirectoryEntry>> = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        if (!forceRefresh && cachedDirectory != null && (now - lastFetchTime < 30_000L)) {
            return@withContext Result.success(cachedDirectory!!)
        }

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
                cachedDirectory = list
                lastFetchTime = now
                Result.success(list)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching phone directory", e)
            if (cachedDirectory != null) {
                Result.success(cachedDirectory!!)
            } else {
                Result.failure(e)
            }
        }
    }

    @JvmStatic
    fun syncPhoneContacts(service: XmppConnectionService, onComplete: Runnable? = null) {
        if (ContextCompat.checkSelfPermission(
                service,
                Manifest.permission.READ_CONTACTS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            onComplete?.let { Handler(Looper.getMainLooper()).post(it) }
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val directoryRes = fetchPhoneDirectory(forceRefresh = true)
                val directory = directoryRes.getOrNull() ?: cachedDirectory ?: emptyList()
                if (directory.isEmpty()) {
                    onComplete?.let { Handler(Looper.getMainLooper()).post(it) }
                    return@launch
                }

                val phoneMap = mutableMapOf<String, String>()
                for (entry in directory) {
                    val norm = normalizePhoneNumber(entry.phone)
                    phoneMap[norm] = entry.jid
                    val digits = norm.replace(Regex("[^0-9]"), "")
                    if (digits.length >= 10) {
                        phoneMap[digits.takeLast(10)] = entry.jid
                    }
                }

                val projection = arrayOf(
                    ContactsContract.Data._ID,
                    ContactsContract.Data.LOOKUP_KEY,
                    ContactsContract.Data.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.Data.PHOTO_URI
                )

                val cursor = service.contentResolver.query(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    projection,
                    null,
                    null,
                    null
                )

                cursor?.use { c ->
                    val numIdx = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                    while (c.moveToNext()) {
                        val number = if (numIdx >= 0) c.getString(numIdx) ?: "" else ""
                        if (number.isNotBlank()) {
                            val norm = normalizePhoneNumber(number)
                            val digits = norm.replace(Regex("[^0-9]"), "")
                            val matchedJid = phoneMap[norm] ?: if (digits.length >= 10) phoneMap[digits.takeLast(10)] else null
                            if (matchedJid != null) {
                                try {
                                    val jid = Jid.of(matchedJid)
                                    val phoneContact = PenikPhoneContact(c)
                                    for (account in service.accounts) {
                                        if (account.isEnabled) {
                                            val contact = account.roster.getContact(jid)
                                            contact.setPhoneContact(phoneContact)
                                            contact.setPhoneNumber(norm)
                                            contact.setOption(Contact.Options.SYNCED_VIA_OTHER)
                                        }
                                    }
                                } catch (e: Exception) {
                                    Log.w(TAG, "Error applying phone contact for $matchedJid", e)
                                }
                            }
                        }
                    }
                }
                service.updateRosterUi()
            } catch (e: Exception) {
                Log.e(TAG, "Error during syncPhoneContacts", e)
            } finally {
                onComplete?.let { Handler(Looper.getMainLooper()).post(it) }
            }
        }
    }

    @JvmStatic
    fun lookupJidByPhone(phone: String, callback: PhoneLookupCallback) {
        val norm = normalizePhoneNumber(phone)
        val digits = norm.replace(Regex("[^0-9]"), "")
        CoroutineScope(Dispatchers.IO).launch {
            val directory = cachedDirectory ?: fetchPhoneDirectory().getOrNull() ?: emptyList()
            var foundJid: String? = null
            for (entry in directory) {
                val entryNorm = normalizePhoneNumber(entry.phone)
                val entryDigits = entryNorm.replace(Regex("[^0-9]"), "")
                if (entryNorm == norm || (digits.length >= 10 && entryDigits.endsWith(digits.takeLast(10)))) {
                    foundJid = entry.jid
                    break
                }
            }
            Handler(Looper.getMainLooper()).post {
                callback.onResult(foundJid)
            }
        }
    }

    @JvmStatic
    fun openContactOrInvite(activity: Activity, service: XmppConnectionService, contactUri: Uri) {
        CoroutineScope(Dispatchers.IO).launch {
            var rawName = ""
            var rawNumber = ""
            var lookupUri: Uri? = null
            var photoUri: String? = null

            try {
                val projection = arrayOf(
                    ContactsContract.Data._ID,
                    ContactsContract.Data.LOOKUP_KEY,
                    ContactsContract.Data.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.Data.PHOTO_URI
                )
                activity.contentResolver.query(contactUri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIdx = cursor.getColumnIndex(ContactsContract.Data.DISPLAY_NAME)
                        val numIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                        val photoIdx = cursor.getColumnIndex(ContactsContract.Data.PHOTO_URI)
                        val idIdx = cursor.getColumnIndex(ContactsContract.Data._ID)
                        val lookupIdx = cursor.getColumnIndex(ContactsContract.Data.LOOKUP_KEY)

                        if (nameIdx >= 0) rawName = cursor.getString(nameIdx) ?: ""
                        if (numIdx >= 0) rawNumber = cursor.getString(numIdx) ?: ""
                        if (photoIdx >= 0) photoUri = cursor.getString(photoIdx)
                        if (idIdx >= 0 && lookupIdx >= 0) {
                            val id = cursor.getLong(idIdx)
                            val lookup = cursor.getString(lookupIdx)
                            lookupUri = ContactsContract.Contacts.getLookupUri(id, lookup)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error querying picked contact", e)
            }

            if (rawNumber.isBlank()) {
                Handler(Looper.getMainLooper()).post {
                    MaterialAlertDialogBuilder(activity)
                        .setTitle("Контакт")
                        .setMessage("У выбранного контакта не указан номер телефона.")
                        .setPositiveButton("OK", null)
                        .show()
                }
                return@launch
            }

            val norm = normalizePhoneNumber(rawNumber)
            val digits = norm.replace(Regex("[^0-9]"), "")
            val directory = cachedDirectory ?: fetchPhoneDirectory(forceRefresh = true).getOrNull() ?: emptyList()
            var matchedJid: String? = null
            for (entry in directory) {
                val entryNorm = normalizePhoneNumber(entry.phone)
                val entryDigits = entryNorm.replace(Regex("[^0-9]"), "")
                if (entryNorm == norm || (digits.length >= 10 && entryDigits.endsWith(digits.takeLast(10)))) {
                    matchedJid = entry.jid
                    break
                }
            }

            Handler(Looper.getMainLooper()).post {
                if (matchedJid != null) {
                    val account = service.accounts.firstOrNull { it.isEnabled }
                    if (account != null) {
                        try {
                            val jid = Jid.of(matchedJid)
                            val contact = account.roster.getContact(jid)
                            if (rawName.isNotBlank()) contact.setSystemName(rawName)
                            contact.setPhoneNumber(norm)
                            contact.setOption(Contact.Options.SYNCED_VIA_OTHER)
                            if (lookupUri != null) contact.setSystemAccount(lookupUri)
                            if (photoUri != null) contact.setPhotoUri(photoUri)
                            service.updateRosterUi()

                            val conversation = service.findOrCreateConversation(account, contact.address, false, true)
                            (activity as? XmppActivity)?.switchToConversation(conversation)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error opening conversation with $matchedJid", e)
                        }
                    }
                } else {
                    val formatted = formatPhoneNumberHuman(norm)
                    val titleName = rawName.ifBlank { formatted }
                    MaterialAlertDialogBuilder(activity)
                        .setTitle(titleName)
                        .setMessage("Пользователь с номером $formatted ещё не зарегистрирован в Penik.\n\nХотите отправить приглашение?")
                        .setPositiveButton("Пригласить") { _, _ ->
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, "Привет! Давай общаться в Penik: https://penik.ru")
                            }
                            activity.startActivity(Intent.createChooser(sendIntent, "Пригласить в Penik"))
                        }
                        .setNegativeButton("Отмена", null)
                        .show()
                }
            }
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
