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

    #[arg(long, env = "STICKERS_SHARED_SECRET")]
    pub shared_secret: String,

    #[arg(long, env = "TELEGRAM_BOT_TOKEN", default_value = "")]
    pub telegram_bot_token: String,
}

pub const LEGACY_SHARED_SECRET: &str = "penik_secret_shared_key";
pub const MIN_SHARED_SECRET_LENGTH: usize = 32;

pub fn validate_shared_secret(shared_secret: &str) -> Result<(), String> {
    if shared_secret.is_empty() {
        return Err(
            "STICKERS_SHARED_SECRET must be set to a secret of at least 32 characters"
                .to_string(),
        );
    }

    if shared_secret == LEGACY_SHARED_SECRET {
        return Err(
            "STICKERS_SHARED_SECRET must not use the former public default value".to_string(),
        );
    }

    if shared_secret.chars().count() < MIN_SHARED_SECRET_LENGTH {
        return Err(format!(
            "STICKERS_SHARED_SECRET must be at least {} characters long",
            MIN_SHARED_SECRET_LENGTH
        ));
    }

    Ok(())
}

impl Config {
    pub fn validate_shared_secret(&self) -> Result<(), String> {
        crate::config::validate_shared_secret(&self.shared_secret)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_secret_validation_rejects_empty_secret() {
        assert!(validate_shared_secret("").is_err());
    }

    #[test]
    fn shared_secret_validation_rejects_legacy_default() {
        assert!(validate_shared_secret(LEGACY_SHARED_SECRET).is_err());
    }

    #[test]
    fn shared_secret_validation_rejects_short_secret() {
        assert!(validate_shared_secret("1234567890123456789012345678901").is_err());
    }

    #[test]
    fn shared_secret_validation_accepts_minimum_length_secret() {
        assert!(validate_shared_secret("12345678901234567890123456789012").is_ok());
    }
}
