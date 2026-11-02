# DinoX Botmother AI — API & User Guide

> Version 1.2 | May 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Getting Started](#2-getting-started)
   - [2.1 Enable Botmother in Settings](#21-enable-botmother-in-settings)
   - [2.2 Your First Bot](#22-your-first-bot)
   - [2.3 Bot Modes](#23-bot-modes)
3. [Personal Bot Management](#3-personal-bot-management)
   - [3.1 UI-first workflow](#31-ui-first-workflow)
   - [3.2 Permissions and target restrictions](#32-permissions-and-target-restrictions)
   - [3.3 Test console](#33-test-console)
   - [3.4 Token management](#34-token-management)
4. [Bot Management via UI (Bot Manager Dialog)](#4-bot-management-via-ui-bot-manager-dialog)
   - [4.1 Opening the Bot Manager](#41-opening-the-bot-manager)
   - [4.2 Bot List & Actions](#42-bot-list--actions)
   - [4.3 ejabberd Settings (for Dedicated Bots)](#43-ejabberd-settings-for-dedicated-bots)
5. [Dedicated Bot Chat — Interactive Menus](#5-dedicated-bot-chat--interactive-menus)
   - [5.1 Main Menu (/help)](#51-main-menu-help)
   - [5.2 AI Assistant (/ki)](#52-ai-assistant-ki)
   - [5.3 Telegram Bridge (/telegram)](#53-telegram-bridge-telegram)
   - [5.4 API Documentation (/api)](#54-api-documentation-api)
   - [5.5 API Server Settings (/api server)](#55-api-server-settings-api-server)
6. [AI Assistant — Setup & Usage](#6-ai-assistant--setup--usage)
   - [6.1 Supported Providers](#61-supported-providers)
   - [6.2 Quick Setup](#62-quick-setup)
   - [6.3 Talking to the AI](#63-talking-to-the-ai)
   - [6.4 System Prompt](#64-system-prompt)
   - [6.5 Changing Provider or Model](#65-changing-provider-or-model)
7. [Telegram Bridge — Setup & Usage](#7-telegram-bridge--setup--usage)
   - [7.1 Prerequisites](#71-prerequisites)
   - [7.2 Setup](#72-setup)
   - [7.3 Bridge Modes](#73-bridge-modes)
   - [7.4 Message Flow](#74-message-flow)
   - [7.5 Planned Features (Roadmap)](#75-planned-features-roadmap)
8. [HTTP API Reference](#8-http-api-reference)
   - [8.1 Authentication](#81-authentication)
   - [8.2 API Server Configuration](#82-api-server-configuration)
   - [8.3 Local Bot Management Endpoints](#83-local-bot-management-endpoints)
   - [8.4 Bot Messaging Endpoints (Auth Required)](#84-bot-messaging-endpoints-auth-required)
   - [8.5 Webhook System](#85-webhook-system)
   - [8.6 Advanced Endpoints](#86-advanced-endpoints)
   - [8.7 ejabberd Admin Endpoints](#87-ejabberd-admin-endpoints)
   - [8.8 Telegram API Endpoints](#88-telegram-api-endpoints)
   - [8.9 AI API Endpoints](#89-ai-api-endpoints)
   - [8.10 Complete curl Examples](#810-complete-curl-examples)
   - [8.11 Python Examples](#811-python-examples)
9. [Settings Reference](#9-settings-reference)
   - [9.1 Application Settings (Preferences)](#91-application-settings-preferences)
   - [9.2 Per-Bot Settings (Database)](#92-per-bot-settings-database)
10. [Database Schema](#10-database-schema)
11. [DinoX CloudBot Server](#11-dinox-cloudbot-server)
12. [OpenClaw Integration](#12-openclaw-integration)

---

## 1. Overview

**Botmother** is DinoX's built-in bot platform. It lets you create, manage, and run XMPP bots directly from DinoX — no separate server or software needed.

**What you can do:**

- Create bots that respond to XMPP messages
- Connect an AI (OpenAI, Claude, Gemini, Groq, Mistral, DeepSeek, Perplexity, xAI/Grok, Ollama, OpenClaw) to any bot
- Bridge bot messages to/from Telegram
- Control bots via an HTTP API with webhooks
- Manage local personal bots through the graphical UI and local REST API
- Run bots as your own account (Personal) or as independent XMPP accounts (Dedicated)

**Architecture:**

```
┌────────────────────────────────────────────────────┐
│                    DinoX App                       │
│                                                    │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────┐   │
│  │  Manager UI  │  │ Bot Chat    │  │ REST API  │  │
│  │ + Console    │  │ (Dedicated) │  │ + Webhook │  │
│  └──────┬───────┘  └──────┬──────┘  └─────┬─────┘  │
│         │                 │               │        │
│  ┌──────┴─────────────────┴───────────────┴─────┐  │
│  │            Message Router                     │ │
│  └──────────────────┬────────────────────────────┘ │
│                     │                              │
│  ┌──────────┬───────┴────────┬──────────────────┐  │
│  │ Bot      │ Session Pool   │ HTTP Server      │  │
│  │ Registry │ (Personal +    │ (REST API +      │  │
│  │ (SQLite) │  Dedicated)    │  TLS)            │  │
│  └──────────┘ └──────────────┘ └────────────────┘  │
│                     │                              │
│  ┌──────────┬───────┴────────┬──────────────────┐  │
│  │ AI       │ Telegram       │ Webhook          │  │
│  │ Integr.  │ Bridge         │ Dispatcher       │  │
│  └──────────┘ └──────────────┘ └────────────────┘  │
└────────────────────────────────────────────────────┘
```

---

## 2. Getting Started

### 2.1 Enable Botmother in Settings

1. Open DinoX
2. Go to **Preferences** (gear icon or menu)
3. Scroll to the **Botmother** section
4. Toggle **"Enable Botmother"** ON

Once enabled, these additional settings appear:

| Setting | Description | Default |
|---------|-------------|---------|
| **API Server Mode** | `Local (localhost)` — HTTP, only accessible from this machine. `Network (0.0.0.0 + TLS)` — HTTPS, accessible from the network. | Local |
| **API Port** | Port number for the API server (1024–65535) | 7842 |
| **TLS Certificate** | Path to PEM certificate file (Network mode only). Leave empty for auto-generated self-signed. | (empty) |
| **TLS Private Key** | Path to PEM key file (Network mode only). Leave empty for auto-generated. | (empty) |

> **Note:** All settings are applied immediately — no restart required. The API server automatically restarts when you change mode, port, or TLS settings.

Turning **Enable Botmother** off stops local bot message processing, dedicated
bot connections, Telegram polling and webhook delivery. Pending startup actions
and retries are cancelled. Bot records, tokens and integration settings are kept;
turning the feature on again starts a fresh runtime without duplicate listeners.
Profile backups include an existing bot registry even when Botmother is disabled
and was not initialized during the current application session.

If the API cannot start because its port is occupied, select a free port while
Botmother remains enabled. The API retries with the corrected settings after a
short delay; toggling the feature off and on is not required. Changing API
settings while Botmother is disabled does not start it.

> The examples in this document use local mode (`http://localhost:7842`). In network mode the API base URL is `https://<host>:<port>`; for DinoX's auto-generated self-signed certificate, external test tools such as `curl` need either a trusted certificate setup or `-k` during local development.

### 2.2 Your First Bot

**Via UI (Bot Manager):**
1. Click the Botmother icon in the header bar, or go to the account menu
2. Click **"New Botmother"**
3. Enter a name, choose a mode and optionally restrict API permissions
4. Optionally set a webhook URL
5. The bot is created with a generated token
6. Store the token immediately if you need external API access. Raw tokens are shown only once when created or regenerated.

### 2.3 Bot Modes

| Mode | How it Works | Best For |
|------|-------------|----------|
| **Personal** | Bot shares your XMPP account and sends through DinoX's normal message pipeline. It does not have its own XMPP JID. | Quick experiments, local automation, Node-RED/webhook/API flows |
| **Dedicated** | Bot gets its own XMPP account, either an existing account you provide or one provisioned through the ejabberd admin API. Appears as a separate contact with its own JID, OMEMO keys, avatar, and roster. | Public bots, bots for other users, full separation |
| **DinoX CloudBot Server** | Create hosted bots at `https://cloud.dinox.im`, then manage them in DinoX with the one-time management token. | Hosted bot infrastructure |

**Personal mode** requires no extra setup. **Dedicated mode** requires either an existing bot account/password or ejabberd admin API access for automatic provisioning (see [Section 4.3](#43-ejabberd-settings-for-dedicated-bots)). **CloudBot creation is not a local `/bot/create` operation**: the local API still rejects `"mode":"cloud"` with `501 not_implemented`. Create CloudBots on `https://cloud.dinox.im`, then click **New Botmother**, choose **DinoX-Client CloudBot**, and paste the management token.

#### Personal Mode — How it works in detail

In Personal mode, the bot shares your own XMPP account:

- API messages are sent as the owner account.
- Direct messages go through DinoX's normal `MessageProcessor` path, so OMEMO and local message handling are preserved.
- MUC messages require `muc_send`, target permission and that the owner account is actually joined to the room.
- Personal bots do not create a fake Botmother/self-chat. Local testing and owner commands belong in the Bot Manager UI.

> **Note:** Since the bot shares your account, messages sent by the bot via the HTTP API appear to come from your own JID. Use target restrictions to prevent accidental sends to unwanted contacts or rooms.

#### Dedicated Mode — How it works in detail

In Dedicated mode, each bot gets its own independent XMPP account. This provides full separation and security:

**Own XMPP Account:**
- DinoX can use an existing bot account that you enter manually.
- Or DinoX can register a new account on your ejabberd server via the admin API.
- For ejabberd-provisioned accounts, the bot JID is generated automatically: `bot_<name>_<hash>@<server>`
- Example: `bot_weatherbot_c3a1@chat.example.com`
- The bot has its own password, stored via DinoX secret settings; the legacy database column is intentionally cleared after migration.

**Automatic OMEMO Encryption:**
- DinoX automatically generates OMEMO keys for the dedicated bot
- The direct 1:1 conversation between you and the bot is **OMEMO-encrypted by default**
- The bot publishes its OMEMO device list and key bundles via PubSub
- Direct owner/bot messages are end-to-end encrypted when OMEMO is available
- No manual OMEMO setup needed — it happens automatically on first connection

**Owner-Only Binding:**
- The dedicated bot is **bound exclusively to its creator's JID**
- In direct 1:1 chats, the bot **only accepts and processes messages from the owner**
- Direct messages from any other JID are ignored
- Subscription requests from non-owners are rejected
- The bot automatically approves mutual presence subscription with the owner
- This means: even if someone discovers the bot's JID, they cannot control it or use it through direct chat
- MUC room messages are handled separately: if the bot has joined a room, normal room participants may trigger the configured group-bot behavior according to the MUC reply mode and target/permission rules.

**Automatic Conversation Setup:**
- When the dedicated bot connects, DinoX automatically:
  1. Prepares the owner-side bot contact and roster display name
  2. Enables OMEMO encryption for the owner-side bot conversation
  3. Sends/approves presence subscription (bot ↔ owner)
  4. Publishes the bot's OMEMO device list and bundles
  5. Publishes vCard4 and vCard-temp metadata, including the avatar if configured
  6. Makes PubSub nodes publicly accessible

**Separate Chat:**
- The dedicated bot is a **separate contact** with its own real JID
- Connecting the bot does not automatically pin/open its chat in the conversation list
- The chat appears when you manually open/write to the bot contact or when the bot sends a real message
- You chat with it just like chatting with any other person
- Slash commands (`/help`, `/ki`, `/telegram`, `/api`) work in this chat
- Non-command messages go to the AI (if configured)
- In MUCs, Dedicated bots only answer AI prompts when the room message mentions the bot name or bot localpart. This prevents every room message from consuming AI runtime.
- MUC messages are sent as normal groupchat stanzas. They are not OMEMO-encrypted; the owner-side direct bot chat can still use OMEMO.
- MUC owner notifications can send a direct message to the bot owner when the bot is mentioned in a room. The `when absent` mode depends on the room exposing occupant real JIDs; anonymous rooms may not provide enough data.

```
┌──────────────────────────┐
│  Chat List               │
│  🤖 WeatherBot 🔒        │  ← Dedicated bot (OMEMO encrypted)
│  🤖 SupportBot 🔒        │  ← Another dedicated bot
│     Alice                │
│     Bob                  │
└──────────────────────────┘

🔒 = OMEMO end-to-end encrypted
```

> **Security:** Dedicated bots are the recommended mode for any bot that handles sensitive data. The OMEMO encryption and owner-only binding ensure that bot communications are private and cannot be intercepted or hijacked.

---

## 3. Personal Bot Management

Personal bot management is UI-first. The old self-chat/Botfather command handler has been removed for personal bots to avoid fake contacts, ambiguous owner chats and cross-account routing mistakes.

### 3.1 UI-first workflow

Use the Bot Manager dialog to:

- create personal bots;
- choose bot permissions during creation;
- enable or disable Botmother for the account;
- activate/deactivate bots;
- delete bots with confirmation;
- regenerate or revoke API tokens;
- configure permissions and target restrictions;
- configure webhook URLs and generate new webhook secrets without exposing the API token;
- send local test messages without exposing the API token.

Dedicated bots may still offer interactive slash-command menus in their own real XMPP chat because they have an actual bot JID and session.

### 3.2 Permissions and target restrictions

Permissions answer **what** the bot may do:

| Permission | Meaning |
|------------|---------|
| `all` | Compatibility super-scope |
| `send_message` | Send direct chat messages |
| `muc_send` | Send groupchat messages |
| `receive_updates` | Receive updates / getUpdates / webhook delivery |
| `webhook` | Webhook management |
| `file_send` | File sending |
| `muc_join` | Room join/leave actions |
| `admin` | Administrative actions |

Target restrictions answer **where** the bot may send:

| Mode | Meaning |
|------|---------|
| `all` | All targets are allowed |
| `allow` | Only listed JIDs/domains are allowed |
| `block` | All targets except listed JIDs/domains are allowed |

Supported target entries:

- full JID: `friend@example.org`
- domain shorthand: `@example.org`
- explicit domain: `domain:example.org`
- MUC JID: `room@conference.example.org`
- wildcard: `*`

The UI offers a contact/MUC picker as the normal workflow. The raw comma-separated target field remains available for domains, wildcards and manual correction.

### 3.3 Test console

The Bot Manager test console sends a local test message through `/bot/testSend`.

- It does not require or display the raw API token.
- It uses the bot's real permissions and target restrictions.
- It can pick contacts and open group chats from the current account.
- It automatically chooses direct chat vs group chat when a target is selected.
- For Personal bot MUC sends, the owner account must be joined to the room.
- For Dedicated bot MUC sends, the dedicated bot account must be joined to the room through its own stream.

The AI test question in the Bot Manager is different from this console: it only checks the configured provider, API key, model and system prompt through `/bot/ai/testAsk`. It does not send anything to XMPP and should not be used to verify chat delivery.

### 3.4 Token Management

Every bot has an API token used for authentication. Tokens currently use the format `bot<id>:<uuid>`, for example `bot1:43291125-6c25-4c62-9927-5cf1de3e03f2`.

- Raw tokens are shown only once when a bot is created or when a token is regenerated.
- DinoX stores only token hashes / inactive markers, never raw tokens.
- Regenerating a token invalidates the old token.
- Revoking a token disables API access for that bot.
- Token management is shown for every bot purpose, even when the normal edit view only exposes AI, Telegram or webhook-specific settings.

---

## 4. Bot Management via UI (Bot Manager Dialog)

### 4.1 Opening the Bot Manager

The Bot Manager dialog provides a graphical interface for all bot operations. It communicates with the local API server.

### 4.2 Bot List & Actions

The main view shows all bots for the selected account:

```
┌─────────────────────────────────────────┐
│  Botmother — ralf@chat.example.com      │
├─────────────────────────────────────────┤
│  [✓] Botmother Active                   │
│      Enable Botmother for this account  │
├─────────────────────────────────────────┤
│                                         │
│  ● WeatherBot                           │
│    ID: 1 · personal · active            │
│    API token                   [+] [✕]   │
│                                         │
│  ● SupportBot                           │
│    ID: 3 · dedicated · active           │
│    support_bot_c3a1@chat.example.com    │
│    API token                   [+] [✕]   │
│                                         │
├─────────────────────────────────────────┤
│  ▸ Server Settings (ejabberd)           │
├─────────────────────────────────────────┤
│  Botmother API: mode-dependent URL      │
│                                         │
│              [+ New Botmother]          │
└─────────────────────────────────────────┘
```

**Available actions per bot:**

| Button | Action |
|--------|--------|
| Toggle switch | Activate / Deactivate bot |
| + / ↻ (Generate/Regenerate) | Generate a new token, copy it to clipboard, and show it once |
| ✕ (Revoke) | Revoke token and disable bot |
| 🗑 (Delete) | Delete bot (with confirmation dialog) |
| Webhook section | Set or disable webhook URL; newly generated secrets are shown once |

### 4.3 ejabberd Settings (for Dedicated Bots)

Dedicated bots can use an existing XMPP account, in which case no ejabberd admin API is needed. If you want DinoX to create and later unregister the bot account automatically, configure the ejabberd admin API. Expand the **"Server Settings"** section:

| Field | Example | Description |
|-------|---------|-------------|
| API URL | `http://localhost:5443/api` | ejabberd REST API endpoint |
| XMPP Host | `chat.example.com` | The XMPP server hostname |
| Admin JID | `admin@chat.example.com` | Admin account for API authentication |
| Admin Password | `••••••••` | Admin account password |

Click **"Test"** to verify the connection, then **"Save"**.

> **Important:** DinoX verifies newly provisioned bot accounts with a real XMPP/SASL login before saving the local bot record. If verification fails, DinoX rolls back the server account and returns an error instead of storing a broken bot. Manually supplied bot accounts are never unregistered by DinoX when the local bot is deleted.
>
> ejabberd's `check_account` command returns its account-exists result inside the command response (`0` = exists, `1` = does not exist), not only through the HTTP status. DinoX parses that result and still retries with a fresh generated JID if registration itself reports that the account already exists.

---

## 5. Dedicated Bot Chat — Interactive Menus

When you have a **Dedicated** bot, it appears as a separate conversation. Open it to access interactive menus via slash commands.

The dedicated chat menu follows the same permission model as the REST API. Help/status commands remain readable for active bots. Non-command message forwarding to getUpdates, webhooks, AI and Telegram requires `receive_updates`. Commands that change AI, Telegram or history state require the `admin` permission and must be sent by the bot owner. Examples: `/ki on`, `/ki setup <provider> <key> <model>`, `/ki system <text>`, `/telegram on`, `/telegram setup ...`, `/telegram mode ...`, `/telegram test` and `/clear`.

### 5.1 Main Menu (/help)

```
You:    /help

Bot:    WeatherBot
        ════════════════════

        Status:
          AI: active (groq / llama-3.3-70b-versatile)
          Telegram: off

        ────────────────────
        Menus:
        /ki         - AI assistant setup & control
        /telegram   - Telegram bridge setup & control
        /api        - HTTP API & webhook documentation

        ────────────────────
        Basic commands:
        /help       - This menu
        /start      - Greeting
        /info       - Bot details

        ────────────────────
        Quick start:
        Just send a message for the AI!
```

### 5.2 AI Assistant (/ki)

The `/ki` menu controls the AI integration for this bot.

```
/ki             → AI main menu (status, available commands)
/ki on          → Enable AI responses
/ki off         → Disable AI, clear history
/ki status      → Current configuration details
/ki setup       → Provider selection menu
/ki setup <p>   → Setup help for a specific provider
/ki setup <provider> <key> <model>
                → Configure AI in one command
/ki model       → Show current model + alternatives
/ki model <name>→ Switch to a different model
/ki system      → Show current system prompt
/ki system <text> → Set a new system prompt
/ki clear       → Clear conversation history
/ki providers   → List all supported providers
```

**Example: Set up AI with Groq:**
```
You:    /ki setup groq gsk_abc123mykey llama-3.3-70b-versatile
Bot:    AI configured!
        Provider: groq
        Model: llama-3.3-70b-versatile
        AI is now active.
```

**Example: Talk to the AI:**
```
You:    What is the capital of France?
Bot:    The capital of France is Paris. It is the largest city in France
        and serves as the country's political, economic, and cultural center.
```

### 5.3 Telegram Bridge (/telegram)

```
/telegram           → Telegram main menu
/telegram on        → Enable bridge (must be configured first)
/telegram off       → Disable bridge, stop polling
/telegram status    → Current configuration
/telegram setup     → Step-by-step setup guide
/telegram setup <TOKEN> <CHAT_ID> [mode]
                    → Configure in one command
/telegram mode      → Show current mode
/telegram mode bridge  → Bidirectional (XMPP <-> Telegram)
/telegram mode forward → One-way (XMPP -> Telegram only)
/telegram test      → Test connection
```

### 5.4 API Documentation (/api)

The `/api` menu provides in-chat documentation for the HTTP API.

```
/api                → API overview (base URL, topics)
/api auth           → Authentication documentation
/api messages       → Send/receive messages (with curl examples)
/api webhook        → Webhook setup and format documentation
/api management     → Bot CRUD operations documentation
/api advanced       → Files, reactions, rooms, commands
/api examples       → Quick-start curl + Python code
/api server         → Server settings menu (see 5.5)
```

### 5.5 API Server Settings (/api server)

Change API server settings directly from chat:

Changing mode, port or TLS settings requires the `admin` permission. The overview and `/api server status` remain readable without `admin`.

```
/api server             → Current settings overview
/api server local       → Switch to localhost-only mode (HTTP)
/api server network     → Switch to all-interfaces mode (HTTPS + TLS)
/api server port <nr>   → Change port (1024-65535)
/api server status      → Detailed server status
/api server cert <path> → Set custom TLS certificate
/api server key <path>  → Set custom TLS key
/api server cert auto   → Reset to auto-generated self-signed cert
/api server renew-cert  → Delete and regenerate self-signed certificate
/api server delete-cert → Delete current self-signed certificate
```

`/api server key` requires a non-empty key path. Use `/api server cert auto` to clear custom TLS paths and return to the auto-generated self-signed certificate.

All changes are applied automatically — no restart needed.

---

## 6. AI Assistant — Setup & Usage

### 6.1 Supported Providers

| Provider | API Key Required | Models | Notes |
|----------|-----------------|--------|-------|
| **OpenAI** | Yes | gpt-4o, gpt-4o-mini, gpt-4-turbo, o1 | Best quality, paid |
| **Claude** (Anthropic) | Yes | claude-sonnet-4-20250514, claude-3-haiku, claude-3-opus | High quality, paid |
| **Gemini** (Google) | Yes | gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro | Uses Google AI Studio keys |
| **Groq** | Yes (free) | llama-3.3-70b-versatile, mixtral-8x7b, gemma-7b | Very fast, free tier |
| **Mistral** | Yes | mistral-large-latest, mistral-medium, mistral-small | European provider |
| **DeepSeek** | Yes | deepseek-chat, deepseek-coder | Good value |
| **Perplexity** | Yes | sonar-medium, sonar-small | Search-augmented |
| **xAI / Grok** | Yes | grok-4.20-reasoning and other xAI response models | Uses xAI Responses API |
| **Ollama** | No (local) | llama3, phi3, gemma, mistral, codellama | Runs on your own machine |
| **OpenClaw** | Yes (token) | agent | Autonomous AI orchestrator, manages models internally |

### 6.2 Quick Setup

**Via chat command (one line):**
```
/ki setup groq YOUR_API_KEY llama-3.3-70b-versatile
```

**Via guided menu:**
```
/ki setup           → Shows provider list
/ki setup groq      → Shows Groq-specific help with signup link
```

**For Ollama (local, no key needed):**
```
/ki setup ollama - llama3
```
Use `-` as the API key placeholder for Ollama.

**For xAI / Grok:**
```
/ki setup xai YOUR_XAI_KEY grok-4.20-reasoning
```

**For OpenClaw (autonomous agent):**
```
/ki setup openclaw YOUR_HOOKS_TOKEN agent
```
OpenClaw manages its own models internally. The `agent` model name tells DinoX to use the webhook API.

### 6.3 Talking to the AI

Once AI is active (`/ki on`), simply send any message without a `/` prefix:

```
You:    Explain quantum computing in simple terms
Bot:    Quantum computing uses quantum bits (qubits) instead of
        regular bits. While a normal bit is either 0 or 1, a qubit
        can be both at the same time (superposition)...
```

The bot maintains conversation history (up to 20 messages per user) for context-aware responses. Use `/ki clear` to reset the history.

In a MUC, first join the room with `/bot/joinRoom` or the Bot Manager test console. Then mention the Dedicated bot by name or localpart, for example `@WeatherBot summarize this`. The bot ignores its own room echoes and does not respond to unrelated room traffic.

Dedicated MUC behavior is intentionally conservative:

- `mention_only` answers only when the bot name, bot localpart or full bot JID is addressed as a real mention.
- `support_questions` and `active_support` may answer broader support/problem messages, but single-word support topics use token boundaries. For example, `xmpp` matches a real word but not `xmppserverparty`.
- Support-question detection also accepts common request wording without a question mark, such as asking for `infos`, `information`, `recommend` or `erkläre`, but only when a DinoX/XMPP support topic is present.
- Owner notifications are separate from bot replies. A room message that mentions the bot and also contains the owner name is treated as bot-directed first and does not create a separate owner notification.
- Delayed/history messages after join or reconnect are ignored before AI, Telegram, webhook or owner-notification handling.

Use the Bot Manager **System prompt** field or the dedicated chat command `/ki system <prompt>` to define the bot's support policy. This is where project-specific instructions belong, not in the AI API key.

Example support prompt:

```text
You are DinoXBot, the support bot for the public DinoX support room.
Answer only about DinoX, XMPP, installation, packaging, OMEMO, calls, media messages and known project workflows.
Be concise, factual and helpful.
If you are unsure, say that you are unsure and suggest asking the DinoX Team.
Do not invent release dates, security claims or server facts.
Do not reveal secrets, tokens, passwords or private configuration.
In public MUCs, answer only when explicitly mentioned.
```

### 6.4 System Prompt

The system prompt defines how the AI behaves:

```
/ki system                              → View current prompt
/ki system You are a helpful weatherbot → Set new prompt
```

Default: "Du bist ein hilfreicher Assistent." (translatable)

### 6.5 Changing Provider or Model

```
/ki providers             → List all providers with details
/ki model                 → Show current model + alternatives
/ki model mixtral-8x7b    → Switch model (same provider)
/ki setup openai KEY gpt-4o → Switch to a different provider
```

---

## 7. Telegram Bridge — Setup & Usage

### 7.1 Prerequisites

1. Create a Telegram bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Get the bot token (format: `123456789:ABCdef...`)
3. Get the target chat ID (send a message to the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`)

### 7.2 Setup

**One-line setup:**
```
/telegram setup 123456789:ABCdef_ghijk 987654321
```

Parameters: `<TELEGRAM_BOT_TOKEN> <CHAT_ID> [bridge|forward]`

**Step-by-step:**
```
/telegram setup          → Shows the 3-step guide:

Step 1: Create a Telegram bot via @BotFather
Step 2: Get your chat ID
Step 3: Run: /telegram setup <TOKEN> <CHAT_ID>
```

**Verify connection:**
```
/telegram test           → Calls Telegram getMe API
```

### 7.3 Bridge Modes

| Mode | Direction | Description |
|------|-----------|-------------|
| **bridge** | XMPP ↔ Telegram | Messages flow both ways. Telegram messages appear in XMPP with `[Telegram] Name:` prefix. XMPP messages appear in Telegram with `[XMPP] jid:` prefix. |
| **forward** | XMPP → Telegram | Messages only go from XMPP to Telegram. Telegram replies are not forwarded. |

```
/telegram mode bridge    → Set bidirectional mode
/telegram mode forward   → Set forward-only mode
```

### 7.4 Message Flow

```
┌─────────┐                          ┌──────────┐
│  XMPP   │  ──── bridge mode ────>  │ Telegram │
│  User   │  <─── bridge mode ─────  │  Chat    │
│         │  ──── forward mode ───>  │          │
└─────────┘                          └──────────┘

Incoming Telegram: [Telegram] John: Hello!
Outgoing to TG:    [XMPP] user@server: Hi there!
```

Polling uses a single active long-poll request per bot. DinoX starts the next poll from a 1 second timer, skips overlapping polls, uses a 25 second Telegram long-poll timeout, and backs off briefly on HTTP 409 when another consumer is already using `getUpdates` for the same Telegram bot token.

Current media handling is limited: XMPP `aesgcm://` upload URLs can be decrypted and uploaded to Telegram when DinoX can fetch the source file. Telegram media is detected and reported back to XMPP, but full Telegram-to-XMPP HTTP Upload re-hosting is still planned.

### 7.5 Planned Features (Roadmap)

The Telegram Bridge is being extended with several powerful features.
All items below are **planned** and not yet implemented.

#### 7.5.1 Media Forwarding

Full media support between XMPP and Telegram:

| Media Type | XMPP → Telegram | Telegram → XMPP |
|------------|------------------|------------------|
| Images / Photos | Uploaded via Telegram Bot API `sendPhoto` | Downloaded and shared as XMPP HTTP Upload |
| Files / Documents | Uploaded via `sendDocument` | Downloaded and offered as file transfer |
| Stickers | Converted to image and sent | Sticker image extracted and displayed inline |
| Voice Messages | Audio file forwarded as `sendVoice` | Audio downloaded, playable in XMPP client |
| Video | Forwarded as `sendVideo` | Downloaded via HTTP Upload |

```
XMPP User sends image
       │
       ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ DinoX Bot    │────>│ HTTP Upload  │────>│ Telegram API │
│ receives     │     │ download URL │     │ sendPhoto    │
│ XMPP file    │     │              │     │              │
└──────────────┘     └──────────────┘     └──────────────┘

Telegram User sends photo
       │
       ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Telegram Bot │────>│ getFile +    │────>│ XMPP HTTP    │
│ API polling  │     │ download     │     │ Upload slot  │
│              │     │              │     │ + send URL   │
└──────────────┘     └──────────────┘     └──────────────┘
```

**Technical Notes:**
- File size limits follow Telegram API limits (20 MB download, 50 MB upload)
- Stickers are converted from WebP to PNG for XMPP compatibility
- XMPP HTTP Upload (XEP-0363) is used for incoming Telegram media

#### 7.5.2 Multi-Chat Bridging

Bridge multiple Telegram groups simultaneously from a single bot:

```
/telegram add <CHAT_ID_1> [alias]    → Add a Telegram group
/telegram add <CHAT_ID_2> [alias]    → Add another group
/telegram list                        → Show all bridged groups
/telegram remove <CHAT_ID>           → Remove a bridge
```

**Routing:**
- Each Telegram group maps to a separate XMPP conversation or MUC room
- Messages include a group prefix: `[TG:GroupName] User: message`
- The bot owner can send to a specific group: `/telegram send <alias> Hello!`
- Default target group can be set: `/telegram default <alias>`

```
                    ┌──── Telegram Group A ("Family")
DinoX Bot ──────────┼──── Telegram Group B ("Work")
                    ├──── Telegram Group C ("Project")
                    └──── Telegram DM (User X)
```

**Use Cases:**
- Monitor multiple Telegram communities from one XMPP client
- Cross-post announcements to several groups at once
- Aggregate messages from different Telegram groups in one place

#### 7.5.3 Bot Commands in Telegram

Allow Telegram users to send commands directly to the DinoX bot:

| Command | Description |
|---------|-------------|
| `/status` | Bot shows online status and bridge info |
| `/help` | Lists available commands for Telegram users |
| `/info` | Shows bot version and uptime |
| `/who` | Shows who is online on the XMPP side |
| `/ping` | Latency check (bot responds with pong + ms) |

**Custom Commands:**
- Bot owner can define custom commands via the XMPP side
- Commands can trigger automated responses or actions
- Example: `/weather Berlin` could query an API and respond in Telegram

```
Telegram User                    DinoX Bot
     │                               │
     │  /status                      │
     │──────────────────────────────>│
     │                               │ (checks XMPP + Bridge state)
     │  Bot is online                │
     │  Bridge: active (2 groups)    │
     │  Uptime: 3d 12h              │
     │<──────────────────────────────│
```

#### 7.5.4 Inline Buttons / Keyboards

Telegram inline keyboards and reply keyboards for interactive bot responses:

**Reply Keyboards:**
```json
{
  "keyboard": [
    [{"text": "Status"}, {"text": "Help"}],
    [{"text": "Send to XMPP"}]
  ],
  "resize_keyboard": true
}
```

**Inline Keyboards with Callbacks:**
```json
{
  "inline_keyboard": [
    [
      {"text": "Bridge ON", "callback_data": "bridge_on"},
      {"text": "Bridge OFF", "callback_data": "bridge_off"}
    ],
    [
      {"text": "Settings", "callback_data": "settings"}
    ]
  ]
}
```

**Use Cases:**
- Quick-action buttons for common operations
- Confirmation dialogs ("Are you sure? [Yes] [No]")
- Navigation menus for bot settings directly in Telegram
- Polls and surveys forwarded from XMPP to Telegram

#### 7.5.5 Admin Features (Moderate Telegram via XMPP)

Manage Telegram groups directly from your XMPP client:

| Command (in XMPP) | Telegram Action |
|--------------------|-----------------|
| `/telegram kick @user` | Remove user from Telegram group |
| `/telegram ban @user [duration]` | Ban user (optionally temporary) |
| `/telegram unban @user` | Unban user |
| `/telegram mute @user [duration]` | Restrict user from posting |
| `/telegram pin <message_id>` | Pin a message in the group |
| `/telegram title <new_title>` | Change group title |
| `/telegram photo <url>` | Change group photo |
| `/telegram members` | List group members |

**Moderation Flow:**
```
XMPP Owner                    DinoX Bot                  Telegram Group
     │                           │                            │
     │ /telegram kick @spammer   │                            │
     │──────────────────────────>│                            │
     │                           │ banChatMember API call     │
     │                           │───────────────────────────>│
     │                           │          OK                │
     │                           │<───────────────────────────│
     │ User @spammer removed     │                            │
     │<──────────────────────────│                            │
```

**Auto-Moderation (planned):**
- Spam detection with configurable word filters
- Auto-ban for specific patterns or link spam
- Rate limiting (max messages per minute per user)
- Welcome messages for new group members
- Logging of all moderation actions in XMPP

---

## 8. HTTP API Reference

### 8.1 Authentication

All bot-specific endpoints require a **Bearer token** in the `Authorization` header:

```
Authorization: Bearer bot1:43291125-6c25-4c62-9927-5cf1de3e03f2
```

**How to get a token:**
- Created automatically when you create a bot via UI or `/bot/create`
- Shown only once in the create response/dialog
- Regenerate via the Bot Manager UI or `/bot/token`; the new token is shown only once
- Revoke via the Bot Manager UI or `/bot/revoke`

**Response format (API endpoints using the Botmother success/error helpers):**

Success:
```json
{
  "ok": true,
  "result": { ... }
}
```

Error:
```json
{
  "ok": false,
  "error": "unauthorized",
  "description": "Unauthorized"
}
```

**Rate limiting:** 30 requests per second per IP.

### 8.2 API Server Configuration

| Setting | Local Mode | Network Mode |
|---------|-----------|--------------|
| Bind Address | `127.0.0.1` | `0.0.0.0` |
| Protocol | HTTP | HTTPS (TLS required) |
| Default Port | 7842 | 7842 |
| TLS Certificate | Not used | Auto-generated self-signed, or custom PEM |
| Access | This machine only | Any network client |

The Bot Manager UI still talks to the local API endpoint on loopback. It uses `http://127.0.0.1:<port>` in local mode and `https://127.0.0.1:<port>` in network mode, accepting DinoX's own local self-signed certificate only for these internal loopback requests.

**Change settings:**
- Via Preferences UI (Settings > Botmother section)
- Via chat: `/api server local`, `/api server network`, `/api server port 8443`
- Via chat for TLS: `/api server cert /path/to/server.crt`, `/api server key /path/to/server.key`, or `/api server cert auto`
- Changes are applied automatically (server restarts within 500ms)

**Self-signed TLS certificates** are automatically generated using GnuTLS and stored at:
```
~/.local/share/dinox/api-tls/server.crt
~/.local/share/dinox/api-tls/server.key
```

### 8.3 Local Bot Management Endpoints

These endpoints manage bots themselves. They are intended for the local Bot Manager UI and require localhost access unless noted otherwise. Raw tokens are returned only by create/regenerate operations.

Unless explicitly noted, local management endpoints return the same `{"ok":true,"result":...}` wrapper as authenticated bot endpoints. `/health` and `/bot/list` are intentionally plain JSON responses for simple local probing and UI listing.

---

#### `GET /health`

Health check. No authentication required.

**Response (plain JSON, not wrapped):**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "active_bots": 3
}
```

**curl:**
```bash
curl http://localhost:7842/health
```

---

#### `POST /bot/create`

Create a new bot.

**Request body:**
```json
{
  "name": "MyBot",
  "account": "user@server.tld",
  "mode": "personal",
  "permissions": "send_message,receive_updates",
  "webhook_url": "https://example.org/webhook",
  "purpose": "ai",
  "avatar": "<base64-encoded-image>",
  "avatar_type": "image/png"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Bot display name |
| `account` | Yes | — | Owner bare account JID (`localpart@domain`, no resource; also accepts `"owner"`) |
| `mode` | No | `"personal"` | `"personal"` or `"dedicated"`. `"cloud"` returns `501 not_implemented`; CloudBots are created at `https://cloud.dinox.im` and managed in DinoX with a management token. |
| `permissions` | No | `"all"` | Comma-separated permission scopes. Invalid scopes return `400 bad_request`. |
| `purpose` | No | `"advanced"` | `"ai"`, `"telegram"`, `"webhook"`, or `"advanced"` for UI grouping and setup flow. |
| `provisioning` | Dedicated only | auto | `"manual"` for an existing bot account or `"ejabberd"` for admin-API provisioning. If omitted, DinoX uses `"manual"` when `bot_jid` is provided, otherwise `"ejabberd"`. |
| `bot_jid` | Manual dedicated only | — | Existing bot account JID. Required with `provisioning:"manual"`. |
| `bot_password` | Manual dedicated only | — | Password for the existing bot account. Stored through DinoX secret settings. |
| `webhook_url` | No | — | Optional initial webhook URL. Must be `http://` or `https://`. |
| `avatar` | No | — | Base64-encoded avatar image. UI-created avatars are scaled before storage/publish. |
| `avatar_type` | No | — | MIME type of avatar (e.g. `"image/png"`) |

**Response (personal, inside `result`):**
```json
{
  "id": 1,
  "name": "MyBot",
  "token": "bot1:43291125-6c25-4c62-9927-5cf1de3e03f2",
  "mode": "personal",
  "permissions": "send_message,receive_updates",
  "api_url": "http://localhost:7842/bot/",
  "hint": "Use token as Bearer in Authorization header"
}
```

**Response (dedicated, inside `result`):**
```json
{
  "id": 2,
  "name": "SupportBot",
  "token": "bot2:70f6003e-656d-4dab-8deb-22d296db4c18",
  "mode": "dedicated",
  "jid": "bot@example.org",
  "provisioning": "manual",
  "permissions": "all",
  "api_url": "http://localhost:7842/bot/",
  "hint": "Use token as Bearer in Authorization header"
}
```

**Errors:** 400 (missing fields, invalid account JID, invalid mode, invalid permission, invalid webhook URL, missing manual bot credentials, missing ejabberd settings), 409 (no free generated bot JID after retries), 429 (max 20 bots per owner), 501 (cloud mode not implemented), 502 (ejabberd registration or verification failed for provisioned dedicated bots)

**curl:**
```bash
curl -X POST http://localhost:7842/bot/create \
  -H "Content-Type: application/json" \
  -d '{"name":"MyBot","account":"ralf@chat.example.com","mode":"personal"}'
```

---

#### `GET /bot/list`

List all bots. Optional filter by owner account.

Only `GET` is accepted. Other methods return `405 method_not_allowed`.

**Query parameters:**
| Parameter | Required | Description |
|-----------|----------|-------------|
| `account` | No | Filter by owner bare account JID |

**Response (plain JSON, not wrapped):**
```json
{
  "bots": [
    {
      "id": 1,
      "name": "MyBot",
      "jid": "",
      "mode": "personal",
      "status": "active",
      "description": "",
      "permissions": "all",
      "target_mode": "all",
      "target_list": "",
      "allowed_targets": "",
      "created_at": 1739478000
    },
    {
      "id": 2,
      "name": "SupportBot",
      "jid": "bot_supportbot_c3a1@chat.example.com",
      "mode": "dedicated",
      "status": "active",
      "description": "Customer support",
      "permissions": "send_message,muc_send",
      "target_mode": "allow",
      "target_list": "friend@example.org,room@conference.example.org",
      "allowed_targets": "friend@example.org,room@conference.example.org",
      "created_at": 1739478100
    }
  ]
}
```

**curl:**
```bash
# All bots
curl http://localhost:7842/bot/list

# Filter by account
curl "http://localhost:7842/bot/list?account=ralf@chat.example.com"
```

---

#### `POST /bot/delete` or `DELETE /bot/delete?id=<ID>`

Delete a bot. For dedicated bots, also unregisters the XMPP account from ejabberd.

**Request body (POST):**
```json
{
  "id": 3
}
```

**Response (inside `result`):**
```json
{
  "deleted": true,
  "id": 3
}
```

For dedicated bots:
```json
{
  "deleted": true,
  "id": 3,
  "account_removed": true
}
```

**curl:**
```bash
curl -X DELETE "http://localhost:7842/bot/delete?id=3"
# or
curl -X POST http://localhost:7842/bot/delete \
  -H "Content-Type: application/json" \
  -d '{"id":3}'
```

---

#### `POST /bot/activate`

Activate, pause or deactivate a bot.

The compatibility `active` field must be a JSON boolean (`true` / `false`), not a string. New callers can use `status` with one of:

- `active`: normal operation; runtime sources, AI, Telegram, webhooks and API tokens work according to permissions.
- `paused`: bot remains configured and visible, but runtime sources stop and authenticated API calls return `inactive`.
- `disabled`: bot is stopped; dedicated streams disconnect and the local bot chat may be closed.

When a Dedicated bot resumes from `paused`, delayed/offline XMPP messages from before the resume point are ignored before OMEMO decryption and before AI, Telegram, getUpdates or webhook routing. This prevents messages sent during the pause from consuming AI/API runtime after reconnect.

**Request body:**
```json
{
  "id": 1,
  "status": "paused"
}
```

Compatibility form:
```json
{
  "id": 1,
  "active": true
}
```

**Response (inside `result`):**
```json
{
  "id": 1,
  "status": "active"
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/activate \
  -H "Content-Type: application/json" \
  -d '{"id":1,"status":"active"}'
```

---

#### `POST /bot/token`

Regenerate API token for a bot (old token becomes invalid).

**Request body:**
```json
{
  "id": 1
}
```

**Response (inside `result`):**
```json
{
  "id": 1,
  "token": "bot1:70f6003e-656d-4dab-8deb-22d296db4c18"
}
```

---

#### `POST /bot/revoke`

Revoke token and disable bot.

**Request body:**
```json
{
  "id": 1
}
```

**Response (inside `result`):**
```json
{
  "id": 1,
  "revoked": true,
  "status": "disabled"
}
```

---

#### `GET/POST /bot/permissions`

Read or update bot permissions. Localhost only.

**GET:**
```bash
curl "http://localhost:7842/bot/permissions?id=1"
```

**POST request body:**
```json
{
  "id": 1,
  "permissions": "send_message,muc_send"
}
```

Invalid permission names are rejected with `400 bad_request`.

---

#### `GET/POST /bot/targets`

Read or update target restrictions. Localhost only.

**POST request body:**
```json
{
  "id": 1,
  "target_mode": "allow",
  "target_list": "friend@example.org,room@conference.example.org,@trusted.example.org"
}
```

`target_mode` may be `all`, `allow`, or `block`. `allowed_targets` is accepted as a compatibility alias for `target_list`.
Invalid `target_mode` values are rejected with `400 bad_request`.
Target entries must be concrete JIDs, `@domain`, `domain:example.org`, or `*`. Malformed entries return `400 bad_request`.

---

#### `GET/POST /bot/webhook`

Read or update webhook settings from the local Bot Manager without exposing the raw API token. Localhost only.

**GET:**
```bash
curl "http://localhost:7842/bot/webhook?id=1"
```

Existing webhook secrets are never returned by GET. `secret_available` only tells the UI whether a secret exists.

**POST request body to set a webhook:**
```json
{
  "id": 1,
  "url": "https://my-server.com/webhook/bot1"
}
```

Setting a webhook generates a new secret and returns it once. Store it immediately.

**POST request body to disable a webhook:**
```json
{
  "id": 1,
  "enabled": false
}
```

An explicitly empty `url` also disables the webhook. A missing `url` without `enabled:false` is rejected with `400 bad_request`.

The URL must be a parseable `http://` or `https://` URL with a host. DinoX stores the full URL for delivery but redacts query strings and fragments in logs.

---

#### `GET/POST /bot/avatar`

Read, update or remove a bot avatar from the local Bot Manager without exposing the raw API token. Localhost only.

The avatar is stored as local Bot Manager state (`bot_avatar:<id>` / `bot_avatar_type:<id>`). For Dedicated bots, changing the avatar triggers a metadata refresh: DinoX republishes vCard4 and vCard-temp for the bot. The UI scales selected images to a small PNG before storing them so vCard-temp does not exceed typical server stanza limits. The runtime also protects vCard-temp publishing with an internal maximum avatar byte size.

**GET:**
```bash
curl "http://localhost:7842/bot/avatar?id=1"
```

**GET response payload inside `result`:**
```json
{
  "id": 1,
  "configured": true,
  "avatar_type": "image/png"
}
```

`GET` never returns the raw image data. It only tells the UI whether an avatar is configured.

**POST request body to set an avatar:**
```json
{
  "id": 1,
  "avatar": "<base64-encoded-image>",
  "avatar_type": "image/png"
}
```

Direct API callers should send a reasonably small image payload, preferably a PNG already scaled to avatar size. The DinoX UI performs this scaling automatically.

**POST request body to remove an avatar:**
```json
{
  "id": 1,
  "remove": true
}
```

---

#### `POST /bot/testSend`

Send a local Bot Manager test message without exposing the raw API token. Localhost only.

```json
{
  "id": 1,
  "to": "friend@example.org",
  "text": "Test from Botmother",
  "type": "chat"
}
```

For MUC sends use `"type": "groupchat"`. The endpoint still enforces bot status, permissions, target restrictions and MUC occupancy. Personal bots require the owner account to be joined. Dedicated bots require the dedicated bot account to be joined through `/bot/joinRoom`.
`to` and `text` must be non-empty. `type` must be `"chat"` or `"groupchat"`.

This endpoint is the Bot Manager delivery test path. It sends through the normal bot routing rules. Use `/bot/ai/testAsk` instead when you only want to test whether the configured AI provider answers.

---

#### `GET/POST /bot/account/status`

Check or toggle whether Botmother is enabled for a specific account.

**GET:** `?account=user@server`

Response payload inside `result`:
```json
{
  "account": "user@server",
  "enabled": true
}
```

**POST:**
```json
{
  "account": "user@server",
  "enabled": false
}
```

The POST response uses the same payload shape inside `result`.

`account` must be a bare account JID. POST requires `enabled` as a JSON boolean. Missing `enabled` or string values such as `"false"` return `400 bad_request`.

---

### 8.4 Bot Messaging Endpoints (Auth Required)

All endpoints below require the `Authorization: Bearer <TOKEN>` header.

Required scopes:
- `/bot/sendMessage`: `send_message` for direct chats, `muc_send` for group chats
- `/bot/getUpdates`: `receive_updates`
- `/bot/getMe`: authenticated token only
- `/bot/getInfo`: authenticated token only

Outbound endpoints also enforce the bot's target restrictions.

---

#### `POST /bot/sendMessage`

Send a message to a JID.

**Request body:**
```json
{
  "to": "user@server.tld",
  "text": "Hello from my bot!",
  "type": "chat"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `to` | Yes | — | Non-empty recipient JID |
| `text` | Yes | — | Non-empty message text |
| `type` | No | `"chat"` | `"chat"` (1:1) or `"groupchat"` (MUC). Other values return `400 bad_request`. |

**Response:**
```json
{
  "ok": true,
  "result": {
    "message_id": "uuid-123-456"
  }
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/sendMessage \
  -H "Authorization: Bearer bot1:YOUR-UUID-TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to":"user@server.tld","text":"Hello!"}'
```

---

#### `GET /bot/getUpdates`

Long-poll for incoming messages (alternative to webhooks).

**Query parameters:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `offset` | No | — | Non-negative integer. Return updates with ID >= offset. Also deletes updates with ID < offset. |
| `limit` | No | 100 | Positive integer. Max updates to return (1-100) |
| `timeout` | No | 0 | Optional long-poll timeout in seconds. Clamped to 0-30. `0` returns immediately. |

**Response:**
```json
{
  "ok": true,
  "result": [
    {
      "update_id": 42,
      "type": "message",
      "data": {
        "from": "sender@server.tld",
        "to": "bot@server.tld",
        "body": "Hello bot!",
        "type": "chat",
        "stanza_id": "msg-uuid-789",
        "timestamp": 1707900000
      }
    }
  ]
}
```

**Usage pattern:**
```bash
# First call — get all pending updates
curl "http://localhost:7842/bot/getUpdates" \
  -H "Authorization: Bearer bot1:YOUR-UUID-TOKEN"

# Next call — acknowledge update 42, get newer ones
curl "http://localhost:7842/bot/getUpdates?offset=43" \
  -H "Authorization: Bearer bot1:YOUR-UUID-TOKEN"

# Long-poll up to 30 seconds for new updates
curl "http://localhost:7842/bot/getUpdates?offset=43&timeout=30" \
  -H "Authorization: Bearer bot1:YOUR-UUID-TOKEN"
```

---

#### `GET /bot/getMe`

Get information about the authenticated bot.

**Response:**
```json
{
  "ok": true,
  "result": {
    "id": 1,
    "name": "MyBot",
    "jid": "",
    "mode": "personal",
    "status": "active",
    "description": "",
    "permissions": "all",
    "target_mode": "all",
    "target_list": "",
    "allowed_targets": "",
    "created_at": 1739478000
  }
}
```

---

#### `GET /bot/getInfo`

Extended bot information including commands and active sessions.

**Response:**
```json
{
  "ok": true,
  "result": {
    "bot": {
      "id": 1,
      "name": "MyBot",
      "mode": "personal",
      "status": "active"
    },
    "commands": [
      {"command": "weather", "description": "Get weather info"},
      {"command": "help", "description": "Show help"}
    ],
    "active_sessions": 0
  }
}
```

---

### 8.5 Webhook System

Instead of polling with `getUpdates`, you can set up a webhook to receive messages via HTTP POST.

Webhook management requires the `webhook` permission.

The authenticated `/bot/setWebhook` and `/bot/deleteWebhook` endpoints are for external token-based API clients. The local Bot Manager uses `/bot/webhook` instead, because raw bot tokens are intentionally shown only once and are not stored by DinoX.

#### `POST /bot/setWebhook`

**Request body:**
```json
{
  "url": "https://my-server.com/webhook/bot1"
}
```

The URL must be a parseable `http://` or `https://` URL with a host. DinoX stores the full URL for delivery but redacts query strings and fragments in logs.

**Response:**
```json
{
  "ok": true,
  "result": {
    "webhook_url": "https://my-server.com/webhook/bot1",
    "secret": "hmac_secret_for_signature_verification"
  }
}
```

> **Important:** Save the `secret` — it's used to verify webhook signatures.

#### `POST /bot/deleteWebhook`

No body required.

**Response:**
```json
{
  "ok": true,
  "result": true
}
```

#### Webhook Delivery Format

DinoX sends incoming messages as HTTP POST to your webhook URL:

**Headers:**
```
Content-Type: application/json
User-Agent: DinoX-BotAPI/1.0
X-Bot-Signature: sha256=<HMAC-SHA256(secret, payload)>
X-Bot-Delivery: <unique-uuid>
```

**Body:**
```json
{
  "update_type": "message",
  "data": {
    "from": "sender@server.tld",
    "to": "bot@server.tld",
    "body": "Hello!",
    "type": "chat",
    "stanza_id": "msg-uuid-123",
    "timestamp": 1707900000
  }
}
```

**Retry behavior:** Up to 3 attempts with exponential backoff (1s, 2s, 4s). Timeout: 10 seconds per attempt.

#### Verify Webhook Signature (Python)

```python
import hmac
import hashlib

def verify_signature(payload: bytes, signature: str, secret: str) -> bool:
    expected = "sha256=" + hmac.new(
        secret.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)

# In your webhook handler:
signature = request.headers.get("X-Bot-Signature")
is_valid = verify_signature(request.body, signature, YOUR_WEBHOOK_SECRET)
```

---

### 8.6 Advanced Endpoints

All require `Authorization: Bearer <TOKEN>`.

Required scopes:
- `/bot/sendFile`: `file_send`
- `/bot/sendReaction`: `send_message`
- `/bot/joinRoom` and `/bot/leaveRoom`: `muc_join`
- `/bot/setCommands`: `admin`
- `/bot/getCommands`: `receive_updates`

Outbound endpoints also enforce the bot's target restrictions.

---

#### `POST /bot/sendFile`

Send a file via OOB (Out-of-Band Data, XEP-0066).

**Request body:**
```json
{
  "to": "user@server.tld",
  "url": "https://example.com/photo.jpg",
  "caption": "Check out this photo!"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `to` | Yes | Non-empty recipient JID |
| `url` | Yes | `http://` or `https://` URL of the file to send |
| `caption` | No | Text caption alongside the file |

---

#### `POST /bot/sendReaction`

Send a reaction (emoji) to a specific message.

**Request body:**
```json
{
  "to": "user@server.tld",
  "message_id": "msg-uuid-123",
  "reaction": "👍"
}
```

All fields must be non-empty.

---

#### `POST /bot/joinRoom`

Join a MUC (Multi-User Chat) room. Personal bots join through the owner account. Dedicated bots join through their own XMPP stream and send no room history request. The Bot Manager provides local `testJoinRoom`/`testLeaveRoom` actions so users do not need to handle the raw bot token for room setup.

**Request body:**
```json
{
  "room": "general@conference.server.tld",
  "nick": "MyBot"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `room` | Yes | — | Non-empty room JID |
| `nick` | No | Bot name | Nickname in the room. Blank values are ignored. |

For Dedicated bots, successful room joins are persisted as desired rooms and rejoined after the bot stream reconnects or DinoX restarts. Rejoin requests do not ask the server for room history.

---

#### `POST /bot/leaveRoom`

Leave a MUC room. Personal bots leave through the owner account. Dedicated bots leave through their own XMPP stream.

**Request body:**
```json
{
  "room": "general@conference.server.tld"
}
```

`room` must be a syntactically valid room JID.

---

#### `POST /bot/setCommands`

Register custom slash commands for the bot.
Each array item must be an object with a non-empty string `command`. Optional `description` must also be a string. Invalid entries return `400 bad_request`.

**Request body:**
```json
{
  "commands": [
    {"command": "weather", "description": "Get weather for a city"},
    {"command": "news", "description": "Show latest news"},
    {"command": "help", "description": "Show available commands"}
  ]
}
```

---

#### `GET /bot/getCommands`

Get the list of registered commands.

**Response:**
```json
{
  "ok": true,
  "result": [
    {"command": "weather", "description": "Get weather for a city"},
    {"command": "news", "description": "Show latest news"}
  ]
}
```

---

### 8.7 ejabberd Admin Endpoints

These endpoints manage the ejabberd server connection for dedicated bots. Responses are returned inside the standard `result` wrapper.

#### `GET /bot/ejabberd/settings`

Get current ejabberd configuration (password is masked).

**Response payload:**
```json
{
  "api_url": "http://localhost:5443/api",
  "admin_jid": "admin@chat.example.com",
  "admin_password": "********",
  "host": "chat.example.com",
  "configured": true
}
```

#### `POST /bot/ejabberd/settings`

Save ejabberd configuration.

**Request body:**
```json
{
  "api_url": "http://localhost:5443/api",
  "admin_jid": "admin@chat.example.com",
  "admin_password": "your_password",
  "host": "chat.example.com"
}
```

`api_url` must use `http://` or `https://`. `admin_jid` must be a bare account JID and `host` must be a domain.

**Response payload:**
```json
{
  "saved": true,
  "configured": true
}
```

#### `POST /bot/ejabberd/test`

Test ejabberd API connectivity.
Inline test credentials follow the same validation as saved settings.

**Response payload:**
```json
{
  "connected": true,
  "response": "ok"
}
```

---

### 8.8 Telegram API Endpoints

All endpoints require `Authorization: Bearer <TOKEN>`. Responses are returned inside the standard `result` wrapper.

Required scopes:
- `/bot/telegram/setup`: `admin`
- `/bot/telegram/status`: `receive_updates`
- `/bot/telegram/enable`: `admin`
- `/bot/telegram/send`: `send_message`
- `/bot/telegram/test`: `admin`

---

#### `POST /bot/telegram/setup`

Configure the Telegram bridge for a bot.

**Request body:**
```json
{
  "token": "123456789:ABCdef_ghijk",
  "chat_id": "987654321",
  "mode": "bridge"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `token` | Yes | -- | Non-empty Telegram Bot API token |
| `chat_id` | Yes | -- | Non-empty target Telegram chat ID |
| `mode` | No | `"bridge"` | `"bridge"` (bidirectional) or `"forward"` (XMPP -> TG only). Other values return `400 bad_request`. |

**Response payload:**
```json
{
  "configured": true,
  "chat_id": "987654321",
  "mode": "bridge"
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/telegram/setup \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"token":"123456:ABC","chat_id":"987654321","mode":"bridge"}'
```

---

#### `GET /bot/telegram/status`

Get Telegram bridge status for a bot.

**Response payload:**
```json
{
  "enabled": true,
  "configured": true,
  "chat_id": "987654321",
  "mode": "bridge"
}
```

**curl:**
```bash
curl http://localhost:7842/bot/telegram/status \
  -H "Authorization: Bearer $TOKEN"
```

---

#### `POST /bot/telegram/enable`

Enable or disable the Telegram bridge.

The `enabled` field must be a JSON boolean (`true` / `false`), not a string.

**Request body:**
```json
{
  "enabled": true
}
```

**Response payload:**
```json
{
  "enabled": true
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/telegram/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}'
```

---

#### `POST /bot/telegram/send`

Send a message to Telegram via the bridge.

`text` must be non-empty.

**Request body:**
```json
{
  "text": "Hello from the API!"
}
```

**Response payload:**
```json
{
  "sent": true
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/telegram/send \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello Telegram!"}'
```

---

#### `POST /bot/telegram/test`

Test the Telegram bot token (calls Telegram `getMe` API).

**Response payload:**
```json
{
  "connected": true,
  "info": "Bot: MyBot (@mybot_bot)"
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/telegram/test \
  -H "Authorization: Bearer $TOKEN"
```

---

### 8.9 AI API Endpoints

All endpoints require `Authorization: Bearer <TOKEN>`. Responses are returned inside the standard `result` wrapper.

Required scopes:
- `/bot/ai/setup`: `admin`
- `/bot/ai/status`: `receive_updates`
- `/bot/ai/enable`: `admin`
- `/bot/ai/ask`: `send_message`

---

#### `POST /bot/ai/setup`

Configure the AI provider for a bot.

**Request body:**
```json
{
  "provider": "openai",
  "api_key": "sk-abc123",
  "model": "gpt-4o"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `provider` | Yes | -- | Non-empty provider name (openai, claude, gemini, groq, mistral, deepseek, perplexity, xai, ollama, openclaw) |
| `api_key` | Provider-dependent | `"-"` | API key. Required for every provider except Ollama; use `"-"` for Ollama. |
| `model` | Yes | -- | Non-empty model name (e.g. `gpt-4o`, `llama3`, `agent`) |

When a bot is switched to a provider that does not require a key, such as Ollama, DinoX clears any previously stored external provider key for that bot. Provider/model updates do not modify the bot's existing system prompt.

**Errors:** 400 (missing provider/model, unknown provider, missing required API key), 403 (missing `admin` permission)

**Response payload:**
```json
{
  "configured": true,
  "provider": "openai",
  "model": "gpt-4o"
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/ai/setup \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"provider":"groq","api_key":"gsk_abc","model":"llama-3.3-70b-versatile"}'
```

---

#### `GET /bot/ai/status`

Get AI configuration status.

**Response payload:**
```json
{
  "enabled": true,
  "configured": true,
  "provider": "openai",
  "type": "openai",
  "model": "gpt-4o",
  "endpoint": "https://api.openai.com/v1/chat/completions",
  "system_prompt": "Answer briefly and only on DinoX support topics.",
  "muc_owner_notify": "mentions_when_owner_absent",
  "muc_ai_mode": "support_questions"
}
```

`system_prompt`, `muc_owner_notify` and `muc_ai_mode` are included for Bot Manager and dedicated group-bot behavior. Empty strings mean the default behavior is active.

**curl:**
```bash
curl http://localhost:7842/bot/ai/status \
  -H "Authorization: Bearer $TOKEN"
```

---

#### `POST /bot/ai/enable`

Enable or disable the AI for a bot.

The `enabled` field must be a JSON boolean (`true` / `false`), not a string.

**Request body:**
```json
{
  "enabled": true
}
```

**Response payload:**
```json
{
  "enabled": true
}
```

---

#### `POST /bot/ai/ask`

Send a question to the AI and get a response.

**Request body:**
```json
{
  "message": "What is the capital of France?"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `message` | Yes | Non-empty question or prompt (also accepts `"text"`) |
| `from` (query) | No | Sender identifier for conversation history (default: `"api-client"`) |

**Response payload:**
```json
{
  "response": "The capital of France is Paris."
}
```

**curl:**
```bash
curl -X POST http://localhost:7842/bot/ai/ask \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"What is the capital of France?"}'
```

---

### 8.10 Complete curl Examples

```bash
# === SETUP ===

# Check server health
curl http://localhost:7842/health

# Create a personal bot
curl -X POST http://localhost:7842/bot/create \
  -H "Content-Type: application/json" \
  -d '{"name":"MyBot","account":"ralf@chat.example.com"}'

# Create a dedicated bot (requires ejabberd)
curl -X POST http://localhost:7842/bot/create \
  -H "Content-Type: application/json" \
  -d '{"name":"SupportBot","account":"ralf@chat.example.com","mode":"dedicated"}'

# List all bots
curl http://localhost:7842/bot/list

# === MESSAGING ===

TOKEN="bot1:YOUR-UUID-TOKEN"

# Send a message
curl -X POST http://localhost:7842/bot/sendMessage \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to":"user@chat.example.com","text":"Hello from the API!"}'

# Send a file
curl -X POST http://localhost:7842/bot/sendFile \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to":"user@chat.example.com","url":"https://example.com/image.jpg","caption":"Look!"}'

# Send a reaction
curl -X POST http://localhost:7842/bot/sendReaction \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to":"user@chat.example.com","message_id":"msg-uuid","reaction":"👍"}'

# Get incoming messages (polling)
curl "http://localhost:7842/bot/getUpdates" \
  -H "Authorization: Bearer $TOKEN"

# Acknowledge and get next
curl "http://localhost:7842/bot/getUpdates?offset=43" \
  -H "Authorization: Bearer $TOKEN"

# === WEBHOOKS ===

# Set webhook
curl -X POST http://localhost:7842/bot/setWebhook \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://my-server.com/webhook"}'

# Delete webhook
curl -X POST http://localhost:7842/bot/deleteWebhook \
  -H "Authorization: Bearer $TOKEN"

# === ROOMS ===

# Join a MUC room
curl -X POST http://localhost:7842/bot/joinRoom \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"room":"general@conference.chat.example.com","nick":"MyBot"}'

# Leave a room
curl -X POST http://localhost:7842/bot/leaveRoom \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"room":"general@conference.chat.example.com"}'

# === COMMANDS ===

# Register bot commands
curl -X POST http://localhost:7842/bot/setCommands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"commands":[{"command":"help","description":"Show help"},{"command":"weather","description":"Get weather"}]}'

# Get registered commands
curl "http://localhost:7842/bot/getCommands" \
  -H "Authorization: Bearer $TOKEN"

# === BOT INFO ===

# Get bot info
curl "http://localhost:7842/bot/getMe" \
  -H "Authorization: Bearer $TOKEN"

# Get extended info
curl "http://localhost:7842/bot/getInfo" \
  -H "Authorization: Bearer $TOKEN"

# === MANAGEMENT ===

# Regenerate token
curl -X POST http://localhost:7842/bot/token \
  -H "Content-Type: application/json" \
  -d '{"id":1}'

# Revoke token
curl -X POST http://localhost:7842/bot/revoke \
  -H "Content-Type: application/json" \
  -d '{"id":1}'

# Activate bot
curl -X POST http://localhost:7842/bot/activate \
  -H "Content-Type: application/json" \
  -d '{"id":1,"status":"active"}'

# Pause bot without deleting configuration or closing the chat
curl -X POST http://localhost:7842/bot/activate \
  -H "Content-Type: application/json" \
  -d '{"id":1,"status":"paused"}'

# Deactivate bot
curl -X POST http://localhost:7842/bot/activate \
  -H "Content-Type: application/json" \
  -d '{"id":1,"status":"disabled"}'

# Delete bot
curl -X DELETE "http://localhost:7842/bot/delete?id=1"

# === TELEGRAM BRIDGE ===

# Setup Telegram bridge
curl -X POST http://localhost:7842/bot/telegram/setup \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"token":"123456:ABC-DEF","chat_id":"987654321","mode":"bridge"}'

# Check Telegram status
curl http://localhost:7842/bot/telegram/status \
  -H "Authorization: Bearer $TOKEN"

# Enable/disable Telegram
curl -X POST http://localhost:7842/bot/telegram/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}'

# Send message to Telegram
curl -X POST http://localhost:7842/bot/telegram/send \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello Telegram!"}'

# Test Telegram connection
curl -X POST http://localhost:7842/bot/telegram/test \
  -H "Authorization: Bearer $TOKEN"

# === AI ===

# Setup AI provider
curl -X POST http://localhost:7842/bot/ai/setup \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"provider":"groq","api_key":"gsk_abc","model":"llama-3.3-70b-versatile"}'

# Setup OpenClaw
curl -X POST http://localhost:7842/bot/ai/setup \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"provider":"openclaw","api_key":"oc_token","model":"agent"}'

# Check AI status
curl http://localhost:7842/bot/ai/status \
  -H "Authorization: Bearer $TOKEN"

# Enable AI
curl -X POST http://localhost:7842/bot/ai/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}'

# Ask the AI a question
curl -X POST http://localhost:7842/bot/ai/ask \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"What is quantum computing?"}'
```

### 8.11 Python Examples

#### Simple Bot (Polling)

```python
import requests
import time

API_URL = "http://localhost:7842"
TOKEN = "bot1:YOUR-UUID-TOKEN"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

def send_message(to: str, text: str):
    """Send a message to a JID."""
    r = requests.post(f"{API_URL}/bot/sendMessage",
                      headers=HEADERS,
                      json={"to": to, "text": text})
    return r.json()

def get_updates(offset: int = 0):
    """Poll for incoming messages."""
    r = requests.get(f"{API_URL}/bot/getUpdates",
                     headers=HEADERS,
                     params={"offset": offset} if offset else {})
    return r.json()

# Main polling loop
offset = 0
print("Bot started. Waiting for messages...")

while True:
    response = get_updates(offset)

    if response.get("ok"):
        updates = response.get("result", [])
        for update in updates:
            update_id = update["update_id"]
            data = update["data"]
            sender = data["from"]
            text = data.get("body", "")

            print(f"Message from {sender}: {text}")

            # Echo bot: repeat back what was said
            send_message(sender, f"You said: {text}")

            offset = update_id + 1

    time.sleep(2)
```

#### Webhook Bot (Flask)

```python
import hmac
import hashlib
import json
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

API_URL = "http://localhost:7842"
TOKEN = "bot1:YOUR-UUID-TOKEN"
WEBHOOK_SECRET = "your_webhook_secret"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

def verify_signature(payload: bytes, signature: str) -> bool:
    """Verify the webhook signature."""
    expected = "sha256=" + hmac.new(
        WEBHOOK_SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)

def send_message(to: str, text: str):
    """Send a reply."""
    requests.post(f"{API_URL}/bot/sendMessage",
                  headers=HEADERS,
                  json={"to": to, "text": text})

@app.route("/webhook", methods=["POST"])
def handle_webhook():
    signature = request.headers.get("X-Bot-Signature", "")
    if not verify_signature(request.data, signature):
        return jsonify({"error": "invalid signature"}), 403

    data = request.json
    if data.get("update_type") == "message":
        msg = data["data"]
        sender = msg["from"]
        text = msg.get("body", "")

        # Process the message
        if text.lower() == "ping":
            send_message(sender, "Pong! 🏓")
        else:
            send_message(sender, f"Received: {text}")

    return jsonify({"ok": True})

if __name__ == "__main__":
    # Register webhook first
    r = requests.post(f"{API_URL}/bot/setWebhook",
                      headers=HEADERS,
                      json={"url": "https://your-server.com/webhook"})
    print(f"Webhook registered: {r.json()}")

    app.run(host="0.0.0.0", port=5000)
```

#### Bot with Commands

```python
import requests

API_URL = "http://localhost:7842"
TOKEN = "bot1:YOUR-UUID-TOKEN"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# Register commands
commands = [
    {"command": "hello", "description": "Get a greeting"},
    {"command": "time",  "description": "Get current time"},
    {"command": "help",  "description": "Show available commands"}
]

requests.post(f"{API_URL}/bot/setCommands",
              headers=HEADERS,
              json={"commands": commands})

# Handle commands in your polling/webhook handler
def handle_command(sender: str, text: str):
    if text == "/hello":
        return "Hello! Nice to meet you! 👋"
    elif text == "/time":
        from datetime import datetime
        return f"Current time: {datetime.now().strftime('%H:%M:%S')}"
    elif text == "/help":
        return "Available commands:\n/hello - Get a greeting\n/time - Get current time\n/help - This message"
    else:
        return f"Unknown command: {text}"
```

---

## 9. Settings Reference

### 9.1 Application Settings (Preferences)

These settings are in DinoX Preferences > Botmother section and apply globally.

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `bot_features_enabled` | Boolean | `false` | Master toggle for the entire Botmother system |
| `api_mode` | String | `"local"` | `"local"` (HTTP on 127.0.0.1) or `"network"` (HTTPS on 0.0.0.0) |
| `api_port` | Integer | `7842` | API server port (1024-65535) |
| `api_tls_cert` | String | `""` | Custom TLS certificate path (empty = auto-generate) |
| `api_tls_key` | String | `""` | Custom TLS key path (empty = auto-generate) |

### 9.2 Per-Bot Settings (Database)

These are stored in the bot registry database (`~/.local/share/dinox/bot_registry.db`) in the `settings` table.

**AI settings per bot:**

| Key | Values | Description |
|-----|--------|-------------|
| `bot_{id}_ai_enabled` | `"true"` / `"false"` | AI active for this bot |
| `bot_{id}_ai_type` | `"openai"`, `"claude"`, `"gemini"`, `"groq"`, `"mistral"`, `"deepseek"`, `"perplexity"`, `"xai"`, `"ollama"`, `"openclaw"` | AI provider type |
| `bot_{id}_ai_endpoint` | URL | Provider API endpoint |
| `bot_{id}_ai_key` | `ENC:...` or empty secret | Encrypted API key. Empty only for Ollama. |
| `bot_{id}_ai_model` | String | Model name |
| `bot_{id}_ai_system` | String | System prompt |

**Telegram settings per bot:**

| Key | Values | Description |
|-----|--------|-------------|
| `bot_{id}_tg_enabled` | `"true"` / `"false"` | Telegram bridge active |
| `bot_{id}_tg_token` | `ENC:...` | Encrypted Telegram Bot API token |
| `bot_{id}_tg_chat_id` | String | Target Telegram chat ID |
| `bot_{id}_tg_mode` | `"bridge"` / `"forward"` | Bridge mode |

**Avatar settings per bot:**

| Key | Values | Description |
|-----|--------|-------------|
| `bot_avatar:{id}` | Base64 image data | Locally stored bot avatar image, normally a scaled PNG created by the UI |
| `bot_avatar_type:{id}` | MIME type | Avatar MIME type, usually `image/png` |

**Account settings:**

| Key | Values | Description |
|-----|--------|-------------|
| `botmother_account_enabled:{jid}` | `"true"` / `"false"` | Botmother enabled for account |

**ejabberd settings:**

| Key | Values | Description |
|-----|--------|-------------|
| `ejabberd_api_url` | URL | ejabberd REST API URL |
| `ejabberd_host` | String | XMPP server hostname |
| `ejabberd_admin_jid` | String | Admin JID |
| `ejabberd_admin_password` | Secret setting | Admin password |

---

## 10. Database Schema

**Location:** `~/.local/share/dinox/bot_registry.db` (SQLite, WAL mode)

**Current version:** 3

### Tables

#### `bot`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment bot ID |
| `name` | TEXT | Display name |
| `jid` | TEXT | Bot's XMPP JID (dedicated mode only) |
| `token_hash` | TEXT UNIQUE | HMAC-SHA256 hash of the API token |
| `token_raw` | TEXT | Legacy DB column from DB v2; intentionally unused. Raw tokens are not stored. |
| `owner_jid` | TEXT | Owner's XMPP JID |
| `description` | TEXT | Bot description |
| `permissions` | TEXT | Comma-separated permission scopes (default: `"all"`) |
| `status` | TEXT | `"active"`, `"paused"` or `"disabled"` |
| `mode` | TEXT | `"personal"` or `"dedicated"` in the local client. CloudBots are not stored as local bot rows; they are loaded through a management token in the Bot Manager. |
| `created_at` | INTEGER | Unix timestamp of creation |
| `last_active` | INTEGER | Unix timestamp of last activity |
| `webhook_url` | TEXT | Webhook delivery URL |
| `webhook_secret` | TEXT | Legacy DB column. New webhook secrets are stored as encrypted settings and migrated from this column on read. |
| `webhook_enabled` | INTEGER | 0 or 1 |
| `bot_password` | TEXT | Legacy DB column for dedicated bot XMPP passwords. New passwords are stored as encrypted settings and migrated from this column on read. |

#### `bot_command`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment |
| `bot_id` | INTEGER | Foreign key to `bot.id` |
| `command` | TEXT | Command name (without `/`) |
| `description` | TEXT | Command description |

#### `update_queue`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment update ID |
| `bot_id` | INTEGER | Foreign key to `bot.id` |
| `update_type` | TEXT | e.g. `"message"` |
| `payload` | TEXT | JSON payload |
| `created_at` | INTEGER | Unix timestamp |

#### `settings`

| Column | Type | Description |
|--------|------|-------------|
| `key` | TEXT PK | Setting key |
| `value` | TEXT | Setting value |

#### `audit_log`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment |
| `bot_id` | INTEGER | Related bot ID |
| `action` | TEXT | Action name (e.g. `"created"`, `"deleted"`, `"token_generated"`, `"token_revoked"`, `"token_regenerated"`) |
| `details` | TEXT | Action details |
| `ip_address` | TEXT | Client IP |
| `timestamp` | INTEGER | Unix timestamp |

---

## 11. DinoX CloudBot Server

> **Status: In Development / early integration**
>
> CloudBot is a separate persistent server runtime at `https://cloud.dinox.im`. The local DinoX client deliberately keeps CloudBot separate from local Personal/Dedicated bots: local `/bot/create` rejects `"mode":"cloud"` with `501 not_implemented`, while the Bot Manager loads and controls hosted bots by management token through **New Botmother** -> **DinoX-Client CloudBot**.

### Current Bot Modes vs. Cloud

| Feature | Personal | Dedicated | CloudBot |
|---------|----------|-----------|-----------------|
| Own XMPP account | No (shares yours) | Yes | Yes |
| Own XMPP stream | No | Yes | Yes |
| Requires DinoX running | Yes | Yes | **No** |
| Requires ejabberd API | No | Yes | Server-side only |
| Survives app restart | Session only | Yes | **Yes** |
| Multi-user bots | No | Owner only | **Yes** |
| Scalable | No | Limited | **Yes** |
| OMEMO encryption | Via owner | Own keys | Direct 1:1 uses hosted OMEMO readiness; groupchat remains plaintext |
| Administration | Chat + UI | Chat + UI + API | **Cloud web/API + DinoX token control** |

### Current Integration

**1. Standalone Bot Server**
- Bots run as a server-side service independent of the DinoX desktop app.
- Bot XMPP passwords are generated server-side and are never returned to users.
- Each bot gets a one-time management token; DinoX uses that token to load and control the bot.
- DinoX stores CloudBot management tokens locally per owner account through the local Botmother API secret store. Tokens are not local bot rows and are not mixed with local Botmother API tokens.

**2. Public CloudBot Registration**
- Public bot registration is separate from DinoX account registration.
- The public website uses Cloudflare Turnstile when enabled.
- Owner verification uses a short-lived verification code flow; the public website must not ask for or store owner XMPP passwords.
- Billing and open registration can be enabled or disabled server-side.

**3. DinoX Client Management**
- Open the Bot Manager, create a new Botmother entry, choose **DinoX-Client CloudBot**, and paste the CloudBot management token from `cloud.dinox.im`.
- After the token is loaded and saved, the hosted bot appears as a token-controlled CloudBot row in the Bot Manager. DinoX shows status, runtime/OMEMO readiness, current AI-token usage and the latest bot-scoped diagnostic entry there. Activate, pause, rotate tokens or delete it there.
- If a still-valid management token should be replaced, DinoX can rotate it. The new token is shown once, copied to the clipboard and placed in the management token field; existing active tokens stop working.
- DinoX can create a separate event token for automation systems such as Node-RED. Event tokens are shown once, can call `/api/v1/bot/events`, and cannot manage the bot.
- Local webhook fields are not CloudBot management endpoints; CloudBot URLs are rejected in local webhook configuration.

**4. Admin Panel**
- The server has a separate admin UI for service flags, status overview, bot/account status changes, token rotation and deprovisioning.
- Admin actions are server-side and must not expose XMPP bot passwords, encrypted secrets or raw stored tokens.

**5. Owner API**
- `GET /api/v1/bot/me` loads token-bound bot metadata.
- `POST /api/v1/bot/status` lets the owner switch between `active` and `paused`; `disabled` remains admin-only.
- `GET /api/v1/bot/runtime` reports whether the hosted runtime currently has a session for the bot.
- `GET /api/v1/bot/audit?limit=20` returns bot-scoped diagnostics without admin access.
- `POST /api/v1/bot/token/rotate` rotates a still-valid management token and returns the replacement once.
- `POST /api/v1/bot/events/token/rotate` creates a scoped event token from a valid management token. Existing event tokens stop working, but the management token remains valid.
- `POST /api/v1/bot/events` accepts a management token or scoped event token and sends structured automation events through the hosted bot runtime.

### Planned Enhancements

**1. Enhanced Scalability**
- Connection pooling for XMPP streams
- Load balancing across multiple bot instances
- Horizontal scaling for high-traffic bots
- Message queue integration (for high throughput)

**2. Advanced Bot Features**
- Scheduled messages and cron-like triggers
- Bot-to-bot communication
- Persistent conversation state (beyond in-memory)
- Plugin system for custom bot logic
- File storage and media handling

**3. Deployment Options**
- Docker container with docker-compose setup
- Systemd service for Linux servers
- Configuration via environment variables or config file
- Prometheus metrics endpoint for monitoring

### How CloudBot Server Works

```
┌──────────────────────────────────────────────────┐
│              DinoX Bot Server                    │
│                                                  │
│  ┌──────────────┐  ┌─────────────────────────┐   │
│  │ HTTP API     │  │ XMPP Connection Manager │   │
│  │ (REST +      │  │  - Bot streams           │  │
│  │  WebSocket)  │  │  - OMEMO per bot         │  │
│  └──────┬───────┘  │  - Auto-reconnect        │  │
│         │          └──────────┬──────────────┘   │
│         │                    │                   │
│  ┌──────┴────────────────────┴──────────────┐    │
│  │            Bot Runtime Engine             │   │
│  │  - Message routing                        │   │
│  │  - AI integration                         │   │
│  │  - Telegram bridge                        │   │
│  │  - Webhook dispatch                       │   │
│  │  - Command handling                       │   │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  ┌──────────────┐  ┌────────────────────────┐    │
│  │ Database     │  │ Web Admin Panel        │    │
│  │ (PostgreSQL  │  │ (Vue.js / React)       │    │
│  │  or SQLite)  │  │                        │    │
│  └──────────────┘  └────────────────────────┘    │
└──────────────────────────────────────────────────┘
```

### Possible Migration Path

Future migration tooling may support:

1. **Personal → Cloud**: Bot gets its own XMPP account, moves to the server
2. **Dedicated → Cloud**: Bot stream transferred to server management
3. **Cloud → Dedicated**: Bot moved back to local DinoX management

The API remains backward-compatible — existing tokens and endpoints will continue to work.

---

## 12. OpenClaw Integration

> **Status: Basic integration implemented (v1.1)**
>
> OpenClaw is available as an AI integration preset. The agent webhook API
> (`POST /hooks/agent`) is fully supported. Direction 1 (OpenClaw connects
> to DinoX as XMPP client) is planned for a future release.

OpenClaw (https://openclaw.ai/) is a **self-hosted autonomous AI agent** —
not an AI itself, but an orchestrator that manages AI models (Claude, GPT,
Ollama, ...) and uses them as tools. Think of n8n without UI, on steroids.
It runs on your PC or VPS, acts proactively, browses the web, runs commands,
has persistent memory, and manages its own skills and automations.

**OpenClaw is not a passive language-model provider.** The other Chapter 6
providers expose model APIs. OpenClaw is an active agent with hands and eyes
(like a worker that uses those brains). It decides which model to use, when
to browse, when to run a shell command, and when to reach out proactively.

### How the Connection Works

There are two directions — same pattern as Telegram:

**Direction 1: OpenClaw connects to DinoX (like Telegram)**

With Telegram, you create a bot via @BotFather, get a token, and give it to
OpenClaw. OpenClaw connects itself and listens for messages. The same model
could work for XMPP — give OpenClaw the bot's JID and credentials, and it
connects as an XMPP client.

**Direction 2: DinoX connects to OpenClaw (via Webhook API)**

OpenClaw exposes a webhook endpoint. DinoX sends messages to it, gets
responses back. This works today with OpenClaw's existing API:

```bash
# Send a message to OpenClaw and get a response
curl -X POST http://localhost:18789/hooks/agent \
  -H "Authorization: Bearer <OPENCLAW_HOOKS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"message": "Check if my website is online"}'
```

This is the same pattern as our existing AI providers: text in, text out.
The difference is that OpenClaw might browse the web, run commands, or
use multiple AI models internally before responding.

### How to Configure OpenClaw in DinoX

The basic integration is already available through the normal AI provider
setup path. OpenClaw uses the default gateway endpoint
`http://localhost:18789/hooks/agent`; DinoX sends user messages to that
endpoint and displays the response in the bot chat.

```
/ki setup openclaw <OPENCLAW_HOOKS_TOKEN> agent
/ki on
```

That is all. OpenClaw handles everything else internally — models, tools,
memory, skills, automations. DinoX does not manage or configure any of it.

### Requirements

- OpenClaw installed and running (`npm install -g openclaw@latest`)
- Node.js >= 22 on the OpenClaw host
- Network access from DinoX to OpenClaw Gateway (port 18789)
- Webhook hooks enabled in OpenClaw config with a token

For OpenClaw setup, configuration, and usage details, see the official docs:
https://docs.openclaw.ai/

---

*This document covers DinoX Botmother version 1.1.x. For updates, see the [CHANGELOG](CHANGELOG.md).*
