# Telegram Puppeting Bridge Architecture Plan (MTProto ⇄ XMPP)

## 1. Overview & Goal
Full-duplex puppeting bridge connecting a user's personal Telegram account directly to Penik via XEP-0114 Component Protocol (`tg.snikket.penik.ru`).
Allows receiving, sending, and managing Telegram 1:1 direct chats, group chats, channels, media, voice notes, stickers, and reactions directly inside Penik.

## 2. Virtual Entities Mapping
- Control Bot: `@tgbridgebot` on `bot.snikket.penik.ru` (Standard Penik Bot via WS API: Login FSM, `/chats` menu with inline toggles, `/add`, `/list`)
- Virtual Contacts: `u_{telegram_user_id}@tg.snikket.penik.ru` (XEP-0114 Component `tg.snikket.penik.ru`)
- Virtual Groups: `g_{chat_id}@tg.snikket.penik.ru` (XEP-0114 Component `tg.snikket.penik.ru`)
- Selective Sync: User explicitly picks which TG chats to bridge to Penik instead of auto-importing everything.

## 3. Technology Stack
- Language: Rust (Tokio, async-await)
- MTProto: `grammers` (lightweight pure Rust async MTProto client) or `tdlib-rs`
- Storage: SQLite WAL with encrypted auth keys
- Server Protocol: XEP-0114 External Component to Prosody over Direct TLS 1.3 (`snikket.penik.ru:5348`)

## 4. Key Protocol Mapping
- Messages: `<message type='chat'>` bidirectional
- Replies: XEP-0461 (Reply)
- Edits: XEP-0308 (Last Message Correction)
- Retractions: XEP-0424 (Message Retraction)
- Reactions: XEP-0444 (Reactions)
- Voice Notes: OGG Opus (native compatibility with Penik voice player)
- Media Files: XEP-0363 HTTP Upload to `share.snikket.penik.ru`
- Stickers: Animated/Static WebP conversion via `penik-service-rs`

## 5. Phases
1. Component skeleton + interactive onboarding via `bot@tg.snikket.penik.ru` (login -> code -> 2FA).
2. 1:1 direct messaging, presence sync, typing indicators, vCard avatars.
3. Media pipeline (photos, voice notes, documents, stickers).
4. MUC group chats with participant nick mapping.
5. Reconnection handling, FloodWait backoff, Docker containerization.
