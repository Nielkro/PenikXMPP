# Penik Bot & Bridge Architecture Specification

Complete technical specification and developer manual for creating external bots and puppeting bridges (including the Telegram Bridge `penik-tg-bridge`) within the Penik ecosystem.

---

## 1. Architectural Overview

Penik uses modern XMPP (Prosody) as its real-time message bus with custom high-performance extensions:
* **FunXMPP (PXMPP):** Tokenized binary streaming protocol between Penik mobile clients and Prosody.
* **XEP-0114 Direct TLS (Jabber Component Protocol):** Secure Direct TLS 1.3 connection for external daemon services (bridges, gateways, bots) over port `5348` (plaintext port `5347` is restricted to localhost `127.0.0.1`).
* **vCard-temp / PEP:** Profile synchronization (avatars, display names).
* **Penik Bot Markup (`penik:bot:markup`):** Telegram-compatible rich UI inside native chat bubbles (inline buttons, reply keyboards, toasts, alert dialogs).
* **Penik Bot Commands (`penik:bot:commands`):** Dynamic command discovery for interactive menus and `/` autocomplete.

```
+--------------------------------------------------------------------------------+
|                             Telegram Cloud (MTProto)                           |
+--------------------------------------------------------------------------------+
                                       ▲
                                       │ MTProto (grammers / TDLib)
                                       ▼
+--------------------------------------------------------------------------------+
|                     penik-tg-bridge (External Daemon)                          |
|  - SQLite WAL (sessions, bridged_chats)                                        |
|  - Auth & Settings Bot (@tgbridgebot on bot.snikket.penik.ru via WS)           |
|  - Virtual XMPP entity router (u_{id}@..., g_{id}@...) via Direct TLS 5348    |
+--------------------------------------------------------------------------------+
             │                                              ▲
             │ WS /bot:token/ws                             │ XEP-0114 Direct TLS :5348
             ▼                                              ▼
+--------------------------------------------------------------------------------+
|                             Prosody Core (VPS)                                 |
|  - VirtualHost "snikket.penik.ru"                                              |
|  - Component "tg.snikket.penik.ru" (configured secret in Prosody)              |
|  - Component "bot.snikket.penik.ru" (Bot Gateway: @tgbridgebot)                |
|  - Component "share.snikket.penik.ru" (HTTP Upload XEP-0363)                  |
+--------------------------------------------------------------------------------+
                                       ▲
                                       │ TLS / FunXMPP (Mobile Binary Protocol)
                                       ▼
+--------------------------------------------------------------------------------+
|                      Penik Android / Web Client                                |
+--------------------------------------------------------------------------------+
```

---

## 2. Server Connection Parameters (`tg.snikket.penik.ru`)

The bot and bridge run on a **dedicated separate server** and connect to the Penik cluster over the network:

* **Component Domain:** `tg.snikket.penik.ru`
* **Prosody Host:** `snikket.penik.ru`
* **XEP-0114 Direct TLS Port:** `5348` (TCP with Direct TLS 1.3, open on firewall).
  > Plaintext port `5347` is restricted to localhost (`127.0.0.1`) for local microservices only (`bot.snikket.penik.ru`).
* **Component Secret:** Configured in Prosody (`push.cfg.lua`)
* **Bot Gateway WebSocket URL:** `wss://bot.snikket.penik.ru/bot:token/ws` (for `@tgbridgebot` FSM and interactive chat picker)
* **HTTP Upload Domain:** `https://share.snikket.penik.ru` (XEP-0363 upload service for photos and audio)

### 2.1. Handshake Flow (RFC 3921 / XEP-0114 with Direct TLS)
1. Bridge establishes TCP connection to `snikket.penik.ru:5348` and immediately performs TLS 1.3 handshake with SNI `snikket.penik.ru`.
2. Over the encrypted TLS socket, Bridge sends stream header:
   ```xml
   <stream:stream xmlns='jabber:component:accept' xmlns:stream='http://etherx.jabber.org/streams' to='tg.snikket.penik.ru'>
   ```
3. Prosody responds with stream ID:
   ```xml
   <stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:component:accept' id='STREAM_ID_12345' from='tg.snikket.penik.ru'>
   ```
