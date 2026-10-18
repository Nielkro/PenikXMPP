package eu.siacs.conversations.stickers

import android.content.Context
import android.util.Log
import eu.siacs.conversations.Config
import eu.siacs.conversations.entities.Sticker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

data class StickerPackHeader(
    val id: String,
    val title: String,
    val coverStickerId: String,
    val format: String,
    val telegramName: String? = null
)

data class StickerItem(
    val id: String,
    val packId: String,
    val emoji: String,
    val fileName: String,
    val width: Int,
    val height: Int,
    val format: String,
    val url: String = ""
)

data class StickerPackWithItems(
    val header: StickerPackHeader,
    val stickers: List<StickerItem>
)

class StickerManager private constructor(private val context: Context) {

    private val httpClient = OkHttpClient.Builder().build()
    private val stickersDir: File = File(context.filesDir, "stickers").apply { mkdirs() }
    private val recentFile: File = File(stickersDir, "recent.json")

    private val _installedPacks = MutableStateFlow<List<StickerPackWithItems>>(emptyList())
    val installedPacks: StateFlow<List<StickerPackWithItems>> = _installedPacks.asStateFlow()

    private val _recentStickers = MutableStateFlow<List<StickerItem>>(emptyList())
    val recentStickers: StateFlow<List<StickerItem>> = _recentStickers.asStateFlow()

    init {
        refreshPacks()
        refreshRecent()
    }

    fun refreshPacks() {
        val packs = mutableListOf<StickerPackWithItems>()
        val packDirs = stickersDir.listFiles { f -> f.isDirectory } ?: emptyArray()

        for (dir in packDirs) {
            val packJsonFile = File(dir, "pack.json")
            if (packJsonFile.exists()) {
                try {
                    val jsonStr = packJsonFile.readText()
                    val root = JSONObject(jsonStr)
                    val packObj = if (root.has("pack")) root.getJSONObject("pack") else root
                    val id = packObj.optString("id", dir.name)
                    val title = packObj.optString("title", id)
                    val cover = packObj.optString("cover_sticker_id", "")
                    val format = packObj.optString("format", Sticker.FORMAT_STATIC)
                    val tgName = if (packObj.has("telegram_name")) packObj.optString("telegram_name") else null

                    val header = StickerPackHeader(id, title, cover, format, tgName)
                    val items = mutableListOf<StickerItem>()
                    val stickersArray = root.optJSONArray("stickers") ?: JSONArray()

                    for (i in 0 until stickersArray.length()) {
                        val s = stickersArray.getJSONObject(i)
                        val sId = s.optString("id")
                        val pId = s.optString("pack_id", id)
                        val rawUrl = s.optString("url", "")
                        val ext = if (format == Sticker.FORMAT_ANIMATED) "tgs" else "webp"
                        val fName = s.optString("file_name").takeIf { it.isNotBlank() } ?: "$sId.$ext"
                        val itemUrl = if (rawUrl.isNotBlank()) rawUrl else "${Config.STICKERS_BASE_URL}/api/v1/stickers/file/$pId/$fName"
                        items.add(
                            StickerItem(
                                id = sId,
                                packId = pId,
                                emoji = s.optString("emoji", ""),
                                fileName = fName,
                                width = s.optInt("width", 512),
                                height = s.optInt("height", 512),
                                format = format,
                                url = itemUrl
                            )
                        )
                    }
                    packs.add(StickerPackWithItems(header, items))
                } catch (e: Exception) {
                    Log.e(Config.LOGTAG, "Failed to parse pack.json in ${dir.name}", e)
                }
            }
        }
        _installedPacks.value = packs
    }

    fun refreshRecent() {
        if (!recentFile.exists()) {
            _recentStickers.value = emptyList()
            return
        }
        try {
            val jsonArray = JSONArray(recentFile.readText())
            val list = mutableListOf<StickerItem>()
            for (i in 0 until jsonArray.length()) {
                val s = jsonArray.getJSONObject(i)
                val sId = s.optString("id")
                val pId = s.optString("pack_id")
                val sFormat = s.optString("format", Sticker.FORMAT_STATIC)
                val rawUrl = s.optString("url", "")
                val ext = if (sFormat == Sticker.FORMAT_ANIMATED) "tgs" else "webp"
                val fName = s.optString("file_name").takeIf { it.isNotBlank() } ?: "$sId.$ext"
                val itemUrl = if (rawUrl.isNotBlank()) rawUrl else "${Config.STICKERS_BASE_URL}/api/v1/stickers/file/$pId/$fName"
                list.add(
                    StickerItem(
                        id = sId,
                        packId = pId,
                        emoji = s.optString("emoji", ""),
                        fileName = fName,
                        width = s.optInt("width", 512),
                        height = s.optInt("height", 512),
                        format = sFormat,
                        url = itemUrl
                    )
                )
            }
            _recentStickers.value = list
        } catch (e: Exception) {
            Log.e(Config.LOGTAG, "Failed to load recent stickers", e)
        }
    }

