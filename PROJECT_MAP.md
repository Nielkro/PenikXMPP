# Project Map

Map of core source files for the PenikXMPP project (Conversations XMPP fork, rebranded to Penik). Paths are relative to the project root; cache, logs, vendor code, auto-generated build artifacts, and the read-only UI donor `libs/Penik` are excluded (see note at the bottom).

## App Entry & Build Configuration

- `build.gradle` — Main Gradle build: `namespace eu.siacs.conversations` / `applicationId ru.penik.xmpp` (`appName Penik`), Compose BOM + navigation/coil deps (Compose compiler plugin, `compose = true`), `minSdk 26`, flavors (`conversations`, `quicksy` x `free`, `playstore`), sourceSets, signing, R8, dataBinding.
- `settings.gradle` — Gradle modules: `libs:annotation`, `libs:annotation-processor`; `rootProject.name`.
- `gradle.properties` — AndroidX, non-transitive R class, heap, R8 flags.
- `gradle/libs.versions.toml` — Version catalog for dependencies.
- `gradle/wrapper/` — Gradle wrapper binaries and properties.
- `gradlew`, `gradlew.bat` — Build entry points.
- `proguard-rules.pro` — R8/ProGuard keep rules.
- `signing.properties` — Release keystore config (local only, not committed).
- `libs/annotation/`, `libs/annotation-processor/` — Local annotation libraries used by the app.
- `src/main/AndroidManifest.xml` — App declaration (application theme `Theme.Penik`): permissions, services, 20+ activities, FileProvider (`${applicationId}.files`, `.barcodes`), UnifiedPush, backup intents.
- `src/main/java/eu/siacs/conversations/Conversations.java` — Application class: global context, account supplier, Conscrypt init, emoji init, foreground activity tracker (`isInForeground()`).
- `src/main/java/eu/siacs/conversations/Config.java` — Global constants: domains, timeouts, ping intervals, avatar/image sizes, feature flags.
- `src/main/java/eu/siacs/conversations/AppSettings.java` — Typed wrapper over SharedPreferences settings.

## XMPP Core

### Connection & Stream

- `src/main/java/eu/siacs/conversations/xmpp/XmppConnection.java` — Low-level XMPP stream: connect, TLS, SASL, bind, stanza read/write loop.
- `src/main/java/eu/siacs/conversations/xmpp/Managers.java` — Aggregator giving access to all stanza managers for a connection.
- `src/main/java/eu/siacs/conversations/xmpp/Jid.java` — JID parsing, validation, bare/full/domain helpers.
- `src/main/java/eu/siacs/conversations/xmpp/OnStatusChanged.java` — Callback for account connection state changes.
- `src/main/java/eu/siacs/conversations/xmpp/OnContactStatusChanged.java` — Callback for contact presence changes.
- `src/main/java/eu/siacs/conversations/xmpp/OnBindListener.java` — Callback fired after resource bind.
- `src/main/java/eu/siacs/conversations/xmpp/OnMessageAcknowledged.java` — Callback for XEP-0198 stream acks.
- `src/main/java/eu/siacs/conversations/xmpp/OnMessagePacketReceived.java` — Callback for inbound message packets.
- `src/main/java/eu/siacs/conversations/xmpp/OnUpdateBlocklist.java` — Callback for blocklist pushes.
- `src/main/java/eu/siacs/conversations/xmpp/OnKeyStatusUpdated.java` — Callback for OMEMO key status changes.
- `src/main/java/eu/siacs/conversations/xmpp/OnAdvancedStreamFeaturesLoaded.java` — Callback after disco features are known.
- `src/main/java/eu/siacs/conversations/xmpp/PreconditionNotMetException.java` — Stream precondition errors.

### Stanza Managers (`xmpp/manager/`)

