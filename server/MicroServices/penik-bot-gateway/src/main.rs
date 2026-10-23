mod api;
mod botfather;
mod config;
mod db;
mod models;
mod ssrf;
mod webhook;
mod xmpp;

use api::AppState;
use botfather::BotFatherEngine;
use clap::Parser;
use config::Config;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use webhook::WebhookDispatcher;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "penik_bot_gateway=info,tower_http=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config = Config::parse();
    info!("Starting Penik Bot Gateway v{}", env!("CARGO_PKG_VERSION"));
    info!("Configuration: {:?}", config);

    // 1. Initialize SQLite Database
    let pool = db::init_db(&config.db_path).await?;
    info!("SQLite database initialized at '{}'", config.db_path);

    // 2. Initialize internal channels and shared state
    let (stanza_tx, stanza_rx) = mpsc::channel::<String>(2048);

    let gateway_public_url = config.get_public_url();
    let botfather = Arc::new(BotFatherEngine::new(pool.clone(), gateway_public_url));
    let dispatcher = Arc::new(WebhookDispatcher::new(
        pool.clone(),
        stanza_tx.clone(),
        config.component_domain.clone(),
    ));

    // 3. Spawn background TTL cleanup task (runs every 60 minutes)
    let pool_cleaner = pool.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(3600));
        loop {
            interval.tick().await;
            match db::cleanup_old_updates(&pool_cleaner).await {
                Ok(n) => {
                    if n > 0 {
                        info!("TTL cleaner removed {} expired pending updates", n);
                    }
                }
                Err(e) => {
                    error!("Error running pending updates TTL cleaner: {}", e);
                }
            }
        }
    });

    // 4. Spawn XEP-0114 Component Protocol loop
    let config_clone = config.clone();
    let pool_xmpp = pool.clone();
    let botfather_xmpp = botfather.clone();
    let dispatcher_xmpp = dispatcher.clone();

    tokio::spawn(async move {
        xmpp::run_component_loop(
            config_clone,
            pool_xmpp,
            botfather_xmpp,
            dispatcher_xmpp,
            stanza_rx,
        )
        .await;
    });

    // 5. Start Axum REST HTTP server
    let app_state = AppState {
        pool,
        stanza_tx,
        dispatcher,
        component_domain: config.component_domain.clone(),
    };

    let router = api::create_router(app_state);
    let listen_addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&listen_addr).await?;
    info!("REST API listening on http://{}", listen_addr);

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    info!("Penik Bot Gateway shut down gracefully.");
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    info!("Shutdown signal received, draining active connections...");
}