    fun addRecentSticker(sticker: Sticker) {
        val current = _recentStickers.value.toMutableList()
        current.removeAll { it.id == sticker.stickerId() }
        current.add(
            0,
            StickerItem(
                id = sticker.stickerId(),
                packId = sticker.packId(),
                emoji = sticker.emoji(),
                fileName = "${sticker.stickerId()}.${if (sticker.format() == Sticker.FORMAT_ANIMATED) "tgs" else "webp"}",
                width = sticker.width(),
                height = sticker.height(),
                format = sticker.format(),
                url = sticker.url()
            )
        )
        val trimmed = current.take(30)
        _recentStickers.value = trimmed

        try {
            val array = JSONArray()
            for (item in trimmed) {
                val obj = JSONObject()
                obj.put("id", item.id)
                obj.put("pack_id", item.packId)
                obj.put("emoji", item.emoji)
                obj.put("file_name", item.fileName)
                obj.put("width", item.width)
                obj.put("height", item.height)
                obj.put("format", item.format)
                obj.put("url", item.url)
                array.put(obj)
            }
            recentFile.writeText(array.toString())
        } catch (e: Exception) {
            Log.e(Config.LOGTAG, "Failed to save recent stickers", e)
        }
    }

    fun getStickerFile(packId: String, fileName: String): File? {
        val file = File(stickersDir, "$packId/$fileName")
        return if (file.exists() && file.length() > 0L) file else null
    }

    fun getStickerThumbFile(packId: String, stickerId: String): File? {
        val file = File(stickersDir, "$packId/thumb_$stickerId.webp")
        return if (file.exists() && file.length() > 0L) file else null
    }

    suspend fun installBundle(packId: String, zipBytes: ByteArray) = withContext(Dispatchers.IO) {
        val targetDir = File(stickersDir, packId)
        if (!targetDir.exists()) {
            targetDir.mkdirs()
        }

        ZipInputStream(zipBytes.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val entryFile = File(targetDir, entry.name)
                // Prevent path traversal
                if (!entryFile.canonicalPath.startsWith(targetDir.canonicalPath)) {
                    entry = zis.nextEntry
                    continue
                }

                if (entry.isDirectory) {
                    entryFile.mkdirs()
                } else {
                    entryFile.parentFile?.mkdirs()
                    FileOutputStream(entryFile).use { fos ->
                        zis.copyTo(fos)
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
        refreshPacks()
    }

    suspend fun importTelegramPack(
        baseUrl: String,
        token: String,
        linkOrName: String
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val cleanBase = baseUrl.trimEnd('/')
            val jsonBody = JSONObject().apply {
                put("name", linkOrName.trim())
            }.toString()

            val importReq = Request.Builder()
                .url("$cleanBase/api/v1/stickers/import/telegram")
                .addHeader("Authorization", "Bearer $token")
                .post(jsonBody.toRequestBody("application/json".toMediaType()))
                .build()

            val importRes = httpClient.newCall(importReq).execute()
            val resStr = importRes.body.string()
            val root = try { JSONObject(resStr) } catch (_: Exception) { null }
            if (!importRes.isSuccessful || root == null || !root.optBoolean("ok", false)) {
                val serverErr = root?.optString("error")?.takeIf { it.isNotEmpty() }
                val errorMsg = serverErr ?: "HTTP ${importRes.code}"
                return@withContext Result.failure(Exception(errorMsg))
            }

            val packObj = root.getJSONObject("data").getJSONObject("pack")
            val packId = packObj.getString("id")

            // Download bundle.zip
            val bundleReq = Request.Builder()
                .url("$cleanBase/api/v1/stickers/pack/$packId/bundle.zip")
                .build()

            val bundleRes = httpClient.newCall(bundleReq).execute()
            if (!bundleRes.isSuccessful) {
                return@withContext Result.failure(Exception("Bundle download failed: HTTP ${bundleRes.code}"))
            }

            val zipBytes = bundleRes.body.bytes()
            installBundle(packId, zipBytes)

            Result.success(packId)
        } catch (e: Exception) {
            Log.e(Config.LOGTAG, "Error importing telegram sticker pack", e)
            Result.failure(e)
        }
    }

    fun deletePack(packId: String) {
        val dir = File(stickersDir, packId)
        if (dir.exists()) {
            dir.deleteRecursively()
        }
        refreshPacks()
    }

    companion object {
        @Volatile
        private var INSTANCE: StickerManager? = null

        fun getInstance(context: Context): StickerManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: StickerManager(context.applicationContext).also { INSTANCE = it }
            }
        }

        fun createAuthToken(userJid: String, sharedSecret: String = "penik_secret_shared_key"): String {
            val expiresAt = System.currentTimeMillis() / 1000 + 86400 * 7
            val raw = "$userJid:$expiresAt"
            val mac = javax.crypto.Mac.getInstance("HmacSHA256")
            mac.init(javax.crypto.spec.SecretKeySpec(sharedSecret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
            val sigBytes = mac.doFinal(raw.toByteArray(Charsets.UTF_8))
            val sigHex = sigBytes.joinToString("") { "%02x".format(it) }
            val full = "$raw:$sigHex"
            return android.util.Base64.encodeToString(full.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
        }
    }
}
