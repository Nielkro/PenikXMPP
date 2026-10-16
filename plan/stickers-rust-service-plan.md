# План реализации стикеров в PenikXMPP на базе Rust-микросервиса (v2)

## 1. Архитектурный обзор

Система стикеров объединяет легковесный автономный Rust-микросервис для хранения, каталогизации и импорта стикерпаков, расширение XMPP-станз сообщений с обратной совместимостью (XEP-0066 OOB) и Compose UI в Android-клиенте с аппаратным рендерингом нативных форматов.

```mermaid
flowchart TD
    subgraph Telegram["Telegram Cloud"]
        TGBot["Telegram Bot API\n(getStickerSet / getFile)"]
    end

    subgraph Backend["Rust Микросервис (penik-stickers-rs)"]
        API["Axum HTTP Server\n(:8085 /api/v1/stickers)"]
        Auth["Auth Middleware\n(Bearer HMAC-SHA256 Token)"]
        RateLimit["Rate Limiter (Tower Governor)\n(3 req/min на JID)"]
        DB[(SQLite WAL\npacks, stickers, user_packs)]
        Storage[("Файловое хранилище\n/data/stickers/{pack_id}/\n(файлы + предсобранный bundle.zip)")]
        Packager["Static Bundler\n(Однократная сборка bundle.zip при импорте)"]
    end

    subgraph XMPP["Сервер Snikket / Prosody"]
        C2S["XMPP Stream (:5222 / :5223)\nmod_funxmpp"]
        TokenGen["Генерация Auth Token\n(HMAC по Shared Secret)"]
    end

    subgraph Client["Penik Android Client"]
        StickerPicker["Compose Sticker Keyboard\n(Сетка, табы, недавние)"]
        StickerCache["Локальный кэш бандлов\n(cache/stickers/{pack_id}/)"]
        ChatRenderer["Рендерер стикеров в чате\n(WebP: Coil, WebM: MediaCodec/ExoPlayer, TGS: Lottie)"]
        StickerModel["XMPP Парсер/Генератор\n(<sticker xmlns='penik:stickers:0'/>)"]
    end

    Client -->|1. Запрос токена / XMPP| C2S
    C2S --> TokenGen
    Client -->|2. Авторизованный HTTP API (Bearer)| Auth
    Auth --> RateLimit
    RateLimit --> API
    API -->|Проверка telegram_name| DB
    API -->|Загрузка новых файлов| TGBot
    TGBot --> Storage
    Storage --> Packager
    Packager -->|Готовый bundle.zip на диск| Storage
    Storage -->|Скачивание bundle.zip целиком| StickerCache

    StickerPicker -->|3. Отправка стикера| StickerModel
    StickerModel -->|4. XMPP Message со <sticker>| C2S
    C2S -->|5. Доставка сообщения| Client
    Client -->|6. Нативный рендеринг из кэша/URL| ChatRenderer
```

---

## 2. Ключевые архитектурные решения

### 2.1. Отказ от транскодирования WebM в Animated WebP (Zero-Transcoding)
- **Проблема:** WebM видеостикеры сжаты кодеком VP9 с прозрачностью (альфа-каналом). Крэйт `image` не декодирует WebM-контейнеры. Добавление `ffmpeg` разрушает идею легковесного статического Rust-бинарника. Кроме того, Animated WebP при сопоставимом качестве весит в **3–5 раз больше**, а кодирование пака из 50 стикеров полностью парализует CPU одноядерного VPS на несколько минут.
- **Решение:**
  - **Rust-микросервис сохраняет и отдаёт оригинальные файлы как есть:**
    - Статические стикеры: `image/webp`.
    - Анимированные векторные: `application/x-tgsticker` (TGS) или распакованный JSON Lottie.
    - Видеостикеры: `video/webm` (VP9 + альфа).
  - Никакого перекодирования на сервере — микросервис работает как сверхбыстрый асинхронный I/O диспетчер.
  - **На Android:**
    - Статический WebP отображается через Coil (`AsyncImage`).
    - TGS/Lottie рендерится через `lottie-compose`.
    - WebM видеостикеры рендерятся аппаратно через Android `MediaCodec` / легковесный SurfaceView плеер на базе Media3 ExoPlayer с аппаратным VP9 декодером. Это гарантирует 60 FPS, экономит батарею смартфона и исключает лаги в списках `LazyVerticalGrid`.

---

### 2.2. Защита и авторизация REST API
- **Проблема:** Передача `?jid={user_jid}` в query-параметрах открывает критическую уязвимость: любой желающий может удалять/устанавливать чужие стикерпаки и вызывать DoS сервиса через `/import/telegram`.
- **Решение:**
  - Все модифицирующие и персональные эндпоинты защищены заголовком `Authorization: Bearer <token>`.
  - Токен формируется по схеме **HMAC-SHA256**:
    `token = base64(jid + ":" + expires_at + ":" + hmac_sha256(jid + ":" + expires_at, shared_secret))`
    где `shared_secret` известен только серверу XMPP/Snikket и Rust-микросервису.
  - Микросервис валидирует подпись и срок жизни токена в Axum middleware, извлекая `user_jid` из проверенного контекста.
  - На эндпоинт `/api/v1/stickers/import/telegram` накладывается Rate Limiter (`tower_governor`) с ограничением: не более 3 запросов на импорт в минуту от одного `user_jid` / IP.