4. Bridge computes SHA1 digest:
   ```text
   auth_token = SHA1(STREAM_ID_12345 + component_secret)
   ```
5. Bridge sends handshake stanza:
   ```xml
   <handshake>a94a8fe5ccb19ba61c4c0873d391e987982fbbd3</handshake>
   ```
6. Prosody replies:
   ```xml
   <handshake/>
   ```
   *Handshake completed. The bridge is now authorized to send and receive any stanzas to/from `*@tg.snikket.penik.ru`.*

---

## 3. Addressing Scheme & JID Conventions

The bridge dynamically provisions virtual XMPP entities on the fly:

| Entity Type | JID Pattern | Domain / Host | Purpose |
| :--- | :--- | :--- | :--- |
| **Control Bot** | `tgbridgebot@bot.snikket.penik.ru` | `bot.snikket.penik.ru` (Bot Gateway) | Regular Penik Bot (`@tgbridgebot`): Login FSM, `/chats` menu, `/add`, `/list` |
| **Direct Contact (1:1)** | `u_{tg_user_id}@tg.snikket.penik.ru` | `tg.snikket.penik.ru` (Component) | Virtual 1:1 contact mirroring TG user |
| **Group / Supergroup** | `g_{tg_chat_id}@tg.snikket.penik.ru` | `tg.snikket.penik.ru` (Component) | Virtual MUC room mirroring TG group |
| **Broadcast Channel** | `c_{tg_channel_id}@tg.snikket.penik.ru` | `tg.snikket.penik.ru` (Component) | Read-only MUC mirroring TG channel |

> [!NOTE]
> All JIDs under `tg.snikket.penik.ru` automatically receive the `Telegram` subtitle badge in the Penik client header.

---

## 4. Rich UI & Keyboard Protocol (`penik:bot:markup`)

The Penik client renders Telegram-style UI components directly inside chat bubbles and input bars.

### 4.1. Inline Keyboards (Buttons under messages)
To render interactive buttons under a message bubble:
```xml
<message type='chat' to='user@snikket.penik.ru' from='bot@tg.snikket.penik.ru' id='msg_001'>
  <body>Выберите чаты Telegram для подключения:</body>
  <markup xmlns='penik:bot:markup' type='inline'>
    <row>
      <button text='⬜ Иван Иванов' data='toggle:123456789'/>
    </row>
    <row>
      <button text='✅ Рабочий чат' data='toggle:987654321'/>
    </row>
    <row>
      <button text='🌐 Открыть в Telegram' url='https://t.me/durov'/>
    </row>
  </markup>
</message>
```

#### Button Attributes:
* `text`: Label displayed on button.
* `data`: Callback data payload (sent back to bridge on tap).
* `url`: Direct web link (opens in browser / external app without callback).

### 4.2. Callback Clicks
When a user taps an inline button with `data`:
```xml
<message type='chat' to='bot@tg.snikket.penik.ru' from='user@snikket.penik.ru' id='cb_001'>
  <callback xmlns='penik:bot:markup' msg_id='msg_001' data='toggle:123456789'/>
  <no-store xmlns='urn:xmpp:hints'/>
</message>
```

### 4.3. Callback Answers (Toasts & Alerts)
The bridge must answer button clicks to provide user feedback:
```xml
<message type='chat' to='user@snikket.penik.ru' from='bot@tg.snikket.penik.ru'>
  <callback_answer xmlns='penik:bot:markup' id='user@snikket.penik.ru:msg_001' text='Чат успешно подключен!' show_alert='false'/>
  <no-store xmlns='urn:xmpp:hints'/>
</message>
```
* `show_alert='false'`: Displays a subtle native Android Toast banner.
* `show_alert='true'`: Displays a modal Material 3 Alert Dialog.

### 4.4. Reply Keyboards (Bottom screen grid replacing software keyboard)
```xml
<message type='chat' to='user@snikket.penik.ru' from='bot@tg.snikket.penik.ru' id='msg_002'>
  <body>Главное меню моста:</body>
  <markup xmlns='penik:bot:markup' type='reply' resize='true' one_time='false'>
    <row>
      <button text='📋 Список чатов'/>
      <button text='🔄 Переподключить'/>
    </row>
    <row>
      <button text='❌ Выйти из аккаунта'/>
    </row>
  </markup>
</message>
```

