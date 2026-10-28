# Project Map

Map of core source files for the PenikXMPP project (Conversations XMPP fork, rebranded to Penik). Paths are relative to the project root; cache, logs, vendor code, auto-generated build artifacts, and the read-only UI donor `libs/Penik` are excluded (see note at the bottom).

## App Entry, CI/CD & Build Configuration

- `.github/workflows/` — Automated CI/CD pipeline:
  - `ci-fast.yml` — Fast CI on feature/fix branches and PRs (Lua test suites, Rust `cargo check`, Android Kotlin & Java compilation).
  - `dev-integration.yml` — Full integration suite on `dev` (Lua tests, Rust `cargo test` & `clippy`, Android unit tests, full APK build, debug artifact upload).
  - `release-cd.yml` — Production release & deployment pipeline on `main`/`master` (test gate, APK artifact packaging, automated Snikket SSH deployment).
- `android/build.gradle` — Main Gradle build: `namespace eu.siacs.conversations` / `applicationId ru.penik.xmpp` (`appName Penik`), Compose BOM + navigation/coil deps (Compose compiler plugin, `compose = true`), `minSdk 26`, flavors (`conversations`, `quicksy` x `free`, `playstore`), sourceSets, signing, R8, dataBinding.
- `android/settings.gradle` — Gradle modules: `libs:annotation`, `libs:annotation-processor`; `rootProject.name`.
- `android/gradle.properties` — AndroidX, non-transitive R class, heap, R8 flags.
- `android/gradle/libs.versions.toml` — Version catalog for dependencies.
- `android/gradle/wrapper/` — Gradle wrapper binaries and properties.
- `android/gradlew`, `android/gradlew.bat` — Build entry points.
- `android/proguard-rules.pro` — R8/ProGuard keep rules.
- `android/signing.properties` — Release keystore config (local only, not committed).
- `android/libs/annotation/`, `android/libs/annotation-processor/` — Local annotation libraries used by the app.
- `android/src/main/AndroidManifest.xml` — App declaration (application theme `Theme.Penik`): permissions, services, 20+ activities, FileProvider (`${applicationId}.files`, `.barcodes`), UnifiedPush, backup intents.
- `android/src/main/java/eu/siacs/conversations/Conversations.java` — Application class: global context, account supplier, Conscrypt init, emoji init, foreground activity tracker (`isInForeground()`).
- `android/src/main/java/eu/siacs/conversations/Config.java` — Global constants: domains, timeouts, ping intervals, avatar/image sizes, feature flags.
- `android/src/main/java/eu/siacs/conversations/AppSettings.java` — Typed wrapper over SharedPreferences settings.

## XMPP Core

### Connection & Stream

