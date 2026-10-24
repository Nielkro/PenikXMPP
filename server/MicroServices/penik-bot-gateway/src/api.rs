use crate::db::{self, BotRecord};
use crate::models::{
    AnswerCallbackQueryRequest, ApiResponse, Chat, EditMessageTextRequest, GetUpdatesParams,
    InlineKeyboardMarkup, Message, ReplyMarkup, SendDocumentRequest, SendMessageRequest,
    SendPhotoRequest, SetWebhookRequest, Update, User, WebhookInfo,
};
use crate::webhook::WebhookDispatcher;
use crate::xmpp::{generate_jid_hash_id, xml_escape};
use axum::{
    extract::{
        ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures_util::{SinkExt, StreamExt};
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
        .route("/bot:token/answerCallbackQuery", post(answer_callback_query))
        .route("/bot:token/ws", get(ws_handler))
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

fn build_reply_markup_xml(markup: &ReplyMarkup) -> String {
    match markup {
        ReplyMarkup::Inline(inline) => {
            let mut xml = String::from("<markup xmlns='penik:bot:markup' type='inline'>");
            for row in &inline.inline_keyboard {
                xml.push_str("<row>");
                for btn in row {
                    xml.push_str(&format!("<button text='{}'", xml_escape(&btn.text)));
                    if let Some(data) = &btn.callback_data {
                        xml.push_str(&format!(" data='{}'", xml_escape(data)));
                    }
                    if let Some(url) = &btn.url {
                        xml.push_str(&format!(" url='{}'", xml_escape(url)));
                    }
                    xml.push_str("/>");
                }
                xml.push_str("</row>");
            }
            xml.push_str("</markup>");
            xml
        }
        ReplyMarkup::Reply(reply) => {
            let resize = reply.resize_keyboard.unwrap_or(true);
            let one_time = reply.one_time_keyboard.unwrap_or(false);
            let mut xml = format!(
                "<markup xmlns='penik:bot:markup' type='reply' resize='{}' one_time='{}'>",
                resize, one_time
            );
            for row in &reply.keyboard {
                xml.push_str("<row>");
                for btn in row {
                    xml.push_str(&format!("<button text='{}'/>", xml_escape(&btn.text)));
                }
                xml.push_str("</row>");
            }
            xml.push_str("</markup>");
            xml
        }
        ReplyMarkup::Remove(_) => {
            "<markup xmlns='penik:bot:markup' type='remove'/>".to_string()
        }
    }
}

pub async fn do_send_message(
    state: &AppState,
    bot: &BotRecord,
    chat_id: String,
    text: String,
    reply_markup: Option<ReplyMarkup>,
) -> Result<Message, String> {
    let msg_id = format!("msg_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let mut markup_xml = String::new();
    if let Some(ref mk) = reply_markup {
        markup_xml = build_reply_markup_xml(mk);
    }

    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{}</body>\
        {}\
        </message>",
        xml_escape(&chat_id),
        bot_jid,
        msg_id,
        xml_escape(&text),
        markup_xml
    );

    state
        .stanza_tx
        .send(stanza)
        .await
        .map_err(|e| format!("Failed to deliver stanza: {}", e))?;

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title.clone(),
            username: Some(bot.username.clone()),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&chat_id),
            r#type: "private".to_string(),
            username: Some(chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(text),
        reply_markup,
    };

    Ok(result)
}

pub async fn do_edit_message_text(
    state: &AppState,
    bot: &BotRecord,
    chat_id: String,
    message_id: String,
    text: String,
    reply_markup: Option<InlineKeyboardMarkup>,
) -> Result<Message, String> {
    let new_msg_id = format!("edit_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let mut markup_xml = String::new();
    if let Some(ref mk) = reply_markup {
        markup_xml = build_reply_markup_xml(&ReplyMarkup::Inline(mk.clone()));
    }

    // XEP-0308 Last Message Correction
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{}</body>\
        <replace id='{}' xmlns='urn:xmpp:message-correct:0'/>\
        {}\
        </message>",
        xml_escape(&chat_id),
        bot_jid,
        new_msg_id,
        xml_escape(&text),
        xml_escape(&message_id),
        markup_xml
    );

    state
        .stanza_tx
        .send(stanza)
        .await
        .map_err(|e| format!("Failed to deliver stanza: {}", e))?;

    let result = Message {
        message_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title.clone(),
            username: Some(bot.username.clone()),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&chat_id),
            r#type: "private".to_string(),
            username: Some(chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(text),
        reply_markup: reply_markup.map(ReplyMarkup::Inline),
    };

    Ok(result)
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

    match do_send_message(&state, &bot, payload.chat_id, payload.text, payload.reply_markup).await {
        Ok(msg) => (StatusCode::OK, Json(ApiResponse::success(msg))).into_response(),
        Err(e) => api_error(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
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

    match do_edit_message_text(&state, &bot, payload.chat_id, payload.message_id, payload.text, payload.reply_markup).await {
        Ok(msg) => (StatusCode::OK, Json(ApiResponse::success(msg))).into_response(),
        Err(e) => api_error(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

async fn answer_callback_query(
    State(state): State<AppState>,
    Path(token): Path<String>,
    Json(payload): Json<AnswerCallbackQueryRequest>,
) -> impl IntoResponse {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    let user_jid = if let Some(colon) = payload.callback_query_id.find(':') {
        &payload.callback_query_id[..colon]
    } else {
        &payload.callback_query_id
    };

    let bot_jid = format!("{}@{}", bot.username, state.component_domain);
    let alert_text = payload.text.unwrap_or_default();
    let show_alert = payload.show_alert.unwrap_or(false);

    let stanza = format!(
        "<message type='chat' to='{}' from='{}'>\
        <callback_answer xmlns='penik:bot:markup' id='{}' text='{}' show_alert='{}'/>\
        <no-store xmlns='urn:xmpp:hints'/>\
        </message>",
        xml_escape(user_jid),
        bot_jid,
        xml_escape(&payload.callback_query_id),
        xml_escape(&alert_text),
        show_alert
    );

    let _ = state.stanza_tx.send(stanza).await;

    (StatusCode::OK, Json(ApiResponse::success(true))).into_response()
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

pub async fn do_send_photo(
    state: &AppState,
    bot: &BotRecord,
    chat_id: String,
    photo: String,
    caption: Option<String>,
) -> Result<Message, String> {
    let msg_id = format!("photo_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let caption_text = caption.as_deref().unwrap_or("");
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{} {}</body>\
        <x xmlns='jabber:x:oob'><url>{}</url></x>\
        </message>",
        xml_escape(&chat_id),
        bot_jid,
        msg_id,
        xml_escape(caption_text),
        xml_escape(&photo),
        xml_escape(&photo)
    );

    state
        .stanza_tx
        .send(stanza)
        .await
        .map_err(|e| format!("Delivery failed: {}", e))?;

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title.clone(),
            username: Some(bot.username.clone()),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&chat_id),
            r#type: "private".to_string(),
            username: Some(chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(caption_text.to_string()),
        reply_markup: None,
    };

    Ok(result)
}

pub async fn do_send_document(
    state: &AppState,
    bot: &BotRecord,
    chat_id: String,
    document: String,
    caption: Option<String>,
) -> Result<Message, String> {
    let msg_id = format!("doc_{}", Uuid::new_v4().simple());
    let bot_jid = format!("{}@{}", bot.username, state.component_domain);

    let caption_text = caption.as_deref().unwrap_or("");
    let stanza = format!(
        "<message type='chat' to='{}' from='{}' id='{}'>\
        <body>{} {}</body>\
        <x xmlns='jabber:x:oob'><url>{}</url></x>\
        </message>",
        xml_escape(&chat_id),
        bot_jid,
        msg_id,
        xml_escape(caption_text),
        xml_escape(&document),
        xml_escape(&document)
    );

    state
        .stanza_tx
        .send(stanza)
        .await
        .map_err(|e| format!("Delivery failed: {}", e))?;

    let result = Message {
        message_id: msg_id,
        from: Some(User {
            id: bot.id,
            is_bot: true,
            first_name: bot.title.clone(),
            username: Some(bot.username.clone()),
        }),
        chat: Chat {
            id: generate_jid_hash_id(&chat_id),
            r#type: "private".to_string(),
            username: Some(chat_id),
            first_name: None,
            title: None,
        },
        date: db::current_timestamp(),
        text: Some(caption_text.to_string()),
        reply_markup: None,
    };

    Ok(result)
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

    match do_send_photo(&state, &bot, payload.chat_id, payload.photo, payload.caption).await {
        Ok(msg) => (StatusCode::OK, Json(ApiResponse::success(msg))).into_response(),
        Err(e) => api_error(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
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

    match do_send_document(&state, &bot, payload.chat_id, payload.document, payload.caption).await {
        Ok(msg) => (StatusCode::OK, Json(ApiResponse::success(msg))).into_response(),
        Err(e) => api_error(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

#[derive(serde::Deserialize, Debug, Default)]
struct WsRequest {
    #[serde(default)]
    id: Option<serde_json::Value>,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    params: Option<serde_json::Value>,
    #[serde(default)]
    chat_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    reply_markup: Option<ReplyMarkup>,
    #[serde(default)]
    photo: Option<String>,
    #[serde(default)]
    document: Option<String>,
    #[serde(default)]
    caption: Option<String>,
    #[serde(default)]
    message_id: Option<String>,
}

async fn ws_handler(
    State(state): State<AppState>,
    Path(token): Path<String>,
    ws: WebSocketUpgrade,
) -> Response {
    let bot = match authenticate_bot(&state.pool, &token).await {
        Ok(b) => b,
        Err(resp) => return resp,
    };

    ws.on_upgrade(move |socket| handle_bot_ws(socket, bot, state))
}

async fn handle_bot_ws(socket: WebSocket, bot: BotRecord, state: AppState) {
    let (mut ws_sender, mut ws_receiver) = socket.split();
    let mut update_rx = state.dispatcher.get_ws_sender(bot.id).subscribe();
    let (out_tx, mut out_rx) = mpsc::channel::<WsMessage>(128);

    tracing::info!("Bot @{} (id={}) connected via WebSocket", bot.username, bot.id);

    // Sender task: forwards updates and command replies to the WebSocket
    let mut send_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                update_res = update_rx.recv() => {
                    match update_res {
                        Ok(update) => {
                            if let Ok(json_str) = serde_json::to_string(&update) {
                                if ws_sender.send(WsMessage::Text(json_str)).await.is_err() {
                                    break;
                                }
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("WS subscriber lagged by {} updates", n);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            break;
                        }
                    }
                }
                out_msg = out_rx.recv() => {
                    match out_msg {
                        Some(msg) => {
                            if ws_sender.send(msg).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
        }
    });

    // Receiver task: receives commands and messages from the bot over WebSocket
    let state_clone = state.clone();
    let bot_clone = bot.clone();
    let out_tx_clone = out_tx.clone();

    let mut recv_task = tokio::spawn(async move {
        while let Some(msg_res) = ws_receiver.next().await {
            match msg_res {
                Ok(WsMessage::Text(text)) => {
                    let trimmed = text.trim();
                    if trimmed.eq_ignore_ascii_case("ping") {
                        let _ = out_tx_clone.send(WsMessage::Text(serde_json::json!({"ok": true, "result": "pong"}).to_string())).await;
                        continue;
                    }
                    if let Ok(req) = serde_json::from_str::<WsRequest>(&text) {
                        let resp = process_ws_request(&state_clone, &bot_clone, req).await;
                        let _ = out_tx_clone.send(WsMessage::Text(resp.to_string())).await;
                    } else {
                        let err_resp = serde_json::json!({
                            "ok": false,
                            "error_code": 400,
                            "description": "Invalid JSON format"
                        });
                        let _ = out_tx_clone.send(WsMessage::Text(err_resp.to_string())).await;
                    }
                }
                Ok(WsMessage::Binary(bin)) => {
                    if let Ok(req) = serde_json::from_slice::<WsRequest>(&bin) {
                        let resp = process_ws_request(&state_clone, &bot_clone, req).await;
                        let _ = out_tx_clone.send(WsMessage::Text(resp.to_string())).await;
                    }
                }
                Ok(WsMessage::Ping(payload)) => {
                    let _ = out_tx_clone.send(WsMessage::Pong(payload)).await;
                }
                Ok(WsMessage::Close(_)) => {
                    break;
                }
                Ok(WsMessage::Pong(_)) => {}
                Err(e) => {
                    tracing::debug!("WebSocket error for bot @{}: {}", bot_clone.username, e);
                    break;
                }
            }
        }
    });

    tokio::select! {
        _ = (&mut send_task) => recv_task.abort(),
        _ = (&mut recv_task) => send_task.abort(),
    }

    tracing::info!("Bot @{} (id={}) WebSocket disconnected", bot.username, bot.id);
}

async fn process_ws_request(
    state: &AppState,
    bot: &BotRecord,
    mut req: WsRequest,
) -> serde_json::Value {
    let req_id = req.id.clone();

    // If params is provided as an object, extract missing fields
    if let Some(ref params) = req.params {
        if req.chat_id.is_none() {
            req.chat_id = params.get("chat_id").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.text.is_none() {
            req.text = params.get("text").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.message_id.is_none() {
            req.message_id = params.get("message_id").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.photo.is_none() {
            req.photo = params.get("photo").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.document.is_none() {
            req.document = params.get("document").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.caption.is_none() {
            req.caption = params.get("caption").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
        if req.reply_markup.is_none() {
            if let Some(mk) = params.get("reply_markup") {
                req.reply_markup = serde_json::from_value(mk.clone()).ok();
            }
        }
    }

    let method = req.method.as_deref().unwrap_or_else(|| {
        if req.text.is_some() {
            "sendMessage"
        } else {
            ""
        }
    });

    let res: Result<serde_json::Value, String> = match method {
        "getMe" => {
            let u = User {
                id: bot.id,
                is_bot: true,
                first_name: bot.title.clone(),
                username: Some(bot.username.clone()),
            };
            Ok(serde_json::to_value(u).unwrap_or(serde_json::Value::Null))
        }
        "sendMessage" => {
            let chat_id = match req.chat_id {
                Some(cid) => cid,
                None => return make_ws_response(req_id, Err("chat_id is required".to_string())),
            };
            let text = match req.text {
                Some(txt) => txt,
                None => return make_ws_response(req_id, Err("text is required".to_string())),
            };
            match do_send_message(state, bot, chat_id, text, req.reply_markup).await {
                Ok(msg) => Ok(serde_json::to_value(msg).unwrap_or(serde_json::Value::Null)),
                Err(e) => Err(e),
            }
        }
        "editMessageText" => {
            let chat_id = match req.chat_id {
                Some(cid) => cid,
                None => return make_ws_response(req_id, Err("chat_id is required".to_string())),
            };
            let message_id = match req.message_id {
                Some(mid) => mid,
                None => return make_ws_response(req_id, Err("message_id is required".to_string())),
            };
            let text = match req.text {
                Some(txt) => txt,
                None => return make_ws_response(req_id, Err("text is required".to_string())),
            };
            let inline_markup = match req.reply_markup {
                Some(ReplyMarkup::Inline(ikm)) => Some(ikm),
                _ => None,
            };
            match do_edit_message_text(state, bot, chat_id, message_id, text, inline_markup).await {
                Ok(msg) => Ok(serde_json::to_value(msg).unwrap_or(serde_json::Value::Null)),
                Err(e) => Err(e),
            }
        }
        "sendPhoto" => {
            let chat_id = match req.chat_id {
                Some(cid) => cid,
                None => return make_ws_response(req_id, Err("chat_id is required".to_string())),
            };
            let photo = match req.photo {
                Some(p) => p,
                None => return make_ws_response(req_id, Err("photo is required".to_string())),
            };
            match do_send_photo(state, bot, chat_id, photo, req.caption).await {
                Ok(msg) => Ok(serde_json::to_value(msg).unwrap_or(serde_json::Value::Null)),
                Err(e) => Err(e),
            }
        }
        "sendDocument" => {
            let chat_id = match req.chat_id {
                Some(cid) => cid,
                None => return make_ws_response(req_id, Err("chat_id is required".to_string())),
            };
            let document = match req.document {
                Some(d) => d,
                None => return make_ws_response(req_id, Err("document is required".to_string())),
            };
            match do_send_document(state, bot, chat_id, document, req.caption).await {
                Ok(msg) => Ok(serde_json::to_value(msg).unwrap_or(serde_json::Value::Null)),
                Err(e) => Err(e),
            }
        }
        other => Err(format!("Unknown or unsupported method: {}", other)),
    };

    make_ws_response(req_id, res)
}

fn make_ws_response(req_id: Option<serde_json::Value>, res: Result<serde_json::Value, String>) -> serde_json::Value {
    let mut val = match res {
        Ok(v) => serde_json::json!({
            "ok": true,
            "result": v
        }),
        Err(err) => serde_json::json!({
            "ok": false,
            "error_code": 400,
            "description": err
        }),
    };
    if let Some(id) = req_id {
        val["id"] = id;
    }
    val
}
