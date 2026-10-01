# Penik (XMPP)

Android XMPP client with the Penik interface: a fork of [Conversations](https://codeberg.org/iNPUTmice/Conversations) (`codeberg.org/iNPUTmice/Conversations`), rebuilt as **Penik** (`ru.penik.xmpp`).

> Upstream lives on Codeberg. This repository tracks it plus the Penik UI port (see `plan/penik-xmpp-ui-port-plan.md`).

## What changed vs Conversations

- **Penik branding**: `applicationId ru.penik.xmpp`, Penik name, Penik icon and theme (`Theme.Penik`, `penik_colors.xml` palette, circular avatars).
- **Main screen one-to-one with Penik** (Jetpack Compose): top bar with search, connection banner (yellow "Connecting...", red only when everything is down), Saved messages, chat archive, bottom tabs Chats/Calls/Profile, calls from RTP history.
- **Default server** — `snikket.penik.ru` (`Config.MAGIC_CREATE_DOMAIN`).
- **Domain hidden**: only the nick before `@` is shown everywhere (`JidHelper.displayAddress()`).
- **Follower-only encryption**: everything is plaintext by default; OMEMO/PGP controls removed from the UI. If a contact writes first over OMEMO, the chat upgrades itself to OMEMO, keys are accepted automatically, messages get a lock.
- **Calls (Jingle)**: video upgrades apply silently and independently on each side (like Telegram); a refused/timed-out upgrade no longer kills the audio; avatar instead of a black screen until video frames arrive; incoming calls open the call screen right away, not just a notification.
- **Small things**: the "no more history on server" toast is gone, long crash reports collapse under a label, bug reports go to `niel_kro@snikket.penik.ru`, S2S is firewalled off on the server.

## Stack

| Part | Technologies |
|-------|-----------|
| Base | Conversations fork: XMPP (Smack-compatible `im.conversations.android.xmpp` core), OMEMO, Jingle/WebRTC calls, SQLite, classic Views + Activities |
| Penik UI | Jetpack Compose (Material 3, Navigation, Coil), Compose BOM 2026.09, Kotlin 2.4; `minSdk` 26, `targetSdk`/`compileSdk` 37 |
| Build | Gradle 9 (Groovy), AGP 9.2, R8, DataBinding |

## Repository structure

```
src/main/java/eu/siacs/conversations/  core: Config, entities, xmpp, crypto, services
  ui/            Activities and Fragments (chat, calls, settings)
  ui/compose/    ported Penik screens (PenikChatsList: chats/calls/profile)
  ui/adapter/    list adapters (messages, contacts, media)
src/main/res/    layouts, values/penik_colors.xml, values/themes.xml (Theme.Penik), values-night/
plan/            UI port and rebranding plan
libs/Penik/      READ-ONLY UI donor submodule (do not touch)
PROJECT_MAP.md   source index describing every file
fastlane/        publishing metadata
```

Navigate the code via `PROJECT_MAP.md`.

## Quick start

```bash
./gradlew assembleConversationsFreeDebug
```

APK: `build/outputs/apk/conversationsFree/debug/`. First launch: register/log in on `snikket.penik.ru`.

## Server operator notes

- The client tries **5223 (direct TLS, XEP-0368)** first, then falls back to **5222 (STARTTLS)**. If 5223 is published but dead (accept + reset, e.g. a Docker port with nothing listening behind it, or a closed ufw), every connect wastes ~12 seconds on the timeout. Either open a working 5223 (`ufw allow 5223/tcp`) or close it so SYN gets refused immediately — then the fallback is instant.
- For a closed installation, S2S (5269) is cut at the firewall (`ufw deny 5269/tcp` + `ufw deny out 5269/tcp`).

## Links

- Upstream: [codeberg.org/iNPUTmice/Conversations](https://codeberg.org/iNPUTmice/Conversations)
- This fork's issues: [github.com/Nielkro/PenikXMPP/issues](https://github.com/Nielkro/PenikXMPP/issues)
