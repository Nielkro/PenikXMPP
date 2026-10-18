use crate::models::{
    PhoneDirectoryDetails, PhoneDirectoryEntry, PhoneDirectoryLookupEntry, Sticker, StickerPack,
};
use sha2::{Digest, Sha256};
use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};
use std::str::FromStr;

pub fn normalize_phone_digits(phone: &str) -> String {
    let mut digits: String = phone.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() == 11 && digits.starts_with('8') {
        digits.replace_range(0..1, "7");
    }
    digits
}

pub fn hash_phone(phone: &str) -> String {
    let digits = normalize_phone_digits(phone);
    let mut hasher = Sha256::new();
    hasher.update(digits.as_bytes());
    hex::encode(hasher.finalize())
}

pub async fn init_db(db_path: &str) -> anyhow::Result<SqlitePool> {
    if let Some(parent) = std::path::Path::new(db_path).parent() {
        if !parent.as_os_str().is_empty() {
            tokio::fs::create_dir_all(parent).await?;
        }
    }

    let opts = SqliteConnectOptions::from_str(db_path)?
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .synchronous(sqlx::sqlite::SqliteSynchronous::Normal);

    let pool = SqlitePool::connect_with(opts).await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS sticker_packs (
            id TEXT PRIMARY KEY,
            telegram_name TEXT UNIQUE,
            title TEXT NOT NULL,
            author_jid TEXT NOT NULL DEFAULT '',
            cover_sticker_id TEXT NOT NULL DEFAULT '',
            format TEXT NOT NULL DEFAULT 'static',
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_packs_tg_name ON sticker_packs(telegram_name);

        CREATE TABLE IF NOT EXISTS stickers (
            id TEXT PRIMARY KEY,
            pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
            emoji TEXT NOT NULL DEFAULT '',
            file_name TEXT NOT NULL,
            width INTEGER NOT NULL DEFAULT 512,
            height INTEGER NOT NULL DEFAULT 512,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_stickers_pack ON stickers(pack_id, sort_order);

        CREATE TABLE IF NOT EXISTS user_sticker_packs (
            user_jid TEXT NOT NULL,
            pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
            sort_order INTEGER NOT NULL DEFAULT 0,
            installed_at INTEGER NOT NULL,
            PRIMARY KEY (user_jid, pack_id)
        );
        CREATE INDEX IF NOT EXISTS idx_user_packs ON user_sticker_packs(user_jid, sort_order);

        CREATE TABLE IF NOT EXISTS phone_directory (
            jid TEXT PRIMARY KEY,
            phone TEXT NOT NULL,
            phone_hash TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_phone ON phone_directory(phone);
        "#,
    )
    .execute(&pool)
    .await?;

    // Migration: add phone_hash column if it doesn't exist yet
    let _ = sqlx::query("ALTER TABLE phone_directory ADD COLUMN phone_hash TEXT NOT NULL DEFAULT ''")
        .execute(&pool)
        .await;
    let _ = sqlx::query("CREATE INDEX IF NOT EXISTS idx_phone_hash ON phone_directory(phone_hash)")
        .execute(&pool)
        .await;

    // Backfill empty phone_hash for existing records
    let rows = sqlx::query_as::<_, PhoneDirectoryEntry>(
        "SELECT jid, phone, phone_hash, updated_at FROM phone_directory WHERE phone_hash = ''"
    )
    .fetch_all(&pool)
    .await
    .unwrap_or_default();

    for r in rows {
        let hash = hash_phone(&r.phone);
        let _ = sqlx::query("UPDATE phone_directory SET phone_hash = ? WHERE jid = ?")
            .bind(hash)
            .bind(&r.jid)
            .execute(&pool)
            .await;
    }

    Ok(pool)
}

pub async fn get_pack_by_id(pool: &SqlitePool, id: &str) -> anyhow::Result<Option<StickerPack>> {
    let pack = sqlx::query_as::<_, StickerPack>(
        "SELECT id, telegram_name, title, author_jid, cover_sticker_id, format, created_at FROM sticker_packs WHERE id = ?"
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(pack)
}

pub async fn get_pack_by_tg_name(pool: &SqlitePool, tg_name: &str) -> anyhow::Result<Option<StickerPack>> {
    let pack = sqlx::query_as::<_, StickerPack>(
        "SELECT id, telegram_name, title, author_jid, cover_sticker_id, format, created_at FROM sticker_packs WHERE telegram_name = ?"
    )
    .bind(tg_name)
    .fetch_optional(pool)
    .await?;
    Ok(pack)
}

pub async fn get_stickers_by_pack_id(pool: &SqlitePool, pack_id: &str) -> anyhow::Result<Vec<Sticker>> {
    let stickers = sqlx::query_as::<_, Sticker>(
        "SELECT id, pack_id, emoji, file_name, width, height, sort_order FROM stickers WHERE pack_id = ? ORDER BY sort_order ASC"
    )
    .bind(pack_id)
    .fetch_all(pool)
    .await?;
    Ok(stickers)
}

pub async fn save_pack_and_stickers(
    pool: &SqlitePool,
    pack: &StickerPack,
    stickers: &[Sticker],
) -> anyhow::Result<()> {
    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        INSERT INTO sticker_packs (id, telegram_name, title, author_jid, cover_sticker_id, format, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            telegram_name = excluded.telegram_name,
            title = excluded.title,
            cover_sticker_id = excluded.cover_sticker_id,
            format = excluded.format
        "#,
    )
    .bind(&pack.id)
    .bind(&pack.telegram_name)
    .bind(&pack.title)
    .bind(&pack.author_jid)
    .bind(&pack.cover_sticker_id)
    .bind(&pack.format)
    .bind(pack.created_at)
    .execute(&mut *tx)
    .await?;

    sqlx::query("DELETE FROM stickers WHERE pack_id = ?")
        .bind(&pack.id)
        .execute(&mut *tx)
        .await?;

    for s in stickers {
        sqlx::query(
            r#"
            INSERT INTO stickers (id, pack_id, emoji, file_name, width, height, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&s.id)
        .bind(&s.pack_id)
        .bind(&s.emoji)
        .bind(&s.file_name)
        .bind(s.width)
        .bind(s.height)
        .bind(s.sort_order)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

pub async fn is_pack_installed(pool: &SqlitePool, user_jid: &str, pack_id: &str) -> anyhow::Result<bool> {
    let exists: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM user_sticker_packs WHERE user_jid = ? AND pack_id = ?"
    )
    .bind(user_jid)
    .bind(pack_id)
    .fetch_optional(pool)
    .await?;
    Ok(exists.is_some())
}

pub async fn install_pack(pool: &SqlitePool, user_jid: &str, pack_id: &str) -> anyhow::Result<()> {
    let max_order: Option<i32> = sqlx::query_scalar(
        "SELECT MAX(sort_order) FROM user_sticker_packs WHERE user_jid = ?"
    )
    .bind(user_jid)
    .fetch_optional(pool)
    .await?;

    let next_order = max_order.unwrap_or(0) + 1;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    sqlx::query(
        r#"
        INSERT INTO user_sticker_packs (user_jid, pack_id, sort_order, installed_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_jid, pack_id) DO NOTHING
        "#,
    )
    .bind(user_jid)
    .bind(pack_id)
    .bind(next_order)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn uninstall_pack(pool: &SqlitePool, user_jid: &str, pack_id: &str) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM user_sticker_packs WHERE user_jid = ? AND pack_id = ?")
        .bind(user_jid)
        .bind(pack_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn get_user_installed_packs(pool: &SqlitePool, user_jid: &str) -> anyhow::Result<Vec<StickerPack>> {
    let packs = sqlx::query_as::<_, StickerPack>(
        r#"
        SELECT p.id, p.telegram_name, p.title, p.author_jid, p.cover_sticker_id, p.format, p.created_at
        FROM sticker_packs p
        JOIN user_sticker_packs u ON p.id = u.pack_id
        WHERE u.user_jid = ?
        ORDER BY u.sort_order ASC
        "#,
    )
    .bind(user_jid)
    .fetch_all(pool)
    .await?;
    Ok(packs)
}

pub async fn save_phone(pool: &SqlitePool, jid: &str, phone: &str) -> anyhow::Result<()> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let phone_hash = hash_phone(phone);

    sqlx::query(
        r#"
        INSERT INTO phone_directory (jid, phone, phone_hash, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(jid) DO UPDATE SET
            phone = excluded.phone,
            phone_hash = excluded.phone_hash,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(jid)
    .bind(phone)
    .bind(phone_hash)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn lookup_phone_hashes_by_prefixes(
    pool: &SqlitePool,
    prefixes: &[String],
) -> anyhow::Result<Vec<PhoneDirectoryLookupEntry>> {
    if prefixes.is_empty() {
        return Ok(Vec::new());
    }

    // Filter, lowercase, ensure valid hex prefix between 2 and 64 chars
    let mut clean_prefixes: Vec<String> = prefixes
        .iter()
        .map(|p| p.trim().to_lowercase())
        .filter(|p| p.len() >= 2 && p.len() <= 64 && p.chars().all(|c| c.is_ascii_hexdigit()))
        .collect();
    clean_prefixes.sort();
    clean_prefixes.dedup();
    clean_prefixes.truncate(500);

    if clean_prefixes.is_empty() {
        return Ok(Vec::new());
    }

    let mut all_results = Vec::new();
    let mut seen_jids = std::collections::HashSet::new();

    // Query in chunks of 50 to avoid huge SQL statements
    for chunk in clean_prefixes.chunks(50) {
        let placeholders = chunk.iter().map(|_| "phone_hash LIKE ?").collect::<Vec<_>>().join(" OR ");
        let sql = format!(
            "SELECT jid, phone_hash, updated_at FROM phone_directory WHERE {} LIMIT 1000",
            placeholders
        );

        let mut query = sqlx::query_as::<_, PhoneDirectoryLookupEntry>(&sql);
        for prefix in chunk {
            query = query.bind(format!("{}%", prefix));
        }

        let chunk_entries = query.fetch_all(pool).await?;
        for entry in chunk_entries {
            if seen_jids.insert(entry.jid.clone()) {
                all_results.push(entry);
            }
        }
    }

    Ok(all_results)
}

pub async fn get_phone_by_jid(pool: &SqlitePool, jid: &str) -> anyhow::Result<Option<PhoneDirectoryDetails>> {
    let entry = sqlx::query_as::<_, PhoneDirectoryDetails>(
        "SELECT jid, phone, phone_hash, updated_at FROM phone_directory WHERE jid = ?"
    )
    .bind(jid)
    .fetch_optional(pool)
    .await?;
    Ok(entry)
}

