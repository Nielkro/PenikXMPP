use serde::Deserialize;
use tracing::info;

#[derive(Debug, Deserialize)]
pub struct TgResponse<T> {
    pub ok: bool,
    pub result: Option<T>,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TgStickerSet {
    pub name: String,
    pub title: String,
    #[serde(default)]
    pub is_animated: bool,
    #[serde(default)]
    pub is_video: bool,
    pub stickers: Vec<TgSticker>,
}

#[derive(Debug, Deserialize)]
pub struct TgSticker {
    pub file_id: String,
    pub file_unique_id: String,
    pub emoji: Option<String>,
    pub width: i32,
    pub height: i32,
    #[serde(default)]
    pub is_animated: bool,
    #[serde(default)]
    pub is_video: bool,
    pub thumbnail: Option<TgPhotoSize>,
}

#[derive(Debug, Deserialize)]
pub struct TgPhotoSize {
    pub file_id: String,
}

#[derive(Debug, Deserialize)]
pub struct TgFile {
    pub file_id: String,
    pub file_path: Option<String>,
}

#[derive(Clone)]
pub struct TelegramClient {
    bot_token: String,
    http: reqwest::Client,
}

impl TelegramClient {
    pub fn new(bot_token: String) -> Self {
        Self {
            bot_token,
            http: reqwest::Client::builder().build().unwrap(),
        }
    }

    pub async fn get_sticker_set(&self, name: &str) -> anyhow::Result<TgStickerSet> {
        if self.bot_token.trim().is_empty() {
            anyhow::bail!("TELEGRAM_BOT_TOKEN не настроен на сервере в .env");
        }
        let url = format!(
            "https://api.telegram.org/bot{}/getStickerSet?name={}",
            self.bot_token, name
        );

        let res = self.http.get(&url).send().await?;
        let tg_res: TgResponse<TgStickerSet> = res.json().await?;

        if !tg_res.ok || tg_res.result.is_none() {
            anyhow::bail!(
                "Telegram API error: {}",
                tg_res.description.unwrap_or_else(|| "Unknown error".into())
            );
        }

        Ok(tg_res.result.unwrap())
    }

    pub async fn get_file_path(&self, file_id: &str) -> anyhow::Result<String> {
        let url = format!(
            "https://api.telegram.org/bot{}/getFile?file_id={}",
            self.bot_token, file_id
        );

        let res = self.http.get(&url).send().await?;
        let tg_res: TgResponse<TgFile> = res.json().await?;

        if !tg_res.ok || tg_res.result.is_none() {
            anyhow::bail!(
                "Telegram API getFile error: {}",
                tg_res.description.unwrap_or_else(|| "Unknown error".into())
            );
        }

        let file = tg_res.result.unwrap();
        file.file_path
            .ok_or_else(|| anyhow::anyhow!("No file_path returned by Telegram"))
    }

    pub async fn download_file(&self, file_path: &str) -> anyhow::Result<Vec<u8>> {
        let url = format!(
            "https://api.telegram.org/file/bot{}/{}",
            self.bot_token, file_path
        );

        info!("Downloading file from Telegram: {}", file_path);
        let res = self.http.get(&url).send().await?;
        if !res.status().is_success() {
            anyhow::bail!("Failed to download file from Telegram: HTTP {}", res.status());
        }

        let bytes = res.bytes().await?;
        Ok(bytes.to_vec())
    }
}
