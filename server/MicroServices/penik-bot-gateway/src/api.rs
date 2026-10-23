use crate::db::{self, BotRecord};
use crate::models::{
    ApiResponse, Chat, EditMessageTextRequest, GetUpdatesParams, InlineKeyboardMarkup, Message,
    SendMessageRequest, SetWebhookRequest, Update, User, WebhookInfo, SendPhotoRequest, SendDocumentRequest,
};
use crate::webhook::WebhookDispatcher;
use crate::xmpp::{generate_jid_hash_id, xml_escape};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use sqlx::SqlitePool;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub stanza_tx: mpsc::Sender<String>,
    pub dispatcher: Arc<WebhookDispatcher>,
    pub component_domain: String,
}

pub fn create_router(state: AppState) -> Router {
    Router::new()
        .route("/bot:token/getMe", get(get_me))
        .route("/bot:token/sendMessage", post(send_message))
        .route("/bot:token/editMessageText", post(edit_message_text))
        .route("/bot:token/setWebhook", post(set_webhook))
        .route("/bot:token/deleteWebhook", post(delete_webhook))
        .route("/bot:token/getWebhookInfo", get(get_webhook_info))
        .route("/bot:token/getUpdates", get(get_updates_get).post(get_updates_post))
        .route("/bot:token/sendPhoto", post(send_photo))
        .route("/bot:token/sendDocument", post(send_document))
        .with_state(state)
}

fn api_error(status: StatusCode, desc: impl Into<String>) -> Response {
    (
        status,
        Json(ApiResponse::<()>::err(status.as_u16(), desc)),
    )
        .into_response()
}

async fn authenticate_bot(pool: &SqlitePool, token: &str) -> Result<BotRecord, Response> {
    match db::get_bot_by_token(pool, token).await {
        Ok(Some(bot)) => Ok(bot),
        Ok(None) => Err(api_error(StatusCode::UNAUTHORIZED, "Unauthorized: invalid bot token")),
        Err(e) => Err(api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Database error: {}", e))),
    }
}

async fn get_me(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let user = User {
        id: bot.id,
        is_bot: true,
        first_name: bot.title,
        username: Some(bot.username),
    };

    (StatusCode::OK, Json(ApiResponse::success(user))).into_response()
}

fn build_markup_xml(markup: &InlineKeyboardMarkup) -> String {
    let mut xml = String::from("<markup xmlns='penik:bot:markup'>");
    for row in &markup.inline_keyboard {
        xml.push_str("<row>");
        for btn in row {
            xml.push_str(&format!("<button text='{}'", xml_escape(&btn.text)));
            if let Some(ref data) = btn.callback_data {
                xml.push_str(&format!(" data='{}'", xml_escape(data)));
            }
            if let Some(ref url) = btn.url {
                xml.push_str(&format!(" url='{}'", xml_escape(url)));
            }
            xml.push_str("/>");
        }
        xml.push_str("</row>");
    }
    xml.push_str("</markup>");
    xml
}

async fn send_message(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<SendMessageRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let msg_id = format!("msg_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let mut markup_xml = String::new();
    if let Some(ref mk) = payload.reply_markup {
        markup_xml = build_markup_xml(mk);
    }

    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{}</body>\
        {}\
        </message>",
        xml_escape(&payload.chat_id),
        bot_jid,
        msg_id,
        xml_escape(&payload.text),
        markup_xml
    );

    if let Err(e) = state.stanza_tx.send(stanza).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to deliver stanza: {}", e));
    }

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title,
            username: Some(bot.username),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&payload.chat_id),
            r#type: "private".to_string(),
            username: Some(payload.chat_id.clone()),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(payload.text),
        reply_markup: payload.reply_markup,
    };

    (StatusCode::OK, Json(ApiResponse::success(result))).into_response()
}

async fn edit_message_text(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<EditMessageTextRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let new_msg_id = format!("edit_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let mut markup_xml = String::new();
    if let Some(ref mk) = payload.reply_markup {
        markup_xml = build_markup_xml(mk);
    }

    // XEP-0308 Last Message Correction
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{}</body>\
        <replace id='{}' xmlns='urn:xmpp:message-correct:0'/>\
        {}\
        </message>",
        xml_escape(&payload.chat_id),
        bot_jid,
        new_msg_id,
        xml_escape(&payload.text),
        xml_escape(&payload.message_id),
        markup_xml
    );

    if let Err(e) = state.stanza_tx.send(stanza).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to deliver stanza: {}", e));
    }

    let result = Message {
        message_id: payload.message_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title,
            username: Some(bot.username),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&payload.chat_id),
            r#type: "private".to_string(),
            username: Some(payload.chat_id.clone()),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(payload.text),
        reply_markup: payload.reply_markup,
    };

    (StatusCode::OK, Json(ApiResponse::success(result))).into_response()
}

