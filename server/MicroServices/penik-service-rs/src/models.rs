use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct StickerPack {
    pub id: String,
    pub telegram_name: Option<String>,
    pub title: String,
    pub author_jid: String,
    pub cover_sticker_id: String,
    pub format: String, // "static", "animated" (tgs), "animated_webp"
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Sticker {
    pub id: String,
    pub pack_id: String,
    pub emoji: String,
    pub file_name: String,
    pub width: i32,
    pub height: i32,
    pub sort_order: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct UserStickerPack {
    pub user_jid: String,
    pub pack_id: String,
    pub sort_order: i32,
    pub installed_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PackWithStickers {
    pub pack: StickerPack,
    pub stickers: Vec<Sticker>,
    pub installed: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ImportRequest {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct PhoneDirectoryEntry {
    pub jid: String,
    pub phone: String,
    pub updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdatePhoneRequest {
    pub jid: Option<String>,
    pub phone: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl<T> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            ok: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            data: None,
            error: Some(message.into()),
        }
    }
}