---

### 2.3. Однократная генерация `bundle.zip` и дедупликация
- **Проблема:** Сборка ZIP-архива «на лету» при каждом клиентском скачивании нерационально тратит память и такты процессора.
- **Решение:**
  - При импорте пака архив `bundle.zip` генерируется **ровно один раз** и сохраняется на диск: `/data/stickers/{pack_id}/bundle.zip`.
  - Эндпоинт `GET /api/v1/stickers/pack/{id}/bundle.zip` отдаёт готовый файл с диска со стандартными заголовками `ETag`, `Last-Modified` и поддержкой `304 Not Modified`. Раздачу можно без изменений вынести на reverse-proxy (Caddy / Nginx).
  - В таблице `sticker_packs` колонка `telegram_name TEXT UNIQUE`: повторный запрос на импорт пака с тем же именем моментально возвращает существующую запись из базы без лишних обращений к Telegram Bot API.

---

### 2.4. Приватность и XMPP-станзы
- В Penik сквозное шифрование OMEMO по умолчанию отключено (follower-only режим, весь чат открытый). Поэтому передача метаданных стикера в корневом теге `<sticker xmlns='penik:stickers:0'/>` и fallback-ссылки в `<x xmlns='jabber:x:oob'>` полностью легитимна.
- Если в будущем OMEMO активируется для конкретного диалога, генератор станз клиента упакует тег `<sticker>` внутрь шифруемого содержимого (payload), чтобы скрыть идентификатор стикера и URL от промежуточных узлов.

---

## 3. Спецификация Rust-микросервиса (`server/penik-stickers-rs`)

### 3.1. Стек и зависимости
- Язык: Rust (2021 edition).
- Асинхронный рантайм: `tokio`.
- HTTP-сервер: `axum` + `tower` + `tower-http` (файловый стриминг, сжатие gzip/brotli, CORS).
- Rate Limiting: `tower_governor`.
- База данных: `sqlx` со встроенным SQLite (WAL-режим, пул соединений).
- HTTP-клиент: `reqwest` (TLS native-tls / rustls).
- Архивация: `zip` (однократная упаковка при импорте).
- Безопасность: `hmac` + `sha2`.

### 3.2. Схема базы данных (SQLite)
```sql
CREATE TABLE IF NOT EXISTS sticker_packs (
    id TEXT PRIMARY KEY,
    telegram_name TEXT UNIQUE,
    title TEXT NOT NULL,
    author_jid TEXT NOT NULL DEFAULT '',
    cover_sticker_id TEXT NOT NULL DEFAULT '',
    format TEXT NOT NULL DEFAULT 'static', -- 'static' (webp), 'animated' (tgs), 'video' (webm)
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_packs_tg_name ON sticker_packs(telegram_name);

CREATE TABLE IF NOT EXISTS stickers (
    id TEXT PRIMARY KEY,
    pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    emoji TEXT NOT NULL DEFAULT '',
    file_name TEXT NOT NULL,
    width INTEGER NOT NULL DEFAULT 512,
    height INTEGER NOT NULL DEFAULT 512,
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_stickers_pack ON stickers(pack_id, sort_order);

CREATE TABLE IF NOT EXISTS user_sticker_packs (
    user_jid TEXT NOT NULL,
    pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    installed_at INTEGER NOT NULL,
    PRIMARY KEY (user_jid, pack_id)
);
CREATE INDEX IF NOT EXISTS idx_user_packs ON user_sticker_packs(user_jid, sort_order);
```

### 3.3. REST API Эндпоинты

| Метод | Путь | Авторизация | Описание |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/stickers/my` | Bearer Token | Список установленных паков пользователя (из `user_jid` токена). |
| `GET` | `/api/v1/stickers/pack/{id}` | Опционально | Полные метаданные пака и список всех стикеров. |
| `POST` | `/api/v1/stickers/pack/{id}/install` | Bearer Token | Добавить пак в личную коллекцию пользователя. |
| `DELETE` | `/api/v1/stickers/pack/{id}/install` | Bearer Token | Удалить пак из личной коллекции. |
| `POST` | `/api/v1/stickers/import/telegram` | Bearer Token + RateLimit | Импорт пака по ссылке `t.me/addstickers/{name}`. |
| `GET` | `/api/v1/stickers/pack/{id}/bundle.zip` | Публично (кэш) | Скачивание предсобранного ZIP-архива всего пака. |
| `GET` | `/api/v1/stickers/file/{pack_id}/{file}` | Публично (кэш) | Раздача отдельного стикера (`.webp`, `.tgs`, `.webm`). |

---

## 4. XMPP Протокол (Формат передачи)

```xml
<message to='contact@snikket.penik.ru' type='chat' id='stk_918237'>
  <body>[Стикер: 🔥]</body>
  <sticker xmlns='penik:stickers:0'
           pack_id='tg_meme_cats'
           sticker_id='cat_fire'
           emoji='🔥'
           width='512'
           height='512'
           format='video'
           url='https://snikket.penik.ru/api/v1/stickers/file/tg_meme_cats/cat_fire.webm'/>
  <!-- XEP-0066 Out of Band Data для сторонних клиентов -->
  <x xmlns='jabber:x:oob'>
    <url>https://snikket.penik.ru/api/v1/stickers/file/tg_meme_cats/cat_fire.webm</url>
  </x>