- `android/src/main/java/eu/siacs/conversations/xmpp/XmppConnection.java` — Low-level XMPP stream: connect, TLS, SASL, bind, stanza read/write loop.
- `android/src/main/java/eu/siacs/conversations/xmpp/Managers.java` — Aggregator giving access to all stanza managers for a connection.
- `android/src/main/java/eu/siacs/conversations/xmpp/Jid.java` — JID parsing, validation, bare/full/domain helpers.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnStatusChanged.java` — Callback for account connection state changes.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnContactStatusChanged.java` — Callback for contact presence changes.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnBindListener.java` — Callback fired after resource bind.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnMessageAcknowledged.java` — Callback for XEP-0198 stream acks.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnMessagePacketReceived.java` — Callback for inbound message packets.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnUpdateBlocklist.java` — Callback for blocklist pushes.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnKeyStatusUpdated.java` — Callback for OMEMO key status changes.
- `android/src/main/java/eu/siacs/conversations/xmpp/OnAdvancedStreamFeaturesLoaded.java` — Callback after disco features are known.
- `android/src/main/java/eu/siacs/conversations/xmpp/PreconditionNotMetException.java` — Stream precondition errors.
- `android/src/main/java/eu/siacs/conversations/xmpp/fun/` — FunXMPP binary tokenized protocol: FunTokens (multi-version dictionary: LTS v1 68a7596d + v2 3a145c7a with bot tokens), FunWriter (TLV encoder with negotiated dictionary and literal fallback), FunReader (safe TLV decoder with direct stream feature recognition). Direct PXMPP over TLS ALPN (`pxmpp-1`).

### Stanza Managers (`xmpp/manager/`)

- `android/src/main/java/eu/siacs/conversations/xmpp/manager/AbstractManager.java` — Base class for stanza managers.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/DiscoManager.java` — Service discovery (XEP-0030), caps, features.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/RosterManager.java` — Roster get/push handling.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PresenceManager.java` — Presence send/subscribe/probe.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/MessageArchiveManager.java` — MAM history queries (XEP-0313).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/MultiUserChatManager.java` — MUC join, config, invites, kicks.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PubSubManager.java` — PubSub publish/retract/subscribe base.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PepManager.java` — PEP avatar, OMEMO bundles, presence templates.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/AxolotlManager.java` — OMEMO session/key stanza wiring.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ChatStateManager.java` — Chat states (composing/paused, XEP-0085).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/DeliveryReceiptManager.java` — Delivery receipts (XEP-0184).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/DisplayedManager.java` — Displayed/chat markers synchronization.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ReactionManager.java` — Emoji reactions (XEP-0444).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/BlockingManager.java` — Blocklist (XEP-0191).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/BookmarkManager.java` — MUC bookmarks (native + legacy + compat layer).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/CarbonsManager.java` — Message carbons (XEP-0280).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PingManager.java` — XMPP ping, pong timeouts.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/JingleManager.java` — Jingle session dispatch to RTP/file-transfer.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/JingleMessageManager.java` — Jingle call signaling messages.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/HttpUploadManager.java` — HTTP upload slot requests (XEP-0363).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/AvatarManager.java` — Avatar publish/fetch via PEP/vCard.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/VCardManager.java` — vCard-temp fetch/update.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/RegistrationManager.java` — In-band registration (XEP-0077).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/EasyOnboardingManager.java` — Easy onboarding invites.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ExternalServiceDiscoveryManager.java` — External services (STUN/TURN).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/UnifiedPushManager.java` — UnifiedPush registration to XMPP push server.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PushNotificationManager.java` — App-server push enable/disable.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ModerationManager.java` — Message moderation in MUC.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/NickManager.java` — Nick register/publish.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/PrivateStorageManager.java` — Private XML storage.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/StreamHostManager.java` — SOCKS5 bytestream hosts.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/EntityTimeManager.java` — Entity time (XEP-0202).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/AdHocCommandsManager.java` — Ad-hoc commands.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ActivityManager.java` — User activity (XEP-0108).
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/OfflineMessagesManager.java` — Offline message headers.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/StanzaIdManager.java` — Stanza ID tracking for acks.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/ClientStateIndicationManager.java` — CSI active/inactive.
- `android/src/main/java/eu/siacs/conversations/xmpp/manager/MessageDisplayedSynchronizationManager.java` — Multi-device displayed sync.

### Parsers & Generators

- `android/src/main/java/eu/siacs/conversations/parser/AbstractParser.java` — Shared stanza parse helpers.
- `android/src/main/java/eu/siacs/conversations/parser/MessageParser.java` — Inbound message, receipts, reactions, RTP, MUC logic.
- `android/src/main/java/eu/siacs/conversations/parser/PresenceParser.java` — Presence, MUC status codes, caps.
- `android/src/main/java/eu/siacs/conversations/parser/IqParser.java` — IQ dispatch: roster, disco, MAM, OMEMO, upload, push.
- `android/src/main/java/eu/siacs/conversations/generator/IqGenerator.java` — Outbound IQ builders.
- `android/src/main/java/eu/siacs/conversations/generator/MessageGenerator.java` — Outbound message builders (chat, group, receipts).
- `android/src/main/java/eu/siacs/conversations/generator/AbstractGenerator.java` — Shared XML element builders.
- `android/src/main/java/eu/siacs/conversations/xml/Element.java` — Generic XML element model.
- `android/src/main/java/eu/siacs/conversations/xml/Tag.java` — Start-tag model.
- `android/src/main/java/eu/siacs/conversations/xml/TagWriter.java` — Stream XML serializer.
- `android/src/main/java/eu/siacs/conversations/xml/XmlReader.java` — Stream XML pull parser.
- `android/src/main/java/eu/siacs/conversations/xml/Namespace.java` — XMPP namespace constants.
- `android/src/main/java/eu/siacs/conversations/xml/LocalizedContent.java` — Lang-tagged element text.

### Shared XMPP Library (`im.conversations.android.xmpp`)

- `android/src/main/java/im/conversations/android/xmpp/Entity.java` — Base stanza entity.
- `android/src/main/java/im/conversations/android/xmpp/EntityCapabilities.java` — Legacy caps hashing (XEP-0115).
- `android/src/main/java/im/conversations/android/xmpp/EntityCapabilities2.java` — New caps hashing (XEP-0390).
- `android/src/main/java/im/conversations/android/xmpp/ExtensionFactory.java` — Extension element factory.
- `android/src/main/java/im/conversations/android/xmpp/StreamElementWriter.java` — Stream open/close writer.
- `android/src/main/java/im/conversations/android/xmpp/model/` — Stanza models (message, presence, iq, error, bind, carbons, receipts, fun).
- `android/src/main/java/im/conversations/android/xmpp/model/fun/` — FunXMPP stream models: Funxmpp (feature), Enable, Enabled, Failed.
- `android/src/main/java/im/conversations/android/xmpp/processor/` — Stream processors (bind, ack, account state).

## Crypto

- `android/src/main/java/eu/siacs/conversations/crypto/axolotl/AxolotlService.java` — OMEMO sessions, bundles, trust, healing.
- `android/src/main/java/eu/siacs/conversations/crypto/axolotl/XmppAxolotlSession.java` — Single Double-Ratchet session wrapper.
- `android/src/main/java/eu/siacs/conversations/crypto/axolotl/XmppAxolotlMessage.java` — OMEMO envelope parse/build.
- `android/src/main/java/eu/siacs/conversations/crypto/axolotl/SQLiteAxolotlStore.java` — Signal store on SQLite.
- `android/src/main/java/eu/siacs/conversations/crypto/axolotl/FingerprintStatus.java` — Trust states (trusted, undecided, compromised).
- `android/src/main/java/eu/siacs/conversations/crypto/PgpEngine.java` — OpenPGP encrypt/decrypt via OpenKeychain.
- `android/src/main/java/eu/siacs/conversations/crypto/PgpDecryptionService.java` — Background PGP decrypt service.
- `android/src/main/java/eu/siacs/conversations/crypto/OmemoSetting.java` — Per-contact OMEMO preference.
- `android/src/main/java/eu/siacs/conversations/crypto/sasl/` — SASL mechanisms (PLAIN, SCRAM-SHA-1/256/512 +PLUS, EXTERNAL, ANONYMOUS, tokens).
- `android/src/main/java/eu/siacs/conversations/crypto/XmppDomainVerifier.java` — TLS domain verification.

## Services (Android Runtime)

- `android/src/main/java/eu/siacs/conversations/services/XmppConnectionService.java` — Central foreground service: accounts, conversations, send/receive, notifications, Jingle dispatch, backup hooks.
- `android/src/main/java/eu/siacs/conversations/services/NotificationService.java` — MessagingStyle notifications, reply/mark-read actions, summary grouping. Incoming calls open `RtpSessionActivity` directly when the app is in the foreground.
- `android/src/main/java/eu/siacs/conversations/services/AvatarService.java` — Avatar load/cache/publish pipeline.
- `android/src/main/java/eu/siacs/conversations/services/ChannelDiscoveryService.java` — Public channel search (`search.jabber.network`).
- `android/src/main/java/eu/siacs/conversations/services/BarcodeProvider.java` — QR barcode content provider.
- `android/src/main/java/eu/siacs/conversations/services/AttachFileToConversationRunnable.java` — File attach pipeline (transcode, encrypt, upload).
- `android/src/main/java/eu/siacs/conversations/services/UnifiedPushBroker.java` — UnifiedPush distributor broker.
- `android/src/main/java/eu/siacs/conversations/services/AbstractConnectionManager.java` — Reconnect/backoff supervisor.
- `android/src/main/java/eu/siacs/conversations/services/CallIntegration.java` — Telecom integration for calls.
- `android/src/main/java/eu/siacs/conversations/services/CallIntegrationConnectionService.java` — Telecom ConnectionService.
- `android/src/main/java/eu/siacs/conversations/services/MediaPlayer.java` — Voice message playback.
- `android/src/main/java/eu/siacs/conversations/services/MemorizingTrustManager.java` — TOFU TLS trust manager.
- `android/src/main/java/eu/siacs/conversations/services/MessageSearchTask.java` — FTS message search.
- `android/src/main/java/eu/siacs/conversations/services/ShortcutService.java` — Launcher shortcuts for chats.
- `android/src/main/java/eu/siacs/conversations/receiver/SystemEventReceiver.java` — Boot, connectivity, shutdown hooks.
- `android/src/main/java/eu/siacs/conversations/receiver/UnifiedPushDistributor.java` — UnifiedPush register/unregister receiver.
- `android/src/main/java/eu/siacs/conversations/worker/ExportBackupWorker.java` — Encrypted `.ceb` backup export.
- `android/src/main/java/eu/siacs/conversations/worker/ImportBackupWorker.java` — Backup restore.

## UI

### Top-Level Activities

- `android/src/main/java/eu/siacs/conversations/ui/ConversationActivity.java` — Main chat screen (launcher): conversation list + active chat fragment.
- `android/src/main/java/eu/siacs/conversations/ui/ConversationFragment.java` — Chat room: messages, input, receipts, call buttons.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikChatsList.kt` — Penik main screen (Compose, 1:1 with Penik app): TopAppBar with search, connection banner, chats tab (self-chat row, archive folder, rows with avatars/unread/lock/mute, archive dialogs), calls tab from RTP history, profile tab (avatar, Telegram-style info card with phone number and display name editing), bottom navigation; data bridged from `ConversationsOverviewFragment` via `PenikChatsState`.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikChatRoom.kt` — Penik chat room (Compose): timeline with date headers, text bubbles with links/quotes/ticks/lock/edited, emoji-only messages, attachments (image thumbs, inline voice player, files, audio, geo), call cards from RTP history, bug-report collapse, long-press menu (copy/reply/edit/share/resend/open); data bridged from `ConversationFragment` via `PenikChatState`.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikAttachmentPickerBottomSheet.kt` — Penik attachment picker (Compose, Telegram-style): 3-column media grid with live camera tile, numeric multi-selection pills, floating bottom capsule ("Галерея" / "Файл"), permission flow, and quick send.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikBotCommands.kt` — Penik bot commands popup & autocomplete (Compose): floating command picker over input bar with icons, descriptions, and one-tap command execution.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikStickerBubble.kt` — Penik sticker bubble (Compose): renders static and animated WebP (Coil + ImageDecoderDecoder) and Telegram `.tgs` vector animations (lottie-compose) with semi-transparent delivery badges.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikStickerPicker.kt` — Telegram-style sticker picker bottom sheet (Compose): recents tab, installed pack tabs, 4-column static thumbnail grid (128x128 WebP) to avoid UI stutters, and Telegram pack import dialog.
- `android/src/main/java/eu/siacs/conversations/ui/compose/PenikAuthScreen.kt` — Penik onboarding & auth screen (Compose, 1:1 with Penik app): Welcome screen, 3-step registration wizard (nickname, password, avatar/display name) on default server without server picker, and login wizard.
- `android/src/main/java/eu/siacs/conversations/ui/ConversationsActivity.java` — Account/conversation overview host (`singleTask`).
- `android/src/main/java/eu/siacs/conversations/ui/ConversationsOverviewFragment.java` — Unified inbox list.
- `android/src/main/java/eu/siacs/conversations/ui/StartConversationActivity.java` — New chat, search contacts, join conference.
- `android/src/main/java/eu/siacs/conversations/ui/ConferenceDetailsActivity.java` — MUC details, subject, members, config.
- `android/src/main/java/eu/siacs/conversations/ui/EditConferenceActivity.java` — Dedicated screen for editing group chat name, subject/topic, and avatar.
- `android/src/main/java/eu/siacs/conversations/ui/ContactDetailsActivity.java` — 1:1 contact profile (Telegram-style): big centered avatar, name, online/last seen status, quick action buttons (Chat, Sound, Call, Video), username, bio, shared media, and 3-dots overflow menu with icons (Notifications, Edit, Delete, Block, Share).
- `android/src/main/java/eu/siacs/conversations/ui/EditAccountActivity.java` — XMPP account add/edit (login/register).
- `android/src/main/java/eu/siacs/conversations/ui/RtpSessionActivity.java` — Audio/video call screen (Jingle/WebRTC) modernized with Penik dark theme, big avatar, E2EE badge, and circular call controls.
- `android/src/main/java/eu/siacs/conversations/ui/activity/SettingsActivity.java` — Preferences host.
- `android/src/main/java/eu/siacs/conversations/ui/SearchActivity.java` — Full-text message search.
- `android/src/main/java/eu/siacs/conversations/ui/TrustKeysActivity.java` — OMEMO fingerprint verification.
- `android/src/main/java/eu/siacs/conversations/ui/ChannelDiscoveryActivity.java` — Public channel directory.
- `android/src/main/java/eu/siacs/conversations/ui/BlocklistActivity.java` — Blocked contacts.
- `android/src/main/java/eu/siacs/conversations/ui/AboutActivity.java` — About, licenses.
- `android/src/main/java/eu/siacs/conversations/ui/ImportBackupActivity.java` — Backup restore incl. `.ceb` intents.
- `android/src/main/java/eu/siacs/conversations/ui/ShareWithActivity.java` — System share target.
- `android/src/main/java/eu/siacs/conversations/ui/MediaBrowserActivity.java` — Chat media gallery.
- `android/src/main/java/eu/siacs/conversations/ui/MucUsersActivity.java` — Group member list.
- `android/src/main/java/eu/siacs/conversations/ui/ChooseContactActivity.java` — Contact picker.
- `android/src/main/java/eu/siacs/conversations/ui/ScanQrCodeActivity.java` — QR scan entry.
- `android/src/main/java/eu/siacs/conversations/ui/YuriLauncherActivity.java` — `xmpp:` / invite link dispatcher.
- `android/src/main/java/eu/siacs/conversations/ui/UnifiedPushDistributor.java` — UnifiedPush setup UI.

### Adapters

- `android/src/main/java/eu/siacs/conversations/ui/adapter/MessageAdapter.java` — Chat message list (bubbles, media, statuses).
- `android/src/main/java/eu/siacs/conversations/ui/adapter/ConversationAdapter.java` — Inbox rows (last message, unread, drafts).
- `android/src/main/java/eu/siacs/conversations/ui/adapter/MediaAdapter.java` — Media grid.
- `android/src/main/java/eu/siacs/conversations/ui/adapter/AccountAdapter.java` — Account list.
- `android/src/main/java/eu/siacs/conversations/ui/adapter/UserAdapter.java` — MUC/contact user rows.
- `android/src/main/java/eu/siacs/conversations/ui/adapter/ListItemAdapter.java` — Generic searchable rows.
- `android/src/main/java/eu/siacs/conversations/ui/adapter/ChannelSearchResultAdapter.java` — Channel search rows.

### UI Helpers

- `android/src/main/java/eu/siacs/conversations/ui/util/Attachment.java` — Attachment model (type, uri, transcoding).
- `android/src/main/java/eu/siacs/conversations/ui/util/ConversationMenuConfigurator.java` — Per-chat menu (mute, archive, security).
- `android/src/main/java/eu/siacs/conversations/ui/util/QuoteHelper.java` — Reply/quote builder.
- `android/src/main/java/eu/siacs/conversations/ui/util/AvatarWorkerTask.java` — Async avatar loading.
- `android/src/main/java/eu/siacs/conversations/ui/util/ScrollState.java` — List scroll-down FAB logic.
- `android/src/main/java/eu/siacs/conversations/ui/util/SendButtonAction.java`, `SendButtonTool.java` — Send/record button state.
- `android/src/main/java/eu/siacs/conversations/ui/util/ShareUtil.java` — Share/link helpers.
- `android/src/main/java/eu/siacs/conversations/ui/util/SettingsUtils.java` — Night mode / theme helpers.
- `android/src/main/java/eu/siacs/conversations/ui/widget/` — Custom views (scanner, bubbles, spans, audio recorder).
- `android/src/main/java/eu/siacs/conversations/ui/text/` — Message spans (quote, URL, divider).
- `android/src/main/java/eu/siacs/conversations/ui/interfaces/` — Activity/fragment callbacks (backend connected, conversation selected/read).

### Resources (Penik rebrand targets)

- `android/src/main/res/anim/` — Telegram-style smooth slide transitions (`penik_slide_in_right`, `penik_slide_out_left`, `penik_slide_in_left`, `penik_slide_out_right`).
- `android/src/main/res/layout/` — ~70 screens: `activity_conversations`, `fragment_conversation`, `fragment_conversations_overview`, `activity_rtp_session`, `activity_edit_account`, `item_message_*`, `item_conversation`, `dialog_*`.
- `android/src/main/res/values/themes.xml` — `Theme.Conversations3` (+ Dark, Splash, Dialog, FullScreen); rebrand target `Theme.Penik`.
- `android/src/main/res/values/strings.xml` — `app_name` and all user strings.
- `android/src/main/res/values/colors-md.xml` — Material3 palette; rebrand target `penik_colors.xml`.
- `android/src/main/res/values/penik_colors.xml` — Penik light palette ported from `libs/Penik` `Color.kt` (`LightAppColors`).
- `android/src/main/res/values-night/penik_colors.xml` — Penik dark palette, default (`DarkAppColors`).
- `android/src/main/res/values/themes.xml` — Now also declares `Theme.Penik` and `Theme.Penik.Dark` on top of the Penik palette.
- `android/src/main/res/menu/` — Chat, MUC, contact, media, search menus.
- `android/src/main/res/xml/` — Preferences (`preferences_*.xml`), `shortcuts.xml`, `file_paths.xml`, `network_security_configuration.xml`, backup rules.
- `android/src/main/res/mipmap-*/`, `drawable-*/` — Launcher icons (`new_launcher` → Penik icon).

## Data & Persistence

- `android/src/main/java/eu/siacs/conversations/persistance/DatabaseBackend.java` — SQLite schema, accounts, messages, MUC, fingerprints.
- `android/src/main/java/eu/siacs/conversations/persistance/FileBackend.java` — Attachment files, encryption, thumbnails.
- `android/src/main/java/eu/siacs/conversations/persistance/UnifiedPushDatabase.java` — Push subscriptions store.
- `android/src/main/java/eu/siacs/conversations/entities/Account.java` — Account state machine.
- `android/src/main/java/eu/siacs/conversations/entities/Conversation.java` — 1:1 and MUC conversation aggregate.
- `android/src/main/java/eu/siacs/conversations/entities/Message.java` — Message with statuses, edits, reactions, attachments, stickers (`TYPE_STICKER = 7`), and bot inline keyboards (`botMarkup`).
- `android/src/main/java/eu/siacs/conversations/entities/BotMarkup.java` — Bot markup model: Inline keyboards under message bubbles, Reply keyboards (`ReplyKeyboardMarkup`) replacing system keyboard, and `ReplyKeyboardRemove` with JSON serialization/deserialization.
- `android/src/main/java/eu/siacs/conversations/entities/BotCommand.java` — Bot command model (`command`, `description`) for autocomplete and bot menu interaction.
- `android/src/main/java/eu/siacs/conversations/entities/Sticker.java` — Sticker entity (`packId`, `stickerId`, `emoji`, `width`, `height`, `format`, `url`) with JSON serialization/deserialization.
- `android/src/main/java/eu/siacs/conversations/stickers/StickerManager.kt` — Sticker pack and recents manager: local storage, bundle installation, Telegram sticker pack import via REST API, HMAC-SHA256 token generator.
- `android/src/main/java/eu/siacs/conversations/phone/PenikPhoneDirectoryManager.kt` — Phone directory manager: client for $k$-anonymity contact discovery (computes SHA-256 of normalized E.164 phone numbers, queries matching buckets via 3-hex-char prefixes with `POST /phone-directory/lookup`, matches full hashes locally without disclosing user contacts to the server, and fetches plain numbers via targeted single-JID `GET /phone-directory/:jid` with mutual contact check), managing local address book matching and roster synchronization.
- `android/src/main/java/eu/siacs/conversations/android/PenikPhoneContact.java` — Phone contact model extending `AbstractPhoneContact` for local address book matching.
- `android/src/main/java/eu/siacs/conversations/entities/Contact.java`, `Roster.java` — Roster model.
- `android/src/main/java/eu/siacs/conversations/entities/MucOptions.java` — MUC roles, affiliation, subject, config.
- `android/src/main/java/eu/siacs/conversations/entities/Presences.java` — Presence map per contact.
- `android/src/main/java/eu/siacs/conversations/http/HttpConnectionManager.java` — Upload/download connection pool.
- `android/src/main/java/eu/siacs/conversations/http/HttpUploadConnection.java` — XEP-0363 slot PUT with progress.
- `android/src/main/java/eu/siacs/conversations/http/HttpDownloadConnection.java` — AES-GCM URL download.
- `android/src/main/java/eu/siacs/conversations/http/AesGcmURL.java` — `aesgcm://` URL crypto.