### 4.5. Keyboard Removal
```xml
<message type='chat' to='user@snikket.penik.ru' from='bot@tg.snikket.penik.ru' id='msg_003'>
  <body>Клавиатура скрыта</body>
  <markup xmlns='penik:bot:markup' type='remove'/>
</message>
```

---

## 5. Bot Commands Discovery (`penik:bot:commands`)

When a user chats with `bot@tg.snikket.penik.ru`, Penik queries available bot commands to populate the `[/]` menu and `/` autocomplete popup:

### 5.1. Query Stanza from Client:
```xml
<iq type='get' id='cmd_query_1' to='bot@tg.snikket.penik.ru' from='user@snikket.penik.ru'>
  <query xmlns='penik:bot:commands'/>
</iq>
```

### 5.2. Result Stanza from Bridge:
```xml
<iq type='result' id='cmd_query_1' to='user@snikket.penik.ru' from='bot@tg.snikket.penik.ru'>
  <commands xmlns='penik:bot:commands'>
    <command name='chats' description='Выбрать чаты Telegram для переноса'/>
    <command name='add' description='Подключить чат по @username или ссылке'/>
    <command name='list' description='Показать активные чаты моста'/>
    <command name='status' description='Проверить статус подключения к Telegram'/>
    <command name='logout' description='Отключить аккаунт Telegram'/>
  </commands>
</iq>
```

---

## 6. Profiles & Avatars (vCard-temp)

When Penik opens a virtual contact (e.g., `u_123456789@tg.snikket.penik.ru`), it fetches avatar and name via vCard-temp:

### 6.1. Client Request:
```xml
<iq type='get' id='vcard_1' to='u_123456789@tg.snikket.penik.ru' from='user@snikket.penik.ru'>
  <vCard xmlns='vcard-temp'/>
</iq>
```

### 6.2. Bridge Response:
```xml
<iq type='result' id='vcard_1' to='user@snikket.penik.ru' from='u_123456789@tg.snikket.penik.ru'>
  <vCard xmlns='vcard-temp'>
    <FN>Павел Дуров</FN>
    <NICKNAME>durov</NICKNAME>
    <DESC>Telegram Founder</DESC>
    <PHOTO>
      <TYPE>image/jpeg</TYPE>
      <BINVAL>iVBORw0KGgoAAAANSUhEUgAA...</BINVAL>
    </PHOTO>
  </vCard>
</iq>
```

---

## 7. Media & File Handling Pipeline

Telegram media is bridged transparently to Penik:
1. When Telegram sends a photo, voice note, document, or video note:
   * The bridge downloads the file chunks via MTProto stream.
2. The bridge uploads the file to Penik's HTTP Upload server (`share.snikket.penik.ru`):
   * Requests upload slot via XEP-0363:
     ```xml
     <iq type='get' to='share.snikket.penik.ru' id='slot_1'>
       <request xmlns='urn:xmpp:http:upload:0' filename='voice.ogg' size='45120' content-type='audio/ogg'/>
     </iq>
     ```
   * HTTP PUT file data to returned `put_url`.
3. The bridge delivers the download URL (`get_url`) in the message body to the Penik client:
   ```xml
   <message type='chat' to='user@snikket.penik.ru' from='u_123456789@tg.snikket.penik.ru' id='m_101'>
     <body>https://share.snikket.penik.ru/files/abc123xyz/voice.ogg</body>
     <x xmlns='jabber:x:oob'><url>https://share.snikket.penik.ru/files/abc123xyz/voice.ogg</url></x>
   </message>
   ```
4. **Voice Notes:** Telegram sends voice notes in Ogg Opus format. Penik plays them natively with live waveform!
5. **Video Notes:** Sent as MP4.
6. **Outgoing files from Penik to Telegram:** When the user sends a file/photo in Penik, the client uploads it to `share.snikket.penik.ru` and sends the URL. The bridge downloads the URL and calls MTProto `send_file`.