- `src/main/java/eu/siacs/conversations/xmpp/manager/AbstractManager.java` — Base class for stanza managers.
- `src/main/java/eu/siacs/conversations/xmpp/manager/DiscoManager.java` — Service discovery (XEP-0030), caps, features.
- `src/main/java/eu/siacs/conversations/xmpp/manager/RosterManager.java` — Roster get/push handling.
- `src/main/java/eu/siacs/conversations/xmpp/manager/PresenceManager.java` — Presence send/subscribe/probe.
- `src/main/java/eu/siacs/conversations/xmpp/manager/MessageArchiveManager.java` — MAM history queries (XEP-0313).
- `src/main/java/eu/siacs/conversations/xmpp/manager/MultiUserChatManager.java` — MUC join, config, invites, kicks.
- `src/main/java/eu/siacs/conversations/xmpp/manager/PubSubManager.java` — PubSub publish/retract/subscribe base.
- `src/main/java/eu/siacs/conversations/xmpp/manager/PepManager.java` — PEP avatar, OMEMO bundles, presence templates.
- `src/main/java/eu/siacs/conversations/xmpp/manager/AxolotlManager.java` — OMEMO session/key stanza wiring.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ChatStateManager.java` — Chat states (composing/paused, XEP-0085).
- `src/main/java/eu/siacs/conversations/xmpp/manager/DeliveryReceiptManager.java` — Delivery receipts (XEP-0184).
- `src/main/java/eu/siacs/conversations/xmpp/manager/DisplayedManager.java` — Displayed/chat markers synchronization.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ReactionManager.java` — Emoji reactions (XEP-0444).
- `src/main/java/eu/siacs/conversations/xmpp/manager/BlockingManager.java` — Blocklist (XEP-0191).
- `src/main/java/eu/siacs/conversations/xmpp/manager/BookmarkManager.java` — MUC bookmarks (native + legacy + compat layer).
- `src/main/java/eu/siacs/conversations/xmpp/manager/CarbonsManager.java` — Message carbons (XEP-0280).
- `src/main/java/eu/siacs/conversations/xmpp/manager/PingManager.java` — XMPP ping, pong timeouts.
- `src/main/java/eu/siacs/conversations/xmpp/manager/JingleManager.java` — Jingle session dispatch to RTP/file-transfer.
- `src/main/java/eu/siacs/conversations/xmpp/manager/JingleMessageManager.java` — Jingle call signaling messages.
- `src/main/java/eu/siacs/conversations/xmpp/manager/HttpUploadManager.java` — HTTP upload slot requests (XEP-0363).
- `src/main/java/eu/siacs/conversations/xmpp/manager/AvatarManager.java` — Avatar publish/fetch via PEP/vCard.
- `src/main/java/eu/siacs/conversations/xmpp/manager/VCardManager.java` — vCard-temp fetch/update.
- `src/main/java/eu/siacs/conversations/xmpp/manager/RegistrationManager.java` — In-band registration (XEP-0077).
- `src/main/java/eu/siacs/conversations/xmpp/manager/EasyOnboardingManager.java` — Easy onboarding invites.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ExternalServiceDiscoveryManager.java` — External services (STUN/TURN).
- `src/main/java/eu/siacs/conversations/xmpp/manager/UnifiedPushManager.java` — UnifiedPush registration to XMPP push server.
- `src/main/java/eu/siacs/conversations/xmpp/manager/PushNotificationManager.java` — App-server push enable/disable.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ModerationManager.java` — Message moderation in MUC.
- `src/main/java/eu/siacs/conversations/xmpp/manager/NickManager.java` — Nick register/publish.
- `src/main/java/eu/siacs/conversations/xmpp/manager/PrivateStorageManager.java` — Private XML storage.
- `src/main/java/eu/siacs/conversations/xmpp/manager/StreamHostManager.java` — SOCKS5 bytestream hosts.
- `src/main/java/eu/siacs/conversations/xmpp/manager/EntityTimeManager.java` — Entity time (XEP-0202).
- `src/main/java/eu/siacs/conversations/xmpp/manager/AdHocCommandsManager.java` — Ad-hoc commands.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ActivityManager.java` — User activity (XEP-0108).
- `src/main/java/eu/siacs/conversations/xmpp/manager/OfflineMessagesManager.java` — Offline message headers.
- `src/main/java/eu/siacs/conversations/xmpp/manager/StanzaIdManager.java` — Stanza ID tracking for acks.
- `src/main/java/eu/siacs/conversations/xmpp/manager/ClientStateIndicationManager.java` — CSI active/inactive.
- `src/main/java/eu/siacs/conversations/xmpp/manager/MessageDisplayedSynchronizationManager.java` — Multi-device displayed sync.

### Parsers & Generators

- `src/main/java/eu/siacs/conversations/parser/AbstractParser.java` — Shared stanza parse helpers.
- `src/main/java/eu/siacs/conversations/parser/MessageParser.java` — Inbound message, receipts, reactions, RTP, MUC logic.
- `src/main/java/eu/siacs/conversations/parser/PresenceParser.java` — Presence, MUC status codes, caps.
- `src/main/java/eu/siacs/conversations/parser/IqParser.java` — IQ dispatch: roster, disco, MAM, OMEMO, upload, push.
- `src/main/java/eu/siacs/conversations/generator/IqGenerator.java` — Outbound IQ builders.
- `src/main/java/eu/siacs/conversations/generator/MessageGenerator.java` — Outbound message builders (chat, group, receipts).
- `src/main/java/eu/siacs/conversations/generator/AbstractGenerator.java` — Shared XML element builders.
- `src/main/java/eu/siacs/conversations/xml/Element.java` — Generic XML element model.
- `src/main/java/eu/siacs/conversations/xml/Tag.java` — Start-tag model.
- `src/main/java/eu/siacs/conversations/xml/TagWriter.java` — Stream XML serializer.
- `src/main/java/eu/siacs/conversations/xml/XmlReader.java` — Stream XML pull parser.
- `src/main/java/eu/siacs/conversations/xml/Namespace.java` — XMPP namespace constants.
- `src/main/java/eu/siacs/conversations/xml/LocalizedContent.java` — Lang-tagged element text.

### Shared XMPP Library (`im.conversations.android.xmpp`)

- `src/main/java/im/conversations/android/xmpp/Entity.java` — Base stanza entity.
- `src/main/java/im/conversations/android/xmpp/EntityCapabilities.java` — Legacy caps hashing (XEP-0115).
- `src/main/java/im/conversations/android/xmpp/EntityCapabilities2.java` — New caps hashing (XEP-0390).
- `src/main/java/im/conversations/android/xmpp/ExtensionFactory.java` — Extension element factory.
- `src/main/java/im/conversations/android/xmpp/StreamElementWriter.java` — Stream open/close writer.
- `src/main/java/im/conversations/android/xmpp/model/` — Stanza models (message, presence, iq, error, bind, carbons, receipts).
- `src/main/java/im/conversations/android/xmpp/processor/` — Stream processors (bind, ack, account state).

## Crypto

- `src/main/java/eu/siacs/conversations/crypto/axolotl/AxolotlService.java` — OMEMO sessions, bundles, trust, healing.
- `src/main/java/eu/siacs/conversations/crypto/axolotl/XmppAxolotlSession.java` — Single Double-Ratchet session wrapper.
- `src/main/java/eu/siacs/conversations/crypto/axolotl/XmppAxolotlMessage.java` — OMEMO envelope parse/build.
- `src/main/java/eu/siacs/conversations/crypto/axolotl/SQLiteAxolotlStore.java` — Signal store on SQLite.
- `src/main/java/eu/siacs/conversations/crypto/axolotl/FingerprintStatus.java` — Trust states (trusted, undecided, compromised).
- `src/main/java/eu/siacs/conversations/crypto/PgpEngine.java` — OpenPGP encrypt/decrypt via OpenKeychain.
- `src/main/java/eu/siacs/conversations/crypto/PgpDecryptionService.java` — Background PGP decrypt service.
- `src/main/java/eu/siacs/conversations/crypto/OmemoSetting.java` — Per-contact OMEMO preference.
- `src/main/java/eu/siacs/conversations/crypto/sasl/` — SASL mechanisms (PLAIN, SCRAM-SHA-1/256/512 +PLUS, EXTERNAL, ANONYMOUS, tokens).
- `src/main/java/eu/siacs/conversations/crypto/XmppDomainVerifier.java` — TLS domain verification.

## Services (Android Runtime)

- `src/main/java/eu/siacs/conversations/services/XmppConnectionService.java` — Central foreground service: accounts, conversations, send/receive, notifications, Jingle dispatch, backup hooks.
- `src/main/java/eu/siacs/conversations/services/NotificationService.java` — MessagingStyle notifications, reply/mark-read actions, summary grouping. Incoming calls open `RtpSessionActivity` directly when the app is in the foreground.
- `src/main/java/eu/siacs/conversations/services/AvatarService.java` — Avatar load/cache/publish pipeline.
- `src/main/java/eu/siacs/conversations/services/ChannelDiscoveryService.java` — Public channel search (`search.jabber.network`).
- `src/main/java/eu/siacs/conversations/services/BarcodeProvider.java` — QR barcode content provider.
- `src/main/java/eu/siacs/conversations/services/AttachFileToConversationRunnable.java` — File attach pipeline (transcode, encrypt, upload).
- `src/main/java/eu/siacs/conversations/services/UnifiedPushBroker.java` — UnifiedPush distributor broker.
- `src/main/java/eu/siacs/conversations/services/AbstractConnectionManager.java` — Reconnect/backoff supervisor.
- `src/main/java/eu/siacs/conversations/services/CallIntegration.java` — Telecom integration for calls.
- `src/main/java/eu/siacs/conversations/services/CallIntegrationConnectionService.java` — Telecom ConnectionService.
- `src/main/java/eu/siacs/conversations/services/MediaPlayer.java` — Voice message playback.
- `src/main/java/eu/siacs/conversations/services/MemorizingTrustManager.java` — TOFU TLS trust manager.
- `src/main/java/eu/siacs/conversations/services/MessageSearchTask.java` — FTS message search.
- `src/main/java/eu/siacs/conversations/services/ShortcutService.java` — Launcher shortcuts for chats.
- `src/main/java/eu/siacs/conversations/receiver/SystemEventReceiver.java` — Boot, connectivity, shutdown hooks.
- `src/main/java/eu/siacs/conversations/receiver/UnifiedPushDistributor.java` — UnifiedPush register/unregister receiver.
- `src/main/java/eu/siacs/conversations/worker/ExportBackupWorker.java` — Encrypted `.ceb` backup export.
- `src/main/java/eu/siacs/conversations/worker/ImportBackupWorker.java` — Backup restore.

## UI

### Top-Level Activities

- `src/main/java/eu/siacs/conversations/ui/ConversationActivity.java` — Main chat screen (launcher): conversation list + active chat fragment.
- `src/main/java/eu/siacs/conversations/ui/ConversationFragment.java` — Chat room: messages, input, receipts, call buttons.
- `src/main/java/eu/siacs/conversations/ui/compose/PenikChatsList.kt` — Penik main screen (Compose, 1:1 with Penik app): TopAppBar with search, connection banner, chats tab (self-chat row, archive folder, rows with avatars/unread/lock/mute, archive dialogs), calls tab from RTP history, profile tab, bottom navigation; data bridged from `ConversationsOverviewFragment` via `PenikChatsState`.
- `src/main/java/eu/siacs/conversations/ui/ConversationsActivity.java` — Account/conversation overview host (`singleTask`).
- `src/main/java/eu/siacs/conversations/ui/ConversationsOverviewFragment.java` — Unified inbox list.
- `src/main/java/eu/siacs/conversations/ui/StartConversationActivity.java` — New chat, search contacts, join conference.
- `src/main/java/eu/siacs/conversations/ui/ConferenceDetailsActivity.java` — MUC details, subject, members, config.
- `src/main/java/eu/siacs/conversations/ui/ContactDetailsActivity.java` — 1:1 details, keys, presence.
- `src/main/java/eu/siacs/conversations/ui/EditAccountActivity.java` — XMPP account add/edit (login/register).
- `src/main/java/eu/siacs/conversations/ui/RtpSessionActivity.java` — Audio/video call screen (Jingle/WebRTC).
- `src/main/java/eu/siacs/conversations/ui/activity/SettingsActivity.java` — Preferences host.
- `src/main/java/eu/siacs/conversations/ui/SearchActivity.java` — Full-text message search.
- `src/main/java/eu/siacs/conversations/ui/TrustKeysActivity.java` — OMEMO fingerprint verification.
- `src/main/java/eu/siacs/conversations/ui/ChannelDiscoveryActivity.java` — Public channel directory.
- `src/main/java/eu/siacs/conversations/ui/BlocklistActivity.java` — Blocked contacts.
- `src/main/java/eu/siacs/conversations/ui/AboutActivity.java` — About, licenses.
- `src/main/java/eu/siacs/conversations/ui/ImportBackupActivity.java` — Backup restore incl. `.ceb` intents.
- `src/main/java/eu/siacs/conversations/ui/ShareWithActivity.java` — System share target.
- `src/main/java/eu/siacs/conversations/ui/MediaBrowserActivity.java` — Chat media gallery.
- `src/main/java/eu/siacs/conversations/ui/MucUsersActivity.java` — Group member list.
- `src/main/java/eu/siacs/conversations/ui/ChooseContactActivity.java` — Contact picker.
- `src/main/java/eu/siacs/conversations/ui/ScanQrCodeActivity.java` — QR scan entry.
- `src/main/java/eu/siacs/conversations/ui/YuriLauncherActivity.java` — `xmpp:` / invite link dispatcher.
- `src/main/java/eu/siacs/conversations/ui/UnifiedPushDistributor.java` — UnifiedPush setup UI.

### Adapters

- `src/main/java/eu/siacs/conversations/ui/adapter/MessageAdapter.java` — Chat message list (bubbles, media, statuses).
- `src/main/java/eu/siacs/conversations/ui/adapter/ConversationAdapter.java` — Inbox rows (last message, unread, drafts).
- `src/main/java/eu/siacs/conversations/ui/adapter/MediaAdapter.java` — Media grid.
- `src/main/java/eu/siacs/conversations/ui/adapter/AccountAdapter.java` — Account list.
- `src/main/java/eu/siacs/conversations/ui/adapter/UserAdapter.java` — MUC/contact user rows.
- `src/main/java/eu/siacs/conversations/ui/adapter/ListItemAdapter.java` — Generic searchable rows.
- `src/main/java/eu/siacs/conversations/ui/adapter/ChannelSearchResultAdapter.java` — Channel search rows.

### UI Helpers

- `src/main/java/eu/siacs/conversations/ui/util/Attachment.java` — Attachment model (type, uri, transcoding).
- `src/main/java/eu/siacs/conversations/ui/util/ConversationMenuConfigurator.java` — Per-chat menu (mute, archive, security).
- `src/main/java/eu/siacs/conversations/ui/util/QuoteHelper.java` — Reply/quote builder.
- `src/main/java/eu/siacs/conversations/ui/util/AvatarWorkerTask.java` — Async avatar loading.
- `src/main/java/eu/siacs/conversations/ui/util/ScrollState.java` — List scroll-down FAB logic.
- `src/main/java/eu/siacs/conversations/ui/util/SendButtonAction.java`, `SendButtonTool.java` — Send/record button state.
- `src/main/java/eu/siacs/conversations/ui/util/ShareUtil.java` — Share/link helpers.
- `src/main/java/eu/siacs/conversations/ui/util/SettingsUtils.java` — Night mode / theme helpers.
- `src/main/java/eu/siacs/conversations/ui/widget/` — Custom views (scanner, bubbles, spans, audio recorder).
- `src/main/java/eu/siacs/conversations/ui/text/` — Message spans (quote, URL, divider).
- `src/main/java/eu/siacs/conversations/ui/interfaces/` — Activity/fragment callbacks (backend connected, conversation selected/read).

### Resources (Penik rebrand targets)

- `src/main/res/layout/` — ~70 screens: `activity_conversations`, `fragment_conversation`, `fragment_conversations_overview`, `activity_rtp_session`, `activity_edit_account`, `item_message_*`, `item_conversation`, `dialog_*`.
- `src/main/res/values/themes.xml` — `Theme.Conversations3` (+ Dark, Splash, Dialog, FullScreen); rebrand target `Theme.Penik`.
- `src/main/res/values/strings.xml` — `app_name` and all user strings.
- `src/main/res/values/colors-md.xml` — Material3 palette; rebrand target `penik_colors.xml`.
- `src/main/res/values/penik_colors.xml` — Penik light palette ported from `libs/Penik` `Color.kt` (`LightAppColors`).
- `src/main/res/values-night/penik_colors.xml` — Penik dark palette, default (`DarkAppColors`).
- `src/main/res/values/themes.xml` — Now also declares `Theme.Penik` and `Theme.Penik.Dark` on top of the Penik palette.
- `src/main/res/menu/` — Chat, MUC, contact, media, search menus.
- `src/main/res/xml/` — Preferences (`preferences_*.xml`), `shortcuts.xml`, `file_paths.xml`, `network_security_configuration.xml`, backup rules.
- `src/main/res/mipmap-*/`, `drawable-*/` — Launcher icons (`new_launcher` → Penik icon).

## Data & Persistence

- `src/main/java/eu/siacs/conversations/persistance/DatabaseBackend.java` — SQLite schema, accounts, messages, MUC, fingerprints.
- `src/main/java/eu/siacs/conversations/persistance/FileBackend.java` — Attachment files, encryption, thumbnails.
- `src/main/java/eu/siacs/conversations/persistance/UnifiedPushDatabase.java` — Push subscriptions store.
- `src/main/java/eu/siacs/conversations/entities/Account.java` — Account state machine.
- `src/main/java/eu/siacs/conversations/entities/Conversation.java` — 1:1 and MUC conversation aggregate.
- `src/main/java/eu/siacs/conversations/entities/Message.java` — Message with statuses, edits, reactions, attachments.
- `src/main/java/eu/siacs/conversations/entities/Contact.java`, `Roster.java` — Roster model.
- `src/main/java/eu/siacs/conversations/entities/MucOptions.java` — MUC roles, affiliation, subject, config.
- `src/main/java/eu/siacs/conversations/entities/Presences.java` — Presence map per contact.
- `src/main/java/eu/siacs/conversations/http/HttpConnectionManager.java` — Upload/download connection pool.
- `src/main/java/eu/siacs/conversations/http/HttpUploadConnection.java` — XEP-0363 slot PUT with progress.
- `src/main/java/eu/siacs/conversations/http/HttpDownloadConnection.java` — AES-GCM URL download.
- `src/main/java/eu/siacs/conversations/http/AesGcmURL.java` — `aesgcm://` URL crypto.

