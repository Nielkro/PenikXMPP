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
import eu.siacs.conversations.Conversations
import eu.siacs.conversations.android.PenikPhoneContact
import eu.siacs.conversations.entities.Contact
import eu.siacs.conversations.persistance.DatabaseBackend
import eu.siacs.conversations.services.XmppConnectionService
import eu.siacs.conversations.stickers.StickerManager
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
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

data class PhoneDirectoryLookupEntry(
    val jid: String,
    val phoneHash: String,
    val updatedAt: Long
)

data class PhoneDirectoryDetails(
    val jid: String,
    val phone: String,
    val phoneHash: String,
    val updatedAt: Long
)

// Backwards-compatibility alias
typealias DirectoryEntry = PhoneDirectoryDetails

data class MatchedPhoneContact(
    val jid: String,
    val localName: String,
    val rawPhoneNumber: String
)

fun interface PhoneLookupCallback {
    fun onResult(result: String?)
}

object PenikPhoneDirectoryManager {

    private const val TAG = "PenikPhoneDir"

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    @Volatile
    private var activeUserJid: String? = null

    // Cache of resolved matches:
    // phone digits -> JID
    private val cachedPhoneToJid = ConcurrentHashMap<String, String>()
    // full phone hash -> JID
    private val cachedHashToJid = ConcurrentHashMap<String, String>()
    // JID -> normalized phone
    private val cachedJidToPhone = ConcurrentHashMap<String, String>()
    // Cached lookup entries from prefix queries
    private val cachedLookupEntries = ConcurrentHashMap<String, PhoneDirectoryLookupEntry>()

    @JvmStatic
    fun normalizePhoneDigits(phone: String): String {
        val digits = phone.filter { it.isDigit() }
        if (digits.length == 11 && (digits.startsWith("7") || digits.startsWith("8"))) {
            return "7" + digits.substring(1)
        }
        return digits
    }

    @JvmStatic
    fun hashPhone(phone: String): String {
        val digits = normalizePhoneDigits(phone)
        if (digits.isEmpty()) return ""
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(digits.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

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

    fun getAuthToken(preferredJid: String? = null): String {
        val jid = preferredJid
            ?: activeUserJid
            ?: try {
                val ctx = Conversations.getContext()
                if (ctx != null) {
                    DatabaseBackend.getInstance(ctx).accounts.firstOrNull { it.isEnabled }?.jid?.asBareJid()?.toString()
                } else null
            } catch (_: Exception) { null }
            ?: "anonymous@penik.ru"
        return StickerManager.createAuthToken(jid)
    }

    fun uploadPhoneAsync(jid: String, phoneNumber: String, authToken: String? = null) {
        val cleanJid = jid.trim().lowercase()
        activeUserJid = cleanJid
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
                val normalized = normalizePhoneNumber(phoneNumber)
                val token = if (!authToken.isNullOrBlank()) authToken else getAuthToken(cleanJid)

                val json = JSONObject().apply {
                    put("phone", normalized)
                }.toString()

                val request = Request.Builder()
                    .url("$cleanBase/api/v1/phone-directory")
                    .addHeader("Authorization", "Bearer $token")
                    .post(json.toRequestBody("application/json".toMediaType()))
                    .build()

                httpClient.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Log.d(TAG, "Uploaded phone for $cleanJid successfully")
                        val digits = normalizePhoneDigits(normalized)
                        val hash = hashPhone(normalized)
                        cachedPhoneToJid[digits] = cleanJid
                        cachedHashToJid[hash] = cleanJid
                        cachedJidToPhone[cleanJid] = normalized
                    } else {
                        Log.w(TAG, "Failed to upload phone: HTTP ${response.code}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error uploading phone for $cleanJid", e)
            }
        }
    }