---

## 8. Selective Chat Bridging Workflow

To prevent hitting Telegram `FloodWait` and avoid cluttering the contact list, the bridge implements **Selective Bridging**:

### 8.1. State Machine (SQLite Table: `auth_sessions`)
* `UNAUTHORIZED` -> user writes `login +79991234567`
* `WAIT_CODE` -> bridge calls `SendCode`, prompts user for `code 12345`
* `WAIT_PASSWORD` -> (if 2FA enabled) prompts for `password secret`
* `AUTHENTICATED` -> session saved, ready for `/chats`

### 8.2. Interactive Selection (`/chats`)
1. User interacts with `@tgbridgebot` (`tgbridgebot@bot.snikket.penik.ru`) via Penik Bot API (WebSocket `wss://bot.snikket.penik.ru/bot:token/ws`).
2. Bridge fetches recent dialogs via MTProto `client.get_dialogs()`.
3. Bridge looks up SQLite table `bridged_chats (user_jid, tg_chat_id, enabled)`.
4. Bridge sends message with Telegram-compatible inline keyboard rows via `sendMessage`:
   * `[ ⬜ Павел Дуров ] (callback_data: toggle:12345)`
   * `[ ✅ Команда Penik ] (callback_data: toggle:98765)`
5. When user clicks `toggle:12345`:
   * Penik client dispatches callback query.
   * Bridge flips state in SQLite (`enabled = true`).
   * Bridge calls `answerCallbackQuery(text='Чат подключен!', show_alert=false)` -> displays toast.
   * Bridge calls `editMessageText` updating button text to `[ ✅ Павел Дуров ]`.
   * Bridge sends roster push / presence from `u_12345@tg.snikket.penik.ru` into the user's Penik chat list.
   * Only enabled chats deliver incoming messages and poll for updates.

---

## 9. Message Edits, Retractions & Reactions

* **Edits (Telegram edit ⇄ Penik edit):**
  * Uses **XEP-0308 (Last Message Correction)**:
    ```xml
    <message type='chat' to='user@snikket.penik.ru' from='u_12345@tg.snikket.penik.ru' id='new_msg_id'>
      <body>Отредактированный текст</body>
      <replace xmlns='urn:xmpp:message-correct:0' id='original_msg_id'/>
    </message>
    ```
* **Deletions (Message Retraction):**
  * Uses **XEP-0424**:
    ```xml
    <message type='chat' to='user@snikket.penik.ru' from='u_12345@tg.snikket.penik.ru'>
      <apply-to xmlns='urn:xmpp:fasten:0' id='original_msg_id'>
        <retract xmlns='urn:xmpp:message-retract:0'/>
      </apply-to>
    </message>
    ```
* **Emoji Reactions:**
  * Uses **XEP-0444**:
    ```xml
    <message type='chat' to='user@snikket.penik.ru' from='u_12345@tg.snikket.penik.ru'>
      <reactions xmlns='urn:xmpp:reactions:0' id='original_msg_id'>
        <reaction>👍</reaction>
      </reactions>
    </message>
    ```

---

## 10. Summary Checklist for Implementing `penik-tg-bridge`

1. **Register Bot:** Create `@tgbridgebot` via Penik BotFather (`botfather@bot.snikket.penik.ru`) to get bot token.
2. **Connect Bot API:** Connect to `wss://bot.snikket.penik.ru/bot:token/ws` for handling user onboarding (`/start`, `login`, `/chats`, inline buttons).
3. **Connect XMPP Component:** Establish Direct TLS 1.3 TCP stream to `snikket.penik.ru:5348` (SNI `snikket.penik.ru`), perform XEP-0114 handshake with `tg.snikket.penik.ru` and component secret.
4. **Route Virtual Entities:**
   * Incoming messages from Penik to `u_{id}@tg.snikket.penik.ru` -> send to Telegram via MTProto.
   * Inbound updates from Telegram for `enabled` chats -> forward as `u_{id}@tg.snikket.penik.ru` to Penik user.
5. **Deploy:** Package as lightweight Docker image (`rust:slim` binary, ~20MB RAM) on the dedicated bridge server.
