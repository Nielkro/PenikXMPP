# Penik Bot Gateway (`penik-bot-gateway`)

Telegram Bot API compatible microservice gateway for Penik XMPP messenger.

Runs on VPS 1 alongside Prosody, connecting via **XEP-0114 Component Protocol** (`127.0.0.1:5347`) to manage the `bot.penik.chat` sub-domain.

## Features

- **XEP-0114 External Component:**
  - Connects to Prosody with automatic reconnection and SHA1 challenge-handshake.
  - Automatically accepts mutual presence subscriptions (`<presence type="subscribe"/>` -> `subscribed`).
  - Responds to vCard (`vcard-temp`) and service discovery queries (`disco#info`).
- **BotFather In-Process Engine (`botfather@bot.penik.chat`):**
  - Manages bots directly within the chat dialog (`/newbot`, `/mybots`, `/token`, `/cancel`).
  - In-memory FSM dialog tracking per user JID (`DashMap<Jid, (DialogState, Instant)>`).
  - Secure random token generation (`<bot_id>:<64_hex_random>`).
- **Telegram Bot API Compatibility:**
  - `GET /bot<token>/getMe`
  - `POST /bot<token>/sendMessage` (with text and inline keyboard markup)
  - `POST /bot<token>/editMessageText` (XEP-0308 Last Message Correction `<replace id="..."/>`)
  - `POST /bot<token>/setWebhook` & `POST /bot<token>/deleteWebhook`
  - `GET /bot<token>/getWebhookInfo`
  - `GET /bot<token>/getUpdates` & `POST /bot<token>/getUpdates` (Long polling with `offset` confirmation)
  - `POST /bot<token>/sendPhoto` & `POST /bot<token>/sendDocument` (XEP-0066 OOB URL attachment)
- **SSRF & DNS Rebinding Mitigation:**
  - Custom `SafeDnsResolver` implementing `reqwest::dns::Resolve` trait.
  - Filters out all loopback, RFC1918 private, link-local, carrier-grade NAT, and documentation IP addresses.
  - Resolves within the HTTP client before connection, preventing TOCTOU / DNS rebinding.
  - Disables redirects and enforces 5-second request timeouts.
- **Circuit Breaker:**
  - Tracks consecutive webhook delivery failures.
  - Freezes webhook and alerts bot owner via BotFather stanza upon 50 consecutive failures.
- **SQLite WAL Storage:**
  - `bots` table with indexes on token, username, and owner JID.
  - `pending_updates` table with hourly TTL cleanup (> 24h) and FIFO cap (max 1000 items per bot).