async fn set_webhook(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<SetWebhookRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let url = payload.url.trim();
    if !url.starts_with("https://") {
        return api_error(StatusCode::BAD_REQUEST, "Bad Request: Webhook URL must use HTTPS protocol");
    }

    if let Err(e) = db::set_webhook(&state.pool, bot.id, Some(url)).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to set webhook: {}", e));
    }

    (
        StatusCode::OK,
        Json(ApiResponse {
            ok: true,
            result: Some(true),
            description: Some("Webhook was set successfully".to_string()),
            error_code: None,
        }),
    )
        .into_response()
}

async fn delete_webhook(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    if let Err(e) = db::set_webhook(&state.pool, bot.id, None).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to delete webhook: {}", e));
    }

    (
        StatusCode::OK,
        Json(ApiResponse {
            ok: true,
            result: Some(true),
            description: Some("Webhook was deleted".to_string()),
            error_code: None,
        }),
    )
        .into_response()
}

async fn get_webhook_info(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let pending_count = db::count_pending_updates(&state.pool, bot.id)
        .await
        .unwrap_or(0);

    let info = WebhookInfo {
        url: bot.webhook_url.unwrap_or_default(),
        has_custom_certificate: false,
        pending_update_count: pending_count,
        last_error_date: None,
        last_error_message: if bot.fail_count > 0 {
            Some(format!("Consecutive failures: {}", bot.fail_count))
        } else {
            None
        },
    };

    (StatusCode::OK, Json(ApiResponse::success(info))).into_response()
}

async fn get_updates_get(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Query(params): Query<GetUpdatesParams>,
) -> impl IntoResponse {
    handle_get_updates(state, token, params).await
}

async fn get_updates_post(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(params): Json<GetUpdatesParams>,
) -> impl IntoResponse {
    handle_get_updates(state, token, params).await
}

async fn handle_get_updates(
    state: AppState,
    token: String,
    params: GetUpdatesParams,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let limit = params.limit.unwrap_or(100).clamp(1, 100);
    let timeout_secs = params.timeout.unwrap_or(0).min(50);

    // Initial check
    let mut records = match db::acknowledge_and_get_updates(&state.pool, bot.id, params.offset, limit).await {
        Ok(r) => r,
        Err(e) => return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Database query error: {}", e)),
    };

    // If no records and long-poll timeout requested, wait on Notify
    if records.is_empty() && timeout_secs > 0 {
        let notifier = state.dispatcher.get_notifier(bot.id);
        let _ = tokio::time::timeout(Duration::from_secs(timeout_secs), notifier.notified()).await;

        records = match db::acknowledge_and_get_updates(&state.pool, bot.id, params.offset, limit).await {
            Ok(r) => r,
            Err(e) => return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Database query error: {}", e)),
        };
    }

    let mut updates = Vec::new();
    for rec in records {
        if let Ok(mut upd) = serde_json::from_str::<Update>(&rec.update_data) {
            upd.update_id = rec.id;
            updates.push(upd);
        }
    }

    (StatusCode::OK, Json(ApiResponse::success(updates))).into_response()
}

async fn send_photo(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<SendPhotoRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let msg_id = format!("photo_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let caption_text = payload.caption.as_deref().unwrap_or("");
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{} {}</body>\
        <x xmlns='jabber:x:oob'><url>{}</url></x>\
        </message>",
        xml_escape(&payload.chat_id),
        bot_jid,
        msg_id,
        xml_escape(caption_text),
        xml_escape(&payload.photo),
        xml_escape(&payload.photo)
    );

    if let Err(e) = state.stanza_tx.send(stanza).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Delivery failed: {}", e));
    }

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title,
            username: Some(bot.username),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&payload.chat_id),
            r#type: "private".to_string(),
            username: Some(payload.chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(caption_text.to_string()),
        reply_markup: None,
    };

    (StatusCode::OK, Json(ApiResponse::success(result))).into_response()
}

async fn send_document(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<SendDocumentRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let msg_id = format!("doc_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let caption_text = payload.caption.as_deref().unwrap_or("");
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{} {}</body>\
        <x xmlns='jabber:x:oob'><url>{}</url></x>\
        </message>",
        xml_escape(&payload.chat_id),
        bot_jid,
        msg_id,
        xml_escape(caption_text),
        xml_escape(&payload.document),
        xml_escape(&payload.document)
    );

    if let Err(e) = state.stanza_tx.send(stanza).await {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, format!("Delivery failed: {}", e));
    }

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title,
            username: Some(bot.username),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&payload.chat_id),
            r#type: "private".to_string(),
            username: Some(payload.chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(caption_text.to_string()),
        reply_markup: None,
    };

    (StatusCode::OK, Json(ApiResponse::success(result))).into_response()
}
