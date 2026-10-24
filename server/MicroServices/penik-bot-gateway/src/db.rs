use serde::{Deserialize, Serialize};
use sqlx::{sqlite::SqliteConnectOptions, FromRow, SqlitePool};
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct BotRecord {
    pub id: i64,
    pub username: String,
    pub token: String,
    pub title: String,
    pub about: Option<String>,
    pub avatar_url: Option<String>,
    pub owner_jid: String,
    pub webhook_url: Option<String>,
    pub fail_count: i64,
    pub is_active: bool,
    pub commands_json: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct PendingUpdateRecord {
    pub id: i64,
    pub bot_id: i64,
    pub update_data: String,
    pub created_at: i64,
}

pub fn current_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
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
        CREATE TABLE IF NOT EXISTS bots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            token TEXT UNIQUE NOT NULL,
            title TEXT NOT NULL,
            about TEXT,
            avatar_url TEXT,
            owner_jid TEXT NOT NULL,
            webhook_url TEXT,
            fail_count INTEGER DEFAULT 0,
            is_active BOOLEAN DEFAULT 1,
            commands_json TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_bots_token ON bots(token);
        CREATE INDEX IF NOT EXISTS idx_bots_username ON bots(username);
        CREATE INDEX IF NOT EXISTS idx_bots_owner ON bots(owner_jid);

        CREATE TABLE IF NOT EXISTS pending_updates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bot_id INTEGER NOT NULL,
            update_data TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_pending_bot ON pending_updates(bot_id, id);

        CREATE TABLE IF NOT EXISTS jid_chats (
            chat_id INTEGER PRIMARY KEY,
            jid TEXT NOT NULL UNIQUE
        );

        CREATE INDEX IF NOT EXISTS idx_jid_chats_jid ON jid_chats(jid);
        "#,
    )
    .execute(&pool)
    .await?;

    Ok(pool)
}

pub async fn upsert_jid_chat(pool: &SqlitePool, chat_id: i64, jid: &str) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO jid_chats (chat_id, jid) VALUES (?, ?) ON CONFLICT(chat_id) DO UPDATE SET jid = excluded.jid",
    )
    .bind(chat_id)
    .bind(jid)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn get_jid_by_chat_id(pool: &SqlitePool, chat_id: i64) -> anyhow::Result<Option<String>> {
    let row: Option<(String,)> = sqlx::query_as("SELECT jid FROM jid_chats WHERE chat_id = ?")
        .bind(chat_id)
        .fetch_optional(pool)
        .await?;

    Ok(row.map(|r| r.0))
}

pub async fn get_bot_by_token(pool: &SqlitePool, token: &str) -> anyhow::Result<Option<BotRecord>> {
    let bot = sqlx::query_as::<_, BotRecord>(
        "SELECT id, username, token, title, about, avatar_url, owner_jid, webhook_url, fail_count, is_active, commands_json, created_at FROM bots WHERE token = ? AND is_active = 1",
    )
    .bind(token)
    .fetch_optional(pool)
    .await?;

    Ok(bot)
}

pub async fn get_bot_by_username(pool: &SqlitePool, username: &str) -> anyhow::Result<Option<BotRecord>> {
    let normalized = username.to_ascii_lowercase();
    let bot = sqlx::query_as::<_, BotRecord>(
        "SELECT id, username, token, title, about, avatar_url, owner_jid, webhook_url, fail_count, is_active, commands_json, created_at FROM bots WHERE LOWER(username) = ? AND is_active = 1",
    )
    .bind(normalized)
    .fetch_optional(pool)
    .await?;

    Ok(bot)
}

pub async fn list_bots_by_owner(pool: &SqlitePool, owner_jid: &str) -> anyhow::Result<Vec<BotRecord>> {
    let bare_owner = owner_jid.split('/').next().unwrap_or(owner_jid);
    let bots = sqlx::query_as::<_, BotRecord>(
        "SELECT id, username, token, title, about, avatar_url, owner_jid, webhook_url, fail_count, is_active, commands_json, created_at FROM bots WHERE owner_jid = ? AND is_active = 1 ORDER BY id ASC",
    )
    .bind(bare_owner)
    .fetch_all(pool)
    .await?;

    Ok(bots)
}

