use crate::botfather::BotFatherEngine;
use crate::config::Config;
use crate::db;
use crate::models::{CallbackQuery, Chat, Message, Update, User};
use crate::webhook::WebhookDispatcher;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use sha1::{Digest, Sha1};
use sqlx::SqlitePool;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

pub fn xml_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            other => out.push(other),
        }
    }
    out
}

#[allow(dead_code)]
pub fn xml_unescape(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IqKind {
    Ping,
    DiscoInfo,
    DiscoItems,
    VCard,
    Other,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RawStanza {
    pub tag: String, // "message", "presence", "iq"
    pub to: String,
    pub from: String,
    pub id: String,
    pub stanza_type: String, // "chat", "get", "result", etc.
    pub body: Option<String>,
    pub callback_msg_id: Option<String>,
    pub callback_data: Option<String>,
    pub iq_kind: IqKind,
}

/// Classifies an IQ query payload by its child element namespace and name
pub fn classify_iq(root: &roxmltree::Node) -> IqKind {
    match root.first_element_child() {
        Some(child) => {
            let name = child.tag_name().name();
            let ns = child.tag_name().namespace().unwrap_or_default();
            match (name, ns) {
                ("ping", "urn:xmpp:ping") => IqKind::Ping,
                ("query", "http://jabber.org/protocol/disco#info") => IqKind::DiscoInfo,
                ("query", "http://jabber.org/protocol/disco#items") => IqKind::DiscoItems,
                ("vCard", "vcard-temp") => IqKind::VCard,
                _ => IqKind::Other,
            }
        }
        None => IqKind::Other,
    }
}

/// Parses a single complete XML stanza string into a structured RawStanza using roxmltree
pub fn parse_stanza(xml: &str) -> Option<RawStanza> {
    let doc = roxmltree::Document::parse(xml).ok()?;
    let root = doc.root_element();
    let tag = root.tag_name().name().to_string();

    let to = root.attribute("to").unwrap_or_default().to_string();
    let from = root.attribute("from").unwrap_or_default().to_string();
    let id = root.attribute("id").unwrap_or_default().to_string();
    let stanza_type = root.attribute("type").unwrap_or_default().to_string();

    let body = root
        .children()
        .find(|n| n.has_tag_name("body"))
        .and_then(|b| b.text())
        .map(|s| s.to_string());

    let callback = root.children().find(|n| {
        n.tag_name().name() == "callback"
            && n.tag_name().namespace() == Some("penik:bot:markup")
    });

    let callback_msg_id = callback
        .and_then(|c| c.attribute("msg_id"))
        .map(|s| s.to_string());

    let callback_data = callback
        .and_then(|c| c.attribute("data"))
        .map(|s| s.to_string());

    let iq_kind = if tag == "iq" {
        classify_iq(&root)
    } else {
        IqKind::Other
    };

    Some(RawStanza {
        tag,
        to,
        from,
        id,
        stanza_type,
        body,
        callback_msg_id,
        callback_data,
        iq_kind,
    })
}

/// Extracts complete XML stanzas from an incremental stream buffer
pub fn extract_next_stanza(buf: &mut String) -> Option<String> {
    let trimmed = buf.trim_start();
    let offset = buf.len() - trimmed.len();
    if offset > 0 {
        buf.drain(0..offset);
    }

    if buf.is_empty() {
        return None;
    }

    // Check if buffer starts with '<'
    if !buf.starts_with('<') {
        // Strip unexpected noise
        if let Some(pos) = buf.find('<') {
            buf.drain(0..pos);
        } else {
            buf.clear();
            return None;
        }
    }

    let mut reader = Reader::from_str(buf);
    let mut depth: usize = 0;
    let mut in_stanza = false;
    let mut stanza_end = None;

    let mut ev_buf = Vec::new();
    loop {
        match reader.read_event_into(&mut ev_buf) {
            Ok(Event::Start(ref e)) => {
                if e.name().as_ref() != b"stream:stream" {
                    in_stanza = true;
                    depth += 1;
                }
            }
            Ok(Event::End(_)) => {
                if in_stanza {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        stanza_end = Some(reader.buffer_position());
                        break;
                    }
                }
            }
            Ok(Event::Empty(_)) => {
                if !in_stanza || depth == 0 {
                    stanza_end = Some(reader.buffer_position());
                    break;
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        ev_buf.clear();
    }

    if let Some(end) = stanza_end {
        let stanza: String = buf.drain(0..(end as usize)).collect();
        Some(stanza)
    } else {
        None
    }
}

/// Runs the resilient XEP-0114 Component Protocol loop with automatic reconnect
pub async fn run_component_loop(
    config: Config,
    pool: SqlitePool,
    botfather: Arc<BotFatherEngine>,
    dispatcher: Arc<WebhookDispatcher>,
    stanza_rx: mpsc::Receiver<String>,
) {
    let addr = format!("{}:{}", config.prosody_host, config.prosody_port);
    let shared_rx = Arc::new(tokio::sync::Mutex::new(stanza_rx));

    loop {
        info!("Connecting to Prosody XEP-0114 component port at {}...", addr);
        match TcpStream::connect(&addr).await {
            Ok(stream) => {
                info!("TCP connection established. Performing XEP-0114 handshake...");
                match perform_handshake(stream, &config).await {
                    Ok((mut reader_half, mut writer_half)) => {
                        info!("XEP-0114 handshake successful! Component is online as '{}'.", config.component_domain);

                        // Spawn outbound writer task
                        let (outbound_tx, mut outbound_rx) = mpsc::channel::<String>(256);

                        let writer_task = tokio::spawn(async move {
                            while let Some(xml) = outbound_rx.recv().await {
                                if let Err(e) = writer_half.write_all(xml.as_bytes()).await {
                                    error!("Failed writing stanza to XEP-0114 stream: {}", e);
                                    break;
                                }
                                if let Err(e) = writer_half.flush().await {
                                    error!("Failed flushing XEP-0114 stream: {}", e);
                                    break;
                                }
                            }
                        });

                        // Pipe global outbound messages to this active writer
                        let forwarder_tx = outbound_tx.clone();
                        let rx_clone = shared_rx.clone();
                        let forwarder_task = tokio::spawn(async move {
                            let mut rx = rx_clone.lock().await;
                            while let Some(msg) = rx.recv().await {
                                if forwarder_tx.send(msg).await.is_err() {
                                    break;
                                }
                            }
                        });

                        // Read and dispatch incoming stanzas
                        let mut read_buf = [0u8; 4096];
                        let mut stream_string_buf = String::new();

                        loop {
                            match reader_half.read(&mut read_buf).await {
                                Ok(0) => {
                                    warn!("XEP-0114 connection closed by remote Prosody server.");
                                    break;
                                }
                                Ok(n) => {
                                    let chunk = String::from_utf8_lossy(&read_buf[..n]);
                                    stream_string_buf.push_str(&chunk);

                                    while let Some(stanza_xml) = extract_next_stanza(&mut stream_string_buf) {
                                        let pool_clone = pool.clone();
                                        let botfather_clone = botfather.clone();
                                        let dispatcher_clone = dispatcher.clone();
                                        let outbound_clone = outbound_tx.clone();
                                        let domain_clone = config.component_domain.clone();

                                        tokio::spawn(async move {
                                            handle_incoming_stanza(
                                                &stanza_xml,
                                                &pool_clone,
                                                &botfather_clone,
                                                &dispatcher_clone,
                                                &outbound_clone,
                                                &domain_clone,
                                            )
                                            .await;
                                        });
                                    }
                                }
                                Err(e) => {
                                    error!("Error reading from XEP-0114 socket: {}", e);
                                    break;
                                }
                            }
                        }

                        writer_task.abort();
                        forwarder_task.abort();
                    }
                    Err(e) => {
                        error!("XEP-0114 handshake failed: {}", e);
                    }
                }
            }
            Err(e) => {
                error!("Could not connect to Prosody at {}: {}", addr, e);
            }
        }

        info!("Waiting 5 seconds before attempting reconnect to Prosody...");
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

async fn perform_handshake(
    mut stream: TcpStream,
    config: &Config,
) -> anyhow::Result<(tokio::net::tcp::OwnedReadHalf, tokio::net::tcp::OwnedWriteHalf)> {
    // 1. Send stream open tag
    let open_stream = format!(
        "<?xml version='1.0'?><stream:stream xmlns='jabber:component:accept' xmlns:stream='http://etherx.jabber.org/streams' to='{}'>",
        config.component_domain
    );
    stream.write_all(open_stream.as_bytes()).await?;
    stream.flush().await?;

    // 2. Read stream header response from Prosody
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).await?;
    let header_reply = String::from_utf8_lossy(&buf[..n]);

    // Extract stream id: id='...' or id="..."
    let session_id = extract_attribute(&header_reply, "id").ok_or_else(|| {
        anyhow::anyhow!("Could not find stream id in Prosody reply: {}", header_reply)
    })?;

    // 3. Compute SHA1(session_id + secret)
    let mut hasher = Sha1::new();
    hasher.update(session_id.as_bytes());
    hasher.update(config.component_secret.as_bytes());
    let handshake_hash = hex::encode(hasher.finalize());

    // 4. Send <handshake>hash</handshake>
    let handshake_stanza = format!("<handshake>{}</handshake>", handshake_hash);
    stream.write_all(handshake_stanza.as_bytes()).await?;
    stream.flush().await?;

    // 5. Read handshake confirmation: <handshake/>
    let n = stream.read(&mut buf).await?;
    let auth_reply = String::from_utf8_lossy(&buf[..n]);

    if !auth_reply.contains("<handshake") {
        return Err(anyhow::anyhow!(
            "Prosody authentication rejected credentials: {}",
            auth_reply
        ));
    }

    Ok(stream.into_split())
}

fn extract_attribute(xml: &str, attr: &str) -> Option<String> {
    let key1 = format!("{}=\"", attr);
    let key2 = format!("{}='", attr);

    if let Some(start) = xml.find(&key1) {
        let val_start = start + key1.len();
        if let Some(end) = xml[val_start..].find('"') {
            return Some(xml[val_start..val_start + end].to_string());
        }
    } else if let Some(start) = xml.find(&key2) {
        let val_start = start + key2.len();
        if let Some(end) = xml[val_start..].find('\'') {
            return Some(xml[val_start..val_start + end].to_string());
        }
    }
    None
}

async fn handle_incoming_stanza(
    stanza_xml: &str,
    pool: &SqlitePool,
    botfather: &BotFatherEngine,
    dispatcher: &WebhookDispatcher,
    outbound: &mpsc::Sender<String>,
    component_domain: &str,
) {
    let raw = match parse_stanza(stanza_xml) {
        Some(s) => s,
        None => return,
    };

    debug!("Parsed incoming stanza: {:?}", raw);

    // Extract localpart of 'to': e.g. "weather_bot" from "weather_bot@bot.penik.chat/res"
    let to_jid = &raw.to;
    let localpart = if let Some(at_pos) = to_jid.find('@') {
        &to_jid[..at_pos]
    } else {
        to_jid.as_str()
    };

    // Case 1: Stanza addressed to botfather
    if localpart.eq_ignore_ascii_case("botfather") {
        handle_botfather_stanza(&raw, botfather, outbound, component_domain).await;
        return;
    }

    // Case 2: Ping or disco to component domain itself
    if to_jid == component_domain || to_jid.is_empty() {
        if raw.tag == "iq" {
            handle_iq_query(
                &raw,
                component_domain,
                outbound,
                "Penik Bot Gateway",
                "component",
                "generic",
                &["urn:xmpp:ping", "penik:bot:markup"],
                None,
            )
            .await;
        }
        return;
    }

    // Case 3: Stanza addressed to a specific registered bot
    let bot_opt = match db::get_bot_by_username(pool, localpart).await {
        Ok(b) => b,
        Err(e) => {
            error!("Database lookup error for bot {}: {}", localpart, e);
            return;
        }
    };

    let bot = match bot_opt {
        Some(b) => b,
        None => {
            // Unknown bot: reply service-unavailable so sender does not time out
            let from = &raw.from;
            let to = &raw.to;
            let id = &raw.id;
            match (raw.tag.as_str(), raw.stanza_type.as_str()) {
                ("message", "chat" | "") => {
                    let err_msg = format!(
                        "<message type='error' to='{}' from='{}' id='{}'>\
                        <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>\
                        </message>",
                        xml_escape(from),
                        xml_escape(to),
                        xml_escape(id)
                    );
                    let _ = outbound.send(err_msg).await;
                }
                ("iq", "get" | "set") => {
                    let err_iq = format!(
                        "<iq type='error' to='{}' from='{}' id='{}'>\
                        <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>\
                        </iq>",
                        xml_escape(from),
                        xml_escape(to),
                        xml_escape(id)
                    );
                    let _ = outbound.send(err_iq).await;
                }
                _ => {}
            }
            return;
        }
    };

    let bot_full_jid = format!("{}@{}", bot.username, component_domain);

    match raw.tag.as_str() {
        "presence" => handle_bot_presence(&raw, &bot_full_jid, "Bot ready", outbound).await,
        "iq" => {
            let desc = bot.about.as_deref().unwrap_or("Penik Messenger Bot");
            handle_iq_query(
                &raw,
                &bot_full_jid,
                outbound,
                &bot.title,
                "client",
                "bot",
                &[
                    "vcard-temp",
                    "urn:xmpp:ping",
                    "penik:bot:markup",
                    "urn:xmpp:message-correct:0",
                ],
                Some(desc),
            )
            .await;
        }
        "message" => {
            // Build Telegram-compatible Update
            let user_jid = raw.from.split('/').next().unwrap_or(&raw.from).to_string();
            let user_localpart = user_jid.split('@').next().unwrap_or(&user_jid).to_string();
            let chat_id_num = generate_jid_hash_id(&user_jid);
            let _ = db::upsert_jid_chat(pool, chat_id_num, &user_jid).await;

            let update_id = db::current_timestamp();

            let update = if let (Some(msg_id), Some(data)) = (raw.callback_msg_id, raw.callback_data) {
                // Button click CallbackQuery
                Update {
                    update_id,
                    message: None,
                    callback_query: Some(CallbackQuery {
                        id: format!("{}:{}", user_jid, if raw.id.is_empty() { msg_id.clone() } else { raw.id.clone() }),
                        from: User {
                            id: generate_jid_hash_id(&user_jid),
                            is_bot: false,
                            first_name: user_localpart.clone(),
                            username: Some(user_localpart.clone()),
                        },
                        message: Some(Message {
                            message_id: msg_id,
                            from: None,
                            chat: Chat {
                                id: generate_jid_hash_id(&user_jid),
                                r#type: "private".to_string(),
                                username: Some(user_localpart),
                                first_name: None,
                                title: None,
                            },
                            date: db::current_timestamp(),
                            text: None,
                            reply_markup: None,
                        }),
                        data: Some(data),
                    }),
                }
            } else if let Some(body_text) = raw.body {
                // Normal chat message
                Update {
                    update_id,
                    message: Some(Message {
                        message_id: raw.id.clone(),
                        from: Some(User {
                            id: generate_jid_hash_id(&user_jid),
                            is_bot: false,
                            first_name: user_localpart.clone(),
                            username: Some(user_localpart.clone()),
                        }),
                        chat: Chat {
                            id: generate_jid_hash_id(&user_jid),
                            r#type: "private".to_string(),
                            username: Some(user_localpart),
                            first_name: None,
                            title: None,
                        },
                        date: db::current_timestamp(),
                        text: Some(body_text),
                        reply_markup: None,
                    }),
                    callback_query: None,
                }
            } else {
                return;
            };

            if let Err(e) = dispatcher.dispatch_update(&bot, update).await {
                error!("Failed dispatching update to bot @{}: {}", bot.username, e);
            }
        }
        _ => {}
    }
}

async fn handle_bot_presence(
    raw: &RawStanza,
    responder_jid: &str,
    status_text: &str,
    outbound: &mpsc::Sender<String>,
) {
    let from = &raw.from;
    match raw.stanza_type.as_str() {
        "subscribe" => {
            let sub_resp = format!(
                "<presence type='subscribed' to='{}' from='{}'/>",
                xml_escape(from),
                xml_escape(responder_jid)
            );
            let online_resp = format!(
                "<presence to='{}' from='{}'><show>chat</show><status>{}</status></presence>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(status_text)
            );
            let _ = outbound.send(sub_resp).await;
            let _ = outbound.send(online_resp).await;
        }
        "" | "probe" => {
            let online_resp = format!(
                "<presence to='{}' from='{}'><show>chat</show><status>{}</status></presence>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(status_text)
            );
            let _ = outbound.send(online_resp).await;
        }
        _ => {}
    }
}

async fn handle_iq_query(
    raw: &RawStanza,
    responder_jid: &str,
    outbound: &mpsc::Sender<String>,
    disco_name: &str,
    disco_category: &str,
    disco_type: &str,
    extra_features: &[&str],
    vcard_desc: Option<&str>,
) {
    let from = &raw.from;
    let id = &raw.id;
    match (raw.stanza_type.as_str(), &raw.iq_kind) {
        ("get", IqKind::Ping) => {
            let resp = format!(
                "<iq type='result' to='{}' from='{}' id='{}'/>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(id)
            );
            let _ = outbound.send(resp).await;
        }
        ("get", IqKind::DiscoInfo) => {
            let mut features_xml = String::new();
            for f in extra_features {
                features_xml.push_str(&format!("<feature var='{}'/>", f));
            }
            let resp = format!(
                "<iq type='result' to='{}' from='{}' id='{}'>\
                <query xmlns='http://jabber.org/protocol/disco#info'>\
                    <identity category='{}' type='{}' name='{}'/>\
                    <feature var='http://jabber.org/protocol/disco#info'/>\
                    <feature var='http://jabber.org/protocol/disco#items'/>\
                    {}\
                </query>\
                </iq>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(id),
                disco_category,
                disco_type,
                xml_escape(disco_name),
                features_xml
            );
            let _ = outbound.send(resp).await;
        }
        ("get", IqKind::DiscoItems) => {
            let resp = format!(
                "<iq type='result' to='{}' from='{}' id='{}'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(id)
            );
            let _ = outbound.send(resp).await;
        }
        ("get", IqKind::VCard) if vcard_desc.is_some() => {
            let resp = format!(
                "<iq type='result' to='{}' from='{}' id='{}'>\
                <vCard xmlns='vcard-temp'>\
                    <FN>{}</FN>\
                    <DESC>{}</DESC>\
                </vCard>\
                </iq>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(id),
                xml_escape(disco_name),
                xml_escape(vcard_desc.unwrap())
            );
            let _ = outbound.send(resp).await;
        }
        ("get" | "set", _) => {
            let resp = format!(
                "<iq type='error' to='{}' from='{}' id='{}'>\
                <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>\
                </iq>",
                xml_escape(from),
                xml_escape(responder_jid),
                xml_escape(id)
            );
            let _ = outbound.send(resp).await;
        }
        _ => {}
    }
}

async fn handle_botfather_stanza(
    raw: &RawStanza,
    botfather: &BotFatherEngine,
    outbound: &mpsc::Sender<String>,
    component_domain: &str,
) {
    let bf_jid = format!("botfather@{}", component_domain);

    match raw.tag.as_str() {
        "presence" => handle_bot_presence(raw, &bf_jid, "BotFather ready", outbound).await,
        "iq" => {
            handle_iq_query(
                raw,
                &bf_jid,
                outbound,
                "BotFather",
                "client",
                "bot",
                &["vcard-temp", "urn:xmpp:ping"],
                Some("BotFather - the one to rule them all. Use it to create and manage Penik bots."),
            )
            .await;
        }
        "message" => {
            if let Some(ref text) = raw.body {
                let reply_text = botfather.handle_message(&raw.from, text).await;
                let reply_msg = format!(
                    "<message type='chat' to='{}' from='{}'><body>{}</body></message>",
                    xml_escape(&raw.from),
                    bf_jid,
                    xml_escape(&reply_text)
                );
                let _ = outbound.send(reply_msg).await;
            }
        }
        _ => {}
    }
}

/// Computes a stable positive i64 ID from a user JID string
pub fn generate_jid_hash_id(jid: &str) -> i64 {
    let mut hasher = Sha1::new();
    hasher.update(jid.as_bytes());
    let hash = hasher.finalize();
    let val = i64::from_be_bytes(hash[..8].try_into().unwrap());
    val.abs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_next_stanza() {
        let mut buf = "<message to='bot@domain' from='user@domain' id='1'><body>Hello!</body></message><presence to='bot@domain'/>".to_string();
        
        let s1 = extract_next_stanza(&mut buf).unwrap();
        assert!(s1.starts_with("<message"));
        assert!(s1.ends_with("</message>"));

        let s2 = extract_next_stanza(&mut buf).unwrap();
        assert_eq!(s2, "<presence to='bot@domain'/>");

        assert!(extract_next_stanza(&mut buf).is_none());
    }

    #[test]
    fn test_parse_message_with_callback() {
        let xml = "<message type='chat' to='weather_bot@bot.penik.chat' from='alice@penik.chat' id='msg_01'><callback xmlns='penik:bot:markup' msg_id='100' data='city:msk'/><no-store xmlns='urn:xmpp:hints'/></message>";
        let s = parse_stanza(xml).unwrap();
        assert_eq!(s.to, "weather_bot@bot.penik.chat");
        assert_eq!(s.from, "alice@penik.chat");
        assert_eq!(s.callback_msg_id.as_deref(), Some("100"));
        assert_eq!(s.callback_data.as_deref(), Some("city:msk"));
    }

    #[test]
    fn test_xml_escaping() {
        let raw = "Hello <World> & 'Friends' \"123\"";
        let escaped = xml_escape(raw);
        assert_eq!(escaped, "Hello &lt;World&gt; &amp; &apos;Friends&apos; &quot;123&quot;");
        assert_eq!(xml_unescape(&escaped), raw);
    }

    #[test]
    fn test_roxmltree_basics() {
        let xml = "<iq type='get' id='123' to='bot.snikket.penik.ru'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>";
        let doc = roxmltree::Document::parse(xml).unwrap();
        let root = doc.root_element();
        assert_eq!(root.tag_name().name(), "iq");
        assert_eq!(root.attribute("type"), Some("get"));
        assert_eq!(root.attribute("to"), Some("bot.snikket.penik.ru"));
        
        let child = root.first_element_child().unwrap();
        assert_eq!(child.tag_name().name(), "query");
        assert_eq!(child.tag_name().namespace(), Some("http://jabber.org/protocol/disco#info"));

        let msg_xml = "<message to='bot@domain' from='user@domain' id='m1'><body>Hello &amp; world!</body><callback xmlns='penik:bot:markup' msg_id='42' data='btn:1'/></message>";
        let msg_doc = roxmltree::Document::parse(msg_xml).unwrap();
        let msg_root = msg_doc.root_element();
        let body = msg_root.children().find(|n| n.has_tag_name("body")).unwrap();
        assert_eq!(body.text(), Some("Hello & world!"));

        let cb = msg_root.children().find(|n| n.has_tag_name("callback")).unwrap();
        assert_eq!(cb.tag_name().namespace(), Some("penik:bot:markup"));
        assert_eq!(cb.attribute("msg_id"), Some("42"));
        assert_eq!(cb.attribute("data"), Some("btn:1"));
    }

    #[test]
    fn test_parse_stanza_iq_variants() {
        // Self-closing disco#info query
        let xml1 = "<iq type='get' id='1' to='bot.snikket.penik.ru'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>";
        let s1 = parse_stanza(xml1).unwrap();
        assert_eq!(s1.tag, "iq");
        assert_eq!(s1.stanza_type, "get");
        assert_eq!(s1.iq_kind, IqKind::DiscoInfo);

        // Open/close disco#info query
        let xml2 = "<iq type='get' id='2' to='bot.snikket.penik.ru'><query xmlns='http://jabber.org/protocol/disco#info'></query></iq>";
        let s2 = parse_stanza(xml2).unwrap();
        assert_eq!(s2.iq_kind, IqKind::DiscoInfo);

        // Ping
        let xml3 = "<iq type='get' id='3' to='bot.snikket.penik.ru'><ping xmlns='urn:xmpp:ping'/></iq>";
        let s3 = parse_stanza(xml3).unwrap();
        assert_eq!(s3.iq_kind, IqKind::Ping);

        // vCard
        let xml4 = "<iq type='get' id='4' to='bot.snikket.penik.ru'><vCard xmlns='vcard-temp'/></iq>";
        let s4 = parse_stanza(xml4).unwrap();
        assert_eq!(s4.iq_kind, IqKind::VCard);

        // disco#items
        let xml5 = "<iq type='get' id='5' to='bot.snikket.penik.ru'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>";
        let s5 = parse_stanza(xml5).unwrap();
        assert_eq!(s5.iq_kind, IqKind::DiscoItems);

        // Unknown IQ
        let xml6 = "<iq type='get' id='6' to='bot.snikket.penik.ru'><unknown xmlns='urn:unknown'/></iq>";
        let s6 = parse_stanza(xml6).unwrap();
        assert_eq!(s6.iq_kind, IqKind::Other);
    }
}
