use crate::models::{PhoneDirectoryEntry, Sticker, StickerPack};
use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};
use std::str::FromStr;

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
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_phone ON phone_directory(phone);
        "#,
    )
    .execute(&pool)
    .await?;

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

    sqlx::query(
        r#"
        INSERT INTO phone_directory (jid, phone, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(jid) DO UPDATE SET
            phone = excluded.phone,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(jid)
    .bind(phone)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn get_phone_directory(pool: &SqlitePool) -> anyhow::Result<Vec<PhoneDirectoryEntry>> {
    let entries = sqlx::query_as::<_, PhoneDirectoryEntry>(
        "SELECT jid, phone, updated_at FROM phone_directory ORDER BY updated_at DESC"
    )
    .fetch_all(pool)
    .await?;
    Ok(entries)
}