pub async fn create_bot(
    pool: &SqlitePool,
    username: &str,
    token: &str,
    title: &str,
    owner_jid: &str,
) -> anyhow::Result<BotRecord> {
    let now = current_timestamp();
    let bare_owner = owner_jid.split('/').next().unwrap_or(owner_jid);
    let normalized_username = username.to_ascii_lowercase();

    let id = sqlx::query(
        r#"
        INSERT INTO bots (username, token, title, owner_jid, created_at)
        VALUES (?, ?, ?, ?, ?)
        "#,
    )
    .bind(&normalized_username)
    .bind(token)
    .bind(title)
    .bind(bare_owner)
    .bind(now)
    .execute(pool)
    .await?
    .last_insert_rowid();

    Ok(BotRecord {
        id,
        username: normalized_username,
        token: token.to_string(),
        title: title.to_string(),
        about: None,
        avatar_url: None,
        owner_jid: bare_owner.to_string(),
        webhook_url: None,
        fail_count: 0,
        is_active: true,
        commands_json: None,
        created_at: now,
    })
}

pub async fn set_bot_commands(pool: &SqlitePool, bot_id: i64, commands_json: Option<&str>) -> anyhow::Result<()> {
    sqlx::query("UPDATE bots SET commands_json = ? WHERE id = ?")
        .bind(commands_json)
        .bind(bot_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn set_webhook(pool: &SqlitePool, bot_id: i64, url: Option<&str>) -> anyhow::Result<()> {
    sqlx::query("UPDATE bots SET webhook_url = ?, fail_count = 0 WHERE id = ?")
        .bind(url)
        .bind(bot_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn increment_webhook_failure(pool: &SqlitePool, bot_id: i64) -> anyhow::Result<(i64, Option<String>)> {
    sqlx::query("UPDATE bots SET fail_count = fail_count + 1 WHERE id = ?")
        .bind(bot_id)
        .execute(pool)
        .await?;

    let row = sqlx::query_as::<_, (i64, Option<String>, String)>(
        "SELECT fail_count, webhook_url, owner_jid FROM bots WHERE id = ?",
    )
    .bind(bot_id)
    .fetch_one(pool)
    .await?;

    let (fail_count, webhook_url, owner_jid) = row;

    if fail_count >= 50 && webhook_url.is_some() {
        // Freeze webhook
        sqlx::query("UPDATE bots SET webhook_url = NULL WHERE id = ?")
            .bind(bot_id)
            .execute(pool)
            .await?;
        return Ok((fail_count, Some(owner_jid)));
    }

    Ok((fail_count, None))
}

pub async fn reset_webhook_failure(pool: &SqlitePool, bot_id: i64) -> anyhow::Result<()> {
    sqlx::query("UPDATE bots SET fail_count = 0 WHERE id = ?")
        .bind(bot_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn push_pending_update(pool: &SqlitePool, bot_id: i64, data_json: &str) -> anyhow::Result<i64> {
    let now = current_timestamp();
    let id = sqlx::query(
        "INSERT INTO pending_updates (bot_id, update_data, created_at) VALUES (?, ?, ?)",
    )
    .bind(bot_id)
    .bind(data_json)
    .bind(now)
    .execute(pool)
    .await?
    .last_insert_rowid();

    Ok(id)
}

pub async fn acknowledge_and_get_updates(
    pool: &SqlitePool,
    bot_id: i64,
    offset: Option<i64>,
    limit: i64,
) -> anyhow::Result<Vec<PendingUpdateRecord>> {
    if let Some(off) = offset {
        if off > 0 {
            sqlx::query("DELETE FROM pending_updates WHERE bot_id = ? AND id < ?")
                .bind(bot_id)
                .bind(off)
                .execute(pool)
                .await?;
        }
    }

    let min_id = offset.unwrap_or(0);
    let records = sqlx::query_as::<_, PendingUpdateRecord>(
        "SELECT id, bot_id, update_data, created_at FROM pending_updates WHERE bot_id = ? AND id >= ? ORDER BY id ASC LIMIT ?",
    )
    .bind(bot_id)
    .bind(min_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(records)
}

pub async fn count_pending_updates(pool: &SqlitePool, bot_id: i64) -> anyhow::Result<i64> {
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM pending_updates WHERE bot_id = ?")
        .bind(bot_id)
        .fetch_one(pool)
        .await?;
    Ok(count.0)
}

pub async fn cleanup_old_updates(pool: &SqlitePool) -> anyhow::Result<u64> {
    let cutoff = current_timestamp() - 86400; // 24 hours
    let res = sqlx::query("DELETE FROM pending_updates WHERE created_at < ?")
        .bind(cutoff)
        .execute(pool)
        .await?;

    // Also enforce max 1000 items per bot (delete oldest beyond 1000)
    sqlx::query(
        r#"
        DELETE FROM pending_updates
        WHERE id IN (
            SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (PARTITION BY bot_id ORDER BY id DESC) as rn
                FROM pending_updates
            ) WHERE rn > 1000
        )
        "#,
    )
    .execute(pool)
    .await?;

    Ok(res.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_db_bot_and_updates_lifecycle() {
        let pool = init_db(":memory:").await.unwrap();

        // 1. Create bot
        let bot = create_bot(&pool, "weather_bot", "123:abc_secret", "Weather Bot", "alice@penik.chat").await.unwrap();
        assert_eq!(bot.username, "weather_bot");
        assert_eq!(bot.title, "Weather Bot");
        assert_eq!(bot.owner_jid, "alice@penik.chat");

        // 2. Lookup bot
        let by_username = get_bot_by_username(&pool, "Weather_Bot").await.unwrap().unwrap();
        assert_eq!(by_username.id, bot.id);

        let by_token = get_bot_by_token(&pool, "123:abc_secret").await.unwrap().unwrap();
        assert_eq!(by_token.id, bot.id);

        // 3. Webhook and Circuit Breaker
        set_webhook(&pool, bot.id, Some("https://example.com/webhook")).await.unwrap();
        let b = get_bot_by_token(&pool, "123:abc_secret").await.unwrap().unwrap();
        assert_eq!(b.webhook_url.as_deref(), Some("https://example.com/webhook"));

        // Simulate 49 failures
        for _ in 0..49 {
            let (_, tripped) = increment_webhook_failure(&pool, bot.id).await.unwrap();
            assert!(tripped.is_none());
        }

        // 50th failure -> circuit breaker trips!
        let (count, tripped) = increment_webhook_failure(&pool, bot.id).await.unwrap();
        assert_eq!(count, 50);
        assert_eq!(tripped.as_deref(), Some("alice@penik.chat"));

        let b = get_bot_by_token(&pool, "123:abc_secret").await.unwrap().unwrap();
        assert!(b.webhook_url.is_none(), "Webhook URL should be reset to NULL on circuit trip");

        // 4. Pending updates and offset acknowledgement
        let _u1 = push_pending_update(&pool, bot.id, r#"{"update_id":1,"text":"first"}"#).await.unwrap();
        let u2 = push_pending_update(&pool, bot.id, r#"{"update_id":2,"text":"second"}"#).await.unwrap();
        let u3 = push_pending_update(&pool, bot.id, r#"{"update_id":3,"text":"third"}"#).await.unwrap();

        assert_eq!(count_pending_updates(&pool, bot.id).await.unwrap(), 3);

        // Query with offset = u2 (acknowledging u1)
        let updates = acknowledge_and_get_updates(&pool, bot.id, Some(u2), 10).await.unwrap();
        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].id, u2);
        assert_eq!(updates[1].id, u3);

        // u1 should now be deleted from database
        assert_eq!(count_pending_updates(&pool, bot.id).await.unwrap(), 2);

        // 5. Cleanup
        let deleted = cleanup_old_updates(&pool).await.unwrap();
        assert_eq!(deleted, 0); // Not older than 24h
    }
}

