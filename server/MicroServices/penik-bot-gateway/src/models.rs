use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<u16>,
}

impl<T> ApiResponse<T> {
    pub fn success(result: T) -> Self {
        Self {
            ok: true,
            result: Some(result),
            description: None,
            error_code: None,
        }
    }

    pub fn err(code: u16, desc: impl Into<String>) -> Self {
        Self {
            ok: false,
            result: None,
            description: Some(desc.into()),
            error_code: Some(code),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BotCommand {
    pub command: String,
    pub description: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetMyCommandsRequest {
    pub commands: Vec<BotCommand>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: i64,
    pub is_bot: bool,
    pub first_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chat {
    pub id: i64,
    pub r#type: String, // "private"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InlineKeyboardButton {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub callback_data: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InlineKeyboardMarkup {
    pub inline_keyboard: Vec<Vec<InlineKeyboardButton>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyboardButton {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplyKeyboardMarkup {
    pub keyboard: Vec<Vec<KeyboardButton>>,
    #[serde(default)]
    pub resize_keyboard: Option<bool>,
    #[serde(default)]
    pub one_time_keyboard: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplyKeyboardRemove {
    pub remove_keyboard: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ReplyMarkup {
    Inline(InlineKeyboardMarkup),
    Reply(ReplyKeyboardMarkup),
    Remove(ReplyKeyboardRemove),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub message_id: String,
    pub from: Option<User>,
    pub chat: Chat,
    pub date: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_markup: Option<ReplyMarkup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallbackQuery {
    pub id: String,
    pub from: User,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Update {
    pub update_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub callback_query: Option<CallbackQuery>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SendMessageRequest {
    pub chat_id: String,
    pub text: String,
    #[serde(default)]
    pub reply_markup: Option<ReplyMarkup>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AnswerCallbackQueryRequest {
    pub callback_query_id: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub show_alert: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EditMessageTextRequest {
    pub chat_id: String,
    pub message_id: String,
    pub text: String,
    #[serde(default)]
    pub reply_markup: Option<InlineKeyboardMarkup>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetWebhookRequest {
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct WebhookInfo {
    pub url: String,
    pub has_custom_certificate: bool,
    pub pending_update_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error_date: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error_message: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct GetUpdatesParams {
    pub offset: Option<i64>,
    pub limit: Option<i64>,
    pub timeout: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SendPhotoRequest {
    pub chat_id: String,
    pub photo: String, // URL
    #[serde(default)]
    pub caption: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SendDocumentRequest {
    pub chat_id: String,
    pub document: String, // URL
    #[serde(default)]
    pub caption: Option<String>,
}
