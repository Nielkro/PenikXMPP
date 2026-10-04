# План: диета XMPP-станз (E2EE выключен, сервер Snikket, совместимость с Monal/Dino)

## Цель

Снизить оверхед передачи сообщения `привет как дела` (полезная нагрузка 28 байт UTF-8) с сохранением 100% интеропа с Monal, Dino, Gajim.

| Вариант | Сейчас | После |
|---|---|---|
| 1:1, full-JID | 245 Б (оверхед 217 Б, 8.75x) | **~193 Б** (оверхед ~165 Б, 5.9x) |
| Penik cloud (ориентир) | 98–107 Б | — |

Разбор экономии −52 Б: `from` −28, UUID-36 → id-12 −24. `markable` (44 Б) и `request` (36 Б) НЕ трогаем: `DisplayedManager.java:151-158` шлёт `<displayed/>` только на markable-сообщения, Monal/Dino работают так же по XEP-0333 — без `markable` в 1:1 пропадут галочки прочтения.

MAM-синхронизация: ~491 → ~451 Б на сообщение (−8%, обёртка `result/forwarded/delay/stanza-id` фиксирована).

## Контекст

- Клиент: этот форк (Conversations), OMEMO на клиенте выключен, plaintext.
- Сервер: Snikket — SM, CSI (`csi_simple`), MAM, carbons, SASL2/Bind2/FAST уже включены из коробки. Серверных работ не требуется.
- Опционально и отдельно: `SNIKKET_TWEAK_REQUIRE_SASL2=1`, только если все клиенты SASL2-совместимы.

## Шаг 1. Убрать `from` — `generator/MessageGenerator.java:53`

- Удалить `packet.setFrom(account.getJid())` (и ставшую ненужной локальную переменную). По RFC 6120 section 8.1.2.1 сервер обязан подставить JID сам — Monal/Dino получат станзу с корректным `from` от Snikket/Prosody. Экономия ~28 Б.
- `request` и `markable` оставить без изменений (интероп галочек).

## Шаг 2. Короткие id сообщений + фикс Attachment

- Новый `utils/Random.shortId()`: 12 символов из unambiguous-алфавита на `SECURE_RANDOM` (~59 бит). RFC 6120 разрешает произвольную строку в `id`.
- Заменить `UUID.randomUUID()` в `entities/Message.java:152,185` (конструкторы) и `:563` (`putEdited`), плюс `parser/MessageParser.java:597`.
- `ui/util/Attachment.java`: поле `uuid` с `UUID` на `String` (`UUID.fromString(message.getUuid())` в `:59` и `:156` упадёт на коротких id). Затронуты: `FileBackend.java:547` (`.toString()` на границе с `FilePath`, таблица файлов не меняется), `ui/adapter/MediaAdapter.java:111,376` (`Set/Collection<String>`), `ui/MediaBrowserActivity.java:184` (убрать `UUID::fromString`).
- Экономия ~24 Б. `CryptoHelper.UUID_PATTERN` (`Message.java:737`) применяется только к входящим `remoteMsgId`, не трогаем.

## Шаг 3. Троттлинг chat-states — `xmpp/manager/ChatStateManager.java:114`

- В приватный `sendChatState`: `Composing` не чаще 1 раза в 8 с (`SystemClock.elapsedRealtime`, карта `lastComposingSent`). `Paused/Active/Gone/Inactive` редкие — пропускать всегда. Дедуплика одинаковых состояний (`setOutgoingChatState`) уже есть, троттлинг режет flapping composing→paused→composing.
- Monal/Dino держат плашку «печатает» 8–10 с от последнего пакета — совместимо.
- Эффект: −10–15 станз по ~130 Б за сессию печати + меньше пробуждений LTE-модема.

## Шаг 4. MAM-страницы — `Config.java:63`

- `PAGE_SIZE` 50 → 20. Одна константа, только наш клиент. Быстрее первый экран, меньше памяти (`PAGE_SIZE * MAX_NUM_PAGES`), меньше полных ретраев пачки на рваной сети.

## Шаг 5. Проверка и замер

- Отправить `привет как дела`, снять станзу из лога (logcat) — сверить ~193 Б.
- Регресс: receipt/displayed в 1:1 с Monal/Dino, replace/edit по id, MAM-история, маркеры в MUC, отправка/просмотр файлов (Attachment), шаринг из MediaBrowser.
- Коммиты по шагам, scope `xmpp`/`chat`.

## Порядок и риски

Шаги 1→4 отдельными коммитами. Основной риск — шаг 2 (касается файлов и медиа-селектора), тестировать отправку файлов отдельно. Серверный lua-модуль Snikket — только если появятся сторонние клиенты, отдельным пунктом.
