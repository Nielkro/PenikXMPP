use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(author, version, about = "Penik Bot Gateway - Telegram Bot API compatible gateway for Penik XMPP")]
pub struct Config {
    #[arg(long, env = "BOT_GATEWAY_HOST", default_value = "0.0.0.0")]
    pub host: String,

    #[arg(long, env = "BOT_GATEWAY_PORT", default_value_t = 8086)]
    pub port: u16,

    #[arg(long, env = "BOT_GATEWAY_DB_PATH", default_value = "data/bot_gateway.db")]
    pub db_path: String,

    #[arg(long, env = "PROSODY_HOST", default_value = "127.0.0.1")]
    pub prosody_host: String,

    #[arg(long, env = "PROSODY_PORT", default_value_t = 5347)]
    pub prosody_port: u16,

    #[arg(long, env = "COMPONENT_DOMAIN", default_value = "bot.snikket.penik.ru")]
    pub component_domain: String,

    #[arg(long, env = "COMPONENT_SECRET", default_value = "penik_bot_gateway_secret_2026")]
    pub component_secret: String,

    #[arg(long, env = "PROSODY_UPLOAD_JID", default_value = "share.snikket.penik.ru")]
    pub prosody_upload_jid: String,

    #[arg(long, env = "BOT_GATEWAY_PUBLIC_URL")]
    pub public_url: Option<String>,
}

impl Config {
    pub fn get_public_url(&self) -> String {
        if let Some(ref url) = self.public_url {
            url.trim_end_matches('/').to_string()
        } else {
            format!("https://{}", self.component_domain)
        }
    }
}
