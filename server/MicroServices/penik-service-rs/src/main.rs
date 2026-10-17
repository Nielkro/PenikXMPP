mod auth;
mod bundler;
mod config;
mod db;
mod handlers;
mod models;
mod telegram;
mod transcode;

use clap::Parser;
use config::Config;
use handlers::AppState;
use std::sync::Arc;
use tower_http::{
    compression::CompressionLayer,
    cors::{Any, CorsLayer},
    trace::TraceLayer,
};
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // 1. Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "penik_service_rs=info,tower_http=info".into()),
        )
        .init();

    // 2. Parse configuration
    let config = Arc::new(Config::parse());
    info!(
        "Starting Penik Service on {}:{}",
        config.host, config.port
    );

    // 3. Ensure storage directory exists
    tokio::fs::create_dir_all(&config.storage_dir).await?;

    // 4. Initialize database
    let pool = db::init_db(&config.db_path).await?;
    info!("Database initialized at {}", config.db_path);

    // 5. Initialize Telegram Bot API client
    let tg_client = telegram::TelegramClient::new(config.telegram_bot_token.clone());

    // 6. Build application state
    let state = Arc::new(AppState {
        pool,
        config: config.clone(),
        tg_client,
    });

    // 7. Setup router
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let api_router = axum::Router::new()
        .route("/stickers/my", axum::routing::get(handlers::get_my_packs))
        .route(
            "/stickers/pack/:id",
            axum::routing::get(handlers::get_pack),
        )
        .route(
            "/stickers/pack/:id/install",
            axum::routing::post(handlers::install_pack)
                .delete(handlers::uninstall_pack),
        )
        .route(
            "/stickers/import/telegram",
            axum::routing::post(handlers::import_telegram_pack),
        )
        .route(
            "/stickers/pack/:id/bundle.zip",
            axum::routing::get(handlers::get_bundle_zip),
        )
        .route(
            "/stickers/file/:pack_id/:file_name",
            axum::routing::get(handlers::get_file),
        )
        .route(
            "/phone-directory",
            axum::routing::get(handlers::get_phone_directory)
                .post(handlers::update_phone),
        );

    let app = axum::Router::new()
        .nest("/api/v1", api_router)
        .layer(axum::Extension(config.clone()))
        .layer(cors)
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // 8. Bind and serve
    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("Listening on http://{}", addr);

    axum::serve(listener, app).await?;

    Ok(())
}
