use crate::db::{self, BotRecord};
use crate::models::Update;
use crate::ssrf::SafeDnsResolver;
use dashmap::DashMap;
use reqwest::redirect::Policy;
use sqlx::SqlitePool;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, Notify};
use tracing::{error, warn};

pub struct WebhookDispatcher {
    pool: SqlitePool,
    client: reqwest::Client,
    stanza_tx: mpsc::Sender<String>,
    component_domain: String,
    notifiers: Arc<DashMap<i64, Arc<Notify>>>,
    ws_senders: Arc<DashMap<i64, broadcast::Sender<Update>>>,
}

impl WebhookDispatcher {
    pub fn new(
        pool: SqlitePool,
        stanza_tx: mpsc::Sender<String>,
        component_domain: String,
    ) -> Self {
        let client = reqwest::Client::builder()
            .dns_resolver(Arc::new(SafeDnsResolver))
            .redirect(Policy::none())
            .timeout(Duration::from_secs(5))
            .build()
            .expect("Failed to initialize SSRF-safe reqwest client");

        Self {
            pool,
            client,
            stanza_tx,
            component_domain,
            notifiers: Arc::new(DashMap::new()),
            ws_senders: Arc::new(DashMap::new()),
        }
    }

    pub fn get_notifier(&self, bot_id: i64) -> Arc<Notify> {
        self.notifiers
            .entry(bot_id)
            .or_insert_with(|| Arc::new(Notify::new()))
            .clone()
    }

    pub fn get_ws_sender(&self, bot_id: i64) -> broadcast::Sender<Update> {
        self.ws_senders
            .entry(bot_id)
            .or_insert_with(|| {
                let (tx, _) = broadcast::channel(256);
                tx
            })
            .clone()
    }

    pub async fn dispatch_update(&self, bot: &BotRecord, update: Update) -> anyhow::Result<()> {
        let json_str = serde_json::to_string(&update)?;

        // 1. Real-time WebSocket streaming to connected clients
        if let Some(ws_tx) = self.ws_senders.get(&bot.id) {
            if ws_tx.receiver_count() > 0 {
                let _ = ws_tx.send(update.clone());
            }
        }

        if let Some(ref webhook_url) = bot.webhook_url {
            let client = self.client.clone();
            let pool = self.pool.clone();
            let stanza_tx = self.stanza_tx.clone();
            let component_domain = self.component_domain.clone();
            let url = webhook_url.clone();
            let bot_id = bot.id;
            let bot_username = bot.username.clone();

            tokio::spawn(async move {
                let res = client
                    .post(&url)
                    .header("Content-Type", "application/json")
                    .body(json_str)
                    .send()
                    .await;

                match res {
                    Ok(resp) if resp.status().is_success() => {
                        let _ = db::reset_webhook_failure(&pool, bot_id).await;
                    }
                    Ok(resp) => {
                        warn!(
                            "Webhook for bot @{} returned error status: {}",
                            bot_username,
                            resp.status()
                        );
                        handle_webhook_error(&pool, bot_id, &bot_username, &component_domain, &stanza_tx).await;
                    }
                    Err(e) => {
                        warn!(
                            "Webhook delivery failed for bot @{}: {}",
                            bot_username, e
                        );
                        handle_webhook_error(&pool, bot_id, &bot_username, &component_domain, &stanza_tx).await;
                    }
                }
            });
        } else {
            // Long polling mode: save to pending_updates and notify waiters
            db::push_pending_update(&self.pool, bot.id, &json_str).await?;
            self.get_notifier(bot.id).notify_waiters();
        }

        Ok(())
    }
}

async fn handle_webhook_error(
    pool: &SqlitePool,
    bot_id: i64,
    bot_username: &str,
    component_domain: &str,
    stanza_tx: &mpsc::Sender<String>,
) {
    if let Ok((fail_count, tripped_owner)) = db::increment_webhook_failure(pool, bot_id).await {
        if let Some(owner_jid) = tripped_owner {
            error!(
                "Bot @{} webhook reached {} consecutive errors! Circuit breaker tripped.",
                bot_username, fail_count
            );
            let alert_msg = format!(
                "<message type='chat' to='{}' from='botfather@{}'>\
                <body>⚠️ Webhook for bot @{} has failed 50 times in a row and has been deactivated. \
                Please check your bot server and re-configure setWebhook.</body>\
                </message>",
                owner_jid, component_domain, bot_username
            );
            let _ = stanza_tx.send(alert_msg).await;
        }
    }
}
