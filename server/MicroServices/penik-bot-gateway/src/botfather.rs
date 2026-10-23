use crate::db;
use dashmap::DashMap;
use rand::RngCore;
use regex::Regex;
use sqlx::SqlitePool;
use std::time::{Duration, Instant};

const SESSION_TTL: Duration = Duration::from_secs(900); // 15 minutes

#[derive(Debug, Clone)]
pub enum DialogState {
    Idle,
    WaitingForTitle,
    WaitingForUsername { title: String },
}

pub struct BotFatherEngine {
    pool: SqlitePool,
    states: DashMap<String, (DialogState, Instant)>,
    username_regex: Regex,
    gateway_public_url: String,
}

impl BotFatherEngine {
    pub fn new(pool: SqlitePool, gateway_public_url: String) -> Self {
        Self {
            pool,
            states: DashMap::new(),
            username_regex: Regex::new(r"^[a-zA-Z0-9_]{3,32}$").unwrap(),
            gateway_public_url,
        }
    }

    fn get_state(&self, jid: &str) -> DialogState {
        if let Some(entry) = self.states.get(jid) {
            let (ref state, ref instant) = *entry;
            if instant.elapsed() < SESSION_TTL {
                return state.clone();
            }
        }
        DialogState::Idle
    }

    fn set_state(&self, jid: &str, state: DialogState) {
        self.states.insert(jid.to_string(), (state, Instant::now()));
    }

    fn clear_state(&self, jid: &str) {
        self.states.remove(jid);
    }