    suspend fun lookupHashesByPrefixes(
        prefixes: Collection<String>,
        authToken: String
    ): Result<List<PhoneDirectoryLookupEntry>> = withContext(Dispatchers.IO) {
        if (prefixes.isEmpty()) {
            return@withContext Result.success(emptyList())
        }
        try {
            val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
            val jsonArray = JSONArray()
            for (p in prefixes) {
                val clean = p.trim().lowercase()
                if (clean.length >= 2) {
                    jsonArray.put(clean)
                }
            }
            if (jsonArray.length() == 0) {
                return@withContext Result.success(emptyList())
            }

            val requestBody = JSONObject().apply {
                put("prefixes", jsonArray)
            }.toString()

            val request = Request.Builder()
                .url("$cleanBase/api/v1/phone-directory/lookup")
                .addHeader("Authorization", "Bearer $authToken")
                .post(requestBody.toRequestBody("application/json".toMediaType()))
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return@withContext Result.failure(Exception("HTTP ${response.code}"))
                }
                val bodyStr = response.body.string()
                val root = JSONObject(bodyStr)
                if (!root.optBoolean("ok", false)) {
                    val err = root.optString("error", "Unknown server error")
                    return@withContext Result.failure(Exception(err))
                }

                val dataArray = root.getJSONArray("data")
                val list = mutableListOf<PhoneDirectoryLookupEntry>()
                for (i in 0 until dataArray.length()) {
                    val item = dataArray.getJSONObject(i)
                    val entry = PhoneDirectoryLookupEntry(
                        jid = item.getString("jid"),
                        phoneHash = item.getString("phone_hash"),
                        updatedAt = item.optLong("updated_at", 0L)
                    )
                    list.add(entry)
                    cachedLookupEntries[entry.phoneHash] = entry
                }
                Result.success(list)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error looking up phone hashes by prefixes", e)
            Result.failure(e)
        }
    }

    suspend fun fetchPhoneByJid(
        targetJid: String,
        authToken: String
    ): Result<PhoneDirectoryDetails> = withContext(Dispatchers.IO) {
        val cleanJid = targetJid.trim().lowercase()
        val cachedPhone = cachedJidToPhone[cleanJid]
        if (cachedPhone != null) {
            return@withContext Result.success(
                PhoneDirectoryDetails(
                    jid = cleanJid,
                    phone = cachedPhone,
                    phoneHash = hashPhone(cachedPhone),
                    updatedAt = System.currentTimeMillis() / 1000
                )
            )
        }

        try {
            val cleanBase = Config.STICKERS_BASE_URL.trimEnd('/')
            val encodedJid = Uri.encode(cleanJid)
            val request = Request.Builder()
                .url("$cleanBase/api/v1/phone-directory/$encodedJid")
                .addHeader("Authorization", "Bearer $authToken")
                .get()
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return@withContext Result.failure(Exception("HTTP ${response.code}"))
                }
                val bodyStr = response.body.string()
                val root = JSONObject(bodyStr)
                if (!root.optBoolean("ok", false)) {
                    val err = root.optString("error", "Unknown error")
                    return@withContext Result.failure(Exception(err))
                }
                val data = root.getJSONObject("data")
                val details = PhoneDirectoryDetails(
                    jid = data.getString("jid"),
                    phone = data.getString("phone"),
                    phoneHash = data.optString("phone_hash", ""),
                    updatedAt = data.optLong("updated_at", 0L)
                )
                cachedJidToPhone[details.jid] = details.phone
                val digits = normalizePhoneDigits(details.phone)
                cachedPhoneToJid[digits] = details.jid
                if (details.phoneHash.isNotEmpty()) {
                    cachedHashToJid[details.phoneHash] = details.jid
                }
                Result.success(details)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching phone for $targetJid", e)
            Result.failure(e)
        }
    }

    @JvmStatic
    fun fetchPhoneForJidAsync(targetJid: String, userJid: String, callback: PhoneLookupCallback) {
        val cachedPhone = cachedJidToPhone[targetJid.trim().lowercase()]
        if (cachedPhone != null) {
            callback.onResult(cachedPhone)
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            val token = getAuthToken(userJid)
            val details = fetchPhoneByJid(targetJid, token).getOrNull()
            Handler(Looper.getMainLooper()).post {
                callback.onResult(details?.phone)
            }
        }
    }

    private data class LocalContactRecord(
        val displayName: String,
        val normPhone: String,
        val digits: String,
        val hash: String,
        val phoneContact: PenikPhoneContact
    )

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

        val account = service.accounts.firstOrNull { it.isEnabled }
        if (account == null) {
            onComplete?.let { Handler(Looper.getMainLooper()).post(it) }
            return
        }
        val userJid = account.jid.asBareJid().toString()
        activeUserJid = userJid
        val authToken = getAuthToken(userJid)

        CoroutineScope(Dispatchers.IO).launch {
            try {
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

                val localContacts = mutableListOf<LocalContactRecord>()
                val localContactsByHash = mutableMapOf<String, MutableList<LocalContactRecord>>()

                cursor?.use { c ->
                    val numIdx = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                    val nameIdx = c.getColumnIndex(ContactsContract.Data.DISPLAY_NAME)
                    while (c.moveToNext()) {
                        val number = if (numIdx >= 0) c.getString(numIdx) ?: "" else ""
                        if (number.isNotBlank()) {
                            val norm = normalizePhoneNumber(number)
                            val digits = normalizePhoneDigits(norm)
                            val hash = hashPhone(norm)
                            val name = if (nameIdx >= 0) c.getString(nameIdx) ?: "" else ""
                            if (hash.isNotEmpty()) {
                                val rec = LocalContactRecord(
                                    displayName = name,
                                    normPhone = norm,
                                    digits = digits,
                                    hash = hash,
                                    phoneContact = PenikPhoneContact(c)
                                )
                                localContacts.add(rec)
                                localContactsByHash.getOrPut(hash) { mutableListOf() }.add(rec)
                            }
                        }
                    }
                }

                if (localContactsByHash.isEmpty()) {
                    onComplete?.let { Handler(Looper.getMainLooper()).post(it) }
                    return@launch
                }

                // Collect k-anonymity prefixes (first 3 hex characters)
                val prefixes = localContactsByHash.keys.map { it.take(3) }.distinct()
                val lookupResult = lookupHashesByPrefixes(prefixes, authToken).getOrNull() ?: emptyList()

                var matchedCount = 0
                for (entry in lookupResult) {
                    val matchingLocalRecords = localContactsByHash[entry.phoneHash] ?: continue
                    val targetJidStr = entry.jid
                    val targetJid = try { Jid.of(targetJidStr) } catch (_: Exception) { continue }

                    if (account.jid.asBareJid().equals(targetJid.asBareJid())) {
                        continue
                    }

                    for (localRec in matchingLocalRecords) {
                        cachedPhoneToJid[localRec.digits] = targetJidStr
                        if (localRec.digits.length >= 10) {
                            cachedPhoneToJid[localRec.digits.takeLast(10)] = targetJidStr
                        }
                        cachedHashToJid[localRec.hash] = targetJidStr
                        cachedJidToPhone[targetJidStr] = localRec.normPhone

                        val contact = account.roster.getContact(targetJid)
                        if (!contact.isSelf) {
                            contact.setPhoneContact(localRec.phoneContact)
                            contact.setPhoneNumber(localRec.normPhone)
                            contact.setOption(Contact.Options.SYNCED_VIA_OTHER)
                            matchedCount++
                        }
                    }
                }

                if (matchedCount > 0) {
                    service.updateRosterUi()
                }
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
        val digits = normalizePhoneDigits(norm)

        val cached = cachedPhoneToJid[digits] ?: if (digits.length >= 10) cachedPhoneToJid[digits.takeLast(10)] else null
        if (cached != null) {
            callback.onResult(cached)
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            val hash = hashPhone(norm)
            var matchedJid = cachedHashToJid[hash]

            if (matchedJid == null && hash.isNotEmpty()) {
                val token = getAuthToken()
                val prefix = hash.take(3)
                val candidates = lookupHashesByPrefixes(listOf(prefix), token).getOrNull() ?: emptyList()
                val match = candidates.firstOrNull { it.phoneHash.equals(hash, ignoreCase = true) }
                if (match != null) {
                    matchedJid = match.jid
                    cachedPhoneToJid[digits] = matchedJid
                    cachedHashToJid[hash] = matchedJid
                }
            }

            Handler(Looper.getMainLooper()).post {
                callback.onResult(matchedJid)
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
            val digits = normalizePhoneDigits(norm)
            val hash = hashPhone(norm)

            var matchedJid = cachedPhoneToJid[digits]
                ?: (if (digits.length >= 10) cachedPhoneToJid[digits.takeLast(10)] else null)
                ?: cachedHashToJid[hash]

            if (matchedJid == null && hash.isNotEmpty()) {
                val account = service.accounts.firstOrNull { it.isEnabled }
                val token = getAuthToken(account?.jid?.asBareJid()?.toString())
                val candidates = lookupHashesByPrefixes(listOf(hash.take(3)), token).getOrNull() ?: emptyList()
                val match = candidates.firstOrNull { it.phoneHash.equals(hash, ignoreCase = true) }
                if (match != null) {
                    matchedJid = match.jid
                    cachedPhoneToJid[digits] = matchedJid
                    cachedHashToJid[hash] = matchedJid
                    cachedJidToPhone[matchedJid] = norm
                }
            }

            Handler(Looper.getMainLooper()).post {
                if (matchedJid != null) {
                    val account = service.accounts.firstOrNull { it.isEnabled }
                    if (account != null) {
                        try {
                            val jid = Jid.of(matchedJid)
                            val contact = account.roster.getContact(jid)
                            if (!contact.isSelf) {
                                if (rawName.isNotBlank()) contact.setSystemName(rawName)
                                contact.setPhoneNumber(norm)
                                contact.setOption(Contact.Options.SYNCED_VIA_OTHER)
                                if (lookupUri != null) contact.setSystemAccount(lookupUri)
                                if (photoUri != null) contact.setPhotoUri(photoUri)
                            }
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

            val contactsToLookup = mutableListOf<Pair<String, String>>() // (name, norm)
            val hashes = mutableMapOf<String, Pair<String, String>>()

            cursor?.use {
                val nameIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)

                while (it.moveToNext()) {
                    val name = if (nameIndex >= 0) it.getString(nameIndex) ?: "" else ""
                    val number = if (numberIndex >= 0) it.getString(numberIndex) ?: "" else ""
                    if (number.isNotBlank()) {
                        val norm = normalizePhoneNumber(number)
                        val digits = normalizePhoneDigits(norm)
                        val cachedJid = cachedPhoneToJid[digits] ?: if (digits.length >= 10) cachedPhoneToJid[digits.takeLast(10)] else null
                        if (cachedJid != null) {
                            matched.add(MatchedPhoneContact(jid = cachedJid, localName = name, rawPhoneNumber = number))
                        } else {
                            val hash = hashPhone(norm)
                            if (hash.isNotEmpty()) {
                                hashes[hash] = Pair(name, number)
                            }
                        }
                    }
                }
            }

            if (hashes.isNotEmpty()) {
                val prefixes = hashes.keys.map { it.take(3) }.distinct()
                val token = getAuthToken()
                val results = lookupHashesByPrefixes(prefixes, token).getOrNull() ?: emptyList()
                for (entry in results) {
                    val pair = hashes[entry.phoneHash]
                    if (pair != null) {
                        cachedHashToJid[entry.phoneHash] = entry.jid
                        val digits = normalizePhoneDigits(pair.second)
                        cachedPhoneToJid[digits] = entry.jid
                        matched.add(
                            MatchedPhoneContact(
                                jid = entry.jid,
                                localName = pair.first,
                                rawPhoneNumber = pair.second
                            )
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying ContactsContract", e)
        }

        matched.distinctBy { it.jid }
    }
}