</message>
```

- В FunXMPP элементы `sticker`, `pack_id`, `sticker_id`, `emoji`, `width`, `height`, `format`, `url` кодируются как компактные строковые литералы либо токенизируются в версии 2.

---

## 5. Android Клиент (Jetpack Compose & Storage)

### 5.1. Хранилище и кэш (`StickerManager.kt`)
1. **Директория хранения:** `context.filesDir/stickers/{pack_id}/`.
2. **Фоновая установка:**
   - Клиент вызывает `POST /api/v1/stickers/pack/{id}/install`.
   - В фоне через `WorkManager` скачивается `bundle.zip` и распаковывается в `filesDir/stickers/{pack_id}/`.
   - Метаданные пака сохраняются локально (JSON / Room).
3. **Открытие чата:** Стикер мгновенно отдаётся из локального файла. Если пак не установлен локально у получателя, файл стримится по HTTP URL с сохранением во временный LRU-кэш.

### 5.2. Рендеринг стикеров в чате (`PenikChatRoom.kt`)
- `PenikStickerBubble`:
  - Прозрачный фон без декоративных рамок текстового пузыря.
  - Фиксированный размер: 180–220 dp с сохранением aspect ratio.
  - В зависимости от `format`:
    - `static`: Coil `AsyncImage`.
    - `animated`: `com.airbnb.android.lottie:lottie-compose` (TGS/Lottie).
    - `video`: Легковесный Compose-компонент поверх Media3/ExoPlayer (автоплей, бесконечный цикл, аппаратное декодирование VP9).
  - Индикатор доставки (одиночная/двойная галочка) на полупрозрачной подложке в нижнем правом углу.

### 5.3. Клавиатура стикеров (`PenikStickerPicker.kt`)
- Вкладки установленных паков с иконками обложек (горизонтальный скролл).
- Вкладка «Недавние» (история последних 30 отправленных стикеров).
- Сетка стикеров (4 колонки).
- Диалог добавления пака: ввод ссылки Telegram `t.me/addstickers/...` с индикатором прогресса загрузки.

---

## 6. Пошаговые этапы реализации

### Этап 1: Rust-микросервис (`server/penik-stickers-rs`)
1. Инициализировать проект `cargo new --bin server/penik-stickers-rs`.
2. Настроить Axum, SQLite миграции (`packs`, `stickers`, `user_packs`), HMAC middleware.
3. Реализовать клиент Telegram Bot API (`getStickerSet`, скачивание файлов через `getFile`).
4. Реализовать сборку `bundle.zip` при импорте и сохранение на диск.
5. Реализовать отдачу статических файлов с ETag и кэшированием.
6. Написать юнит-тесты на проверку HMAC-авторизации, идемпотентности импорта по `telegram_name` и генерации zip.

### Этап 2: Интеграция с XMPP-протоколом
1. Создать XML-модель стикера и интеграцию в `MessageParser.java` / `MessageGenerator.java`.
2. Реализовать провайдер временных HMAC-токенов в Prosody (`mod_funxmpp` или отдельный хук) либо локальный генератор на клиенте при наличии общего секрета.
3. Протестировать парсинг и генерацию станз со стикерами в `FunProtocolTest.java`.

### Этап 3: Менеджер кэширования и загрузки (Android)
1. Реализовать `StickerManager.kt` (HTTP клиент к сервису стикеров, скачивание и распаковка `bundle.zip`).
2. Настроить локальное сохранение метаданных и истории недавних стикеров.

### Этап 4: Jetpack Compose UI
1. Реализовать `PenikStickerPicker.kt` (табы паков, сетка, кнопка импорта).
2. Реализовать `PenikStickerBubble.kt` для рендеринга в `PenikChatRoom.kt` с поддержкой WebP, TGS и WebM (ExoPlayer).
3. Добавить кнопку переключения на стикеры в поле ввода сообщения.

### Этап 5: Сборка, Docker и верификация
1. Подготовить `server/penik-stickers-rs/Dockerfile` для простого деплоя на сервере.
2. Провести E2E-тестирование: импорт пака из Telegram -> скачивание бандла на Android -> отправка стикера в чат -> отображение у собеседника.
3. Обновить `PROJECT_MAP.md`.