## Calls (Jingle/WebRTC)

- `src/main/java/eu/siacs/conversations/xmpp/jingle/JingleRtpConnection.java` — RTP session state machine.
- `src/main/java/eu/siacs/conversations/xmpp/jingle/RtpContentMap.java` — Audio/video content negotiation.
- `src/main/java/eu/siacs/conversations/xmpp/jingle/OngoingRtpSession.java` — Active call handle.
- `src/main/java/eu/siacs/conversations/xmpp/jingle/WebRTCWrapper.java` — WebRTC peer connection wrapper.
- `src/main/java/eu/siacs/conversations/xmpp/jingle/JingleFileTransferConnection.java` — Jingle file transfer.
- `src/main/java/eu/siacs/conversations/services/AppRTCAudioManager.java` — Call audio routing (speaker/BT).

## Product Flavors & Variants

- `src/conversations/java/.../ui/ManageAccountActivity.java` — Conversations account manager.
- `src/conversations/java/.../ui/WelcomeActivity.java`, `MagicCreateActivity.java`, `PickServerActivity.java` — Onboarding.
- `src/conversations/java/.../services/QuickConversationsService.java` — Quick setup service.
- `src/conversations/java/.../utils/SignupUtils.java` — Invite-based signup.
- `src/conversationsFree/`, `src/conversationsPlaystore/`, `src/playstore/`, `src/free/` — Push (FCM vs UnifiedPush), emoji init, install referrer.
- `src/quicksy*/` — Quicksy flavor (SMS verifier, separate branding).
- `src/test/` — Unit tests: JID, parsers, caps, reactions, scan results.

## Project Configuration & Docs

- `README.md` — Penik (XMPP) overview: changes vs upstream, stack, layout, build, server operator notes (5222/5223, S2S).
- `CHANGELOG.md` — Release history.
- `conversations.doap` — Project metadata.
- `fastlane/metadata/` — Play Store listings and screenshots (rebrand target).
- `docs/` — User docs (backup, migration).
- `art/` — Artwork sources.
- `.woodpecker.yml` — CI pipeline.
- `.gitmodules` — `libs/Penik` submodule (read-only UI donor, branch `feat/cloud-chats`).
- `plan/penik-xmpp-ui-port-plan.md` — Plan to port Penik UI and rebrand to `ru.penik.xmpp`.
- `PROJECT_MAP.md` — This index.

## Note on `libs/Penik` (Excluded)

`libs/Penik` is a read-only submodule containing the standalone Penik messenger (Go server, web client, Compose Android app). It is the UI donor for the port but is NOT part of this map and must not be edited. Its own map lives at `libs/Penik/PROJECT_MAP.md`. This map covers only the Conversations XMPP codebase that will be rebranded to `ru.penik.xmpp`.