## Calls (Jingle/WebRTC)

- `android/src/main/java/eu/siacs/conversations/xmpp/jingle/JingleRtpConnection.java` — RTP session state machine.
- `android/src/main/java/eu/siacs/conversations/xmpp/jingle/RtpContentMap.java` — Audio/video content negotiation.
- `android/src/main/java/eu/siacs/conversations/xmpp/jingle/OngoingRtpSession.java` — Active call handle.
- `android/src/main/java/eu/siacs/conversations/xmpp/jingle/WebRTCWrapper.java` — WebRTC peer connection wrapper.
- `android/src/main/java/eu/siacs/conversations/xmpp/jingle/JingleFileTransferConnection.java` — Jingle file transfer.
- `android/src/main/java/eu/siacs/conversations/services/AppRTCAudioManager.java` — Call audio routing (speaker/BT).

## Product Flavors & Variants

- `android/src/conversations/java/.../ui/ManageAccountActivity.java` — Conversations account manager.
- `android/src/conversations/java/.../ui/WelcomeActivity.java`, `MagicCreateActivity.java`, `PickServerActivity.java` — Onboarding.
- `android/src/conversations/java/.../services/QuickConversationsService.java` — Quick setup service.
- `android/src/conversations/java/.../utils/SignupUtils.java` — Invite-based signup.
- `android/src/conversationsFree/`, `src/conversationsPlaystore/`, `src/playstore/`, `src/free/` — Push (FCM vs UnifiedPush), emoji init, install referrer.
- `android/src/quicksy*/` — Quicksy flavor (SMS verifier, separate branding).
- `android/src/test/` — Unit tests: JID, parsers, caps, reactions, scan results.