    pub async fn handle_message(&self, from_jid: &str, text: &str) -> String {
        let bare_jid = from_jid.split('/').next().unwrap_or(from_jid);
        let trimmed = text.trim();

        if trimmed == "/cancel" {
            self.clear_state(bare_jid);
            return "Operation cancelled.".to_string();
        }

        if trimmed == "/start" || trimmed == "/help" {
            self.clear_state(bare_jid);
            return "I can help you create and manage Penik bots.\n\n\
                You can control me by sending these commands:\n\n\
                /newbot - create a new bot\n\
                /mybots - list your bots\n\
                /token - view your bot tokens\n\
                /cancel - cancel the current operation"
                .to_string();
        }

        if trimmed == "/newbot" {
            self.set_state(bare_jid, DialogState::WaitingForTitle);
            return "Alright, a new bot. How are we going to call it? Please choose a name for your bot."
                .to_string();
        }

        if trimmed == "/mybots" {
            return match db::list_bots_by_owner(&self.pool, bare_jid).await {
                Ok(bots) if bots.is_empty() => {
                    "You haven't created any bots yet. Use /newbot to create one.".to_string()
                }
                Ok(bots) => {
                    let mut resp = String::from("Your bots:\n");
                    for b in bots {
                        resp.push_str(&format!("• @{} - {}\n", b.username, b.title));
                    }
                    resp.push_str("\nUse /token to view API tokens.");
                    resp
                }
                Err(e) => format!("Error loading bots: {}", e),
            };
        }

        if trimmed == "/token" {
            return match db::list_bots_by_owner(&self.pool, bare_jid).await {
                Ok(bots) if bots.is_empty() => {
                    "You don't have any bots yet. Use /newbot to create one.".to_string()
                }
                Ok(bots) => {
                    let mut resp = String::from("Bot API tokens:\n\n");
                    for b in bots {
                        resp.push_str(&format!("@{}\n`{}`\n\n", b.username, b.token));
                    }
                    resp.push_str("Keep these tokens secret!");
                    resp
                }
                Err(e) => format!("Error loading tokens: {}", e),
            };
        }

        let current_state = self.get_state(bare_jid);
        match current_state {
            DialogState::WaitingForTitle => {
                if trimmed.is_empty() || trimmed.len() > 64 {
                    return "Title must be between 1 and 64 characters. Please choose a title:".to_string();
                }
                self.set_state(
                    bare_jid,
                    DialogState::WaitingForUsername {
                        title: trimmed.to_string(),
                    },
                );
                "Good. Now let's choose a username for your bot. It must end in 'bot'. Like this, for example: TetrisBot or tetris_bot."
                    .to_string()
            }
            DialogState::WaitingForUsername { title } => {
                let username = trimmed.trim_start_matches('@');
                let lower = username.to_ascii_lowercase();

                if !lower.ends_with("bot") {
                    return "Sorry, the username must end in 'bot'. For example: tetris_bot or TetrisBot. Please try again:".to_string();
                }

                if !self.username_regex.is_match(username) {
                    return "Sorry, the username can only contain Latin letters, numbers, and underscores (3-32 characters). Please try again:".to_string();
                }

                // Check if username already exists in database
                match db::get_bot_by_username(&self.pool, username).await {
                    Ok(Some(_)) => {
                        return "Sorry, this username is already taken. Please try something different:".to_string();
                    }
                    Err(e) => return format!("Internal database error: {}", e),
                    Ok(None) => {}
                }

                // Generate random secure token: {random_bytes}
                let mut rand_bytes = [0u8; 32];
                rand::rngs::OsRng.fill_bytes(&mut rand_bytes);
                let hex_part = hex::encode(rand_bytes);

                // Insert bot to get primary key ID
                let temp_token = format!("temp_{}", hex_part);
                let bot = match db::create_bot(&self.pool, username, &temp_token, &title, bare_jid).await {
                    Ok(b) => b,
                    Err(e) => return format!("Failed to create bot: {}", e),
                };

                let real_token = format!("{}:{}", bot.id, hex_part);
                if let Err(e) = sqlx::query("UPDATE bots SET token = ? WHERE id = ?")
                    .bind(&real_token)
                    .bind(bot.id)
                    .execute(&self.pool)
                    .await
                {
                    return format!("Failed to finalize bot token: {}", e);
                }

                self.clear_state(bare_jid);

                format!(
                    "Done! Congratulations on your new bot. You will find it at @{}.\n\n\
                    Use this token to access the HTTP API:\n\
                    {}\n\n\
                    Keep your token secure and store it safely, it can be used by anyone to control your bot.\n\n\
                    API Base URL:\n\
                    {}/bot{}/getMe",
                    bot.username, real_token, self.gateway_public_url, real_token
                )
            }
            DialogState::Idle => {
                "I don't understand that command. Send /help to see available commands.".to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_botfather_dialog_flow() {
        let pool = db::init_db(":memory:").await.unwrap();
        let engine = BotFatherEngine::new(pool.clone(), "http://localhost:8086".to_string());
        let user = "alice@penik.chat";

        // 1. /start
        let reply = engine.handle_message(user, "/start").await;
        assert!(reply.contains("I can help you create and manage Penik bots"));

        // 2. /newbot
        let reply = engine.handle_message(user, "/newbot").await;
        assert!(reply.contains("Please choose a name for your bot"));

        // 3. Send Title
        let reply = engine.handle_message(user, "My Cool Bot").await;
        assert!(reply.contains("Now let's choose a username"));

        // 4. Invalid username without "bot" suffix
        let reply = engine.handle_message(user, "cool_service").await;
        assert!(reply.contains("must end in 'bot'"));

        // 5. Valid username
        let reply = engine.handle_message(user, "cool_service_bot").await;
        assert!(reply.contains("Done! Congratulations on your new bot"));
        assert!(reply.contains("Use this token to access the HTTP API"));

        // 6. Verify bot exists in database
        let bot = db::get_bot_by_username(&pool, "cool_service_bot").await.unwrap().unwrap();
        assert_eq!(bot.title, "My Cool Bot");
        assert_eq!(bot.owner_jid, "alice@penik.chat");
        assert!(bot.token.starts_with(&format!("{}:", bot.id)));

        // 7. /mybots
        let reply = engine.handle_message(user, "/mybots").await;
        assert!(reply.contains("@cool_service_bot - My Cool Bot"));

        // 8. /token
        let reply = engine.handle_message(user, "/token").await;
        assert!(reply.contains(&bot.token));
    }
}

