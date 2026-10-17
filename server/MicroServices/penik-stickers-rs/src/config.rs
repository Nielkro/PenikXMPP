use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(author, version, about = "Penik Stickers Microservice")]
pub struct Config {
    #[arg(long, env = "STICKERS_HOST", default_value = "0.0.0.0")]
    pub host: String,

    #[arg(long, env = "STICKERS_PORT", default_value_t = 8085)]
    pub port: u16,

    #[arg(long, env = "STICKERS_DB_PATH", default_value = "data/stickers.db")]
    pub db_path: String,

    #[arg(long, env = "STICKERS_STORAGE_DIR", default_value = "data/stickers")]
    pub storage_dir: String,

    #[arg(long, env = "STICKERS_SHARED_SECRET", default_value = "penik_secret_shared_key")]
    pub shared_secret: String,

    #[arg(long, env = "TELEGRAM_BOT_TOKEN", default_value = "")]
    pub telegram_bot_token: String,
}