## Project Configuration & Docs

- `README.md` — Penik (XMPP) overview in English: PXMPP binary protocol, modern Compose UI features, stickers, stack, automated ADB installation, server deployment notes, and upstream heritage.
- `README_RU.md` — Полный обзор Penik (XMPP) на русском языке.
- `android/CHANGELOG.md` — Release history.
- `android/conversations.doap` — Project metadata.
- `android/fastlane/metadata/` — Play Store listings and screenshots (rebrand target).
- `docs/` — User docs (backup, migration).
- `docs/PRIVACY.md` — Privacy Policy for the Penik service (`ru.penik.xmpp`, `penik.ru`): TLS in-transit security, absence of E2EE/OMEMO (cloud MAM), phone directory pseudonymization and public profile visibility, data retention and 14-day backup isolation purge rules.
- `docs/TERMS.md` — Terms of Service for the Penik service: licensing, acceptable use policy, anti-scraping rules for phone directory API, transparent account suspension grounds and appeal procedures.
- `docs/PENIK_BOT_AND_BRIDGE_ARCHITECTURE.md` — Complete architecture specification and implementation guide for external bots, puppeting bridges, and `penik-tg-bridge` (XEP-0114, penik:bot:markup, penik:bot:commands, vCard, media pipeline).
- `docs/PXMPP/` — PenikXMPP (FunXMPP) binary protocol specification & technical docs in English (`README.md`) and Russian (`README_RU.md`).
- `art/` — Artwork sources.
- `.woodpecker.yml` — CI pipeline.
- `.gitmodules` — `libs/Penik` submodule (read-only UI donor, branch `feat/cloud-chats`).
- `scripts/install_phone.sh` — Automated build and installation of Penik debug APK (free or playstore/FCM) to connected Android devices via ADB.
- `scripts/deploy_server.sh` — Deployment script for Prosody Lua modules (`mod_funxmpp`, `mod_stickers_auth`) and Rust microservice to remote Snikket/Prosody servers.
- `plan/penik-xmpp-ui-port-plan.md` — Plan to port Penik UI and rebrand to `ru.penik.xmpp`.
- `plan/xmpp-stanza-diet-plan.md` — Plan to cut XMPP stanza overhead (245 → 193 bytes): omit outbound `from` per RFC 6120, short 12-char ids, chat-state composing throttle (8s), MAM page 20, preserving Monal/Dino interoperability (markable/request receipts).
- `plan/funxmpp-fixes-plan.md` — Plan for FunXMPP review follow-ups: P0 outgoing mod_smacks piggyback `<r/>` string bypassing binary framing, P1 `CONTENT_MIXED` child order (v2 sequence, breaking), P2 buffer/length/counter polish, plus items verified as-is (incoming SM routing, JID `@` scan).
- `plan/stickers-rust-service-plan.md` — Implementation plan for Telegram-compatible stickers via standalone Rust microservice, XMPP stanza extensions, and Compose UI.
- `plan/penik-bot-platform-plan.md` — Architectural blueprint and implementation plan for Telegram-style Bot API platform via XEP-0114 External Component on VPS 1, PXMPP binary transport, and Compose UI.
- `plan/telegram-puppeting-bridge-plan.md` — Architecture plan and phased roadmap for Telegram MTProto puppeting bridge (`tg.snikket.penik.ru`) with selective chat sync.
- `plan/penik-desktop-client-plan.md` — Architectural plan for modular desktop client in Qt 6 (C++/QML) and Rust core with PXMPP support, 1:1 Android UI, rich media, and stickers.
- `plan/direct-pxmpp-architecture-plan.md` — Architecture plan for Direct PXMPP (implicit binary framing over TLS via ALPN `pxmpp-1`, 1-RTT resumption, SCRAM-SHA-256-PLUS) with 100% legacy client compatibility.
- `plan/pxmpp-dictionary-evolution-plan.md` — Architectural plan for PXMPP token dictionary evolution via server multi-dictionary registry, append-only monotonic expansion, virtual session domains, and string literal fallback.
- `landing/` — Static landing page: `index.html` (hero, features, protocol terminal demo, comparison, FAQ, download links), `logo_fixed.svg` / `logo_fixed.webp`; note `landing/penik.apk` stays untracked via the `*.apk` gitignore rule.
- `server/Modules/` — Prosody/Snikket Lua plugins: `mod_funxmpp.lua` (FunXMPP binary tokenized protocol plugin: Direct PXMPP over TLS ALPN `pxmpp-1` and sniffing fallback, symmetric TLV parser, multi-dictionary registry v1/v2, min_compat feature advertisement, literal fallback for older clients, filter hooks), `test_mod_funxmpp.lua` (standalone Lua test suite with multi-version negotiation and Direct PXMPP tests), `mod_stickers_auth.lua` (Prosody HMAC-SHA256 Bearer token issuer for stickers service via IQ `penik:stickers:auth:0`), `test_mod_stickers_auth.lua`, `mod_penik_silent_muc.lua` (Prosody silent MUC supergroup plugin: suppresses join/leave/status presence broadcasts to room occupants, provides persistent members IQ query via `ru:penik:muc:members:1`), `test_mod_penik_silent_muc.lua`.
- `server/MicroServices/` — Standalone backend microservices:
  - `server/MicroServices/penik-service-rs/` — High-performance Rust backend companion service (Axum 0.7, SQLite WAL, Tokio, Reqwest, GPL-3.0-only): Telegram Bot API sticker pack importer, WebM VP9 with alpha to Animated WebP converter via FFmpeg (`-c:v libvpx-vp9`), 128x128 thumbnail generator, pre-built `bundle.zip` packager, and secure phone directory with HMAC-SHA256 Bearer auth. Endpoints: `POST /api/v1/phone-directory` (register/update phone & SHA-256 hash), `POST /api/v1/phone-directory/lookup` ($k$-anonymity 3-hex-char prefix bucket lookup returning `{jid, phone_hash}` without plain numbers), and targeted `GET /api/v1/phone-directory/:jid` (strict single-JID plain phone fetch with mutual contact verification).
  - `server/MicroServices/penik-bot-gateway/` — High-performance Rust Telegram Bot API gateway (Axum 0.7, Tokio, SQLite WAL, roxmltree + quick-xml, GPL-3.0-only): connects to Prosody on VPS 1 via XEP-0114 External Component protocol managing `bot.penik.chat` / `bot.snikket.penik.ru`. Features: in-process BotFather FSM dialog engine (`botfather@...`), REST endpoints (`getMe`, `sendMessage`, `editMessageText` via XEP-0308, `setWebhook`, `getUpdates` with offset ack and Notify, `sendPhoto`, `sendDocument`), full-duplex WebSocket stream (`/bot:token/ws`) for real-time updates and bidirectional RPC/commands, SSRF & DNS-rebinding protection (`reqwest::dns::Resolve`), 50-error circuit breaker, and automatic presence/vCard responses. Includes `examples/demo_bot.py` showcasing inline keyboards, reply keyboards, one-time keyboards, and `answerCallbackQuery` alerts.
- `PROJECT_MAP.md` — This index.

## Note on `libs/Penik` (Excluded)

`libs/Penik` is a read-only submodule containing the standalone Penik messenger (Go server, web client, Compose Android app). It is the UI donor for the port but is NOT part of this map and must not be edited. Its own map lives at `libs/Penik/PROJECT_MAP.md`. This map covers only the Conversations XMPP codebase that will be rebranded to `ru.penik.xmpp`.
