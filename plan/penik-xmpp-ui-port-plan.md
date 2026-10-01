# План: UI Penik → Conversations + ребрендинг в ru.penik.xmpp

## 0. Цель и исходное состояние

**Цель:**
1. Скопировать UI из Penik в Conversations.
2. Переименовать Conversations в Penik с `applicationId = ru.penik.xmpp`.

**Исходное состояние (только чтение Penik):**
- Корень `PenikXMPP/` — форк Conversations:
  - `build.gradle`: `namespace = 'eu.siacs.conversations'`, `applicationId = 'eu.siacs.conversations'`, `rootProject.name = 'Conversations'`.
  - `src/main/` — Views + XML, Java.
- Донор UI (READ ONLY, не менять): `libs/Penik`:
  - `libs/Penik/android/app/src/main/java/niel/kro/penik/ui/` — `theme/`, `navigation/`, `screen/`, `components/`, `call/`, `notification/`.
  - Тема: `ui/theme/Color.kt`, `Theme.kt` (Circular Reveal 650ms).

**Ограничение:** прямое копирование `.kt` невозможно. Стек разный (Views/XMPP vs Compose/REST+WS). Копируем только визуал, логику подключаем к XMPP.

## Фаза 1 — Ребрендинг в ru.penik.xmpp

1. `build.gradle`: `namespace = 'ru.penik.xmpp'`, `applicationId = 'ru.penik.xmpp'`, `appName = "Penik"`. Решить судьбу `quicksy` flavor.
2. `settings.gradle`: `rootProject.name = 'Penik'`.
3. `src/main/AndroidManifest.xml`: FileProvider `${applicationId}.files/.barcodes`, заменить `eu.siacs.conversations.*`, `conversations.im/i|j`, `invite.joinjabber.org` на свой хост, поправить parent в `AboutActivity`.
4. Замена: `eu.siacs.conversations` → `ru.penik.xmpp`, `Conversations` → `Penik` (`strings.xml app_name`, `fastlane/metadata/`, иконки `mipmap/new_launcher`, `conversations.doap`).
5. Проверка: `assembleConversationsFreeDebug` без конфликта со старым ID.

## Фаза 2 — Дизайн-токены Penik

1. Создать `src/main/res/values/penik_colors.xml` + `values-night/` из `Color.kt`.
2. `themes.xml`: новый `Theme.Penik` на `Theme.Material3.*.NoActionBar`, `colorPrimary=Accent`, `surface=Panel`.
3. Шрифты/радиусы из `Type.kt` и `ShapeAppearance` → стили бабблов и инпутов.
4. `ThemeManager` портировать как helper для `AppCompatDelegate` или Compose `PenikTheme`.

## Фаза 3 — Порт экранов (только UI)

| Penik (read-only) | Conversations | Действие |
|---|---|---|
| `ChatsListScreen` | `ConversationsOverviewFragment` | список, аватары по JID, FAB |
| `ChatRoomScreen` + `Components.kt` | `ConversationFragment` | бабблы, Markdown, эмодзи 1-3 без пузыря |
| `GroupsList` / `GroupChat` / `GroupSettings` | MUC | список, приглашения, роли |
| `AuthScreen` | `EditAccountActivity` | стилизация логина |
| `ProfileScreen` + `AvatarCropDialog` | `PublishProfilePictureActivity` | кроп аватара |
| `SettingsScreen` + `DevicesScreen` | `SettingsActivity` | свитч темы, Drawer/BottomBar |
| `CallsListScreen` + `CallOverlayScreen` | `RtpSessionActivity` | оверлей, PiP, reconnect-бейдж |
| `MainScreen` | `ConversationsActivity` | NavGraph → Navigation Component |
| `AttachmentPickerBottomSheet`, `Stickers` | `ShareWithActivity` | bottom-sheet, табы |
| `AppNotificationManager`, Receivers | `NotificationService` | `MessagingStyle`, `ru.penik.xmpp.action.*` |

## Фаза 4 — Сборка

1. В `build.gradle` добавить Compose BOM, `activity-compose`, `navigation-compose`, Hilt, Coil, Media3 (версии из `libs/Penik/android/gradle/libs.versions.toml`).
2. `buildFeatures { compose = true }`, `minSdk 23` → `26`, выровнять Java 21/11 и desugaring.

## Фаза 5 — Навигация, звонки, пуши

1. Навигация: Compose `NavGraph` внутри `ConversationActivity` или оставить Activity-стек.
2. Звонки: Jingle оставить, скопировать только оверлей UI (LiveKit E2EE не переносится).
3. Пуши: `google-services.json` для `ru.penik.xmpp`, FCM ключ.
4. Добавить `READ_MEDIA_IMAGES/VIDEO`, `USE_FULL_SCREEN_INTENT` в манифест.

## Фаза 6 — Тест и релиз

1. `lint`, `assembleConversationsFreeDebug/Release`.
2. Чек: логин XMPP, 1-1 чат, группа, звонок, смена темы, иконка, нотификация, бэкап `.ceb`.
3. Подпись release-ключом, `fastlane` скриншоты.
4. Удалить `quicksy*` sourceSets если не нужны. `libs/Penik` не трогать.

## Риски

- Смена ID ломает authorities, бэкапы, шорткаты.
- `MessageRepository/UseCases` Penik нельзя копировать — другой протокол.
- Jingle ≠ LiveKit, SQLCipher/Room ≠ SQLite Conversations — базы не мигрируют.
